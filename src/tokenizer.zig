buffer: [8192]u8 = undefined,
idx: usize = 0,
len: usize = 0,
raw_maybe: ?[]const u8 = null,
prev_exec: ?[]u8 = null,
c_tkn: usize = 0, // cursor is over this token
err_idx: usize = 0,
edited: bool = false,
editor_mktmp: ?[]u8 = null,

const Tokenizer = @This();

pub const TokenError = Token.Error;

pub const Error = error{
    Empty,
    Exec,
    OutOfMemory,
};

pub const Cursor = enum(usize) {
    _,

    pub const Motion = enum(u8) {
        home,
        end,
        back, // backwards boundary
        word, // forward boundary
        inc,
        dec,

        prev_line,
        next_line,

        pub const left: Motion = .dec;
        pub const right: Motion = .inc;
    };
};

pub fn fromSlice(str: []const u8) Tokenizer {
    var tzr: Tokenizer = .{};
    tzr.consumeSlice(str) catch {};
    return tzr;
}

pub fn getSlice(tkzr: Tokenizer) []const u8 {
    return tkzr.buffer[0..tkzr.len];
}

fn cChar(tkzr: *Tokenizer) ?u8 {
    if (tkzr.len == 0) return null;
    if (tkzr.idx == tkzr.len) return tkzr.buffer[tkzr.idx - 1];
    return tkzr.buffer[tkzr.idx];
}

fn cToBoundry(tkzr: *Tokenizer, comptime forward: bool) void {
    assert(tkzr.len > 0);
    const cursor = if (forward) .inc else .dec;
    tkzr.move(cursor);

    while (isWhitespace(tkzr.cChar().?) and tkzr.idx > 0 and tkzr.idx < tkzr.len) {
        tkzr.move(cursor);
    }

    while (!isWhitespace(tkzr.cChar().?) and tkzr.idx != 0 and tkzr.idx < tkzr.len) {
        tkzr.move(cursor);
    }
    if (!forward and tkzr.idx != 0) tkzr.move(.inc);
}

pub fn move(tkzr: *Tokenizer, motion: Cursor.Motion) void {
    if (tkzr.len == 0) return;
    switch (motion) {
        .home => tkzr.idx = 0,
        .end => tkzr.idx = tkzr.len,
        .back => tkzr.cToBoundry(false),
        .word => tkzr.cToBoundry(true),
        .inc => tkzr.idx +|= 1,
        .dec => tkzr.idx -|= 1,

        .prev_line => unreachable,
        .next_line => unreachable,
    }
    tkzr.idx = @min(tkzr.idx, tkzr.len);
}

pub fn cursorToken(tkzr: *Tokenizer) !Token {
    var i: usize = 0;
    tkzr.c_tkn = 0;
    if (tkzr.len == 0) return Error.Empty;
    while (i < tkzr.len) {
        const t = Token.any(tkzr.getSlice()[i..]) catch break;
        if (t.str.len == 0) break;
        i += t.str.len;
        if (i >= tkzr.idx) return t;
        tkzr.c_tkn += 1;
    }
    return error.TokenizeFailed;
}

pub const iterator = iterate;

pub fn iterate(tkzr: *const Tokenizer) Token.Iterator {
    return .{ .raw = tkzr.buffer[0..tkzr.len] };
}

/// Returns a Token error
pub fn validate(tkzr: *Tokenizer) TokenError!void {
    var i: usize = 0;
    while (i < tkzr.len) {
        const t = try Token.any(tkzr.buffer[i..tkzr.len]);
        i += t.str.len;
    }
}

pub fn count(tkzr: Tokenizer) usize {
    var itr = tkzr.iterator();
    var c: usize = 0;
    while (itr.next()) |_| c += 1;
    return c;
}

// completion commands

/// remove the completion maybe from input
pub fn maybeRemove(tkzr: *Tokenizer, a: Allocator) !void {
    if (tkzr.raw_maybe) |rm|
        tkzr.removeRange(rm.len);
    tkzr.maybeClear(a);
}

pub fn maybeClear(tkzr: *Tokenizer, a: Allocator) void {
    if (tkzr.raw_maybe) |rm| a.free(rm);
    tkzr.raw_maybe = null;
}

pub fn maybeSetOriginal(tkzr: *Tokenizer, orig: []const u8, a: Allocator) !void {
    assert(tkzr.raw_maybe == null);
    tkzr.raw_maybe = try a.dupe(u8, orig);
}

pub fn maybeAdd(tkzr: *Tokenizer, str: []const u8, a: Allocator) !void {
    if (checkSafe(str)) {
        try tkzr.consumeSlice(str);
        return;
    }

    const safe = try dupeSafe(str, a);
    defer a.free(safe);
    try tkzr.consumeSlice(safe);
}

/// This function edits user text, so extra care must be taken to ensure
/// it's something the user asked for!
pub fn maybeReplace(tkzr: *Tokenizer, new: []const u8, a: Allocator) !void {
    try tkzr.maybeRemove(a);
    //if (new.kind == .original) return;
    tkzr.raw_maybe = try dupeSafe(new, a);
    try tkzr.consumeSlice(tkzr.raw_maybe.?);
}

