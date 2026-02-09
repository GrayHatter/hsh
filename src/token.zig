str: []const u8,
kind: Kind = .nos,

const Token = @This();

pub const Reserved = @import("logic.zig").Reserved;
pub const BREAKING_CHAR = " \t\n\"\\'`${|><#;}";
const BSLH = '\\';

pub const IOKind = enum {
    heredoc,
    stderr,
    stderr_append,
    stdin,
    stdout,
    stdout_append,
};

pub const OpKind = enum {
    pipe,
    next,
    success,
    fail,
    background,
};

pub const Error = error{
    Unknown,
    OutOfMemory,
    IllegalToken,
    InvalidLogic,
    OpenGroup,
    OpenLogic,
};

pub const Logic = struct {};

pub const Kind = union(enum) {
    brace: u8,
    comment: void,
    err: void,
    escp: u8,
    io: IOKind,
    logic: Logic,
    nos: void,
    oper: OpKind,
    path: void,
    quote: u8,
    resr: Reserved,
    subp: void,
    vari: void,
    word: void,
    ws: void,

    pub const Quote = enum(u8) {
        bt = '`',
        dq = '"',
        sq = '\'',
    };

    pub fn continues(k: Kind) bool {
        return switch (k) {
            .ws, .oper => false,
            else => true,
        };
    }
};

fn seekTo(str: []const u8, char: u8) ?usize {
    var idx: usize = 0;
    while (idx < str.len) : (idx += 1) {
        const c = str[idx];
        if (c == '\\') {
            idx += 1;
            if (char == '\\' and idx < str.len and str[idx] == '\\') return idx;
        } else if (c == char) {
            return idx;
        }
    } else return null;
}

pub fn make(str: []const u8, k: Kind) Token {
    return .{ .str = str, .kind = k };
}

pub fn any(src: []const u8) Error!Token {
    return switch (src[0]) {
        '\'', '"' => group(src),
        '`' => group(src), // TODO magic
        '{', '(' => group(src), // TODO magic
        ' ', '\t', '\n' => space(src),
        '~', '/' => path(src),
        '>', '<' => ioRedirect(src),
        '|', '&', ';' => execOp(src),
        '$' => dollar(src),
        '#' => comment(src),
        '\\' => backslsh(src),
        else => wordExpanded(src),
    };
}

fn ioRedirect(src: []const u8) Error!Token {
    if (src.len < 3) return error.IllegalToken;
    var i: usize = 1;
    var t: Token = .make(src[0..1], .{ .io = .stderr });
    switch (src[0]) {
        '<' => {
            t.str = if (src[1] == '<') src[0..2] else src[0..1];
            t.kind = .{ .io = .stdin };
        },
        '>' => {
            if (src[1] == '>') {
                t.str = src[0..2];
                t.kind = .{ .io = .stdout_append };
                i = 2;
            } else {
                t.str = src[0..1];
                t.kind = .{ .io = .stdout };
            }
        },
        else => return error.IllegalToken,
    }
    while (src[i] == ' ' or src[i] == '\t') : (i += 1) {}
    const target = (try word(src[i..])).str;
    t.str = src[0 .. i + target.len];
    return t;
}

fn execOp(src: []const u8) Error!Token {
    switch (src[0]) {
        ';' => return .make(src[0..1], .{ .oper = .next }),
        '&' => if (src.len > 1 and src[1] == '&')
            return .make(src[0..2], .{ .oper = .success })
        else
            return .make(src[0..1], .{ .oper = .background }),
        '|' => if (src.len > 1 and src[1] == '|')
            return .make(src[0..2], .{ .oper = .fail })
        else
            return .make(src[0..1], .{ .oper = .pipe }),
        else => return error.IllegalToken,
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
        return Token.make(src[0..i], .comment);
    }

    return Token.make(src, .comment);
}

pub fn dollar(src: []const u8) Error!Token {
    if (src.len <= 1) return error.IllegalToken;
    assert(src[0] == '$');

    switch (src[1]) {
        '{' => return vari(src),
        '(' => return subCommand(src),
        else => return vari(src),
    }
}

pub fn subCommand(src: []const u8) Error!Token {
    assert(src.len > 2);
    assert(src[0] == '$');
    assert(src[1] == '(');
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
            return error.IllegalToken;
        }
    } else if (src[offset] == ')' and src[offset - 1] != ')') offset += 1;

    return .make(src[0..offset], .subp);
}

