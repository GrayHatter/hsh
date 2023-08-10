const std = @import("std");
const log = @import("log");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.fs.File;
const io = std.io;
const mem = std.mem;
const CompOption = @import("completion.zig").CompOption;
const token = @import("token.zig");

const BREAKING_TOKENS = " \t\"'`${|><#;";
const BSLH = '\\';

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

pub const Error = error{
    Unknown,
    Memory,
    LineTooLong,
    TokenizeFailed,
    InvalidSrc,
    OpenGroup,
    Empty,
};

pub const Token = token.Token;
pub const TokenIterator = token.TokenIterator;
pub const Kind = token.Kind;

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
    raw_maybe: ?[]const u8 = null,
    prev_exec: ?ArrayList(u8) = null,
    hist_z: ?ArrayList(u8) = null,
    c_idx: usize = 0,
    c_tkn: usize = 0, // cursor is over this token
    err_idx: usize = 0,
    user_data: bool = false,

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
        if (self.raw.items.len == 0) return Error.Empty;
        while (i < self.raw.items.len) {
            const t = any(self.raw.items[i..]) catch break;
            if (t.str.len == 0) break;
            i += t.str.len;
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
            else => Tokenizer.word(src),
        };
    }

    //pub fn string(src: []const u8) Error!Token {
    //    if (mem.indexOfAny(u8, src[0..1], BREAKING_TOKENS)) |_| return Error.InvalidSrc;
    //    var end: usize = 0;
    //    for (src, 0..) |_, i| {
    //        end = i;
    //        if (mem.indexOfAny(u8, src[i .. i + 1], BREAKING_TOKENS)) |_| break else continue;
    //    } else end += 1;
    //    return Token.make(src[0..end], .word);
    //}

    fn ioredir(src: []const u8) Error!Token {
        if (src.len < 3) return Error.InvalidSrc;
        var i: usize = std.mem.indexOfAny(u8, src, " \t") orelse return Error.InvalidSrc;
        var t = Token.make(src[0..1], .{ .io = .Err });
        switch (src[0]) {
            '<' => {
                t.str = if (src.len > 1 and src[1] == '<') src[0..2] else src[0..1];
                t.kind = .{ .io = .In };
            },
            '>' => {
                if (src[1] == '>') {
                    t.str = src[0..2];
                    t.kind = .{ .io = .Append };
                } else {
                    t.str = src[0..1];
                    t.kind = .{ .io = .Out };
                }
            },
            else => return Error.InvalidSrc,
        }
        while (src[i] == ' ' or src[i] == '\t') : (i += 1) {}
        var target = (try any(src[i..])).str;
        t.resolved = target;
        t.str = src[0 .. i + target.len];
        return t;
    }

    fn execOp(src: []const u8) Error!Token {
        switch (src[0]) {
            ';' => return Token.make(src[0..1], .{ .oper = .Next }),
            '&' => {
                if (src.len > 1 and src[1] == '&') {
                    return Token.make(src[0..2], .{ .oper = .Success });
                }
                return Token.make(src[0..1], .{ .oper = .Background });
            },
            '|' => {
                if (src.len > 1 and src[1] == '|') {
                    return Token.make(src[0..2], .{ .oper = .Fail });
                }
                return Token.make(src[0..1], .{ .oper = .Pipe });
            },
            else => return Error.InvalidSrc,
        }
    }

    pub fn uAlphaNum(src: []const u8) Error!Token {
        var end: usize = 0;
        for (src) |s| {
            if (!std.ascii.isAlphanumeric(s) and s != '_')
                break;
            end += 1;
        }
        return Token.make(src[0..end], .word);
    }

    pub fn vari(src: []const u8) Error!Token {
        if (src.len <= 1) return Error.InvalidSrc;
        if (src[0] != '$') return Error.InvalidSrc;

        if (src[1] == '{') {
            if (src.len < 4) return Error.InvalidSrc;
            if (std.ascii.isDigit(src[2])) return Error.InvalidSrc;
            if (std.mem.indexOf(u8, src, "}")) |end| {
                var t = try uAlphaNum(src[2..end]);
                t.resolved = t.str;
                t.str = src[0 .. t.str.len + 3];
                t.kind = .vari;
                return t;
            } else return Error.InvalidSrc;
        }

        if (std.ascii.isDigit(src[1])) return Error.InvalidSrc;
        var t = try uAlphaNum(src[1..]);
        t.resolved = t.str;
        t.str = src[0 .. t.str.len + 1];
        t.kind = .vari;

        return t;
    }

    pub fn simple(src: []const u8) Error!Token {
        var end: usize = 0;
        while (end < src.len) {
            const s = src[end];
            if (std.mem.indexOfScalar(u8, BREAKING_TOKENS, s)) |_| break;
            end += 1;
        }
        return Token.make(src[0..end], .word);
    }

    // ASCII only :<
    pub fn word(src: []const u8) Error!Token {
        var end: usize = 0;
        while (end < src.len) {
            const s = src[end];
            if (std.mem.indexOfScalar(u8, BREAKING_TOKENS, s)) |_| {
                switch (s) {
                    // '\'', '"' => {
                    //     const t = try any(src[end..]);
                    //     std.debug.print("t {}\n", .{t.str.len});
                    //     end += t.str.len;
                    // },
                    ' ', '\t' => break,
                    else => {
                        const t = try any(src[end..]);
                        end += t.str.len;
                    },
                }
            } else end += 1;
        }
        return Token.make(src[0..end], .word);
    }

    pub fn oper(src: []const u8) Error!Token {
        switch (src[0]) {
            '=' => return Token.make(src[0..1], .{ .io = .Err }),
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
            .str = src[0..end],
            .kind = .quote,
            .subtoken = subt,
        };
    }

    fn space(src: []const u8) Error!Token {
        var end: usize = 0;
        for (src) |s| {
            if (s != ' ') break;
            end += 1;
        }
        return Token.make(src[0..end], .ws);
    }

    fn path(src: []const u8) Error!Token {
        var t = try Tokenizer.word(src);
        t.kind = .path;
        return t;
    }

    pub fn dropMaybe(self: *Tokenizer) !void {
        if (self.raw_maybe) |rm| {
            self.popRange(rm.len) catch {
                log.err("Unable to drop maybe {s} len = {}\n", .{ rm, rm.len });
                log.err("Unable to drop maybe {s} len = {}\n", .{ rm, rm.len });
                @panic("dropMaybe");
            };
            self.raw_maybe = null;
        }
    }

    /// str must be safe to insert directly as is
    pub fn addMaybe(self: *Tokenizer, str: []const u8) !void {
        self.raw_maybe = str;
        try self.consumes(str);
    }

    /// This function edits user text, so extra care must be taken to ensure
    /// it's something the user asked for!
    pub fn replaceToken(self: *Tokenizer, new: *const CompOption) !void {
        if (self.raw_maybe) |_| {
            try self.dropMaybe();
        } else if (new.kind == null) {
            self.raw_maybe = new.str;
        }
        //try self.addMaybe(new.str);

        if (new.kind == null) return;
        self.raw_maybe = new.str;

        try self.consumeSafeish(new.str);
    }

    pub fn replaceCommit(self: *Tokenizer, new: ?*const CompOption) !void {
        self.raw_maybe = null;
        if (new) |n| {
            switch (n.kind.?) {
                .file_system => |fs| {
                    switch (fs) {
                        .Dir => try self.consumec('/'),
                        .File, .Link, .Pipe => try self.consumec(' '),
                        else => {},
                    }
                },
                else => {},
            }
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

    fn dropWhitespace(self: *Tokenizer) Error!usize {
        if (self.c_idx == 0 or !std.ascii.isWhitespace(self.raw.items[self.c_idx - 1])) {
            return 0;
        }
        var count: usize = 1;
        self.c_idx -|= 1;
        var c = self.raw.orderedRemove(@intCast(self.c_idx));
        while (self.c_idx > 0 and std.ascii.isWhitespace(c)) {
            self.c_idx -|= 1;
            c = self.raw.orderedRemove(@intCast(self.c_idx));
            count +|= 1;
        }
        if (!std.ascii.isWhitespace(c)) {
            try self.consumec(c);
            count -|= 1;
        }
        return count;
    }

    fn dropAlphanum(self: *Tokenizer) Error!usize {
        if (self.c_idx == 0 or !std.ascii.isAlphanumeric(self.raw.items[self.c_idx - 1])) {
            return 0;
        }
        var count: usize = 1;
        self.c_idx -|= 1;
        var c = self.raw.orderedRemove(@intCast(self.c_idx));
        while (self.c_idx > 0 and std.ascii.isAlphanumeric(c)) {
            self.c_idx -|= 1;
            c = self.raw.orderedRemove(@intCast(self.c_idx));
            count +|= 1;
        }
        if (!std.ascii.isAlphanumeric(c)) {
            try self.consumec(c);
            count -|= 1;
        }
        return count;
    }

    // this clearly needs a bit more love
    pub fn dropWord(self: *Tokenizer) Error!usize {
        if (self.raw.items.len == 0 or self.c_idx == 0) return 0;

        var count = try self.dropWhitespace();
        var wd = try self.dropAlphanum();
        if (wd > 0) {
            count += wd;
            wd = try self.dropWhitespace();
            count += wd;
            if (wd > 0) {
                try self.consumec(' ');
                count -|= 1;
            }
        }
        return count;
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

    pub fn consumes(self: *Tokenizer, str: []const u8) Error!void {
        for (str) |s| try self.consumec(s);
    }

    pub fn consumec(self: *Tokenizer, c: u8) Error!void {
        self.raw.insert(self.c_idx, @bitCast(c)) catch return Error.Unknown;
        self.c_idx += 1;
        self.user_data = true;
    }

    pub fn saveLine(self: *Tokenizer) void {
        self.resetHist();
        self.hist_z = self.raw;
        self.raw = ArrayList(u8).init(self.alloc);
        self.user_data = false;
    }

    pub fn restoreLine(self: *Tokenizer) void {
        self.resetRaw();
        if (self.hist_z) |h| {
            self.raw = h;
            self.hist_z = null;
        }
        self.user_data = true;
        self.c_idx = self.raw.items.len;
    }

    pub fn reset(self: *Tokenizer) void {
        self.resetRaw();
        self.resetHist();
    }

    fn resetHist(self: *Tokenizer) void {
        if (self.hist_z) |*hz| hz.clearAndFree();
        self.hist_z = null;
        if (self.prev_exec) |*pr| pr.clearAndFree();
        self.prev_exec = null;
    }

    pub fn resetRaw(self: *Tokenizer) void {
        self.raw.clearAndFree();
        self.c_idx = 0;
        self.err_idx = 0;
        self.c_tkn = 0;
        self.user_data = false;
    }

    /// Doesn't exec, called to save previous "local" command
    pub fn exec(self: *Tokenizer) void {
        if (self.prev_exec) |*pr| pr.clearAndFree();
        self.prev_exec = self.raw;
        self.raw = ArrayList(u8).init(self.alloc);
        self.resetRaw();
    }

    pub fn raze(self: *Tokenizer) void {
        self.reset();
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
test "quotes" {
    var t = try Tokenizer.quote("\"\"");
    try expectEql(t.str.len, 2);
    try expectEql(t.cannon().len, 0);

    t = try Tokenizer.quote("\"a\"");
    try expectEql(t.str.len, 3);
    try expectEql(t.cannon().len, 1);
    try expect(std.mem.eql(u8, t.str, "\"a\""));
    try expect(std.mem.eql(u8, t.cannon(), "a"));

    var terr = Tokenizer.quote("\"this is invalid");
    try expectError(Error.OpenGroup, terr);

    t = try Tokenizer.quote("\"this is some text\" more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Tokenizer.quote("`this is some text` more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "`this is some text`"));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Tokenizer.quote("\"this is some text\" more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    terr = Tokenizer.quote(
        \\"this is some text\" more text
    );
    try expectError(Error.OpenGroup, terr);

    t = try Tokenizer.quote("\"this is some text\\\" more text\"");
    try expectEql(t.str.len, 31);
    try expectEql(t.cannon().len, 29);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\\\" more text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\" more text"));

    t = try Tokenizer.quote("\"this is some text\\\\\" more text\"");
    try expectEql(t.str.len, 21);
    try expectEql(t.cannon().len, 19);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\\\\\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\\"));

    t = try Tokenizer.quote("'this is some text' more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "'this is some text'"));
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
    try expect(std.mem.eql(u8, tokens[0].str, "\"this is some text\""));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("`this is some text` more text");
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].str, "`this is some text`"));
    try expect(std.mem.eql(u8, tokens[0].cannon(), "this is some text"));

    t.reset();
    try t.consumes("\"this is some text\" more text");
    a.free(tokens);
    titr = t.iterator();
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, 29);
    try expectEql(tokens[0].cannon().len, 17);
    try expect(std.mem.eql(u8, tokens[0].str, "\"this is some text\""));
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
    try expect(std.mem.eql(u8, tokens[0].str, "\"this is some text\\\" more text\""));

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