pub fn maybeCommit(tkzr: *Tokenizer, trailing: ?u8, a: Allocator) !void {
    tkzr.maybeClear(a);
    //if (new) |n| switch (n.kind) {
    //    .original => {},
    //    .file_system => |f_s| {
    //        switch (f_s) {
    //            .dir => try tkzr.consumeChar('/'),
    //            .file, .link, .pipe => try tkzr.consumeChar(' '),
    //            else => {},
    //        }
    //    },
    //    .path_exe => try tkzr.consumeChar(' '),
    //    .any => unreachable,
    //};
    if (trailing) |t| try tkzr.consumeChar(t);
}

pub fn checkSafe(str: []const u8) bool {
    return findAny(u8, str, Token.BREAKING_TOKENS) == null;
}

fn dupeSafe(str: []const u8, a: Allocator) ![]u8 {
    if (str.len == 0) return &.{};
    if (checkSafe(str)) return a.dupe(u8, str);

    var extra: usize = str.len;
    for (Token.BREAKING_TOKENS) |t| {
        extra += countScalar(u8, str, t);
    }
    assert(extra > str.len);

    var safer = try a.alloc(u8, extra);
    var dst: [*]u8 = safer.ptr;

    for (str) |chr| {
        for (Token.BREAKING_TOKENS) |bad| {
            if (bad == chr) {
                dst[0] = '\\';
                dst += 1;
                break;
            }
        }
        dst[0] = chr;
        dst += 1;
    }
    assert(dst == safer.ptr + safer.len);
    return safer;
}

fn removeWhitespace(tkzr: *Tokenizer) usize {
    if (tkzr.idx == 0 or !isWhitespace(tkzr.buffer[tkzr.idx - 1])) {
        return 0;
    }
    var c: usize = 0;
    var idx = tkzr.idx - 1;
    while (idx > 0 and isWhitespace(tkzr.buffer[idx])) {
        idx -= 1;
        c += 1;
    }

    tkzr.removeRange(c);
    return c;
}

fn removeAlphanum(tkzr: *Tokenizer) usize {
    if (tkzr.idx == 0)
        return 0;

    var extra: u1 = 0;
    if (tkzr.buffer[tkzr.idx - 1] == '/' or tkzr.buffer[tkzr.idx - 1] == '.') {
        tkzr.remove();
        extra = 1;
    }
    var idx = tkzr.idx;
    var c: usize = 0;
    while (idx > 0 and (isAlphanumeric(tkzr.buffer[idx - 1]) or tkzr.buffer[idx - 1] == '-')) {
        idx -= 1;
        c += 1;
    }

    tkzr.removeRange(c);
    return c + extra;
}

// this clearly needs a bit more love
pub fn removeWord(tkzr: *Tokenizer) usize {
    if (tkzr.len == 0 or tkzr.idx == 0) return 0;

    const white = tkzr.removeWhitespace();
    const word = tkzr.removeAlphanum();
    var extra: usize = 0;
    if (word > 0 and tkzr.idx > 0 and tkzr.buffer[tkzr.idx - 1] == ' ') {
        extra = tkzr.removeWhitespace();
        tkzr.consumeChar(' ') catch unreachable;
        extra -|= 1;
    }
    return white + word + extra;
}

pub fn remove(tkzr: *Tokenizer) void {
    if (tkzr.len == 0) return;
    tkzr.idx -|= 1;
    tkzr.len -|= 1;
    tkzr.err_idx = @min(tkzr.idx, tkzr.err_idx);
    tkzr.edited = tkzr.len > 0;
    if (tkzr.idx == 0) return;
    if (tkzr.idx != tkzr.len) {
        @memmove(tkzr.buffer[tkzr.idx..tkzr.len], tkzr.buffer[tkzr.idx + 1 .. tkzr.len + 1]);
    }
}

pub fn removeReverse(tkzr: *Tokenizer) void {
    if (tkzr.len == 0 or tkzr.idx == tkzr.len) return;
    tkzr.idx += 1;
    assert(tkzr.idx <= tkzr.len);
    tkzr.remove();
}

pub fn removeRange(tkzr: *Tokenizer, num: usize) void {
    if (num == 0) return;
    if (tkzr.len == 0 or tkzr.idx == 0) return;
    if (num > tkzr.len) {
        tkzr.idx = 0;
        tkzr.len = 0;
        return;
    }

    assert(tkzr.idx >= num);

    if (tkzr.idx < tkzr.len) {
        for (tkzr.buffer[tkzr.idx..tkzr.len], tkzr.buffer[tkzr.idx - num .. tkzr.len - num]) |s, *d|
            d.* = s;
    }
    tkzr.edited = true;
    tkzr.idx -= num;
    tkzr.len -= num;
}

