const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.fs.File;
const Reader = io.Reader(File, File.ReadError, File.read);
const io = std.io;
const mem = std.mem;
const std = @import("std");
const CompOption = @import("completion.zig").CompOption;

const breaking_tokens = " \t\"'`${|><#;:!+=";

pub const TokenKind = enum(u8) {
    WhiteSpace,
    String,
    Builtin,
    Quote,
    IoRedir,
    Operator,
    Path,
    Var,
    Aliased,
    Command, // custom string that alters hsh in some way
    Tree, // Should this token be a separate type?
};

pub const Error = error{
    Unknown,
    Memory,
    LineTooLong,
    TokenizeFailed,
    InvalidSrc,
    OpenGroup,
    Empty,
};

pub const Token = struct {
    raw: []const u8, // "full" Slice, you probably want to use cannon()
    i: u16 = 0,
    backing: ?ArrayList(u8) = null,
    type: TokenKind,
    parsed: bool = false,
    subtoken: u8 = 0,

    pub fn format(self: Token, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        // this is what net.zig does, so it's what I do
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "Token({}){{{s}}}", .{ self.type, self.raw });
    }

    pub fn cannon(self: Token) []const u8 {
        if (self.backing) |b| return b.items;

        return switch (self.type) {
            .Quote => return self.raw[1 .. self.raw.len - 1],
            else => self.raw,
        };
    }

    // Don't upgrade raw, it must "always" point to the user prompt
    // string[citation needed]
    pub fn upgrade(self: *Token, a: *Allocator) Error![]u8 {
        if (self.*.backing) |_| return self.*.backing.?.items;

        var backing = ArrayList(u8).init(a.*);
        backing.appendSlice(self.*.cannon()) catch return Error.Memory;
        self.*.backing = backing;
        return self.*.backing.?.items;
    }
};

