const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenIterator = tokenizer.TokenIterator;
const Builtins = @import("builtins.zig");
const Aliases = Builtins.Aliases;
const Variables = @import("variables.zig");

pub const Error = error{
    Unknown,
    Memory,
    ParseFailed,
    OpenGroup,
    Empty,
};

/// In effect a duplicate of std.mem.split iterator
pub const ParsedIterator = struct {
    // I hate that this requires an allocator :( but the ratio of thinking
    // to writing is already too high
    alloc: *Allocator,
    tokens: []Token,
    index: ?usize,
    subtokens: ?[]TokenIterator,
    resolved: [][]const u8,
    const Self = @This();

    /// Restart iterator, and assumes length >= 1
    pub fn first(self: *Self) *const Token {
        self.restart();
        return self.next().?;
    }

    pub fn peek(self: *Self) ?*const Token {
        const i = self.index;
        defer self.index = i;
        return self.next();
    }

    /// Returns next Token, omitting, or splitting them as needed.
    pub fn next(self: *Self) ?*const Token {
        const i = self.index orelse return null;
        if (i >= self.tokens.len) {
            self.restart();
            self.index = null;
            return null;
        }

        const token = &self.tokens[i];

        if (self.subtokens) |_| return self.nextSubtoken(token);

        if (i == 0 and token.kind == .String) {
            if (self.nextSubtoken(token)) |tk| return tk;
            return token;
        } else {
            switch (token.kind) {
                .WhiteSpace, .IoRedir, .Operator => {
                    self.index.? += 1;
                    return self.next();
                },
                else => {},
            }
        }
        defer self.index.? += 1;
        return token;
    }

    fn dropSubtoken(self: *Self) void {
        if (self.subtokens) |subtkns| {
            const l = subtkns.len;
            for (subtkns[0 .. l - 1], subtkns[1..]) |*dst, src| {
                dst.* = src;
            }
            self.subtokens = self.alloc.realloc(subtkns, subtkns.len - 1) catch unreachable;
        }
    }

    fn nextSubtoken(self: *Self, token: *const Token) ?*const Token {
        if (self.subtokens) |subtkns| {
            if (subtkns.len == 0) {
                self.subtokens = null;
                self.index.? += 1;
                return self.next();
            }

            if (subtkns[0].next()) |n| {
                return n;
            } else {
                self.dropSubtoken();
                return self.nextSubtoken(token);
            }
        } else {
            self.resolve(token);
            if (self.subtokens) |sts| {
                return sts[0].first();
            }
            defer self.index.? += 1;
            return token;
        }
    }

    fn resolvedAdd(self: *Self, str: []const u8) void {
        self.resolved = self.alloc.realloc(self.resolved, self.resolved.len + 1) catch unreachable;
        self.resolved[self.resolved.len - 1] = str;
    }

    fn resolve(self: *Self, token: *const Token) void {
        if (self.index) |index| {
            if (index == 0) {
                return self.resolveAlias(token);
            } else unreachable;
        }
    }

    fn resolveAlias(self: *Self, token: *const Token) void {
        for (self.resolved) |res| {
            if (std.mem.eql(u8, token.cannon(), res)) {
                return;
            }
        }
        self.resolvedAdd(token.cannon());
        if (Parser.alias(token)) |als| {
            if (self.subtokens) |sub| {
                self.subtokens = self.alloc.realloc(sub, sub.len + 1) catch unreachable;
            } else {
                self.subtokens = self.alloc.alloc(TokenIterator, 1) catch unreachable;
            }
            self.subtokens.?[self.subtokens.?.len - 1] = als;
            var owned = &self.subtokens.?[self.subtokens.?.len - 1];
            self.resolve(owned.*.first());
        } else |e| {
            if (e != Error.Empty) {
                std.debug.print("alias errr {}\n", .{e});
                unreachable;
            }
        }
    }

    /// Resets the iterator to the initial slice.
    pub fn restart(self: *Self) void {
        self.index = 0;
        if (self.resolved.len > 0) {
            self.alloc.free(self.resolved);
        }
        self.resolved = self.alloc.alloc([]u8, 0) catch @panic("Alloc 0 can't fail");
        if (self.subtokens) |ts| {
            self.alloc.free(ts);
            self.subtokens = null;
        }
    }

    /// Alias for restart to free stored memory
    pub fn close(self: *Self) void {
        self.restart();
    }
};