test "tokenize path" {
    var a = std.testing.allocator;
    const tokenn = try Tokenizer.path("blerg");
    try expect(eql(u8, tokenn.str, "blerg"));

    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("blerg ~/dir");
    var titr = t.iterator();
    var tokens = try titr.toSliceAny(a);
    try expectEql(t.raw.items.len, "blerg ~/dir".len);
    try expectEql(tokens.len, 3);
    try expect(tokens[2].kind == .path);
    try expect(eql(u8, tokens[2].str, "~/dir"));
    a.free(tokens);

    t.reset();
    try t.consumes("blerg /home/user/something");
    titr = t.iterator();
    tokens = try titr.toSliceAny(a);
    try expectEql(t.raw.items.len, "blerg /home/user/something".len);
    try expectEql(tokens.len, 3);
    try expect(tokens[2].kind == .path);
    try expect(eql(u8, tokens[2].str, "/home/user/something"));
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

    try std.testing.expectEqualStrings(tokens[2].cannon(), "two");
    t.c_idx = 7;
    try t.replaceToken(&CompOption{
        .str = "two",
        .kind = null,
    });

    try t.replaceToken(&CompOption{
        .str = "TWO",
    });
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSliceAny(a);

    try std.testing.expectEqualStrings(t.raw.items, "one TWO three");
    try std.testing.expectEqualStrings(tokens[2].cannon(), "TWO");
    try expect(tokens.len == 5);

    try t.replaceToken(&CompOption{
        .str = "TWO THREE",
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
    try expect(tokens.len == 3);
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expect(tokens.len == 2);
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
    try std.testing.expect(iot.kind.io == .Out);
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
    try std.testing.expect(iot.kind.io == .Out);

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
    try std.testing.expect(iot.kind.io == .Append);
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
    try std.testing.expect(n.kind == .oper);
    try std.testing.expect(n.kind.oper == .Success);
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
    try std.testing.expect(n.kind == .oper);
    try std.testing.expect(n.kind.oper == .Fail);
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
    try eqlStr("string993", t.cannon());

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

test "dropWhitespace" {
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();
    try t.consumes("a      ");
    try std.testing.expect(t.raw.items.len == 7);
    try std.testing.expect(try t.dropWhitespace() == 6);
    try std.testing.expect(t.raw.items.len == 1);

    t.reset();
    try t.consumes("a      b      ");
    try std.testing.expect(t.raw.items.len == 14);
    try std.testing.expect(try t.dropWhitespace() == 6);
    try std.testing.expect(t.raw.items.len == 8);
    try std.testing.expect(try t.dropWhitespace() == 0);
    try std.testing.expect(t.raw.items.len == 8);
    try t.pop();
    try std.testing.expect(try t.dropWhitespace() == 6);
    try std.testing.expect(t.raw.items.len == 1);
}

test "dropAlpha" {
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();
    try t.consumes("a      aoeu");
    try std.testing.expect(t.raw.items.len == 11);
    try std.testing.expect(try t.dropAlphanum() == 4);
    try std.testing.expect(t.raw.items.len == 7);

    t.reset();
    try t.consumes("a      b      aoeu");
    try std.testing.expect(t.raw.items.len == 18);
    try std.testing.expect(try t.dropAlphanum() == 4);
    try std.testing.expect(t.raw.items.len == 14);
    try std.testing.expect(try t.dropAlphanum() == 0);
    try std.testing.expect(t.raw.items.len == 14);
    _ = try t.dropWhitespace();
    try std.testing.expect(try t.dropAlphanum() == 1);
    try std.testing.expect(t.raw.items.len == 7);
}

test "dropWord" {
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();
    try t.consumes("a      ");
    try std.testing.expect(t.raw.items.len == 7);
    try std.testing.expect(try t.dropWord() == 7);
    try std.testing.expect(t.raw.items.len == 0);

    t.reset();
    try t.consumes("a      b      aoeu aoeu");
    try std.testing.expect(t.raw.items.len == 23);
    try std.testing.expect(try t.dropWord() == 4);
    try std.testing.expect(t.raw.items.len == 19);
    try std.testing.expect(try t.dropWord() == 10);
    try std.testing.expect(t.raw.items.len == 9);
}

test "ualphanum" {
    const t = try Tokenizer.uAlphaNum("word word");
    try std.testing.expect(t.str.len == 4);
    try std.testing.expectEqualStrings("word", t.cannon());
}

test "any" {
    var t = try Tokenizer.any("word");
    try std.testing.expectEqualStrings("word", t.cannon());
}

test "inline quotes" {
    var t = try Tokenizer.any("--inline='quoted string'");
    try std.testing.expectEqualStrings("--inline='quoted string'", t.cannon());
}
