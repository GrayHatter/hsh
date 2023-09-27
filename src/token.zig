const std = @import("std");
const log = @import("log");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
pub const Reserved = @import("logic.zig").Reserved;

pub const Token = @This();

pub const BREAKING_TOKENS = " \t\n\"\\'`${|><#;}";
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
    OutOfMemory,
    LineTooLong,
    TokenizeFailed,
    InvalidSrc,
    InvalidLogic,
    OpenGroup,
    OpenLogic,
};

pub const Logic = struct {};

pub const Kind = union(enum) {
    // legacy types, TODO REMOVE
    ws: void,
    path: void,
    vari: void,

    comment: void,

    // new types
    err: void,
    io: IOKind,
    logic: Logic,
    nos: void,
    oper: OpKind,
    quote: void,
    resr: Reserved,
    subp: void,
    word: void,
};

str: []const u8,
kind: Kind = .nos,
parsed: bool = false,
subtoken: u8 = 0,
// I hate this but I've spent too much time on this already #YOLO
resolved: ?[]u8 = null,
substr: ?[]const u8 = null,

pub fn make(str: []const u8, k: Kind) Token {
    return Token{
        .str = str,
        .kind = k,
    };
}

pub fn format(self: Token, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    // this is what net.zig does, so it's what I do
    if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
    try std.fmt.format(out, "Token({}){{{s}}}", .{ self.kind, self.str });
}

pub fn cannon(self: Token) []const u8 {
    if (self.resolved) |r| return r;

    return switch (self.kind) {
        .quote => return self.str[1 .. self.str.len - 1],
        .io, .vari, .path => return self.substr orelse self.str,
        .comment => return self.str[0..0],
        else => self.str,
    };
}

pub fn any(src: []const u8) Error!Token {
    return switch (src[0]) {
        '\'', '"' => group(src),
        '`' => group(src), // TODO magic
        '{', '(' => group(src), // TODO magic
        ' ', '\t', '\n' => space(src),
        '~', '/' => path(src),
        '>', '<' => ioredir(src),
        '|', '&', ';' => execOp(src),
        '$' => dollar(src),
        '#' => comment(src),
        '\\' => bkslsh(src),
        else => wordExpanded(src),
    };
}