pub fn tokenPos(comptime t: TokenKind, hs: []const Token) ?usize {
    for (hs, 0..) |tk, i| {
        if (t == tk.type) return i;
    }
    return null;
}

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

    pub fn raze(self: *Tokenizer) void {
        self.reset();
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

    /// Return a slice of the current tokens;
    /// Tokenizer owns memory, and makes no guarantee it'll be valid by the time
    /// it's used.
    pub fn tokenize(self: *Tokenizer) Error![]Token {
        self.tokens.clearAndFree();
        var start: usize = 0;
        const src = self.raw.items;
        if (self.raw.items.len == 0) return Error.Empty;
        while (start < src.len) {
            const token = switch (src[start]) {
                '\'', '"' => Tokenizer.quote(src[start..]),
                '`' => Tokenizer.quote(src[start..]), // TODO magic
                ' ' => Tokenizer.space(src[start..]),
                '~', '/' => Tokenizer.path(src[start..]),
                '|' => Tokenizer.ioredir(src[start..]),
                '$' => unreachable,
                '=' => Tokenizer.oper(src[start..]),
                else => Tokenizer.string(src[start..]),
            } catch |err| {
                if (err == Error.InvalidSrc) {
                    if (std.mem.indexOfAny(u8, src[start..], "\"'(")) |_| return Error.OpenGroup;
                    self.err_idx = start;
                }
                return err;
            };
            if (token.raw.len == 0) {
                self.err_idx = start;
                return Error.Unknown;
            }
            self.tokens.append(token) catch return Error.Memory;
            start += token.raw.len;
        }
        self.err_idx = 0;
        if (self.err_idx != 0) return Error.TokenizeFailed;
        return self.tokens.items;
    }

    fn string(src: []const u8) Error!Token {
        if (mem.indexOfAny(u8, src[0..1], breaking_tokens)) |_| return Error.InvalidSrc;
        var end: usize = 0;
        for (src, 0..) |_, i| {
            end = i;
            if (mem.indexOfAny(u8, src[i .. i + 1], breaking_tokens)) |_| break else continue;
        } else end += 1;
        return Token{
            .raw = src[0..end],
            .type = TokenKind.String,
        };
    }

    fn ioredir(src: []const u8) Error!Token {
        if (src[0] != '|') return Error.InvalidSrc;

        if (src.len < 2) return Error.InvalidSrc;
        //if (src.len < 2) return Token{ .raw = src[0..1], .type = .IoRedir };
        //const follower = try Tokenizer.string(src[1..]);
        return Token{
            .raw = src[0..1],
            .type = .IoRedir,
        };
    }

    pub fn oper(src: []const u8) Error!Token {
        switch (src[0]) {
            '=' => return Token{
                .raw = src[0..1],
                .type = .Operator,
            },
            else => return Error.InvalidSrc,
        }
    }

    /// Callers must ensure that src[0] is in (', ")
    pub fn quote(src: []const u8) Error!Token {
        // TODO posix says a ' cannot appear within 'string'
        if (src.len <= 1 or src[0] == '\\') {
            return Error.InvalidSrc;
        }
        const subt = src[0];

        var end: usize = 1;
        for (src[1..], 1..) |s, i| {
            end += 1;
            if (s == subt and !(src[i - 1] == '\\' and src[i - 2] != '\\')) break;
        }

        if (src[end - 1] != subt) return Error.InvalidSrc;

        return Token{
            .raw = src[0..end],
            .type = TokenKind.Quote,
            .subtoken = subt,
        };
    }

    fn space(src: []const u8) Error!Token {
        var end: usize = 0;
        for (src) |s| {
            if (s != ' ') break;
            end += 1;
        }
        return Token{
            .raw = src[0..end],
            .type = TokenKind.WhiteSpace,
        };
    }

    fn path(src: []const u8) Error!Token {
        var t = try Tokenizer.string(src);
        t.type = TokenKind.Path;
        return t;
    }

    pub fn dump_tokens(self: Tokenizer, ws: bool) !void {
        std.debug.print("\n", .{});
        for (self.tokens.items) |i| {
            if (!ws and i.type == .WhiteSpace) continue;
            std.debug.print("{}\n", .{i});
        }
    }

    pub fn tab(self: *const Tokenizer) bool {
        if (self.tokens.items.len > 0) {
            return true;
        }
        return false;
    }

    /// This function edits user text, so extra care must be taken to ensure
    /// it's something the user asked for!
    pub fn replaceToken(self: *Tokenizer, old: *const Token, new: *const CompOption) !void {
        var sum: usize = 0;
        for (self.tokens.items) |*t| {
            if (t == old) break;
            sum += t.raw.len;
        }
        self.c_idx = sum + old.raw.len;
        if (old.type != .WhiteSpace) try self.popRange(old.raw.len);
        if (new.kind == .Original and mem.eql(u8, new.full, " ")) return;

        try self.consumeSafeish(new.full);

        switch (new.kind) {
            .Original => {
                if (mem.eql(u8, new.full, " ")) return;
            },
            .FileSystem => |fs| {
                if (fs == .Dir) {
                    try self.consumec('/');
                }
            },
            else => {},
        }
    }

    fn consumeSafeish(self: *Tokenizer, str: []const u8) Error!void {
        if (mem.indexOfAny(u8, str, breaking_tokens)) |_| {} else {
            for (str) |s| try self.consumec(s);
            return;
        }
        if (mem.indexOf(u8, str, "'")) |_| {} else {
            try self.consumec('\'');
            for (str) |c| try self.consumec(c);
            try self.consumec('\'');
            return;
        }

        return Error.InvalidSrc;
    }

    // this clearly needs a bit more love
    pub fn popUntil(self: *Tokenizer) Error!void {
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

    pub fn pop(self: *Tokenizer) Error!void {
        if (self.raw.items.len == 0 or self.c_idx == 0) return Error.Empty;
        self.c_idx -|= 1;
        _ = self.raw.orderedRemove(@bitCast(usize, self.c_idx));
        self.err_idx = @min(self.c_idx, self.err_idx);
    }

    pub fn rpop(self: *Tokenizer) Error!void {
        _ = self;
    }

    pub fn popRange(self: *Tokenizer, count: usize) Error!void {
        if (count > self.raw.items.len) return Error.Empty;
        if (self.raw.items.len == 0 or self.c_idx == 0) return;
        if (count == 0) return;
        self.c_idx -|= count;
        _ = self.raw.replaceRange(@as(usize, self.c_idx), count, "") catch unreachable;
        // replaceRange is able to expand, but we don't here, thus unreachable
        self.err_idx = @min(self.c_idx, self.err_idx);
    }

    pub fn consumec(self: *Tokenizer, c: u8) Error!void {
        self.raw.insert(@bitCast(usize, self.c_idx), c) catch return Error.Unknown;
        self.c_idx += 1;
        if (self.err_idx > 0) _ = self.tokenize() catch {};
    }

    pub fn push_line(self: *Tokenizer) void {
        self.hist_z = self.raw;
        self.raw = ArrayList(u8).init(self.alloc);
        self.tokens.clearAndFree();
    }

    pub fn push_hist(self: *Tokenizer) void {
        self.c_idx = self.raw.items.len;
        _ = self.tokenize() catch {};
    }

    pub fn pop_line(self: *Tokenizer) void {
        self.clear();
        if (self.hist_z) |h| {
            self.raw = h;
        }
        _ = self.tokenize() catch {};
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

    pub fn consumes(self: *Tokenizer, str: []const u8) Error!void {
        for (str) |s| try self.consumec(s);
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
test "quotes" {
    var t = try Tokenizer.quote("\"\"");
    try expectEql(t.raw.len, 2);
    try expectEql(t.cannon().len, 0);

    t = try Tokenizer.quote("\"a\"");
    try expectEql(t.raw.len, 3);
    try expectEql(t.cannon().len, 1);
    try expect(std.mem.eql(u8, t.raw, "\"a\""));
    try expect(std.mem.eql(u8, t.cannon(), "a"));

    var terr = Tokenizer.quote("\"this is invalid");
    try expectError(Error.InvalidSrc, terr);

    t = try Tokenizer.quote("\"this is some text\" more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Tokenizer.quote("`this is some text` more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "`this is some text`"));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Tokenizer.quote("\"this is some text\" more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    terr = Tokenizer.quote("\"this is some text\\\" more text");
    try expectError(Error.InvalidSrc, terr);

    t = try Tokenizer.quote("\"this is some text\\\" more text\"");
    try expectEql(t.raw.len, 31);
    try expectEql(t.cannon().len, 29);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\\\" more text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\" more text"));

    t = try Tokenizer.quote("\"this is some text\\\\\" more text\"");
    try expectEql(t.raw.len, 21);
    try expectEql(t.cannon().len, 19);
    try expect(std.mem.eql(u8, t.raw, "\"this is some text\\\\\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\\"));

    t = try Tokenizer.quote("'this is some text' more text");
    try expectEql(t.raw.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.raw, "'this is some text'"));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));
}