/// consumeSlice will swallow exec, assuming strings shouldn't be able to
/// start execution
pub fn consumeSlice(tkzr: *Tokenizer, str: []const u8) Error!void {
    assert(tkzr.len + str.len < tkzr.buffer.len);

    if (tkzr.idx < tkzr.len) {
        const len = tkzr.len - tkzr.idx;
        @memmove(tkzr.buffer[tkzr.idx + str.len ..][0..len], tkzr.buffer[tkzr.idx..][0..len]);
    }
    @memcpy(tkzr.buffer[tkzr.idx .. tkzr.idx + str.len], str[0..]);
    tkzr.edited = true;
    tkzr.idx += str.len;
    tkzr.len += str.len;
}

pub fn consumeChar(tkzr: *Tokenizer, c: u8) Error!void {
    assert(tkzr.len < tkzr.buffer.len);

    if (tkzr.len > tkzr.idx) {
        const len = tkzr.len - tkzr.idx;
        @memmove(tkzr.buffer[tkzr.idx + 1 ..][0..len], tkzr.buffer[tkzr.idx..][0..len]);
    }
    tkzr.buffer[tkzr.idx] = c;
    tkzr.edited = true;
    tkzr.idx += 1;
    tkzr.len += 1;

    if (c == '\n') {
        if (tkzr.idx == tkzr.len and tkzr.len > 1 and tkzr.buffer[tkzr.idx - 2] != '\\') {
            return error.Exec;
        }
    }
}

pub fn reset(tkzr: *Tokenizer) void {
    tkzr.idx = 0;
    tkzr.len = 0;
    tkzr.err_idx = 0;
    tkzr.c_tkn = 0;
    tkzr.edited = false;
}

/// Doesn't exec, called to save previous "local" command
pub fn exec(tkzr: *Tokenizer, a: Allocator) !void {
    if (tkzr.prev_exec) |pr| a.free(pr);
    tkzr.prev_exec = try a.dupe(u8, tkzr.getSlice());
    tkzr.reset();
}

pub fn raze(tkzr: *Tokenizer, a: Allocator) void {
    tkzr.reset();
    tkzr.maybeClear(a);
}