pub const Parser = struct {
    alloc: Allocator,

    pub fn parse(a: *Allocator, tokens: []Token) Error!ParsedIterator {
        if (tokens.len == 0) return Error.Empty;
        for (tokens) |*tk| {
            _ = single(a, tk) catch unreachable;
        }
        _ = builtin(&tokens[0]) catch {};
        return ParsedIterator{
            .alloc = a,
            .tokens = tokens,
            .index = 0,
            .subtokens = null,
            .resolved = a.alloc([]u8, 0) catch return Error.Memory,
        };
    }

    fn single(a: *Allocator, token: *Token) Error!*Token {
        if (token.raw.len == 0) return token;

        switch (token.kind) {
            .Quote => {
                var needle = [2]u8{ '\\', token.subtoken };
                if (mem.indexOfScalar(u8, token.raw, '\\')) |_| {} else return token;

                _ = token.upgrade(a) catch return Error.Unknown;
                var i: usize = 0;
                const backing = &token.backing.?;
                while (i + 1 < backing.items.len) : (i += 1) {
                    if (backing.items[i] == '\\') {
                        if (mem.indexOfAny(u8, backing.items[i + 1 .. i + 2], &needle)) |_| {
                            _ = backing.orderedRemove(i);
                        }
                    }
                }
                return token;
            },
            .Var => {
                return try variable(token);
            },
            .String => {
                if (mem.indexOf(u8, token.raw, "/")) |_| {
                    token.kind = .Path;
                    return token;
                } else return token;
            },
            .Path => {
                if (token.cannon()[0] != '~') return token;

                _ = token.upgrade(a) catch return Error.Unknown;
                return try path(token);
            },
            else => {
                switch (token.raw[0]) {
                    '$' => return token,
                    else => return token,
                }
            },
        }
    }

    fn resolve(token: *Token) Error!*Token {
        _ = try alias(token);
        _ = try builtin(token);
        return token;
    }

    fn alias(token: *const Token) Error!TokenIterator {
        if (Aliases.find(token.cannon())) |a| {
            return TokenIterator{ .raw = a.value };
        }
        return Error.Empty;
    }

    fn builtin(tkn: *Token) Error!*Token {
        if (Builtins.exists(tkn.cannon())) {
            tkn.*.kind = .Builtin;
            return tkn;
        }
        return Error.Empty;
    }

    fn variable(tkn: *Token) Error!*Token {
        if (Variables.get(tkn.cannon())) |v| {
            tkn.resolved = v;
        }
        return tkn;
    }

    fn path(tkn: *Token) Error!*Token {
        if (Variables.get("HOME")) |v| {
            tkn.backing.?.clearRetainingCapacity();
            tkn.backing.?.appendSlice(v) catch return Error.Memory;
            tkn.backing.?.appendSlice(tkn.raw[1..]) catch return Error.Memory;
        }
        return tkn;
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
test "quotes parsed" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"\"");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);

    try expectEql(t.raw.items.len, 2);
    try expectEql(tokens.len, 1);
    a.free(tokens);

    t.reset();
    try t.consumes("\"a\"");
    titr = t.iterator();
    tokens = try titr.toSlice(a);

    try expectEql(t.raw.items.len, 3);
    try expect(std.mem.eql(u8, t.raw.items, "\"a\""));
    try expectEql(tokens[0].cannon().len, 1);
    try expect(std.mem.eql(u8, tokens[0].cannon(), "a"));
    a.free(tokens);

    t.reset();
    try t.consumes("\"this is some text\" more text");
    titr = t.iterator();
    tokens = try titr.toSlice(a);

    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));
    a.free(tokens);

    t.reset();
    try t.consumes("`this is some text` more text");
    titr = t.iterator();
    tokens = try titr.toSlice(a);

    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].raw, "`this is some text`"));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));
    a.free(tokens);

    t.reset();
    try t.consumes("\"this is some text\" more text");
    titr = t.iterator();
    tokens = try titr.toSlice(a);

    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));
    a.free(tokens);

    t.reset();
    try t.consumes("\"this is some text\\\" more text\"");
    titr = t.iterator();
    tokens = try titr.toSlice(a);

    try expectEql(t.raw.items.len, 31);
    try expect(std.mem.eql(u8, tokens[0].raw, "\"this is some text\\\" more text\""));
    a.free(tokens);
}

test "quotes parse complex" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    const invalid =
        \\"this is some text\\" more text"
    ;
    try t.consumes(invalid);
    try expectEql(t.raw.items.len, 32);

    //var itr = t.iterator();
    //var err = itr.toSliceError(a);
    //try expectError(Error.InvalidSrc, err); // TODO use OpenGroup
    //try expectEql(t.err_idx, t.raw.items.len - 1);

    t.reset();
    const valid =
        \\"this is some text\\" more text
    ;
    try t.consumes(valid);
    try expectEql(t.raw.items.len, 31);

    var titr = t.iterator();
    var tokens = try titr.toSlice(a);

    try expectEql(tokens.len, 3);
    try expectEql(tokens[0].raw.len, 21);
    const raw =
        \\"this is some text\\"
    ;
    try expect(std.mem.eql(u8, tokens[0].raw, raw));
    //const cannon =
    //    \\this is some text\
    //;
    //try expectEql(tokens[0].cannon().len, 18);
    //try expect(std.mem.eql(u8, tokens[0].cannon(), cannon));
    a.free(tokens);

    t.reset();
    try t.consumes("'this is some text' more text");
    titr = t.iterator();
    tokens = try titr.toSlice(a);

    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].raw, "'this is some text'"));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));
    t.reset();
    a.free(tokens);
}

