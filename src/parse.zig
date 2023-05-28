const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenIterator = tokenizer.TokenIterator;
const Builtins = @import("builtins.zig");
const alias = Builtins.aliases;

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
    alloc: Allocator,
    tokens: []Token,
    index: ?usize,
    subtokens: ?[]TokenIterator,
    resolved: [][]const u8,
    ws: bool,
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
            self.index = null;
            self.alloc.free(self.resolved);
            self.resolved.len = 0;
            std.debug.assert(self.resolved.len == 0);
            return null;
        }

        const token = &self.tokens[i];

        if (self.subtokens) |_| return self.nextSubtoken(token);

        if (i == 0 and token.type == .String) {
            if (self.nextSubtoken(token)) |tk| return tk;
            return token;
        } else if (token.type == .WhiteSpace and !self.ws) {
            self.index.? += 1;
            return self.next();
        }
        defer self.index.? += 1;
        return token;
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
                if (subtkns.len == 1) {
                    self.alloc.free(self.subtokens.?);
                    self.subtokens = null;
                    self.index.? += 1;
                    return self.next();
                }
                const l = subtkns.len;
                for (subtkns[0 .. l - 1], subtkns[1..]) |*dst, src| {
                    dst.* = src;
                }
                self.subtokens = self.alloc.realloc(subtkns, subtkns.len - 1) catch unreachable;
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

    fn setResolved(self: *Self, str: []const u8) void {
        self.resolved = self.alloc.realloc(self.resolved, self.resolved.len + 1) catch unreachable;
        self.resolved[self.resolved.len - 1] = str;
    }

    fn resolve(self: *Self, token: *const Token) void {
        for (self.resolved) |res| {
            if (std.mem.eql(u8, token.cannon(), res)) {
                return;
            }
        }
        self.setResolved(token.cannon());
        if (Parser.parseAlias(token)) |als| {
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
        self.resolved = self.alloc.alloc([]u8, 0) catch unreachable;
        if (self.subtokens) |ts| {
            self.alloc.free(ts);
            self.subtokens = null;
        }
    }
};

pub const Parser = struct {
    alloc: Allocator,

    pub fn parse(a: *Allocator, tokens: []Token, comptime ws: bool) Error!ParsedIterator {
        if (tokens.len == 0) return Error.Empty;
        for (tokens) |*tk| {
            _ = parseToken(a, tk) catch unreachable;
        }
        _ = parseBuiltin(&tokens[0]) catch {};
        return ParsedIterator{
            .alloc = a.*,
            .tokens = tokens,
            .index = 0,
            .subtokens = null,
            .resolved = a.alloc([]u8, 0) catch return Error.Memory,
            .ws = ws,
        };
    }

    fn parseToken(a: *Allocator, token: *Token) Error!*Token {
        if (token.raw.len == 0) return token;

        switch (token.type) {
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
            .String => {
                if (mem.indexOf(u8, token.raw, "/")) |_| {
                    token.type = .Path;
                    return token;
                } else return token;
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
        _ = try parseAlias(token);
        _ = try parseBuiltin(token);
        return token;
    }

    fn parseAlias(token: *const Token) Error!TokenIterator {
        if (alias.find(token.cannon())) |a| {
            return TokenIterator{ .raw = a.value };
        }
        return Error.Empty;
    }

    fn parseBuiltin(tkn: *Token) Error!*Token {
        if (Builtins.exists(tkn.cannon())) {
            tkn.*.type = .Builtin;
            return tkn;
        }
        return Error.Empty;
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
test "quotes parsed" {
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"\"");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, 2);
    try expectEql(t.tokens.items.len, 1);

    t.reset();
    try t.consumes("\"a\"");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, 3);
    try expect(std.mem.eql(u8, t.raw.items, "\"a\""));
    try expectEql(t.tokens.items[0].cannon().len, 1);
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "a"));

    t.reset();
    try t.consumes("\"this is some text\" more text");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, 29);
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("`this is some text` more text");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, 29);
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "`this is some text`"));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("\"this is some text\" more text");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, 29);
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("\"this is some text\\\" more text\"");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, 31);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "\"this is some text\\\" more text\""));
}