pub fn razeExec(tkzr: Tokenizer, a: Allocator) void {
    if (tkzr.prev_exec) |prexec| a.free(prexec);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test consumeChar {
    var t: Tokenizer = .{};
    try expectEqual(0, t.idx);
    try expectEqual(0, t.len);
    try t.consumeSlice("01256");
    try expectEqualStrings("01256", t.getSlice());
    try expectEqual(5, t.idx);
    try expectEqual(5, t.len);
    t.move(.left);
    t.move(.dec);
    try expectEqual(3, t.idx);
    try expectEqualStrings("01256", t.getSlice());
    try t.consumeChar('3');
    try expectEqual(4, t.idx);
    try expectEqual(6, t.len);
    try expectEqualStrings("012356", t.getSlice());
    try t.consumeChar('4');
    try expectEqual(5, t.idx);
    try expectEqual(7, t.len);
    try expectEqualStrings("0123456", t.getSlice());
    t.move(.home);
    try expectEqual(0, t.idx);
    try t.consumeChar('_');
    try expectEqual(1, t.idx);
    try expectEqual(8, t.len);
    try expectEqualStrings("_0123456", t.getSlice());
    try t.consumeChar('-');
    try expectEqual(2, t.idx);
    try expectEqual(9, t.len);
    try expectEqualStrings("_-0123456", t.getSlice());
}

test "quotes tokened" {
    var a = std.testing.allocator;
    var t: Tokenizer = .{};
    defer t.raze(a);

    try t.consumeSlice("\"\"");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expectEqual(t.len, 2);
    try expectEqual(1, tokens.len);

    t.reset();
    try t.consumeSlice("\"a\"");
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expectEqual(t.len, 3);
    try expectEqualStrings(t.buffer[0..t.len], "\"a\"");
    try expectEqual(3, tokens[0].str.len);
    try expectEqualStrings("\"a\"", tokens[0].str);

    var terr = Token.group(
        \\"this is invalid
    );
    try expectError(TokenError.OpenGroup, terr);

    t.reset();
    try t.consumeSlice("\"this is some text\" more text");
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expectEqual(t.len, 29);
    try expectEqual(19, tokens[0].str.len);
    try expectEqualStrings(tokens[0].str, "\"this is some text\"");

    t.reset();
    try t.consumeSlice("`this is some text` more text");
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    try expectEqual(t.len, 29);
    try expectEqual(19, tokens[0].str.len);
    try expectEqualStrings(tokens[0].str, "`this is some text`");

    t.reset();
    try t.consumeSlice("\"this is some text\" more text");
    a.free(tokens);
    titr = t.iterator();
    tokens = try titr.toSlice(a);
    try expectEqual(t.len, 29);
    try expectEqual(19, tokens[0].str.len);
    try expectEqualStrings(tokens[0].str, "\"this is some text\"");

    terr = Token.group(
        \\"this is some text\" more text
    );
    try expectError(TokenError.OpenGroup, terr);

    t.reset();
    try t.consumeSlice(
        \\"this is some text\" more text"
    );
    a.free(tokens);
    titr = t.iterator();
    tokens = try titr.toSlice(a);
    try expectEqual(31, t.len);
    try expectEqualStrings(
        \\"this is some text\" more text"
    , tokens[0].str);

    try expectEqual("\"this is some text\\\" more text\"".len, tokens[0].str.len);
    try expectEqual(31, tokens[0].str.len);
    try expectEqualStrings(
        \\"this is some text\" more text"
    , tokens[0].str);
    a.free(tokens);
}

test "tokens" {
    var a = std.testing.allocator;
    var t: Tokenizer = .{};
    defer t.raze(a);
    for ("token") |c| {
        try t.consumeChar(c);
    }
    var titr = t.iterator();
    const tokens = try titr.toSlice(a);
    defer a.free(tokens);
    try expectEqualStrings(t.buffer[0..t.len], "token");
}

test "tokenize path" {
    var a = std.testing.allocator;
    var t: Tokenizer = .{};
    defer t.raze(a);

    try t.consumeSlice("blerg ~/dir");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expectEqual(t.len, "blerg ~/dir".len);
    try expectEqual(tokens.len, 3);
    try expect(tokens[2].kind == .path);
    try expectEqualStrings("~/dir", tokens[2].str);
    a.free(tokens);

    t.reset();
    try t.consumeSlice("blerg /home/user/something");
    titr = t.iterator();
    tokens = try titr.toSlice(a);
    try expectEqual(t.len, "blerg /home/user/something".len);
    try expectEqual(tokens.len, 3);
    try expect(tokens[2].kind == .path);
    try expectEqualStrings("/home/user/something", tokens[2].str);
    a.free(tokens);
}

test "replace token" {
    var a = std.testing.allocator;
    var t: Tokenizer = .{};
    defer t.raze(a);
    try expectEqualStrings(t.buffer[0..t.len], "");

    try t.consumeSlice("one two three");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expect(tokens.len == 5);

    try std.testing.expectEqualStrings(tokens[2].str, "two");
    t.idx = 7;
    try t.maybeSetOriginal("two", a);

    try t.maybeReplace("TWO", a);
    try expectEqual(7, t.idx);
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);

    try expectEqualStrings(t.buffer[0..t.len], "one TWO three");
    try expectEqualStrings(tokens[2].str, "TWO");
    try expectEqual(5, tokens.len);

    try t.maybeReplace("TWO FOUR", a);
    try expectEqual(13, t.idx);

    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);
    for (tokens) |tkn| if (false) std.debug.print("--- {s} {}\n", .{ tkn.str, tkn });

    try expectEqual(7, tokens.len);
    try expectEqualStrings(tokens[2].str, "TWO");
    try expectEqualStrings(tokens[3].str, "\\ ");
    try expectEqualStrings(tokens[4].str, "FOUR");
    try expectEqualStrings(t.buffer[0..t.len], "one TWO\\ FOUR three");

    try expectEqual(13, t.idx);
    try expectEqual('R', t.buffer[t.idx - 1]);
    try expectEqual(' ', t.buffer[t.idx]);
    try t.maybeCommit(' ', a);
    try expectEqual(14, t.idx);
    try expectEqualStrings("one TWO\\ FOUR  three", t.buffer[0..t.len]);

    a.free(tokens);
}

test "breaking" {
    var a = std.testing.allocator;
    var t: Tokenizer = .{};

    try t.consumeSlice("alias la='ls -la'");
    var titr = t.iterator();
    const tokens = try titr.toSlice(a);
    try expectEqual(tokens.len, 4);
    a.free(tokens);
}

test "tokeniterator 0" {
    var ti = Token.Iterator{ .raw = "one two three" };
    try expectEqualStrings("one", ti.first().str);
    _ = ti.skip();
    try expectEqualStrings("two", ti.next().?.str);
    _ = ti.skip();
    try expectEqualStrings("three", ti.next().?.str);
    try expect(ti.next() == null);
}

test "tokeniterator 1" {
    var ti = Token.Iterator{
        .raw = "one two three",
    };

    try expectEqualStrings("one", ti.first().str);
    _ = ti.next();
    try expectEqualStrings("two", ti.next().?.str);
    _ = ti.next();
    try expectEqualStrings("three", ti.next().?.str);
    try expect(ti.next() == null);
}

test "tokeniterator 2" {
    var ti = Token.Iterator{
        .raw = "one two three",
    };

    var slice = try ti.toSlice(std.testing.allocator);
    defer std.testing.allocator.free(slice);
    try std.testing.expect(slice.len == 5);
    try expectEqualStrings("one", slice[0].str);
}

test "tokeniterator 3" {
    var ti = Token.Iterator{
        .raw = "one two three",
    };

    var slice = try ti.toSlice(std.testing.allocator);
    defer std.testing.allocator.free(slice);
    try std.testing.expect(slice.len == 5);

    try expectEqualStrings("one", slice[0].str);
    try expectEqualStrings(" ", slice[1].str);
}

