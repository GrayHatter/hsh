const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.fs.File;
const Reader = io.Reader(File, File.ReadError, File.read);
const io = std.io;
const mem = std.mem;
const std = @import("std");
const CompOption = @import("completion.zig").CompOption;

const BREAKING_TOKENS = " \t\"'`${|><#;";
const BSLH = '\\';

/// Deprecated, use KindExt. Eventually KindExt will replace Kind by name.
pub const Kind = enum(u8) {
    WhiteSpace,
    String,
    Builtin,
    Quote,
    IoRedir,
    Operator,
    Path,
    Var,
    Aliased,
};

pub const IOKind = enum {
    In,
    HDoc,
    Out,
    Append,
    Err,
};

pub const OpKind = enum {
    Pipe,
    Next,
    Success,
    Fail,
    Background,
};

pub const KindExt = union(enum) {
    nos: void,
    word: void,
    io: IOKind,
    oper: OpKind,
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

pub const TokenIterator = struct {
    raw: []const u8,
    index: ?usize = null,
    token: Token = undefined,

    exec_index: ?usize = null,

    const Self = @This();

    pub fn first(self: *Self) *const Token {
        self.restart();
        return self.next().?;
    }

    pub fn nextAny(self: *Self) ?*const Token {
        if (self.index) |i| {
            if (i >= self.raw.len) {
                return null;
            }
            if (Tokenizer.any(self.raw[i..])) |t| {
                self.token = t;
                self.index = i + t.raw.len;
                return &self.token;
            } else |e| {
                std.debug.print("tokenizer error {}\n", .{e});
                return null;
            }
        } else {
            self.index = 0;
            return self.next();
        }
    }

    /// next skips whitespace, if you need whitespace tokens use nextAny
    pub fn next(self: *Self) ?*const Token {
        const n = self.nextAny() orelse return null;

        if (n.kind == .WhiteSpace) {
            return self.next();
        }
        return n;
    }

    /// returns next until index reaches an executable boundary,
    /// returns null if index is at that boundary.
    pub fn nextExec(self: *Self) ?*const Token {
        if (self.exec_index) |_| {} else {
            self.exec_index = self.index;
        }

        const t_ = self.next();
        if (t_) |t| {
            switch (t.kindext) {
                .oper => {
                    self.index.? -= t.raw.len;
                    return null;
                },
                else => {},
            }
        }
        return t_;
    }

    // caller owns the memory, this will reset the index
    pub fn toSlice(self: *Self, a: Allocator) ![]Token {
        var list = ArrayList(Token).init(a);
        self.index = 0;
        while (self.next()) |n| {
            try list.append(n.*);
        }
        return list.toOwnedSlice();
    }

    // caller owns the memory, this will reset the index
    pub fn toSliceAny(self: *Self, a: Allocator) ![]Token {
        var list = ArrayList(Token).init(a);
        while (self.nextAny()) |n| {
            try list.append(n.*);
        }
        return list.toOwnedSlice();
    }

    // caller owns the memory, this will will move the index so calling next
    // will return the command delimiter (if existing),
    // Any calls to toSliceExec when current index is a command delemiter will
    // start at the following word slice.
    // calling this invalidates the previously returned pointer from next/peek
    pub fn toSliceExec(self: *Self, a: Allocator) ![]Token {
        var list = ArrayList(Token).init(a);
        if (self.nextExec()) |n| {
            try list.append(n.*);
        } else if (self.next()) |n| {
            if (n.kindext != .oper) {
                try list.append(n.*);
            }
        }
        while (self.nextExec()) |n| {
            try list.append(n.*);
        }
        return list.toOwnedSlice();
    }

    /// Returns a Tokenizer error, or toSlice() with index = 0
    pub fn toSliceError(self: *Self, a: Allocator) Error![]Token {
        var i: usize = 0;
        while (i < self.raw.len) {
            const t = try Tokenizer.any(self.raw[i..]);
            i += t.raw.len;
        }
        self.index = 0;
        return self.toSlice(a) catch return Error.Memory;
    }

    pub fn peek(self: *Self) ?*const Token {
        const old = self.index;
        defer self.index = old;
        return self.next();
    }

    pub fn restart(self: *Self) void {
        self.index = 0;
        self.exec_index = null;
    }

    /// Jumps back to the token at most recent nextExec call
    pub fn restartExec(self: *Self) void {
        self.index = self.exec_index;
        self.exec_index = null;
    }
};

pub const Token = struct {
    raw: []const u8, // "full" Slice, you probably want to use cannon()
    i: u16 = 0,
    backing: ?ArrayList(u8) = null,
    kind: Kind,
    kindext: KindExt = .nos,
    parsed: bool = false,
    subtoken: u8 = 0,
    // I hate this but I've spent too much time on this already #YOLO
    resolved: ?[]const u8 = null,

    pub fn format(self: Token, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        // this is what net.zig does, so it's what I do
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "Token({}){{{s}}}", .{ self.kind, self.raw });
    }

    pub fn cannon(self: Token) []const u8 {
        if (self.backing) |b| return b.items;
        //if (self.resolved) |r| return r;

        return switch (self.kind) {
            .Quote => return self.raw[1 .. self.raw.len - 1],
            .IoRedir, .Var, .Path => return self.resolved orelse self.raw,
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

pub const CursorMotion = enum(u8) {
    home,
    end,
    back,
    word,
    inc,
    dec,
};

pub const Tokenizer = struct {
    alloc: Allocator,
    raw: ArrayList(u8),
    prev_raw: ?ArrayList(u8) = null,
    hist_z: ?ArrayList(u8) = null,
    c_idx: usize = 0,
    c_tkn: usize = 0, // cursor is over this token
    err_idx: usize = 0,

    pub fn init(a: Allocator) Tokenizer {
        return Tokenizer{
            .alloc = a,
            .raw = ArrayList(u8).init(a),
        };
    }

    fn cChar(self: *Tokenizer) ?u8 {
        if (self.raw.items.len == 0) return null;
        if (self.c_idx == self.raw.items.len) return self.raw.items[self.c_idx - 1];
        return self.raw.items[self.c_idx];
    }

    fn cToBoundry(self: *Tokenizer, comptime forward: bool) void {
        std.debug.assert(self.raw.items.len > 0);
        const move = if (forward) .inc else .dec;
        self.cPos(move);

        while (std.ascii.isWhitespace(self.cChar().?) and
            self.c_idx > 0 and
            self.c_idx < self.raw.items.len)
        {
            self.cPos(move);
        }

        while (!std.ascii.isWhitespace(self.cChar().?) and
            self.c_idx != 0 and
            self.c_idx < self.raw.items.len)
        {
            self.cPos(move);
        }
        if (!forward and self.c_idx != 0) self.cPos(.inc);
    }

    pub fn cPos(self: *Tokenizer, motion: CursorMotion) void {
        if (self.raw.items.len == 0) return;
        switch (motion) {
            .home => self.c_idx = 0,
            .end => self.c_idx = self.raw.items.len,
            .back => self.cToBoundry(false),
            .word => self.cToBoundry(true),
            .inc => self.c_idx +|= 1,
            .dec => self.c_idx -|= 1,
        }
        self.c_idx = @min(self.c_idx, self.raw.items.len);
    }

    pub fn cursor_token(self: *Tokenizer) !Token {
        var i: usize = 0;
        self.c_tkn = 0;
        while (i < self.raw.items.len) {
            var t = try any(self.raw.items[i..]);
            if (t.raw.len == 0) return Error.TokenizeFailed;
            i += t.raw.len;
            if (i >= self.c_idx) return t;
            self.c_tkn += 1;
        }
        return Error.TokenizeFailed;
    }

    // Cursor adjustment to send to tty
    pub fn cadj(self: Tokenizer) usize {
        return self.raw.items.len - self.c_idx;
    }

    pub fn iterator(self: *Tokenizer) TokenIterator {
        return TokenIterator{ .raw = self.raw.items };
    }

    pub fn any(src: []const u8) Error!Token {
        return switch (src[0]) {
            '\'', '"' => Tokenizer.group(src),
            '`' => Tokenizer.group(src), // TODO magic
            ' ' => Tokenizer.space(src),
            '~', '/' => Tokenizer.path(src),
            '>', '<' => Tokenizer.ioredir(src),
            '|', '&', ';' => Tokenizer.execOp(src),
            '$' => vari(src),
            else => Tokenizer.string(src),
        };
    }

    pub fn string(src: []const u8) Error!Token {
        if (mem.indexOfAny(u8, src[0..1], BREAKING_TOKENS)) |_| return Error.InvalidSrc;
        var end: usize = 0;
        for (src, 0..) |_, i| {
            end = i;
            if (mem.indexOfAny(u8, src[i .. i + 1], BREAKING_TOKENS)) |_| break else continue;
        } else end += 1;
        return Token{
            .raw = src[0..end],
            .kind = Kind.String,
        };
    }

    fn ioredir(src: []const u8) Error!Token {
        if (src.len < 3) return Error.InvalidSrc;
        var i: usize = std.mem.indexOfAny(u8, src, " \t") orelse return Error.InvalidSrc;
        var t = Token{
            .raw = src[0..1],
            .kind = .IoRedir,
        };
        switch (src[0]) {
            '<' => {
                t.raw = if (src.len > 1 and src[1] == '<') src[0..2] else src[0..1];
                t.kindext = KindExt{ .io = .In };
            },
            '>' => {
                if (src[1] == '>') {
                    t.raw = src[0..2];
                    t.kindext = KindExt{ .io = .Append };
                } else {
                    t.raw = src[0..1];
                    t.kindext = KindExt{ .io = .Out };
                }
            },
            else => return Error.InvalidSrc,
        }
        while (src[i] == ' ' or src[i] == '\t') : (i += 1) {}
        var target = (try any(src[i..])).raw;
        t.resolved = target;
        t.raw = src[0 .. i + target.len];
        return t;
    }

    fn execOp(src: []const u8) Error!Token {
        switch (src[0]) {
            ';' => return Token{
                .raw = src[0..1],
                .kind = .Operator,
                .kindext = KindExt{ .oper = .Next },
            },
            '&' => {
                if (src.len > 1 and src[1] == '&') {
                    return Token{
                        .raw = src[0..2],
                        .kind = .Operator,
                        .kindext = KindExt{ .oper = .Success },
                    };
                }
                return Token{
                    .raw = src[0..1],
                    .kind = .Operator,
                    .kindext = KindExt{ .oper = .Background },
                };
            },
            '|' => {
                if (src.len > 1 and src[1] == '|') {
                    return Token{
                        .raw = src[0..2],
                        .kind = .Operator,
                        .kindext = KindExt{ .oper = .Fail },
                    };
                }
                return Token{
                    .raw = src[0..1],
                    .kind = .Operator,
                    .kindext = KindExt{ .oper = .Pipe },
                };
            },
            else => return Error.InvalidSrc,
        }
    }

    pub fn vari(src: []const u8) Error!Token {
        if (src.len <= 1) return Error.InvalidSrc;
        if (src[0] != '$') return Error.InvalidSrc;

        if (src[1] == '{') {
            if (std.mem.indexOf(u8, src, "}")) |end| {
                var t = try word(src[2..end]);
                t.resolved = t.raw;
                t.raw = src[0 .. t.raw.len + 3];
                t.kind = .Var;
                return t;
            } else return Error.InvalidSrc;
        }

        var t = try word(src[1..]);
        t.resolved = t.raw;
        t.raw = src[0 .. t.raw.len + 1];
        t.kind = .Var;

        return t;
    }

    // ASCII only :<
    pub fn word(src: []const u8) Error!Token {
        var i: usize = 0;
        while (i < src.len and (src[i] == '_' or std.ascii.isAlphabetic(src[i]))) : (i += 1) {}
        return Token{
            .raw = src[0..i],
            .kind = .String,
        };
    }

    pub fn oper(src: []const u8) Error!Token {
        switch (src[0]) {
            '=' => return Token{
                .raw = src[0..1],
                .kind = .Operator,
            },
            else => return Error.InvalidSrc,
        }
    }

    pub fn group(src: []const u8) Error!Token {
        std.debug.assert(src.len > 1);
        return switch (src[0]) {
            '\'' => quoteSingle(src),
            '"' => quoteDouble(src),
            '(' => paren(src),
            '[' => bracket(src),
            '{' => bracketCurly(src),
            '`' => backtick(src),
            else => Error.InvalidSrc,
        };
    }

    pub fn quoteSingle(src: []const u8) Error!Token {
        return quote(src);
    }

    pub fn quoteDouble(src: []const u8) Error!Token {
        return quote(src);
    }

    pub fn paren(src: []const u8) Error!Token {
        return quote(src);
    }

    pub fn bracket(src: []const u8) Error!Token {
        return quote(src);
    }

    pub fn bracketCurly(src: []const u8) Error!Token {
        return quote(src);
    }

    pub fn backtick(src: []const u8) Error!Token {
        return quote(src);
    }

    /// Callers must ensure that src[0] is in (', ")
    pub fn quote(src: []const u8) Error!Token {
        // TODO posix says a ' cannot appear within 'string'
        if (src.len <= 1 or src[0] == BSLH) {
            return Error.InvalidSrc;
        }
        const subt = src[0];

        var end: usize = 1;
        for (src[1..], 1..) |s, i| {
            end += 1;
            if (s == subt and !(src[i - 1] == BSLH and src[i - 2] != BSLH)) break;
        }

        if (src[end - 1] != subt) return Error.OpenGroup;

        return Token{
            .raw = src[0..end],
            .kind = Kind.Quote,
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
            .kind = Kind.WhiteSpace,
        };
    }

    fn path(src: []const u8) Error!Token {
        var t = try Tokenizer.string(src);
        t.kind = Kind.Path;
        return t;
    }

    /// This function edits user text, so extra care must be taken to ensure
    /// it's something the user asked for!
    pub fn replaceToken(self: *Tokenizer, new: *const CompOption) !void {
        _ = try self.cursor_token();
        var tokens_rem = self.c_tkn;
        var old: Token = any(self.raw.items) catch return Error.Unknown;
        var i: usize = old.raw.len;
        while (tokens_rem > 0) {
            tokens_rem -= 1;
            old = try any(self.raw.items[i..]);
            if (old.raw.len == 0) return Error.Unknown;
            i += old.raw.len;
        }

        self.c_idx = i;
        if (old.kind != .WhiteSpace) try self.popRange(old.raw.len);
        if (new.kind == .original and mem.eql(u8, new.full, " ")) return;

        try self.consumeSafeish(new.full);

        switch (new.kind) {
            .original => {
                if (mem.eql(u8, new.full, " ")) return;
            },
            .file_system => |fs| {
                if (fs == .Dir) {
                    try self.consumec('/');
                }
            },
            else => {},
        }
    }

    fn consumeSafeish(self: *Tokenizer, str: []const u8) Error!void {
        if (mem.indexOfAny(u8, str, BREAKING_TOKENS)) |_| {} else {
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
        var t = self.raw.orderedRemove(@bitCast(self.c_idx));
        while (std.ascii.isWhitespace(t) and self.c_idx > 0) {
            self.c_idx -|= 1;
            t = self.raw.orderedRemove(@bitCast(self.c_idx));
        }
        while (std.ascii.isAlphanumeric(t) and self.c_idx > 0) {
            self.c_idx -|= 1;
            t = self.raw.orderedRemove(@bitCast(self.c_idx));
        }
        while (std.ascii.isWhitespace(t) and self.c_idx > 0) {
            self.c_idx -|= 1;
            t = self.raw.orderedRemove(@bitCast(self.c_idx));
        }
        if (self.c_idx > 1 and (std.ascii.isWhitespace(t) or std.ascii.isAlphanumeric(t)))
            try self.consumec(t);
    }

    pub fn pop(self: *Tokenizer) Error!void {
        if (self.raw.items.len == 0 or self.c_idx == 0) return Error.Empty;
        self.c_idx -|= 1;
        _ = self.raw.orderedRemove(self.c_idx);
        self.err_idx = @min(self.c_idx, self.err_idx);
    }

    pub fn bsc(self: *Tokenizer) void {
        return self.pop() catch {};
    }

    pub fn delc(self: *Tokenizer) void {
        if (self.raw.items.len == 0 or self.c_idx == self.raw.items.len) return;
        _ = self.raw.orderedRemove(self.c_idx);
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
        self.raw.insert(self.c_idx, @bitCast(c)) catch return Error.Unknown;
        self.c_idx += 1;
    }

    pub fn pushLine(self: *Tokenizer) void {
        self.resetHist();
        self.hist_z = self.raw;
        self.raw = ArrayList(u8).init(self.alloc);
    }

    pub fn pushHist(self: *Tokenizer) void {
        self.c_idx = self.raw.items.len;
    }

    pub fn popLine(self: *Tokenizer) void {
        self.resetRaw();
        if (self.hist_z) |h| {
            self.raw = h;
            self.hist_z = null;
        }
        self.c_idx = self.raw.items.len;
    }

    pub fn reset(self: *Tokenizer) void {
        self.resetRaw();
        self.resetHist();
    }

    fn resetHist(self: *Tokenizer) void {
        if (self.hist_z) |*hz| hz.clearAndFree();
        self.hist_z = null;
    }

    pub fn resetRaw(self: *Tokenizer) void {
        self.raw.clearAndFree();
        self.c_idx = 0;
        self.err_idx = 0;
        self.c_tkn = 0;
    }

    /// Doesn't exec, called to save previous "local" command
    pub fn exec(self: *Tokenizer) void {
        if (self.prev_raw) |*pr| pr.clearAndFree();
        self.prev_raw = self.raw;
        self.raw = ArrayList(u8).init(self.alloc);
        self.resetRaw();
    }

    pub fn raze(self: *Tokenizer) void {
        self.reset();
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
    try expectError(Error.OpenGroup, terr);

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

    terr = Tokenizer.quote(
        \\"this is some text\" more text
    );
    try expectError(Error.OpenGroup, terr);

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
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"\"");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 2);
    try expectEql(tokens.len, 1);

    t.reset();
    try t.consumes("\"a\"");
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 3);
    try expect(std.mem.eql(u8, t.raw.items, "\"a\""));
    try expectEql(tokens[0].cannon().len, 1);
    try expect(std.mem.eql(u8, tokens[0].cannon(), "a"));

    var terr = Tokenizer.quote(
        \\"this is invalid
    );
    try expectError(Error.OpenGroup, terr);

    t.reset();
    try t.consumes("\"this is some text\" more text");
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("`this is some text` more text");
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].raw, "`this is some text`"));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("\"this is some text\" more text");
    a.free(tokens);
    titr = t.iterator();
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].raw, "\"this is some text\""));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));

    terr = Tokenizer.quote(
        \\"this is some text\" more text
    );
    try expectError(Error.OpenGroup, terr);

    t.reset();
    try t.consumes("\"this is some text\\\" more text\"");
    a.free(tokens);
    titr = t.iterator();
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 31);
    try expect(std.mem.eql(u8, tokens[0].raw, "\"this is some text\\\" more text\""));

    try expectEql("this is some text\\\" more text".len, tokens[0].cannon().len);
    try expectEql(tokens[0].cannon().len, 29);
    try expect(!tokens[0].parsed);
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text\\\" more text"));
    a.free(tokens);
}

