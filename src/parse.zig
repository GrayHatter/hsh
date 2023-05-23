const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
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
    tokens: []const Token,
    index: ?usize,
    subindex: ?usize,
    subtoken: ?Token,
    ws: bool,
    const Self = @This();

    /// Restart iterator, and assumes length >= 1
    pub fn first(self: *Self) *const Token {
        self.restart();
        return self.next().?;
    }

    fn nextSubtoken(self: *Self, token: *const Token) ?*const Token {
        if (self.subindex) |si| {
            if (si >= token.cannon().len) {
                self.subindex = null;
                self.index.? += 1;
                return self.next();
            }
            var subi = si;
            while (token.cannon()[subi] == ' ') : (subi += 1) {
                self.subindex.? += 1;
            }
            self.subtoken = Tokenizer.any(token.cannon()[subi..]) catch |e| {
                std.debug.print("e {}\n", .{e});
                unreachable;
            };
        } else {
            self.subindex = 0;
            return self.next();
        }
        self.subindex.? += self.subtoken.?.raw.len;
        return &self.subtoken.?;
    }

    /// Returns next Token, omitting, or splitting them as needed.
    pub fn next(self: *Self) ?*const Token {
        const i = self.index orelse return null;
        if (i >= self.tokens.len) {
            self.index = null;
            return null;
        }

        const token = &self.tokens[i];
        switch (token.type) {
            .Tree => {
                return self.nextSubtoken(token);
            },
            .WhiteSpace => {
                self.index.? += 1;
                if (self.ws) return &self.tokens[i];
                return self.next();
            },
            else => {
                defer self.index.? += 1;
                return token;
            },
        }
    }

    pub fn peek(self: *Self) ?*const Token {
        const i = self.index;
        const si = self.subindex;
        defer self.subindex = si;
        defer self.index = i;
        return self.next();
    }

    /// Resets the iterator to the initial slice.
    pub fn restart(self: *Self) void {
        self.index = 0;
        self.subindex = null;
    }
};

pub const Parser = struct {
    alloc: Allocator,

    pub fn parse(a: *Allocator, tokens: []Token, comptime ws: bool) Error!ParsedIterator {
        if (tokens.len == 0) return Error.Empty;
        for (tokens) |*tk| {
            _ = parseToken(a, tk) catch unreachable;
        }

        _ = try parseAction(&tokens[0]);

        return ParsedIterator{
            .tokens = tokens,
            .index = 0,
            .subindex = null,
            .subtoken = null,
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

    fn resolve() void {}

    fn parseAction(token: *Token) Error!*Token {
        if (Builtins.exists(token.raw)) return parseBuiltin(token);
        if (alias.find(token.cannon())) |a| {
            token.*.type = .Tree;
            token.*.resolved = a.value;
        }
        return token;
    }

    fn parseBuiltin(tkn: *Token) Error!*Token {
        tkn.*.type = .Builtin;
        return tkn;
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

test "iterator tree" {
    var a = std.testing.allocator;

    var ts = [_]Token{
        Token{ .type = .Tree, .raw = "ls -la" },
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