fn ioredir(src: []const u8) Error!Token {
    if (src.len < 3) return Error.InvalidSrc;
    var i: usize = 1;
    var t = Token.make(src[0..1], .{ .io = .Err });
    switch (src[0]) {
        '<' => {
            t.str = if (src[1] == '<') src[0..2] else src[0..1];
            t.kind = .{ .io = .In };
        },
        '>' => {
            if (src[1] == '>') {
                t.str = src[0..2];
                t.kind = .{ .io = .Append };
                i = 2;
            } else {
                t.str = src[0..1];
                t.kind = .{ .io = .Out };
            }
        },
        else => return Error.InvalidSrc,
    }
    while (src[i] == ' ' or src[i] == '\t') : (i += 1) {}
    var target = (try word(src[i..])).str;
    t.substr = target;
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

pub fn comment(src: []const u8) Error!Token {
    if (std.mem.indexOf(u8, src, "\n")) |i| {
        return Token.make(src[0 .. i + 1], .comment);
    }

    return Token.make(src, .comment);
}

pub fn dollar(src: []const u8) Error!Token {
    if (src.len <= 1) return Error.InvalidSrc;
    std.debug.assert(src[0] == '$');

    switch (src[1]) {
        '{' => return vari(src),
        '(' => return cmdsub(src),
        else => return vari(src),
    }
}

pub fn cmdsub(src: []const u8) Error!Token {
    std.debug.assert(src[0] == '$');
    std.debug.assert(src[1] == '(');
    if (src.len <= 2) return Error.InvalidSrc;

    var offset: usize = 2;
    // loop over the token sort functions to find the final ) which will
    // close this command substitution. We can't simply look for the )
    // because it might be within a quoted string.
    while (offset < src.len and src[offset] != ')') {
        const tmp = any(src[offset..]) catch {
            offset += 1;
            continue;
        };
        if (tmp.kind == .quote) {
            offset += tmp.str.len;
            continue;
        }
        offset += 1;
    }
    if (offset >= src.len) {
        if (offset > src.len or src[offset - 1] != ')') {
            return Error.InvalidSrc;
        }
    } else if (src[offset] == ')' and src[offset - 1] != ')') offset += 1;

    return Token.make(src[0..offset], .subp);
}

pub fn vari(src: []const u8) Error!Token {
    if (src.len <= 1) return Error.InvalidSrc;
    std.debug.assert(src[0] == '$');

    if (src[1] == '{') {
        if (src.len < 4) return Error.InvalidSrc;
        if (std.ascii.isDigit(src[2])) return Error.InvalidSrc;
        if (std.mem.indexOf(u8, src, "}")) |end| {
            var t = try uAlphaNum(src[2..end]);
            t.substr = t.str;
            t.str = src[0 .. t.str.len + 3];
            t.kind = .vari;
            return t;
        } else return Error.InvalidSrc;
    }

    if (std.ascii.isDigit(src[1])) return Error.InvalidSrc;
    if (std.mem.indexOfAny(u8, src[1..2], "@*#?-$!0")) |_| {
        var t = Token.make(src[0..2], .vari);
        t.substr = src[1..2];
        return t;
    }
    var t = try uAlphaNum(src[1..]);
    t.substr = t.str;
    t.str = src[0 .. t.str.len + 1];
    t.kind = .vari;

    return t;
}

// ASCII only :<
pub fn word(src: []const u8) Error!Token {
    var end: usize = 0;
    while (end < src.len) {
        const s = src[end];
        if (std.mem.indexOfScalar(u8, BREAKING_TOKENS, s)) |_| {
            break;
        } else end += 1;
    }

    if (end <= 5) {
        if (Reserved.fromStr(src[0..end])) |typ| {
            return Token.make(src[0..end], .{ .resr = typ });
        }
    }

    return Token.make(src[0..end], .word);
}

pub fn wordExpanded(src: []const u8) Error!Token {
    var tkn = try word(src);
    if (tkn.str.len <= 5) {
        if (Reserved.fromStr(tkn.str)) |_| {
            return logic(src);
        }
    }

    return tkn;
}

pub fn logic(src: []const u8) Error!Token {
    const end = std.mem.indexOfAny(u8, src, BREAKING_TOKENS) orelse {
        if (Reserved.fromStr(src)) |typ| {
            return Token.make(src, .{ .resr = typ });
        }
        return Error.InvalidSrc;
    };
    var r = Reserved.fromStr(src[0..end]) orelse unreachable;

    const marker: Reserved = switch (r) {
        .If => .Fi,
        .Case => .Esac,
        .While => .Done,
        .For => .Done,
        else => return Token.make(src[0..end], .{ .resr = r }),
    };

    var offset: usize = end;
    while (offset < src.len) {
        const t = try any(src[offset..]);
        offset += t.str.len;
        if (t.kind == .resr) {
            if (t.kind.resr == marker) {
                return Token.make(src[0..offset], .{ .logic = .{} });
            }
        }
    }
    return Error.OpenLogic;
}

pub fn func(src: []const u8) Error!Token {
    return Token.make(src, .nos);
}

pub fn oper(src: []const u8) Error!Token {
    switch (src[0]) {
        '=' => return Token.make(src[0..1], .{ .io = .Err }),
        else => return Error.InvalidSrc,
    }
}

pub fn group(src: []const u8) Error!Token {
    if (src.len <= 1) return Error.OpenGroup;
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
    return quote(src, '\'');
}

pub fn quoteDouble(src: []const u8) Error!Token {
    return quote(src, '"');
}

pub fn paren(src: []const u8) Error!Token {
    if (src.len > 2 and src[1] == ')') {
        const ws = try space(src[2..]);
        if (ws.str.len > 0 and src[ws.str.len + 2] == '{') return func(src);
    }
    return quote(src, ')');
}

pub fn bracket(src: []const u8) Error!Token {
    return quote(src, ']');
}

pub fn bracketCurly(src: []const u8) Error!Token {
    return quote(src, '}');
}

pub fn backtick(src: []const u8) Error!Token {
    return quote(src, '`');
}

/// Callers must ensure that src[0] is in (', ")
pub fn quote(src: []const u8, close: u8) Error!Token {
    // TODO posix says a ' cannot appear within 'string'
    if (src.len <= 1 or src[0] == BSLH) {
        return Error.InvalidSrc;
    }

    var end: usize = 1;
    for (src[1..], 1..) |s, i| {
        end += 1;
        if (s == close and !(src[i - 1] == BSLH and src[i - 2] != BSLH)) break;
    }

    if (src[end - 1] != close) return Error.OpenGroup;

    return Token{
        .str = src[0..end],
        .kind = .quote,
        .subtoken = close,
    };
}

fn bkslsh(src: []const u8) Error!Token {
    std.debug.assert(src.len > 1);
    std.debug.assert(src[0] == '\\');

    return Token.make(src[0..2], .word);
}

fn space(src: []const u8) Error!Token {
    var end: usize = 0;
    for (src) |s| {
        if (s != ' ' and s != '\t' and s != '\n') break;
        end += 1;
    }
    return Token.make(src[0..end], .ws);
}

fn path(src: []const u8) Error!Token {
    var t = try word(src);
    t.kind = .path;
    return t;
}

pub const Iterator = struct {
    raw: []const u8,
    index: ?usize = null,
    token: Token = undefined,

    exec_index: ?usize = null,

    const Self = @This();

    pub fn first(self: *Self) *const Token {
        self.restart();
        if (self.next()) |n| {
            return n;
        } else {
            self.token = .{ .str = "" };
            return &self.token;
        }
    }

    pub fn next(self: *Self) ?*const Token {
        if (self.index) |i| {
            if (i >= self.raw.len) {
                return null;
            }
            if (any(self.raw[i..])) |t| {
                self.token = t;
                self.index = i + t.str.len;
                return &self.token;
            } else |e| {
                log.err("tokenizer error {}\n", .{e});
                return null;
            }
        } else {
            self.index = 0;
            return self.next();
        }
    }

    pub fn skip(self: *Self) void {
        _ = self.next();
    }

    /// returns next until index reaches an executable boundary,
    /// returns null if index is at that boundary.
    pub fn nextExec(self: *Self) ?*const Token {
        if (self.exec_index) |_| {} else {
            self.exec_index = self.index;
        }

        const t_ = self.next();
        if (t_) |t| {
            switch (t.kind) {
                .oper => {
                    self.index.? -= t.str.len;
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
            if (n.kind != .oper) {
                try list.append(n.*);
            }
        }
        while (self.nextExec()) |n| {
            try list.append(n.*);
        }
        return list.toOwnedSlice();
    }

    pub fn toSliceExecStr(self: *Self, a: Allocator) ![]const []const u8 {
        const tokens = try self.toSliceExec(a);
        var strs = try a.alloc([]u8, tokens.len);
        for (tokens, strs) |t, *s| {
            s.* = @constCast(t.str);
        }
        return strs;
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

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
test "quotes" {
    var t = try Token.group("\"\"");
    try expectEql(t.str.len, 2);
    try expectEql(t.cannon().len, 0);

    t = try Token.group("\"a\"");
    try expectEql(t.str.len, 3);
    try expectEql(t.cannon().len, 1);
    try expect(std.mem.eql(u8, t.str, "\"a\""));
    try expect(std.mem.eql(u8, t.cannon(), "a"));

    var terr = Token.group("\"this is invalid");
    try std.testing.expectError(Error.OpenGroup, terr);

    t = try Token.group("\"this is some text\" more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Token.group("`this is some text` more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "`this is some text`"));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    t = try Token.group("\"this is some text\" more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));

    terr = Token.group(
        \\"this is some text\" more text
    );
    try std.testing.expectError(Error.OpenGroup, terr);

    t = try Token.group("\"this is some text\\\" more text\"");
    try expectEql(t.str.len, 31);
    try expectEql(t.cannon().len, 29);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\\\" more text\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\" more text"));

    t = try Token.group("\"this is some text\\\\\" more text\"");
    try expectEql(t.str.len, 21);
    try expectEql(t.cannon().len, 19);
    try expect(std.mem.eql(u8, t.str, "\"this is some text\\\\\""));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text\\\\"));

    t = try Token.group("'this is some text' more text");
    try expectEql(t.str.len, 19);
    try expectEql(t.cannon().len, 17);
    try expect(std.mem.eql(u8, t.str, "'this is some text'"));
    try expect(std.mem.eql(u8, t.cannon(), "this is some text"));
}
test "path" {
    const tokenn = try path("blerg");
    try std.testing.expectEqualStrings(tokenn.str, "blerg");
}