test "quotes parse complex" {
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    const invalid =
        \\"this is some text\\" more text"
    ;
    try t.consumes(invalid);
    try expectEql(t.raw.items.len, 32);

    const err = t.tokenize();
    try expectError(Error.OpenGroup, err);
    //try expectEql(t.err_idx, t.raw.items.len - 1);

    t.reset();
    const valid =
        \\"this is some text\\" more text
    ;
    try t.consumes(valid);
    try expectEql(t.raw.items.len, 31);

    _ = try t.tokenize();
    try expectEql(t.tokens.items.len, 5); // quoted, ws, str, ws, str
    try expectEql(t.tokens.items[0].raw.len, 21);
    const raw =
        \\"this is some text\\"
    ;
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, raw));
    //const cannon =
    //    \\this is some text\
    //;
    //try expectEql(t.tokens.items[0].cannon().len, 18);
    //try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), cannon));

    t.reset();
    try t.consumes("'this is some text' more text");
    _ = try t.tokenize();
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "'this is some text'"));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));
    t.reset();
}

test "iterator nows" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"this is some text\" more text");
    var ts = try t.tokenize();
    var itr = try Parser.parse(&a, ts, false);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 3);
}

test "iterator ws" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"this is some text\" more text");
    var ts = try t.tokenize();
    var itr = try Parser.parse(&a, ts, true);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 5);
}

// test "iterator tree" {
//     var a = std.testing.allocator;
//
//     var ts = [_]Token{
//         Token{ .type = .Tree, .raw = "ls -la" },
//         Token{ .type = .WhiteSpace, .raw = " " },
//         Token{ .type = .String, .raw = "src" },
//     };
//
//     var itr = try Parser.parse(&a, &ts, false);
//     var i: usize = 0;
//     while (itr.next()) |_| {
//         i += 1;
//     }
//     try expectEql(i, 3);
//     try expect(eql(u8, itr.first().cannon(), "ls"));
//     try expect(eql(u8, itr.next().?.cannon(), "-la"));
//     try expect(eql(u8, itr.next().?.cannon(), "src"));
//     try expect(itr.next() == null);
// }

test "iterator alias is builtin" {
    var a = std.testing.allocator;

    var ts = [_]Token{
        Token{ .type = .String, .raw = "alias" },
    };

    var itr = try Parser.parse(&a, &ts, false);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 1);
    try std.testing.expectEqualStrings("alias", itr.first().cannon());
    try expect(itr.next() == null);
    try std.testing.expect(itr.first().type == .Builtin);
}

test "iterator aliased" {
    var a = std.testing.allocator;
    var als = alias.testing_setup(a);
    defer alias.raze(a);
    try als.append(alias.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .type = .String, .raw = "la" },
        Token{ .type = .WhiteSpace, .raw = " " },
        Token{ .type = .String, .raw = "src" },
    };

    var itr = try Parser.parse(&a, &ts, false);
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
    var als = alias.testing_setup(a);
    defer alias.raze(a);
    try als.append(alias.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .type = .String, .raw = "ls" },
        Token{ .type = .WhiteSpace, .raw = " " },
        Token{ .type = .String, .raw = "src" },
    };

    var itr = try Parser.parse(&a, &ts, false);
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
    var als = alias.testing_setup(a);
    defer alias.raze(a);
    try als.append(alias.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    try als.append(alias.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls --color=auto") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .type = .String, .raw = "la" },
        Token{ .type = .WhiteSpace, .raw = " " },
        Token{ .type = .String, .raw = "src" },
    };

    var itr = try Parser.parse(&a, &ts, false);
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