test "alloc" {
    var t = Tokenizer.init(std.testing.allocator);
    try expect(std.mem.eql(u8, t.raw.items, ""));
}

test "tokens" {
    var a = std.testing.allocator;
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();
    for ("token") |c| {
        try t.consumec(c);
    }
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    defer a.free(tokens);
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
    var a = std.testing.allocator;
    const token = try Tokenizer.path("blerg");
    try expect(eql(u8, token.raw, "blerg"));

    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("blerg ~/dir");
    var titr = t.iterator();
    var tokens = try titr.toSliceAny(a);
    try expectEql(t.raw.items.len, "blerg ~/dir".len);
    try expectEql(tokens.len, 3);
    try expect(tokens[2].kind == Kind.Path);
    try expect(eql(u8, tokens[2].raw, "~/dir"));
    a.free(tokens);

    t.reset();
    try t.consumes("blerg /home/user/something");
    titr = t.iterator();
    tokens = try titr.toSliceAny(a);
    try expectEql(t.raw.items.len, "blerg /home/user/something".len);
    try expectEql(tokens.len, 3);
    try expect(tokens[2].kind == Kind.Path);
    try expect(eql(u8, tokens[2].raw, "/home/user/something"));
    a.free(tokens);
}

test "replace token" {
    var a = std.testing.allocator;
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();
    try expect(std.mem.eql(u8, t.raw.items, ""));

    try t.consumes("one two three");
    var titr = t.iterator();
    var tokens = try titr.toSliceAny(a);
    try expect(tokens.len == 5);

    try expect(eql(u8, tokens[2].cannon(), "two"));
    t.c_idx = 5;

    try t.replaceToken(&CompOption{
        .full = "TWO",
        .name = "TWO",
    });
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSliceAny(a);

    try expect(tokens.len == 5);
    try expect(eql(u8, tokens[2].cannon(), "TWO"));
    try expect(eql(u8, t.raw.items, "one TWO three"));

    try t.replaceToken(&CompOption{
        .full = "TWO THREE",
        .name = "TWO THREE",
    });
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSliceAny(a);

    for (tokens) |tkn| {
        _ = tkn;
        //std.debug.print("--- {}\n", .{tkn});
    }

    try expect(tokens.len == 5);
    try expect(eql(u8, tokens[2].cannon(), "TWO THREE"));
    try expect(eql(u8, t.raw.items, "one 'TWO THREE' three"));
    a.free(tokens);
}