test "token pipeline" {
    var ti = Token.Iterator{
        .raw = "ls -la | cat | sort ; echo this works",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 19);

    ti.restart();
    len = 0;
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 4);

    try expectEqualStrings(ti.next().?.str, "|");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 7);

    try expectEqualStrings(ti.next().?.str, "|");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 10);

    try expectEqualStrings(ti.next().?.str, ";");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 16);
}

test "token pipeline slice" {
    var ti = Token.Iterator{
        .raw = "ls -la | cat | sort ; echo this works",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 19);

    ti.restart();
    len = 0;
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 4);

    ti.restart();

    var slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 4);
    std.testing.allocator.free(slice);

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 3);
    std.testing.allocator.free(slice);

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 3);
    std.testing.allocator.free(slice);

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 6);
    try expectEqualStrings("echo", slice[1].str);
    try expectEqualStrings("this", slice[3].str);
    try expectEqualStrings("works", slice[5].str);
    std.testing.allocator.free(slice);
}

test "token pipeline slice safe with next()" {
    var ti = Token.Iterator{
        .raw = "ls -la | cat | sort ; echo this works",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 19);

    ti.restart();
    len = 0;
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 4);

    ti.restart();

    var slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 4);
    std.testing.allocator.free(slice);

    _ = ti.next();

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 3);
    std.testing.allocator.free(slice);

    _ = ti.next();

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 3);
    std.testing.allocator.free(slice);

    _ = ti.next();

    slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expectEqual(slice.len, 6);
    try expectEqualStrings("echo", slice[1].str);
    try expectEqualStrings("this", slice[3].str);
    try expectEqualStrings("works", slice[5].str);
    std.testing.allocator.free(slice);
}