pub fn vari(src: []const u8) Error!Token {
    assert(src[0] == '$');
    if (src.len <= 1) return error.IllegalToken;

    if (src[1] == '{') {
        if (src.len < 4) return error.IllegalToken;
        if (std.ascii.isDigit(src[2])) return error.IllegalToken;
        if (findScalar(u8, src, '}')) |end| {
            var t = try uAlphaNum(src[2..end]);
            return .make(src[0 .. t.str.len + 3], .vari);
        } else return error.IllegalToken;
    }

    if (std.ascii.isDigit(src[1])) return error.IllegalToken;
    const SPECIALS = "@*#?-$!0";
    for (SPECIALS) |s| if (src[1] == s) return .make(src[0..2], .vari);

    const wt = try uAlphaNum(src[1..]);
    return .make(src[0 .. wt.str.len + 1], .vari);
}

// ASCII only :<
pub fn word(src: []const u8) Error!Token {
    var end: usize = 0;
    while (end < src.len) : (end += 1) {
        if (findScalar(u8, BREAKING_CHAR, src[end])) |_|
            break;
    }

    if (end <= 5) {
        if (Reserved.fromStr(src[0..end])) |typ| {
            return Token.make(src[0..end], .{ .resr = typ });
        }
    }

    return Token.make(src[0..end], .word);
}

pub fn wordExpanded(src: []const u8) Error!Token {
    const tkn = try word(src);

    // I know, and I'm sorry
    if (tkn.str.len <= 5) {
        if (Reserved.fromStr(tkn.str)) |_| {
            return logic(src);
        }
    }

    if (src.len > tkn.str.len) {
        var offset: usize = tkn.str.len;
        // TODO accept other whitespace?
        while (offset < src.len and src[offset] == ' ') offset += 1;

        const f = func(src[offset..]) catch return tkn;
        return Token.make(src[0 .. offset + f.str.len], .nos);
    }

    return tkn;
}

pub fn logic(src: []const u8) Error!Token {
    const end = findAny(u8, src, BREAKING_CHAR) orelse {
        if (Reserved.fromStr(src)) |typ| {
            return .make(src, .{ .resr = typ });
        }
        return error.InvalidLogic;
    };
    const r = Reserved.fromStr(src[0..end]) orelse unreachable;

    const marker: Reserved = switch (r) {
        .If => .Fi,
        .Case => .Esac,
        .While => .Done,
        .For => .Done,
        else => return .make(src[0..end], .{ .resr = r }),
    };

    var offset: usize = end;
    while (offset < src.len) {
        const t = try any(src[offset..]);
        offset += t.str.len;
        if (t.kind == .resr) {
            if (t.kind.resr == marker) {
                return .make(src[0..offset], .{ .logic = .{} });
            }
        }
    }
    return error.OpenLogic;
}

pub fn func(src: []const u8) Error!Token {
    if (src.len < 4) return error.InvalidLogic;
    if (src[0] != '(' or src[1] != ')') {
        return error.InvalidLogic;
    }
    const ws = try space(src[2..]);
    var end: usize = 2 + ws.str.len;
    if (src[end] != '{') return error.InvalidLogic;
    const t = try any(src[end..]);
    end += t.str.len;

    return .make(src[0..end], .nos);
}

pub fn oper(src: []const u8) Error!Token {
    switch (src[0]) {
        '=' => return Token.make(src[0..1], .{ .io = .Err }),
        else => return error.InvalidSrc,
    }
}

pub fn group(src: []const u8) Error!Token {
    if (src.len <= 1) return error.OpenGroup;
    return switch (src[0]) {
        '\'' => quoteSingle(src),
        '"' => quoteDouble(src),
        '(' => paren(src),
        '[' => bracket(src),
        '{' => bracketCurly(src),
        '`' => backtick(src),
        else => unreachable,
    };
}

pub fn quoteSingle(src: []const u8) Error!Token {
    return quote(src, '\'');
}

pub fn quoteDouble(src: []const u8) Error!Token {
    return quote(src, '"');
}

pub fn backtick(src: []const u8) Error!Token {
    return quote(src, '`');
}

pub fn quote(src: []const u8, close: u8) Error!Token {
    // TODO posix says a ' cannot appear within 'string'
    const c = src[0];
    assert(c == '\'' or c == '"' or c == '`');

    var end: usize = seekTo(src[1..], close) orelse return error.OpenGroup;
    end += 2;

    return Token{
        .str = src[0..end],
        .kind = .{ .quote = close },
    };
}

pub fn paren(src: []const u8) Error!Token {
    return brace(src, ')');
}

pub fn bracket(src: []const u8) Error!Token {
    return brace(src, ']');
}

pub fn bracketCurly(src: []const u8) Error!Token {
    return brace(src, '}');
}

pub fn brace(src: []const u8, close: u8) Error!Token {
    var end: usize = 1;
    var skip: usize = 0;
    for (src[1..]) |s| {
        if (skip > 0) {
            skip -|= 1;
            end += 1;
            continue;
        }
        if (s == '"' or s == '\'') {
            const qut = try group(src[end..]);
            end += @max(1, qut.str.len);
            skip += qut.str.len;
            continue;
        }
        end += 1;
        if (s == close) break;
    }

    if (src[end - 1] != close) return error.OpenGroup;

    return .{
        .str = src[0..end],
        .kind = .{ .brace = close },
    };
}

