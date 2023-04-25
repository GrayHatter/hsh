const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const File = fs.File;
const Reader = io.Reader(File, File.ReadError, File.read);
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const std = @import("std");

pub const TokenType = enum(u8) {
    Unknown,
    String,
    Quote,
    Var,
    Pipe,
    IoRedir,
};

pub const Token = struct {
    raw: []const u8,
    real: []const u8,
    type: TokenType = TokenType.Unknown,
    subtoken: u8 = 0,
};

pub const Tokenizer = struct {
    alloc: Allocator,
    raw: ArrayList(u8),
    tokens: ArrayList(Token),

    pub const TokenErr = error{
        None,
        Unknown,
        LineTooLong,
        ParseError,
        InvalidSrc,
    };

    const Builtin = [_][]const u8{
        "alias",
        "which",
        "echo",
    };

    pub fn init(a: Allocator) Tokenizer {
        return Tokenizer{
            .alloc = a,
            .raw = ArrayList(u8).init(a),
            .tokens = ArrayList(Token).init(a),
        };
    }

    pub fn raze(self: Tokenizer) void {
        self.alloc.deinit();
    }

    /// Callers must ensure that src[0] is in (', ")
    pub fn parse_quote(src: []const u8) TokenErr!Token {
        //if (src.len < 3) {
        //    return TokenErr.InvalidSrc;
        //}
        if (src.len <= 1) {
            return TokenErr.InvalidSrc;
        }
        const subt = src[0];

        var end: usize = 1;
        for (src[1..], 1..) |s, i| {
            end += 1;
            if (s == subt and !(src[i - 1] == '\\' and src[i - 2] != '\\')) break;
        }
        if (src[end - 1] != subt) {
            return TokenErr.InvalidSrc;
        }

        return Token{
            .raw = src[0..end],
            .real = src[1 .. end - 1],
            .type = TokenType.Quote,
            .subtoken = subt,
        };
    }

    pub fn parse_string(self: *Tokenizer, src: []const u8) TokenErr!Token {
        _ = self;
        var end: usize = 0;
        for (src, 0..) |s, i| {
            end = i;
            switch (s) {
                ' ', '\t' => break,
                else => continue,
            }
        } else end += 1;
        return Token{
            .raw = src[0..end],
            .real = src[0..end],
            .type = TokenType.String,
        };
    }

    pub fn parse(self: *Tokenizer) TokenErr!void {
        self.tokens.clearAndFree();
        var start: usize = 0;
        while (start < self.raw.items.len) {
            const t = self.parse_string(self.raw.items[start..]);
            if (t) |tt| {
                if (tt.raw.len > 0) {
                    self.tokens.append(tt) catch unreachable;
                    start += tt.raw.len;
                } else {
                    start += 1;
                }
            } else |_| {
                return TokenErr.ParseError;
            }
        }
    }

    pub fn dump_parsed(self: Tokenizer) !void {
        std.debug.print("\n\n", .{});
        for (self.tokens.items) |i| {
            std.debug.print("{}\n", .{i});
            std.debug.print("{s}\n", .{i.raw});
        }
    }

    pub fn tab(self: Tokenizer) !bool {
        _ = self;
        return false;
    }

    pub fn pop(self: *Tokenizer) TokenErr!void {
        _ = self.raw.popOrNull();
    }
    pub fn consumec(self: *Tokenizer, c: u8) TokenErr!void {
        self.raw.append(c) catch return TokenErr.Unknown;
    }

    pub fn clear(self: *Tokenizer) void {
        self.raw.clearAndFree();
        self.tokens.clearAndFree();
    }

    pub fn consumes(self: *Tokenizer, r: Reader) TokenErr!void {
        var buf: [2 ^ 8]u8 = undefined;
        var line = r.readUntilDelimiterOrEof(&buf, '\n') catch |e| {
            if (e == error.StreamTooLong) {
                return TokenErr.LineTooLong;
            }
            return TokenErr.Unknown;
        };
        self.raw.appendSlice(line.?) catch return TokenErr.Unknown;
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
test "parse quotes" {
    var t = try Tokenizer.parse_quote("\"\"");
    try expectEql(t.raw.len, 2);
    try expectEql(t.real.len, 0);

    t = try Tokenizer.parse_quote("\"a\"");
    try expectEql(t.raw.len, 3);
    try expectEql(t.real.len, 1);
    try expect(std.mem.eql(u8, t.raw, "\"a\""));
    try expect(std.mem.eql(u8, t.real, "a"));

    var terr = Tokenizer.parse_quote("\"this is invalid");
    try expectError(Tokenizer.TokenErr.InvalidSrc, terr);

    t = try Tokenizer.parse_quote("\"this is some text\" more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.real.len, 17);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.real, "this is some text"));

    t = try Tokenizer.parse_quote("\"this is some text\" more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.real.len, 17);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.real, "this is some text"));

    terr = Tokenizer.parse_quote("\"this is some text\\\" more text");
    try expectError(Tokenizer.TokenErr.InvalidSrc, terr);

    t = try Tokenizer.parse_quote("\"this is some text\\\" more text\"");
    try expectEql(t.raw.len, 31);
    try expectEql(t.real.len, 29);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\\\" more text\""));
    try expect(std.mem.eql(u8, t.real, "this is some text\\\" more text"));

    t = try Tokenizer.parse_quote("'this is some text' more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.real.len, 17);
    try expect(std.mem.eql(u8, t.raw, "'this is some text'"));
    try expect(std.mem.eql(u8, t.real, "this is some text"));
}