test "token > file" {
    var ti = Token.Iterator{
        .raw = "ls > file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    var iot = ti.next().?;
    try expectEqualStrings("> file.txt", iot.str);
    try std.testing.expect(iot.kind.io == .Out);
}

test "token > file extra ws" {
    var ti = Token.Iterator{
        .raw = "ls >               file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    try expectEqualStrings(">               file.txt", ti.next().?.str);
}

test "token > execSlice" {
    var ti = Token.Iterator{
        .raw = "ls > file.txt",
    };

    var len: usize = 0;
    while (ti.nextExec()) |_|
        len += 1;

    try std.testing.expectEqual(len, 3);

    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    var iot = ti.next().?;
    try expectEqualStrings("> file.txt", iot.str);
    try std.testing.expect(iot.kind.io == .Out);

    ti.restart();
    try std.testing.expect(ti.peek() != null);
    const slice = try ti.toSliceExec(std.testing.allocator);
    try std.testing.expect(ti.peek() == null);
    try std.testing.expect(ti.peek() == null);
    try std.testing.expect(ti.peek() == null);
    try std.testing.expect(ti.peek() == null);
    std.testing.allocator.free(slice);
}

test "token >> file" {
    var ti = Token.Iterator{ .raw = "ls >> file.txt" };

    var len: usize = 0;
    while (ti.next()) |_| len += 1;
    try std.testing.expectEqual(len, 3);

    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    var iot = ti.next().?;
    try std.testing.expectEqual(.Append, iot.kind.io);
    try expectEqualStrings(">> file.txt", iot.str);
}

test "token >>file" {
    var ti = Token.Iterator{ .raw = "ls >>file.txt" };
    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    const iot = ti.next().?;
    try expectEqualStrings(">>file.txt", iot.str);
    try std.testing.expectEqual(.Append, iot.kind.io);
}

test "token < file" {
    var ti = Token.Iterator{
        .raw = "ls < file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    var ls = ti.first();
    try expectEqualStrings("ls", ls.str);
    ti.skip();
    const in_file = ti.next().?;
    try std.testing.expect(in_file.kind == .io);
    try expectEqualStrings("< file.txt", in_file.str);
}

test "token < file extra ws" {
    var ti = Token.Iterator{ .raw = "ls <               file.txt" };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    try expectEqualStrings("<               file.txt", ti.next().?.str);
}

test "token &&" {
    var ti = Token.Iterator{
        .raw = "ls && success",
    };

    var len: usize = 0;
    while (ti.next()) |_| len += 1;
    try std.testing.expectEqual(len, 5);

    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    const n = ti.next().?;
    try expectEqualStrings("&&", n.str);
    try std.testing.expect(n.kind == .oper);
    try std.testing.expect(n.kind.oper == .success);
    ti.skip();
    try expectEqualStrings("success", ti.next().?.str);
}

test "token ||" {
    var ti = Token.Iterator{
        .raw = "ls || fail",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 5);

    try expectEqualStrings("ls", ti.first().str);
    ti.skip();
    const n = ti.next().?;
    try expectEqualStrings("||", n.str);
    try std.testing.expect(n.kind == .oper);
    try std.testing.expect(n.kind.oper == .fail);
    ti.skip();
    try expectEqualStrings("fail", ti.next().?.str);
}

test "token _|" {
    const a = std.testing.allocator;
    var ti = Token.Iterator{ .raw = "_|" };
    const slice = try ti.toSlice(a);
    defer a.free(slice);

    try std.testing.expectEqual(2, slice.len);

    try expectEqualStrings("_", slice[0].str);
    try expectEqualStrings("|", slice[1].str);
}

test "token vari" {
    var t = try Token.vari("$string");

    try expectEqualStrings("$string", t.str);
}

test "token vari words" {
    var t = try Token.vari("$string ");
    try expectEqualStrings("$string", t.str);

    t = try Token.vari("$string993");
    try expectEqualStrings("$string993", t.str);

    t = try Token.vari("$string 993");
    try expectEqualStrings("$string", t.str);

    t = try Token.vari("$string{} 993");
    try expectEqualStrings("$string", t.str);

    t = try Token.vari("$string+");
    try expectEqualStrings("$string", t.str);

    t = try Token.vari("$string:");
    try expectEqualStrings("$string", t.str);

    t = try Token.vari("$string~");
    try expectEqualStrings("$string", t.str);

    t = try Token.vari("$string-");
    try expectEqualStrings("$string", t.str);
}

test "token vari braces" {
    var t = try Token.any("$STRING");
    try expectEqualStrings("$STRING", t.str);

    t = try Token.any("${STRING}");
    try expectEqualStrings("${STRING}", t.str);

    t = try Token.any("${STRING}extra");
    try expectEqualStrings("${STRING}", t.str);

    t = try Token.any("${STR_ING}extra");
    try expectEqualStrings("${STR_ING}", t.str);

    var tzr: Tokenizer = .{};
    try tzr.consumeSlice("${STR_ING}extra");
    try expectEqual(2, tzr.count());
}

test "dollar posix" {
    var t = try Token.any("$!");
    try expect(t.kind == .vari);
    try expectEqualStrings("$!", t.str);
}

test "all execs" {
    var tt = Token.Iterator{ .raw = "ls -with -some -params && files || thing | pipeline ; othercmd & screenshot && some/rel/exec" };
    var num: usize = 0;
    while (tt.next()) |_| {
        while (tt.nextExec()) |_| {}
        _ = tt.next();
        num += 1;
    }
    try expectEqual(7, num);
}

test "pop" {
    var t: Tokenizer = .{};
    const str = "this is a string";
    for (str) |c| {
        try t.consumeChar(c);
    }

    for (str) |_| t.remove();
}

test "removeWhitespace" {
    var t: Tokenizer = .{};
    //defer t.raze(a);
    try t.consumeSlice("a      ");
    try expect(t.len == 7);
    try expect(t.removeWhitespace() == 6);
    try expect(t.len == 1);

    t.reset();
    try t.consumeSlice("a      b      ");
    try expect(t.len == 14);
    try expect(t.removeWhitespace() == 6);
    try expect(t.len == 8);
    try expect(t.removeWhitespace() == 0);
    try expect(t.len == 8);
    t.remove();
    try expect(t.removeWhitespace() == 6);
    try expect(t.len == 1);
}

test "removeAlpha" {
    var t: Tokenizer = .{};
    try t.consumeSlice("a      aoeu");
    try expectEqual(11, t.len);
    try expectEqual(4, t.removeAlphanum());
    try expectEqual(7, t.len);

    t.reset();
    try t.consumeSlice("a      b      aoeu");
    try expect(t.len == 18);
    try expect(t.removeAlphanum() == 4);
    try expect(t.len == 14);
    try expect(t.removeAlphanum() == 0);
    try expect(t.len == 14);
    _ = t.removeWhitespace();
    try expect(t.removeAlphanum() == 1);
    try expect(t.len == 7);
}

test "removeWord" {
    var t: Tokenizer = .{};
    //defer t.raze(a);
    try t.consumeSlice("a      ");
    try expectEqual(7, t.len);
    try expectEqual(7, t.removeWord());
    try expectEqual(0, t.len);

    t.reset();
    try t.consumeSlice("a      b      aoeu aoeu");
    try expectEqual(23, t.len);
    try expectEqual(4, t.removeWord());
    try expectEqual(19, t.len);
    try expectEqual(10, t.removeWord());
    try expectEqual(9, t.len);

    t.reset();
    try t.consumeSlice("ls -la /some/abs/directory/thats/long");

    try expectEqualStrings("ls -la /some/abs/directory/thats/long", t.buffer[0..t.len]);
    try expectEqual(4, t.removeWord());
    try expectEqualStrings("ls -la /some/abs/directory/thats/", t.buffer[0..t.len]);
    try expectEqual(6, t.removeWord());
    try expectEqualStrings("ls -la /some/abs/directory/", t.buffer[0..t.len]);
    try expectEqual(10, t.removeWord());
    try expectEqualStrings("ls -la /some/abs/", t.buffer[0..t.len]);
    try expectEqual(4, t.removeWord());
    try expectEqualStrings("ls -la /some/", t.buffer[0..t.len]);
    try expectEqual(5, t.removeWord());
    try expectEqualStrings("ls -la /", t.buffer[0..t.len]);
    try expectEqual(1, t.removeWord());
    try expectEqualStrings("ls -la ", t.buffer[0..t.len]);
}

test "removeWord2" {
    var t: Tokenizer = .{};
    try t.consumeSlice("git add build.ziggg");

    try expectEqualStrings("git add build.ziggg", t.buffer[0..t.len]);
    try expectEqual(5, t.removeWord());
    try expectEqualStrings("git add build.", t.buffer[0..t.len]);
    try expectEqual(6, t.removeWord());
    try expectEqualStrings("git add ", t.buffer[0..t.len]);
    try expectEqual(4, t.removeWord());
    try expectEqualStrings("git ", t.buffer[0..t.len]);
    try expectEqual(4, t.removeWord());
    try expectEqualStrings("", t.buffer[0..t.len]);
    try expectEqual(0, t.removeWord());
    try expectEqual(0, t.removeWord());
}

test "ualphanum" {
    const t = try Token.uAlphaNum("word word");
    try expect(t.str.len == 4);
    try expectEqualStrings("word", t.str);
}

test "any" {
    var t = try Token.any("word");
    try expectEqualStrings("word", t.str);
}

test "inline quotes" {
    var t = try Token.any("--inline='quoted string'");
    try expectEqualStrings("--inline=", t.str);

    var itr = Token.Iterator{ .raw = "--inline='quoted string'" };
    try expectEqualStrings("--inline=", itr.next().?.str);
    try expectEqualStrings("'quoted string'", itr.next().?.str);
}

test "escapes" {
    var t = try Token.any("--inline=quoted\\ string");
    try expectEqualStrings("--inline=quoted", t.str);

    t = try Token.any("--inline=quoted\\\\ string");
    try expectEqualStrings("--inline=quoted", t.str);

    t = try Token.any("one\\ two");
    try expectEqualStrings("one", t.str);

    t = try Token.any("one\\\\ two");
    try expectEqualStrings("one", t.str);
}

test "reserved" {
    // zig fmt: off
    const res = [_][]const u8{
        "if", "then", "else", "elif", "fi",
        "do", "done", "case", "esac", "while",
        "until", "for", "in"
    };
    // zig fmt: on
    var t: Token = undefined;
    for (res) |r| {
        t = try Token.any(r);
        try expect(t.kind == .resr);
    }
}

test "subp" {
    var t = try Token.any("$(which cat)");

    try expectEqualStrings("$(which cat)", t.str);
    try expect(t.kind == .subp);

    t = try Token.any("$( echo 'lol good luck buddy)' )");

    try expectEqualStrings("$( echo 'lol good luck buddy)' )", t.str);
    try expect(t.kind == .subp);

    t = try Token.any("echo $(pwd))");
    try expectEqualStrings("echo", t.str);
    try expect(t.kind == .word);

    t = try Token.any("$(pwd))");
    try expectEqualStrings("$(pwd)", t.str);
    try expect(t.kind == .subp);
}

test "make safe" {
    var a = std.testing.allocator;
    try expect(checkSafe("string"));
    const str = try dupeSafe("str ing", a);
    defer a.free(str);
    try expectEqualStrings("str\\ ing", str);
}

test "comment" {
    //var a = allocator;
    var tk = try Token.any("# comment");

    try expectEqualStrings("# comment", tk.str);

    var itr = Token.Iterator{ .raw = " echo #comment" };

    itr.skip();
    try expectEqualStrings("echo", itr.next().?.str);
    itr.skip();
    try expectEqualStrings("#comment", itr.next().?.str);
    try expect(null == itr.next());

    itr = Token.Iterator{ .raw = " echo #comment\ncd home" };

    itr.skip();
    try expectEqualStrings("echo", itr.next().?.str);
    itr.skip();
    try expectEqualStrings("#comment", itr.next().?.str);
    itr.skip();
    try expectEqualStrings("cd", itr.next().?.str);
    itr.skip();
    try expectEqualStrings("home", itr.next().?.str);
    try expect(null == itr.next());
}

test "backslash" {
    var tzr = fromSlice("this\\ is some text");

    try expectEqual(7, tzr.count());
    var itr = tzr.iterate();

    try expectEqualStrings("this", itr.first().str);
    try expectEqualStrings("\\ ", itr.next().?.str);
    try expectEqualStrings("is", itr.next().?.str);
    try expectEqualStrings(" ", itr.next().?.str);
    try expectEqualStrings("some", itr.next().?.str);
    try expectEqualStrings(" ", itr.next().?.str);
    try expectEqualStrings("text", itr.next().?.str);
}

test "logic" {
    const if_str =
        \\if true
        \\then
        \\    echo "something"
        \\fi
    ;

    var ifs = try Token.logic(if_str);
    try expectEqualStrings(if_str, ifs.str);

    const case_str =
        \\case $WORD in
        \\    "blerg") echo "hahaha";
        \\    ;;
        \\    "other") panic_carefully;
        \\    ;;
        \\    *)
        \\        hi;
        \\    ;;
        \\esac
    ;

    var cases = try Token.logic(case_str);
    try expectEqualStrings(case_str, cases.str);

    const for_str =
        \\for num in $NUMS
        \\do
        \\    echo "that number is far too small!"
        \\done
    ;

    var fors = try Token.logic(for_str);
    try expectEqualStrings(for_str, fors.str);

    const while_str =
        \\while false;
        \\do
        \\    echo "something crazy"
        \\done
    ;

    var whiles = try Token.logic(while_str);
    try expectEqualStrings(while_str, whiles.str);
}