test "iterator nows" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"this is some text\" more text");
    var itr = t.iterator();
    var ts = try itr.toSlice(a);
    defer a.free(ts);
    var ptr = try Parser.parse(&a, ts);
    var i: usize = 0;
    while (ptr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 3);
}

test "iterator alias is builtin" {
    var a = std.testing.allocator;

    var ts = [_]Token{
        Token{ .kind = .String, .raw = "alias" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 1);
    try std.testing.expectEqualStrings("alias", itr.first().cannon());
    try expect(itr.next() == null);
    try std.testing.expect(itr.first().kind == .Builtin);
}

test "iterator aliased" {
    var a = std.testing.allocator;
    var als = Aliases.testing_setup(a);
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .String, .raw = "la" },
        Token{ .kind = .WhiteSpace, .raw = " " },
        Token{ .kind = .String, .raw = "src" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().cannon(), "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try expect(eql(u8, itr.next().?.cannon(), "src"));
    try expect(itr.next() == null);
}

test "iterator aliased self" {
    var a = std.testing.allocator;
    var als = Aliases.testing_setup(a);
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .String, .raw = "ls" },
        Token{ .kind = .WhiteSpace, .raw = " " },
        Token{ .kind = .String, .raw = "src" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().cannon(), "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try std.testing.expectEqualStrings("src", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "iterator aliased recurse" {
    var a = std.testing.allocator;
    var als = Aliases.testing_setup(a);
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls --color=auto") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .String, .raw = "la" },
        Token{ .kind = .WhiteSpace, .raw = " " },
        Token{ .kind = .String, .raw = "src" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 4);
    var first = itr.first().cannon();
    try expect(eql(u8, first, "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try expect(eql(u8, itr.next().?.cannon(), "--color=auto"));
    try expect(eql(u8, itr.next().?.cannon(), "src"));
    try expect(itr.next() == null);
}

const eqlStr = std.testing.expectEqualStrings;

test "parse vars" {
    var a = std.testing.allocator;

    comptime var ts = [3]Token{
        try Tokenizer.any("echo"),
        try Tokenizer.any("$string"),
        try Tokenizer.any("blerg"),
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);
    try eqlStr("string", itr.peek().?.cannon());
    try expect(itr.next().?.kind == .Var);
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing" {
    var a = std.testing.allocator;

    comptime var ts = [3]Token{
        try Tokenizer.any("echo"),
        try Tokenizer.any("$string"),
        try Tokenizer.any("blerg"),
    };

    Variables.init(a);
    defer Variables.raze();

    try Variables.put("string", "value");

    try eqlStr("value", Variables.get("string").?);

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);
    try eqlStr("value", itr.peek().?.cannon());
    try expect(itr.next().?.kind == .Var);
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo ${string}extra blerg",
    };

    Variables.init(a);
    defer Variables.raze();

    try Variables.put("string", "value");

    try eqlStr("value", Variables.get("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 4);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    // the following is a bug, itr[1] should be "valueextra"
    // It's possible I may disallow this outside of double quotes
    try eqlStr("value", itr.peek().?.cannon());
    try expect(itr.next().?.kind == .Var);
    try eqlStr("extra", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces inline" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string} blerg",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("string", "value");

    try eqlStr("value", Variables.get("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 4);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("extra", itr.next().?.cannon());
    try eqlStr("value", itr.peek().?.cannon());
    try expect(itr.next().?.kind == .Var);
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse path" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    try std.testing.expect(itr.next().?.kind == .Path);
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.backing) |*b| b.clearAndFree();
    }
}

test "parse path ~" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    try std.testing.expect(itr.peek().?.kind == .Path);
    try eqlStr("/home/user", itr.next().?.cannon());
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.backing) |*b| b.clearAndFree();
    }
}

test "parse path ~/" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    try std.testing.expect(itr.peek().?.kind == .Path);
    try eqlStr("/home/user/", itr.next().?.cannon());
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.backing) |*b| b.clearAndFree();
    }
}

test "parse path ~/place" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/place",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    try std.testing.expect(itr.peek().?.kind == .Path);
    try eqlStr("/home/user/place", itr.next().?.cannon());
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.backing) |*b| b.clearAndFree();
    }
}

test "parse path /~/otherplace" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls /~/otherplace",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    try std.testing.expect(itr.peek().?.kind == .Path);
    try eqlStr("/~/otherplace", itr.next().?.cannon());
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.backing) |*b| b.clearAndFree();
    }
}
