const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const File = fs.File;
const Reader = io.Reader(File, File.ReadError, File.read);
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const std = @import("std");
const Builtins = @import("builtins.zig");

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

pub const TokenErr = error{
    Unknown,
    Memory,
    LineTooLong,
    ParseError,
    InvalidSrc,
};

pub const Token = struct {
    raw: []const u8, // "full" Slice, you probably want to use cannon()
    i: u16 = 0,
    backing: ?ArrayList(u8) = null,
    type: TokenType = TokenType.Untyped,
    subtoken: u8 = 0,

    pub fn format(self: Token, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        // this is what net.zig does, so it's what I do
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "Token({}){{{s}}}", .{ self.type, self.raw });
    }

    pub fn cannon(self: Token) []const u8 {
        if (self.backing) |b| return b.items;

        return switch (self.type) {
            .Char, .String => self.raw,
            .Quote => return self.raw[1 .. self.raw.len - 1],
            .Builtin => self.raw,
            else => unreachable,
        };
    }

    // Don't upgrade raw, it must "always" point to the user prompt
    // string[citation needed]
    pub fn upgrade(self: *Token, a: Allocator) ![]u8 {
        if (self.*.backing) |_| return self.*.backing.?.items;

        var backing = ArrayList(u8).init(a);
        backing.appendSlice(self.*.cannon()) catch return TokenErr.Memory;
        self.*.backing = backing;
        return self.*.backing.?.items;
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
    /// Also, Tokeninzer continues to own memory, and may invalidate it whenever
    /// it sees fit.
    /// TODO safety checks
    pub fn cursor_token(self: *Tokenizer) !*const Token {
        self.ctinc();
        return &self.tokens.items[self.c_tkn];
    }

    // Cursor adjustment to send to tty
    pub fn cadj(self: Tokenizer) usize {
        return self.raw.items.len - self.c_idx;
    }

    pub fn tokenize(self: *Tokenizer) TokenErr!bool {
        self.tokens.clearAndFree();
        var start: usize = 0;
        while (start < self.raw.items.len) {
            const token = switch (self.raw.items[start]) {
                '\'', '"' => Tokenizer.parseQuote(self.raw.items[start..]),
                '`' => Tokenizer.parseQuote(self.raw.items[start..]), // TODO magic
                ' ' => Tokenizer.parseSpace(self.raw.items[start..]),
                '$' => unreachable,
                else => Tokenizer.parseString(self.raw.items[start..]),
            } catch {
                self.err_idx = start;
                return TokenErr.ParseError;
            };
            self.tokens.append(token) catch return TokenErr.Memory;
            start += if (token.raw.len > 0) token.raw.len else 1;
        }
        self.err_idx = 0;
        return self.err_idx == 0;
    }

    pub fn parse(self: *Tokenizer) TokenErr!bool {
        _ = try self.tokenize();

        if (self.tokens.items.len == 0) return false;

        for (self.tokens.items) |*t| {
            _ = self.parseToken(t) catch unreachable;
        }

        _ = try self.parseAction(&self.tokens.items[0]);

        const t = self.tokens.items[self.tokens.items.len - 1];
        return switch (t.type) {
            .Char,
            .String,
            .Exe,
            .WhiteSpace,
            .Quote,
            .Builtin,
            => true,
            else => false,
        };
    }

    fn parseToken(self: *Tokenizer, token: *Token) TokenErr!*Token {
        if (token.raw.len == 0) return token;

        switch (token.type) {
            .Quote => {
                var needle = [2]u8{ '\\', token.subtoken };
                if (mem.indexOfScalar(u8, token.raw, '\\')) |_| {} else return token;

                _ = try token.upgrade(self.alloc);
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
            else => {
                switch (token.raw[0]) {
                    '$' => return token,
                    else => return token,
                }
            },
        }
    }

    fn parseAction(self: *Tokenizer, token: *Token) TokenErr!*Token {
        if (Builtins.exists(token.raw)) return parseBuiltin(token);
        _ = try token.upgrade(self.alloc);
        if (token.*.type == TokenType.String) token.*.type = TokenType.Exe;
        return token;
    }

    fn parseString(src: []const u8) TokenErr!Token {
        var end: usize = 0;
        for (src, 0..) |s, i| {
            end = i;
            switch (s) {
                ' ', '\t', '"', '\'', '`', '$', '{', '|', '>', '<', '#' => break,
                else => continue,
            }
        } else end += 1;
        return Token{
            .raw = src[0..end],
            .type = if (end == 1) TokenType.Char else TokenType.String,
        };
    }

    fn parse_char(_: []const u8) !u8 {}

    /// Callers must ensure that src[0] is in (', ")
    pub fn parseQuote(src: []const u8) TokenErr!Token {
        if (src.len <= 1 or src[0] == '\\') {
            return TokenErr.InvalidSrc;
        }
        const subt = src[0];

        var end: usize = 1;
        for (src[1..], 1..) |s, i| {
            end += 1;
            if (s == subt and !(src[i - 1] == '\\' and src[i - 2] != '\\')) break;
        }

        if (src[end - 1] != subt) return TokenErr.InvalidSrc;

        return Token{
            .raw = src[0..end],
            .type = TokenType.Quote,
            .subtoken = subt,
        };
    }

    pub fn parseSpace(src: []const u8) TokenErr!Token {
        var end: usize = 0;
        for (src) |s| {
            if (s != ' ') break;
            end += 1;
        }
        return Token{
            .raw = src[0..end],
            .type = TokenType.WhiteSpace,
        };
    }

    fn parseBuiltin(tkn: *Token) TokenErr!*Token {
        tkn.*.type = .Builtin;
        return tkn;
    }

    pub fn dump_parsed(self: Tokenizer, ws: bool) !void {
        std.debug.print("\n", .{});
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

    /// This function edits user text, so extra care must be taken to ensure
    /// it's something the user asked for!
    pub fn replaceToken(self: *Tokenizer, old: *const Token, new: []u8) !void {
        var sum: usize = 0;
        for (self.tokens.items) |*t| {
            if (t == old) break;
            sum += t.raw.len;
        }
        self.c_idx = sum + old.raw.len;
        // White space is a bit strange, this is probably the wrong hack for it
        if (old.type != .WhiteSpace) for (0..old.raw.len) |_| try self.pop();
        if (!std.mem.eql(u8, new, " ")) for (new) |c| try self.consumec(c);
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
        for (self.tokens.items) |*tkn| {
            if (tkn.backing) |*bk| {
                bk.clearAndFree();
            }
        }
        self.tokens.clearAndFree();
        self.c_idx = 0;
        self.err_idx = 0;
        self.c_tkn = 0;
    }

    pub fn consumes(self: *Tokenizer, str: []const u8) TokenErr!void {
        for (str) |s| try self.consumec(s);
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
test "quotes" {
    var t = try Tokenizer.parseQuote("\"\"");
    try expectEql(t.raw.len, 2);
    try expectEql(t.cannon().len, 0);

    t = try Tokenizer.parseQuote("\"a\"");
    try expectEql(t.raw.len, 3);
    try expectEql(t.cannon().len, 1);
    try expect(std.mem.eql(u8, t.raw, "\"a\""));
    try expect(std.mem.eql(u8, t.cannon(), "a"));

    var terr = Tokenizer.parseQuote("\"this is invalid");
    try expectError(TokenErr.InvalidSrc, terr);

    t = try Tokenizer.parseQuote("\"this is some text\" more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Tokenizer.parseQuote("`this is some text` more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "`this is some text`"));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Tokenizer.parseQuote("\"this is some text\" more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    terr = Tokenizer.parseQuote("\"this is some text\\\" more text");
    try expectError(TokenErr.InvalidSrc, terr);

    t = try Tokenizer.parseQuote("\"this is some text\\\" more text\"");
    try expectEql(t.raw.len, 31);
    try expectEql(t.cannon().len, 29);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\\\" more text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\" more text"));

    t = try Tokenizer.parseQuote("\"this is some text\\\\\" more text\"");
    try expectEql(t.raw.len, 21);
    try expectEql(t.cannon().len, 19);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\\\\\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\\"));

    t = try Tokenizer.parseQuote("'this is some text' more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "'this is some text'"));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));
}

test "quotes parsed" {
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"\"");
    _ = try t.parse();
    try expectEql(t.raw.items.len, 2);
    try expectEql(t.tokens.items.len, 1);

    t.reset();
    try t.consumes("\"a\"");
    _ = try t.parse();
    try expectEql(t.raw.items.len, 3);
    try expect(std.mem.eql(u8, t.raw.items, "\"a\""));
    try expectEql(t.tokens.items[0].cannon().len, 1);
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "a"));

    var terr = Tokenizer.parseQuote("\"this is invalid");
    try expectError(TokenErr.InvalidSrc, terr);

    t.reset();
    try t.consumes("\"this is some text\" more text");
    _ = try t.parse();
    try expectEql(t.raw.items.len, 29);
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("`this is some text` more text");
    _ = try t.parse();
    try expectEql(t.raw.items.len, 29);
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "`this is some text`"));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("\"this is some text\" more text");
    _ = try t.parse();
    try expectEql(t.raw.items.len, 29);
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));

    terr = Tokenizer.parseQuote("\"this is some text\\\" more text");
    try expectError(TokenErr.InvalidSrc, terr);

    t.reset();
    try t.consumes("\"this is some text\\\" more text\"");
    _ = try t.parse();
    try expectEql(t.raw.items.len, 31);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "\"this is some text\\\" more text\""));

    try expectEql("this is some text\" more text".len, t.tokens.items[0].cannon().len);
    try expectEql("this is some text\" more text".len, 28);
    try expectEql(t.tokens.items[0].cannon().len, 28);
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

    const err = t.parse();
    try expectError(TokenErr.ParseError, err);
    try expectEql(t.err_idx, t.raw.items.len - 1);

    t.reset();
    const valid =
        \\"this is some text\\" more text
    ;
    try t.consumes(valid);
    try expectEql(t.raw.items.len, 31);

    _ = try t.parse();
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
    _ = try t.parse();
    try expectEql(t.tokens.items[0].cannon().len, 17);
    try expect(std.mem.eql(u8, t.tokens.items[0].raw, "'this is some text'"));
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text"));
    t.reset();
}

test "alloc" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Tokenizer.init(a);
    try expect(std.mem.eql(u8, t.raw.items, ""));
}

test "tokens" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = Tokenizer.init(a);
    for ("token") |c| {
        try parsed.consumec(c);
    }
    _ = try parsed.parse();
    try expect(std.mem.eql(u8, parsed.raw.items, "token"));
}

test "parse string" {
    var tkn = Tokenizer.parseString("string is true");
    if (tkn) |tk| {
        try expect(std.mem.eql(u8, tk.raw, "string"));
        try expect(tk.raw.len == 6);
    } else |_| {}
}
