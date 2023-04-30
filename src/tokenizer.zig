const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const File = fs.File;
const Reader = io.Reader(File, File.ReadError, File.read);
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const std = @import("std");

pub const TokenType = enum(u8) {
    Untyped,
    Exe,
    Builtin,
    Command, // custom string that alters hsh in some way
    String,
    WhiteSpace,
    Char,
    Quote,
    Var,
    IoRedir,
    Tree, // Should this token be a separate type?
};

pub const Token = struct {
    raw: []const u8,
    i: u16 = 0,
    real: []const u8,
    backing: ?ArrayList(u8) = null,
    type: TokenType = TokenType.Untyped,
    subtoken: u8 = 0,

    pub fn format(self: Token, comptime fmt: []const u8, opt: std.fmt.FormatOptions, out: anytype) !void {
        _ = opt;
        // this is what net.zig does, so it's what I do
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);

        try std.fmt.format(out, "Token({}){{{s}}}", .{ self.type, self.raw });
    }

    pub fn cannon(self: Token) []const u8 {
        return switch (self.type) {
            .String => self.raw,
            .Quote => self.real,
            else => "error",
        };
    }
};

pub const Tokenizer = struct {
    alloc: Allocator,
    raw: ArrayList(u8),
    tokens: ArrayList(Token),
    hist_z: ?ArrayList(u8) = null,
    hist_pos: usize = 0,
    c_idx: usize = 0,
    c_tkn: usize = 0, // cursor is over this token
    err_idx: usize = 0,

    pub const TokenErr = error{
        None,
        Unknown,
        LineTooLong,
        ParseError,
        InvalidSrc,
    };

    const Builtins = [_][]const u8{
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

    /// Increment the cursor over to current token position
    fn ctinc(self: *Tokenizer) void {
        var seek: usize = 0;
        for (self.tokens.items, 0..) |t, i| {
            self.c_tkn = i;
            seek += t.raw.len;
            if (seek >= self.c_idx) break;
        }
    }

    pub fn cinc(self: *Tokenizer, i: isize) void {
        self.c_idx = @intCast(usize, @max(0, @addWithOverflow(@intCast(isize, self.c_idx), i)[0]));
        if (self.c_idx > self.raw.items.len) {
            self.c_idx = self.raw.items.len;
        }
        self.ctinc();
    }

    /// Warning no safety checks made before access!
    /// TODO safety checks
    pub fn cursor_token(self: *Tokenizer) !Token {
        self.ctinc();
        return self.tokens.items[self.c_tkn];
    }

    // Cursor adjustment to send to tty
    pub fn cadj(self: Tokenizer) usize {
        return self.raw.items.len - self.c_idx;
    }

    pub fn parse(self: *Tokenizer) TokenErr!bool {
        self.tokens.clearAndFree();
        var start: usize = 0;
        while (start < self.raw.items.len) {
            var etoken = switch (self.raw.items[start]) {
                '\'', '"' => Tokenizer.parse_quote(self.raw.items[start..]),
                ' ' => Tokenizer.parse_space(self.raw.items[start..]),
                '$' => unreachable,
                else => Tokenizer.parse_string(self.raw.items[start..]),
            };
            // TODO this doesn't belong here
            if (etoken) |*t| {
                if (t.raw.len > 0) {
                    _ = self.parse_token(t) catch unreachable;
                    self.tokens.append(t.*) catch unreachable;
                    start += t.raw.len;
                } else {
                    start += 1;
                }
            } else |_| {
                self.err_idx = start;
                return TokenErr.ParseError;
            }
        }
        self.err_idx = 0;
        if (self.tokens.items.len == 0) return false;
        const t = self.tokens.items[self.tokens.items.len - 1];
        return switch (t.type) {
            TokenType.Char,
            TokenType.String,
            TokenType.Exe,
            TokenType.WhiteSpace,
            TokenType.Quote,
            => true,
            else => false,
        };
    }

    fn parse_token(self: *Tokenizer, token: *Token) TokenErr!*Token {
        if (self.tokens.items.len == 0) {
            return self.parse_action(token);
        }

        switch (token.raw[0]) {
            '$' => return token,
            else => return token,
        }
        return;
    }

    fn parse_action(self: *Tokenizer, token: *Token) TokenErr!*Token {
        if (parse_builtin(token.raw)) {
            for (Builtins) |bin| {
                _ = bin;
            }
        }

        token.*.type = TokenType.Exe;
        token.*.backing = ArrayList(u8).init(self.alloc);
        token.*.backing.?.appendSlice(token.*.real[0..]) catch {
            return TokenErr.Unknown;
        };
        token.*.real = token.*.backing.?.items;
        return token;
    }

    pub fn parse_string(src: []const u8) TokenErr!Token {
        var end: usize = 0;
        for (src, 0..) |s, i| {
            end = i;
            switch (s) {
                ' ', '\t', '"', '\'' => break,
                else => continue,
            }
        } else end += 1;
        return Token{
            .raw = src[0..end],
            .real = src[0..end],
            .type = if (end == 1) TokenType.Char else TokenType.String,
        };
    }

    fn parse_char(_: []const u8) !u8 {}

    /// Callers must ensure that src[0] is in (', ")
    pub fn parse_quote(src: []const u8) TokenErr!Token {
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

    pub fn parse_space(src: []const u8) TokenErr!Token {
        var end: usize = 0;
        for (src) |s| {
            if (s != ' ') break;
            end += 1;
        }
        return Token{
            .raw = src[0..end],
            .real = src[0..end],
            .type = TokenType.WhiteSpace,
        };
    }

    fn parse_builtin(str: []const u8) bool {
        _ = str;
        return false;
    }

    pub fn dump_parsed(self: Tokenizer, ws: bool) !void {
        std.debug.print("\n\n", .{});
        for (self.tokens.items) |i| {
            if (!ws and i.type == .WhiteSpace) continue;
            std.debug.print("{}\n", .{i});
        }
    }

    pub fn tab(self: *Tokenizer) bool {
        _ = self.parse() catch {};
        if (self.tokens.items.len > 0) {
            return true;
        }
        return false;
    }

    // this clearly needs a bit more love
    pub fn popUntil(self: *Tokenizer) TokenErr!void {
        if (self.raw.items.len == 0 or self.c_idx == 0) return;

        self.c_idx -|= 1;
        var t = self.raw.orderedRemove(@bitCast(usize, self.c_idx));
        while (std.ascii.isWhitespace(t) and self.c_idx > 0) {
            self.c_idx -|= 1;
            t = self.raw.orderedRemove(@bitCast(usize, self.c_idx));
        }
        while (std.ascii.isAlphanumeric(t) and self.c_idx > 0) {
            self.c_idx -|= 1;
            t = self.raw.orderedRemove(@bitCast(usize, self.c_idx));
        }
        while (std.ascii.isWhitespace(t) and self.c_idx > 0) {
            self.c_idx -|= 1;
            t = self.raw.orderedRemove(@bitCast(usize, self.c_idx));
        }
        if (self.c_idx > 1 and (std.ascii.isWhitespace(t) or std.ascii.isAlphanumeric(t)))
            try self.consumec(t);
    }

    pub fn pop(self: *Tokenizer) TokenErr!void {
        if (self.raw.items.len == 0 or self.c_idx == 0) return;
        self.c_idx -|= 1;
        _ = self.raw.orderedRemove(@bitCast(usize, self.c_idx));
        self.err_idx = @min(self.c_idx, self.err_idx);
    }

    pub fn rpop(self: *Tokenizer) TokenErr!void {
        _ = self;
    }

    pub fn consumec(self: *Tokenizer, c: u8) TokenErr!void {
        self.raw.insert(@bitCast(usize, self.c_idx), c) catch return TokenErr.Unknown;
        self.c_idx += 1;
        if (self.err_idx > 0) _ = self.parse() catch {};
    }

    pub fn push_line(self: *Tokenizer) void {
        self.hist_z = self.raw;
        self.raw = ArrayList(u8).init(self.alloc);
        self.tokens.clearAndFree();
    }

    pub fn push_hist(self: *Tokenizer) void {
        self.c_idx = self.raw.items.len;
        _ = self.parse() catch {};
    }

    pub fn pop_line(self: *Tokenizer) void {
        self.clear();
        if (self.hist_z) |h| {
            self.raw = h;
        }
        _ = self.parse() catch {};
    }

    pub fn reset(self: *Tokenizer) void {
        self.clear();
        self.hist_z = null;
        self.hist_pos = 0;
    }

    pub fn clear(self: *Tokenizer) void {
        self.raw.clearAndFree();
        self.tokens.clearAndFree();
        self.c_idx = 0;
        self.err_idx = 0;
        self.c_tkn = 0;
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

    t = try Tokenizer.parse_quote("\"this is some text\\\\\" more text\"");
    try expectEql(t.raw.len, 21);
    try expectEql(t.real.len, 19);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\\\\\""));
    try expect(std.mem.eql(u8, t.real, "this is some text\\\\"));

    t = try Tokenizer.parse_quote("'this is some text' more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.real.len, 17);
    try expect(std.mem.eql(u8, t.raw, "'this is some text'"));
    try expect(std.mem.eql(u8, t.real, "this is some text"));
}