test "breaking" {
    var a = std.testing.allocator;
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("alias la='ls -la'");
    var titr = t.iterator();
    var tokens = try titr.toSliceAny(a);
    try expect(tokens.len == 4);
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expect(tokens.len == 3);
    a.free(tokens);
}

test "tokeniterator 0" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    try eqlStr("one", ti.first().cannon());
    try eqlStr("two", ti.next().?.cannon());
    try eqlStr("three", ti.next().?.cannon());
    try std.testing.expect(ti.next() == null);
}

test "tokeniterator 1" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    try eqlStr("one", ti.first().cannon());
    _ = ti.nextAny();
    try eqlStr("two", ti.nextAny().?.cannon());
    _ = ti.nextAny();
    try eqlStr("three", ti.nextAny().?.cannon());
    try std.testing.expect(ti.nextAny() == null);
}

test "tokeniterator 2" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    var slice = try ti.toSlice(std.testing.allocator);
    try std.testing.expect(slice.len == 3);
    try eqlStr("one", slice[0].cannon());
    std.testing.allocator.free(slice);
}

test "tokeniterator 3" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    var slice = try ti.toSliceAny(std.testing.allocator);
    try std.testing.expect(slice.len == 5);

    try eqlStr("one", slice[0].cannon());
    try eqlStr(" ", slice[1].cannon());
    std.testing.allocator.free(slice);
}