test "invalid logic" {
    const if_str =
        \\if true
        \\then
        \\    echo "something"
        \\done
    ;

    const ifs = Token.logic(if_str);
    try expectError(TokenError.OpenLogic, ifs);

    const case_str =
        \\case $WORD in
        \\    "blerg") echo "hahaha";
        \\    ;;
        \\    "other") panic_carefully;
        \\fi
    ;

    const cases = Token.logic(case_str);
    try expectError(TokenError.OpenLogic, cases);

    const for_str =
        \\for num in $NUMS
        \\do
        \\    echo "that number is far too small!"
        \\until
    ;

    const fors = Token.logic(for_str);
    try expectError(TokenError.OpenLogic, fors);

    const while_str =
        \\while false;
        \\do
        \\    echo "something crazy"
        \\true
    ;

    const whiles = Token.logic(while_str);
    try expectError(TokenError.OpenLogic, whiles);
}

test "nested logic" {
    const if_str =
        \\if true
        \\then
        \\    while true;
        \\    do
        \\        my_homework
        \\    done
        \\else
        \\    for HAT in $SHOES; do
        \\        get_dressed
        \\    done
        \\fi
    ;

    var ifs = try Token.logic(if_str);
    try expectEqualStrings(if_str, ifs.str);

    const case_str =
        \\case $WORD in
        \\    "blerg") echo "hahaha";
        \\    ;;
        \\    "other") panic_carefully;
        \\    *)
        \\      if something_wicked_this_way_comes; then; exit 20; else sleep 27y; fi;
        \\    ;;
        \\    esac
    ;

    var cases = try Token.logic(case_str);
    try expectEqualStrings(case_str, cases.str);

    const for_str =
        \\for num in $NUMS
        \\do
        \\    if is_odd $num;
        \\    then
        \\        echo "number is even"
        \\    fi
        \\done
    ;

    var fors = try Token.logic(for_str);
    try expectEqualStrings(for_str, fors.str);

    const while_str =
        \\while false;
        \\do
        \\    case
        \\    esac
        \\true
        \\ done
    ;

    var whiles = try Token.logic(while_str);
    try expectEqualStrings(while_str, whiles.str);
}