test "quotes tokened" {
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

    try expectEql("this is some text\\\" more text".len, t.tokens.items[0].cannon().len);
    try expectEql(t.tokens.items[0].cannon().len, 29);
    try expect(!t.tokens.items[0].parsed);
    try expect(std.mem.eql(u8, t.tokens.items[0].cannon(), "this is some text\\\" more text"));
}

test "alloc" {
    var t = Tokenizer.init(std.testing.allocator);
    try expect(std.mem.eql(u8, t.raw.items, ""));
}

test "tokens" {
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();
    for ("token") |c| {
        try t.consumec(c);
    }
    _ = try t.tokenize();
    try expect(std.mem.eql(u8, t.raw.items, "token"));
}

test "tokenize string" {
    const tkn = Tokenizer.string("string is true");
    if (tkn) |tk| {
        try expect(std.mem.eql(u8, tk.raw, "string"));
        try expect(tk.raw.len == 6);
    } else |_| {
        try expect(false);
    }
}

test "tokenize path" {
    const token = try Tokenizer.path("blerg");
    try expect(eql(u8, token.raw, "blerg"));

    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("blerg ~/dir");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, "blerg ~/dir".len);
    try expectEql(t.tokens.items.len, 3);
    try expect(t.tokens.items[2].type == TokenKind.Path);
    try expect(eql(u8, t.tokens.items[2].raw, "~/dir"));
    t.reset();

    try t.consumes("blerg /home/user/something");
    _ = try t.tokenize();
    try expectEql(t.raw.items.len, "blerg /home/user/something".len);
    try expectEql(t.tokens.items.len, 3);
    try expect(t.tokens.items[2].type == TokenKind.Path);
    try expect(eql(u8, t.tokens.items[2].raw, "/home/user/something"));
}

test "replace token" {
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();
    try expect(std.mem.eql(u8, t.raw.items, ""));

    try t.consumes("one two three");
    _ = try t.tokenize();
    try expect(t.tokens.items.len == 5);

    try expect(eql(u8, t.tokens.items[2].cannon(), "two"));

    try t.replaceToken(&t.tokens.items[2], &CompOption{
        .full = "TWO",
        .name = "TWO",
    });
    _ = try t.tokenize();

    try expect(t.tokens.items.len == 5);
    try expect(eql(u8, t.tokens.items[2].cannon(), "TWO"));
    try expect(eql(u8, t.raw.items, "one TWO three"));

    try t.replaceToken(&t.tokens.items[2], &CompOption{
        .full = "TWO THREE",
        .name = "TWO THREE",
    });
    _ = try t.tokenize();

    for (t.tokens.items) |tkn| {
        _ = tkn;
        //std.debug.print("--- {}\n", .{tkn});
    }

    try expect(t.tokens.items.len == 5);
    try expect(eql(u8, t.tokens.items[2].cannon(), "TWO THREE"));
    try expect(eql(u8, t.raw.items, "one 'TWO THREE' three"));
}

test "breaking" {
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("alias la='ls -la'");
    _ = try t.tokenize();
    try expect(t.tokens.items.len == 5);
}