test "token pipeline" {
    var ti = TokenIterator{
        .raw = "ls -la | cat | sort ; echo this works",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 10);

    ti.restart();
    len = 0;
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    try eqlStr(ti.next().?.cannon(), "|");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    try eqlStr(ti.next().?.cannon(), "|");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 4);

    try eqlStr(ti.next().?.cannon(), ";");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 7);
}

test "token pipeline slice" {
    var ti = TokenIterator{
        .raw = "ls -la | cat | sort ; echo this works",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 10);

    ti.restart();
    len = 0;
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    ti.restart();

    var slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 2);
    std.testing.allocator.free(slice);

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 1);
    std.testing.allocator.free(slice);

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 1);
    std.testing.allocator.free(slice);

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 3);
    try eqlStr("echo", slice[0].cannon());
    try eqlStr("this", slice[1].cannon());
    try eqlStr("works", slice[2].cannon());
    std.testing.allocator.free(slice);
}

test "token pipeline slice safe with next()" {
    var ti = TokenIterator{
        .raw = "ls -la | cat | sort ; echo this works",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 10);

    ti.restart();
    len = 0;
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    ti.restart();

    var slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 2);
    std.testing.allocator.free(slice);

    _ = ti.next();

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 1);
    std.testing.allocator.free(slice);

    _ = ti.next();

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 1);
    std.testing.allocator.free(slice);

    _ = ti.next();

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 3);
    try eqlStr("echo", slice[0].cannon());
    try eqlStr("this", slice[1].cannon());
    try eqlStr("works", slice[2].cannon());
    std.testing.allocator.free(slice);
}