test "naughty strings" {
    const while_str = "thingy (b.argv.next()) |_| {}";

    const tzr = fromSlice(while_str);
    try expectEqual(10, tzr.count());
}

test "escape newline" {
    var tzr: Tokenizer = .{};
    //defer tzr.raze(a);

    try tzr.consumeSlice("zig build test");
    const e = tzr.consumeChar('\n');
    try expectError(error.Exec, e);
    //const ee = tzr.consumeSlice("\n");
    //try expectError(Error.Exec, ee);
    // This API is mildly unstable, if you need string to err.exec create a new
    // handler
    tzr.consumeSlice("\n") catch {
        try expect(false); // consume string doesn't error
    };
    _ = try tzr.consumeChar('\\');
    try tzr.consumeSlice("\n"); // expect no error
}

test "build functions" {
    const a = std.testing.allocator;
    var tzr: Tokenizer = .{};
    defer tzr.raze(a);
    try tzr.consumeSlice("func () a");
    try expectEqual(5, tzr.count());
    tzr.reset();
    try tzr.consumeSlice("func () {}");
    var itr = tzr.iterator();
    try expectEqual(1, tzr.count());

    tzr.raze(a);
    try tzr.consumeSlice("func () {   }   ");
    itr = tzr.iterator();

    try expectEqual(2, tzr.count());

    tzr.raze(a);
    try tzr.consumeSlice(
        \\func () {
        \\    some function call here
        \\}
    );
    itr = tzr.iterator();

    try expectEqual(1, tzr.count());
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const io = std.Io;
const log = @import("log.zig");
const Token = @import("token.zig");
const isWhitespace = std.ascii.isWhitespace;
const assert = std.debug.assert;
const isAlphanumeric = std.ascii.isAlphanumeric;
const findAny = std.mem.findAny;
const findScalar = std.mem.findScalar;
const countScalar = std.mem.countScalar;
