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
const fs = @import("fs.zig");

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

        if (i == 0 and token.kind == .word) {
            if (self.nextSubtoken(token)) |tk| return tk;
            return token;
        } else {
            switch (token.kind) {
                .ws, .io, .oper => {
                    self.index.? += 1;
                    return self.next();
                },
                .word => {
                    if (self.nextSubtoken(token)) |tk| return tk;
                },
                else => {},
            }
        }
        defer self.index.? += 1;
        return token;
    }

    fn subtokensDel(self: *Self) bool {
        if (self.subtokens) |subtkns| {
            const l = subtkns.len;
            self.alloc.free(subtkns[0].raw);
            for (subtkns[0 .. l - 1], subtkns[1..]) |*dst, src| {
                dst.* = src;
            }
            self.subtokens = self.alloc.realloc(subtkns, subtkns.len - 1) catch unreachable;
        }
        if (self.subtokens) |st| {
            return st.len > 0;
        }
        return false;
    }

    fn subtokensDupe(self: *Self, str: []const u8) !void {
        const raw = try self.alloc.dupe(u8, str);
        return self.subtokensAdd(raw);
    }

    fn subtokensAdd(self: *Self, str: []u8) !void {
        if (self.subtokens) |sub| {
            self.subtokens = try self.alloc.realloc(sub, sub.len + 1);
        } else {
            self.subtokens = try self.alloc.alloc(TokenIterator, 1);
        }
        self.subtokens.?[self.subtokens.?.len - 1] = TokenIterator{ .raw = str };
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
                _ = self.subtokensDel();
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
            } else {
                return self.resolveWord(token);
            }
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
            self.subtokensDupe(als) catch unreachable;
            var owned = &self.subtokens.?[self.subtokens.?.len - 1];
            self.resolve(owned.*.first());
        } else |e| {
            if (e != Error.Empty) {
                std.debug.print("alias errr {}\n", .{e});
                unreachable;
            }
        }
    }

    fn resolveWord(self: *Self, token: *const Token) void {
        var t = Tokenizer.simple(token.str) catch unreachable;
        if (t.str.len != token.str.len) {
            var skip: usize = 0;
            var list = std.ArrayList(u8).init(self.alloc.*);
            for (token.str, 0..) |c, i| {
                if (skip > 0) {
                    skip -%= 1;
                    continue;
                }
                switch (c) {
                    '$' => {
                        var vari = Tokenizer.vari(token.str[i..]) catch {
                            list.append(c) catch unreachable;
                            continue;
                        };
                        skip = vari.str.len - 1;
                        const res = Parser.single(self.alloc, &vari) catch continue;
                        if (res.resolved) |str| {
                            for (str) |s| list.append(s) catch unreachable;
                        }
                    },
                    else => list.append(c) catch {},
                }
            }
            const owned = list.toOwnedSlice() catch unreachable;
            self.subtokensAdd(owned) catch unreachable;
        } else if (std.mem.indexOf(u8, token.cannon(), "*")) |_| {
            return self.resolveGlob(token);
        }
        return;
    }

    fn resolveGlob(self: *Self, token: *const Token) void {
        if (std.mem.indexOf(u8, token.cannon(), "*")) |_| {} else return;
        if (Parser.glob(self.alloc, token)) |names| {
            for (names) |name| {
                if (!std.mem.startsWith(u8, token.cannon(), ".") and
                    std.mem.startsWith(u8, name, "."))
                {
                    self.alloc.free(name);
                    continue;
                }
                // as long as we own this memory, this cast is safe
                self.subtokensAdd(@constCast(name)) catch unreachable;
            }
            self.alloc.free(names);
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
        while (self.subtokensDel()) {}
        self.subtokens = null;
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

    pub fn single(a: *Allocator, token: *Token) Error!*Token {
        if (token.str.len == 0) return token;

        switch (token.kind) {
            .quote => {
                var needle = [2]u8{ '\\', token.subtoken };
                if (mem.indexOfScalar(u8, token.str, '\\')) |_| {} else return token;

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
            .vari => {
                return try variable(token);
            },
            .word => {
                if (mem.indexOf(u8, token.str, "/")) |_| {
                    token.kind = .path;
                    return token;
                } else return token;
            },
            .path => {
                if (token.cannon()[0] != '~') return token;

                _ = token.upgrade(a) catch return Error.Unknown;
                return try path(token);
            },
            else => {
                switch (token.str[0]) {
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

    fn alias(token: *const Token) Error![]const u8 {
        if (Aliases.find(token.cannon())) |a| {
            return a.value;
        }
        return Error.Empty;
    }

    fn word(a: *Allocator, t: *Token) *Token {
        std.debug.assert(t.kind == .word);
        var new = ArrayList(u8).init(a.*);
        var esc = false;
        for (t.str) |c| {
            if (c == '\\' and !esc) {
                esc = true;
                continue;
            }
            esc = false;
            new.append(c) catch @panic("memory error");
        }
        t.resolved = new.toOwnedSlice() catch @panic("memory error");
        return t;
    }

    /// Caller owns memory for both list of names, and each name
    fn globAt(a: *Allocator, dir: std.fs.IterableDir, token: *const Token) Error![][]const u8 {
        return fs.globAt(a.*, dir, token.cannon()) catch @panic("this error not implemented");
    }

    /// Caller owns memory for both list of names, and each name
    fn glob(a: *Allocator, token: *const Token) Error![][]const u8 {
        return fs.globCwd(a.*, token.cannon()) catch @panic("this error not implemented");
    }

    fn builtin(tkn: *Token) Error!*Token {
        if (Builtins.exists(tkn.cannon())) {
            tkn.*.kind = .builtin;
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
            tkn.backing.?.appendSlice(tkn.str[1..]) catch return Error.Memory;
        }
        return tkn;
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;

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
        Token{ .kind = .word, .str = "alias" },
    };

    var itr = try Parser.parse(&a, &ts);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 1);
    try std.testing.expectEqualStrings("alias", itr.first().cannon());
    try expect(itr.next() == null);
    try std.testing.expect(itr.first().kind == .builtin);
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
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
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
        Token{ .kind = .word, .str = "ls" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
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
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
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
    try expect(itr.next().?.kind == .vari);
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
    try expect(itr.next().?.kind == .vari);
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
    try expect(itr.next().?.kind == .vari);
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
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("extravalue", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces inline both" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string}thingy blerg",
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
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("extravaluethingy", itr.next().?.cannon());
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

    try std.testing.expect(itr.next().?.kind == .path);
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

    try std.testing.expect(itr.peek().?.kind == .path);
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

    try std.testing.expect(itr.peek().?.kind == .path);
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

    try std.testing.expect(itr.peek().?.kind == .path);
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

    try std.testing.expect(itr.peek().?.kind == .path);
    try eqlStr("/~/otherplace", itr.next().?.cannon());
    try std.testing.expect(itr.next() == null);

    // Should be done by tokenizer, but ¯\_(ツ)_/¯
    for (slice) |*s| {
        if (s.backing) |*b| b.clearAndFree();
    }
}

test "glob" {
    var a = std.testing.allocator;

    var cwd = try std.fs.cwd().openIterableDir(".", .{});
    var di = cwd.iterate();
    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        if (each.name[0] == '.') continue;
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 6), names.items.len);

    var ti = TokenIterator{
        .raw = "echo *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 7), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.cannon())) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else return error.TestingUnmatchedName;
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "glob ." {
    var a = std.testing.allocator;

    var cwd = try std.fs.cwd().openIterableDir(".", .{});
    var di = cwd.iterate();
    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 8), names.items.len);

    var ti = TokenIterator{
        .raw = "echo .* *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(&a, slice);

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 9), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.cannon())) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else return error.TestingUnmatchedName;
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "escapes" {
    var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "one\\\\ two" };
    var first = t.first();
    try std.testing.expectEqualStrings("one\\\\", first.cannon());

    var p = Parser.word(&a, @constCast(first));
    try std.testing.expectEqualStrings("one\\", p.cannon());
    a.free(p.resolved.?);

    t = TokenIterator{ .raw = "--inline=quoted\\ string" };
    first = t.first();
    try std.testing.expectEqualStrings("--inline=quoted\\ string", first.cannon());

    p = Parser.word(&a, @constCast(first));
    try std.testing.expectEqualStrings("--inline=quoted string", p.cannon());
    a.free(p.resolved.?);
}
