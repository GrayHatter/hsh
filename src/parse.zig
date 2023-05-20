const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const Builtins = @import("builtins.zig");

pub const Error = error{
    Unknown,
    Memory,
    ParseFailed,
    OpenGroup,
    Empty,
};

pub const Parser = struct {
    alloc: Allocator,

    pub fn parse(a: *Allocator, tokens: []Token) Error!bool {
        if (tokens.len == 0) return false;

        for (tokens) |*tk| {
            _ = parseToken(a, tk) catch unreachable;
        }

        _ = try parseAction(&tokens[0]);

        return true;
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

    var terr = Tokenizer.quote("\"this is invalid");
    try expectError(Error.InvalidSrc, terr);

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

    terr = Tokenizer.quote("\"this is some text\\\" more text");
    try expectError(Error.InvalidSrc, terr);

    t.reset();
    try t.consumes("\"this is some text\\\" more text\"");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, 31);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "\"this is some text\\\" more text\""));

    //std.debug.print("{s} {}\n", .{ t.tokens.items[0].cannon(), t.tokens.items[0].cannon().len });
    try expectEql("this is some text\\\" more text".len, t.tokens.items[0].cannon().len);
    try expectEql(t.tokens.items[0].cannon().len, 29);
    try expect(t.tokens.items[0].parsed);
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text\" more text"));
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
    const cannon =
        \\this is some text\
    ;
    //try expectEql(t.tokens.items[0].cannon().len, 18);
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), cannon));

    t.reset();
    try t.consumes("'this is some text' more text");
    _ = try t.tokenize();
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "'this is some text'"));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));
    t.reset();
}