fn backslsh(src: []const u8) Error!Token {
    assert(src.len > 1);
    assert(src[0] == '\\');

    return .make(src[0..2], .{ .escp = src[1] });
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
    return .make((try word(src)).str, .path);
}

pub const Iterator = struct {
    raw: []const u8,
    index: ?usize = null,

    exec_index: ?usize = null,

    const Self = @This();

    pub fn peek(self: *Self) ?Token {
        if (self.index) |i| {
            if (i >= self.raw.len) {
                return null;
            }
            if (any(self.raw[i..])) |t| {
                return t;
            } else |e| {
                log.err("tokenizer error {}\n", .{e});
                return null;
            }
        } else {
            self.index = 0;
            return self.peek();
        }
    }

    pub fn first(self: *Self) Token {
        self.restart();
        return self.next().?;
    }

    pub fn next(self: *Self) ?Token {
        if (self.peek()) |token| {
            self.index.? += token.str.len;
            return token;
        }
        return null;
    }

    pub fn skip(self: *Self) void {
        _ = self.next();
    }

    /// returns next until index reaches an executable boundary,
    /// returns null if index is at that boundary.
    pub fn nextExec(self: *Self) ?Token {
        if (self.exec_index) |_| {} else {
            self.exec_index = self.index;
        }

        const t = self.peek() orelse return null;
        switch (t.kind) {
            .oper => return null,
            else => return self.next(),
        }
    }

    // caller owns the memory, this will reset the index
    pub fn toSlice(self: *Self, a: std.mem.Allocator) ![]Token {
        var list: std.ArrayList(Token) = .{};
        self.index = 0;
        while (self.next()) |n| {
            try list.append(a, n);
        }
        return list.toOwnedSlice(a);
    }

    // caller owns the memory, this will will move the index so calling next
    // will return the command delimiter (if existing),
    // Any calls to toSliceExec when current index is a command delemiter will
    // start at the following word slice.
    // calling this invalidates the previously returned pointer from next/peek
    pub fn toSliceExec(self: *Self, a: std.mem.Allocator) ![]Token {
        var list: ArrayList(Token) = .{};
        if (self.nextExec()) |n| {
            try list.append(a, n);
        } else if (self.next()) |n| {
            if (n.kind != .oper) {
                try list.append(a, n);
            }
        }
        while (self.nextExec()) |n| {
            try list.append(a, n);
        }
        return list.toOwnedSlice(a);
    }

    pub fn toSliceExecStr(self: *Self, a: std.mem.Allocator) ![]const []const u8 {
        const tokens = try self.toSliceExec(a);
        const strs = try a.alloc([]u8, tokens.len);
        for (tokens, strs) |t, *s| {
            s.* = @constCast(t.str);
        }
        return strs;
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
const expectEqualStrings = std.testing.expectEqualStrings;
test "quotes" {
    var t = try Token.group("\"\"");
    try expectEql(t.str.len, 2);

    t = try Token.group("\"a\"");
    try expectEql(3, t.str.len);
    try expectEqualStrings(t.str, "\"a\"");

    var terr = Token.group("\"this is invalid");
    try std.testing.expectError(error.OpenGroup, terr);

    t = try Token.group("\"this is some text\" more text");
    try expectEql(19, t.str.len);
    try expectEqualStrings(t.str, "\"this is some text\"");

    t = try Token.group("`this is some text` more text");
    try expectEql(19, t.str.len);
    try expectEqualStrings(t.str, "`this is some text`");

    t = try Token.group("\"this is some text\" more text");
    try expectEql(19, t.str.len);
    try expectEqualStrings(t.str, "\"this is some text\"");

    terr = Token.group(
        \\"this is some text\" more text
    );
    try std.testing.expectError(error.OpenGroup, terr);

    t = try Token.group("\"this is some text\\\" more text\"");
    try expectEql(31, t.str.len);
    try expectEqualStrings(t.str, "\"this is some text\\\" more text\"");

    t = try Token.group("\"this is some text\\\\\" more text\"");
    try expectEql(21, t.str.len);
    try expectEqualStrings(t.str, "\"this is some text\\\\\"");

    t = try Token.group("'this is some text' more text");
    try expectEql(19, t.str.len);
    try expectEqualStrings(t.str, "'this is some text'");
}

test "path" {
    const tokenn = try path("blerg");
    try std.testing.expectEqualStrings(tokenn.str, "blerg");
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const log = @import("log.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const findScalar = std.mem.findScalar;
const findScalarPos = std.mem.findScalarPos;
const findAny = std.mem.findAny;
const assert = std.debug.assert;