test "token > file" {
    var ti = TokenIterator{
        .raw = "ls > file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    try eqlStr("ls", ti.first().cannon());
    var iot = ti.next().?;
    try eqlStr("file.txt", iot.cannon());
    try std.testing.expect(iot.kind == .IoRedir);
    try std.testing.expect(iot.kindext.io == .Out);
}

test "token > file extra ws" {
    var ti = TokenIterator{
        .raw = "ls >               file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    try eqlStr("ls", ti.first().cannon());
    try eqlStr("file.txt", ti.next().?.cannon());
}

test "token > execSlice" {
    var ti = TokenIterator{
        .raw = "ls > file.txt",
    };

    var len: usize = 0;
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    try eqlStr("ls", ti.first().cannon());
    var iot = ti.next().?;
    try eqlStr("file.txt", iot.cannon());
    try std.testing.expect(iot.kind == .IoRedir);
    try std.testing.expect(iot.kindext.io == .Out);

    ti.restart();
    try std.testing.expect(ti.peek() != null);
    var slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expect(ti.peek() == null);
    try std.testing.expect(ti.peek() == null);
    try std.testing.expect(ti.peek() == null);
    try std.testing.expect(ti.peek() == null);
    std.testing.allocator.free(slice);
}

test "token >> file" {
    var ti = TokenIterator{
        .raw = "ls >> file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    try eqlStr("ls", ti.first().cannon());
    var iot = ti.next().?;
    try eqlStr("file.txt", iot.cannon());
    try std.testing.expect(iot.kind == .IoRedir);
    try std.testing.expect(iot.kindext.io == .Append);
}

test "token < file" {
    var ti = TokenIterator{
        .raw = "ls < file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    try eqlStr("ls", ti.first().cannon());
    try eqlStr("file.txt", ti.next().?.cannon());
}

test "token < file extra ws" {
    var ti = TokenIterator{
        .raw = "ls <               file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 2);

    try eqlStr("ls", ti.first().cannon());
    try eqlStr("file.txt", ti.next().?.cannon());
}

test "token &&" {
    var ti = TokenIterator{
        .raw = "ls && success",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    try eqlStr("ls", ti.first().cannon());
    const n = ti.next().?;
    try eqlStr("&&", n.cannon());
    try std.testing.expect(n.kind == .Operator);
    try std.testing.expect(n.kindext == .oper);
    try std.testing.expect(n.kindext.oper == .Success);
    try eqlStr("success", ti.next().?.cannon());
}

const eqlStr = std.testing.expectEqualStrings;

test "token ||" {
    var ti = TokenIterator{
        .raw = "ls || fail",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    try eqlStr("ls", ti.first().cannon());
    const n = ti.next().?;
    try eqlStr("||", n.cannon());
    try std.testing.expect(n.kind == .Operator);
    try std.testing.expect(n.kindext == .oper);
    try std.testing.expect(n.kindext.oper == .Fail);
    try eqlStr("fail", ti.next().?.cannon());
}

test "token vari" {
    var t = try Tokenizer.vari("$string");

    try eqlStr("string", t.cannon());
}

test "token vari words" {
    var t = try Tokenizer.vari("$string ");
    try eqlStr("string", t.cannon());

    t = try Tokenizer.vari("$string993");
    try eqlStr("string", t.cannon());

    t = try Tokenizer.vari("$string 993");
    try eqlStr("string", t.cannon());

    t = try Tokenizer.vari("$string{} 993");
    try eqlStr("string", t.cannon());

    t = try Tokenizer.vari("$string+");
    try eqlStr("string", t.cannon());

    t = try Tokenizer.vari("$string:");
    try eqlStr("string", t.cannon());

    t = try Tokenizer.vari("$string~");
    try eqlStr("string", t.cannon());

    t = try Tokenizer.vari("$string-");
    try eqlStr("string", t.cannon());
}

test "token vari braces" {
    var t = try Tokenizer.any("$STRING");
    try eqlStr("STRING", t.cannon());

    t = try Tokenizer.any("${STRING}");
    try eqlStr("STRING", t.cannon());

    t = try Tokenizer.any("${STRING}extra");
    try eqlStr("STRING", t.cannon());

    t = try Tokenizer.any("${STR_ING}extra");
    try eqlStr("STR_ING", t.cannon());
}

test "all execs" {
    var tt = TokenIterator{ .raw = "ls -with -some -params && files || thing | pipeline ; othercmd & screenshot && some/rel/exec" };
    var count: usize = 0;
    while (tt.next()) |_| {
        while (tt.nextExec()) |_| {}
        _ = tt.next();
        count += 1;
    }
    try std.testing.expect(7 == count);
}

test "pop" {
    var a = std.testing.allocator;
    var t = Tokenizer.init(a);
    const str = "this is a string";
    for (str) |c| {
        try t.consumec(c);
    }

    for (str) |_| {
        try t.pop();
    }
    try std.testing.expectError(Error.Empty, t.pop());
    t.reset();
}
