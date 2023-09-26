const std = @import("std");
const log = @import("log");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.fs.File;
const fs = @import("fs.zig");
const io = std.io;
const mem = std.mem;
const CompOption = @import("completion.zig").CompOption;
const Token = @import("token.zig");

pub const TokenError = Token.Error;

pub const Error = error{
    Empty,
    Exec,
    OutOfMemory,
};

pub const TokenIterator = Token.Iterator;

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
    editor_mktmp: ?[]u8 = null,

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
            const t = Token.any(self.raw.items[i..]) catch break;
            if (t.str.len == 0) break;
            i += t.str.len;
            if (i >= self.c_idx) return t;
            self.c_tkn += 1;
        }
        return Error.TokenizeFailed;
    }

    // Cursor adjustment to send to tty
    pub fn cadj(self: Tokenizer) u32 {
        return @truncate(self.raw.items.len - self.c_idx);
    }

    pub fn iterator(self: *Tokenizer) TokenIterator {
        return TokenIterator{ .raw = self.raw.items };
    }

    /// Returns a Token error
    pub fn validate(self: *Tokenizer) TokenError!void {
        var i: usize = 0;
        while (i < self.raw.items.len) {
            const t = try Token.any(self.raw.items[i..]);
            i += t.str.len;
        }
    }

    // completion commands

    /// remove the completion maybe from input
    pub fn maybeDrop(self: *Tokenizer) !void {
        if (self.raw_maybe) |rm| {
            self.popRange(rm.len) catch {
                log.err("Unable to drop maybe {s} len = {}\n", .{ rm, rm.len });
                log.err("Unable to drop maybe {s} len = {}\n", .{ rm, rm.len });
                @panic("dropMaybe");
            };
        }
        self.maybeClear();
    }

    pub fn maybeClear(self: *Tokenizer) void {
        if (self.raw_maybe) |rm| {
            self.alloc.free(rm);
        }
        self.raw_maybe = null;
    }

    pub fn maybeDupe(self: *Tokenizer, str: []const u8) !void {
        self.maybeClear();
        self.raw_maybe = try self.alloc.dupe(u8, str);
    }

    /// str must be safe to insert directly as is
    pub fn maybeAdd(self: *Tokenizer, str: []const u8) !void {
        const safe = try self.makeSafe(str) orelse try self.alloc.dupe(u8, str);
        defer self.alloc.free(safe);
        try self.maybeDupe(safe);
        try self.consumes(safe);
    }

    /// This function edits user text, so extra care must be taken to ensure
    /// it's something the user asked for!
    pub fn maybeReplace(self: *Tokenizer, new: *const CompOption) !void {
        const str = try self.makeSafe(new.str) orelse try self.alloc.dupe(u8, new.str);
        defer self.alloc.free(str);
        if (self.raw_maybe) |_| {
            try self.maybeDrop();
        } else if (new.kind == null) {
            try self.maybeDupe(str);
        }

        if (new.kind == null) return;
        try self.maybeDupe(str);

        try self.consumes(str);
    }

    pub fn maybeCommit(self: *Tokenizer, new: ?*const CompOption) !void {
        self.maybeClear();
        if (new) |n| {
            switch (n.kind.?) {
                .file_system => |f_s| {
                    switch (f_s) {
                        .dir => try self.consumec('/'),
                        .file, .link, .pipe => try self.consumec(' '),
                        else => {},
                    }
                },
                .path_exe => try self.consumec(' '),
                else => {},
            }
        }
    }

    /// if returned value is null, string is already safe.
    fn makeSafe(self: *Tokenizer, str: []const u8) !?[]u8 {
        if (mem.indexOfAny(u8, str, Token.BREAKING_TOKENS)) |_| {} else {
            return null;
        }
        var extra: usize = str.len;
        var look = [1]u8{0};
        for (Token.BREAKING_TOKENS) |t| {
            look[0] = t;
            extra += mem.count(u8, str, &look);
        }
        std.debug.assert(extra > str.len);

        var safer = try self.alloc.alloc(u8, extra);
        var i: usize = 0;
        for (str) |c| {
            if (mem.indexOfScalar(u8, Token.BREAKING_TOKENS, c)) |_| {
                safer[i] = '\\';
                i += 1;
            }
            safer[i] = c;
            i += 1;
        }
        return safer;
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
        while (self.c_idx > 0 and (c == '-' or std.ascii.isAlphanumeric(c))) {
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
        if (count == 0 and self.raw.items.len > 0 and self.c_idx != 0) {
            try self.pop();
            return 1 + try self.dropWord();
        }
        return count;
    }

    pub fn pop(self: *Tokenizer) Error!void {
        self.user_data = true;
        if (self.raw.items.len == 0 or self.c_idx == 0) return Error.Empty;
        if (self.c_idx < self.raw.items.len) {
            self.c_idx -|= 1;
            _ = self.raw.orderedRemove(self.c_idx);
            return;
        }

        self.c_idx -|= 1;
        self.raw.items.len -|= 1;
        self.err_idx = @min(self.c_idx, self.err_idx);
    }

    pub fn bsc(self: *Tokenizer) void {
        return self.pop() catch {};
    }

    pub fn delc(self: *Tokenizer) void {
        if (self.raw.items.len == 0 or self.c_idx == self.raw.items.len) return;
        self.user_data = true;
        _ = self.raw.orderedRemove(self.c_idx);
    }

    pub fn popRange(self: *Tokenizer, count: usize) Error!void {
        if (count == 0) return;
        if (self.raw.items.len == 0 or self.c_idx == 0) return;
        if (count > self.raw.items.len) return Error.Empty;
        self.user_data = true;
        self.c_idx -|= count;
        _ = self.raw.replaceRange(@as(usize, self.c_idx), count, "") catch unreachable;
        // replaceRange is able to expand, but we don't here, thus unreachable
        self.err_idx = @min(self.c_idx, self.err_idx);
    }

    pub fn consumes(self: *Tokenizer, str: []const u8) Error!void {
        for (str) |s| try self.consumec(s);
    }

    pub fn consumec(self: *Tokenizer, c: u8) Error!void {
        try self.raw.insert(self.c_idx, @bitCast(c));
        self.c_idx += 1;
        self.user_data = true;
        if (self.c_idx == self.raw.items.len and c == '\n') {
            if (self.raw.items.len > 1 and self.raw.items[self.raw.items.len - 2] != '\\')
                return Error.Exec;
        }
    }

    // TODO rename verbNoun -> lineVerb

    pub fn lineEditor(self: *Tokenizer) void {
        const filename = fs.mktemp(self.alloc, self.raw.items) catch {
            log.err("Unable to write prompt to tmp file\n", .{});
            return;
        };
        self.saveLine();
        self.consumes("$EDITOR ") catch unreachable;
        self.consumes(filename) catch unreachable;
        self.editor_mktmp = filename;
    }

    pub fn lineEditorRead(self: *Tokenizer) void {
        if (self.editor_mktmp) |mkt| {
            var file = fs.openFile(mkt, false) orelse return;
            defer file.close();
            file.reader().readAllArrayList(&self.raw, 4096) catch unreachable;
            std.os.unlink(mkt) catch unreachable;
            self.alloc.free(mkt);
        }
        self.editor_mktmp = null;
    }

    pub fn saveLine(self: *Tokenizer) void {
        self.resetHist();
        self.hist_z = self.raw;
        self.raw = ArrayList(u8).init(self.alloc);
        self.c_idx = 0;
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
        self.raw.clearRetainingCapacity();
        self.c_idx = 0;
        self.err_idx = 0;
        self.c_tkn = 0;
        self.user_data = false;
        self.maybeClear();
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
        self.raw.clearAndFree();
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
const eqlStr = std.testing.expectEqualStrings;

test "quotes tokened" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.raze();

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

    var terr = Token.group(
        \\"this is invalid
    );
    try expectError(TokenError.OpenGroup, terr);

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

    terr = Token.group(
        \\"this is some text\" more text
    );
    try expectError(TokenError.OpenGroup, terr);

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
    defer t.raze();
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
    var t = Tokenizer.init(std.testing.allocator);
    defer t.raze();

    try t.consumes("blerg ~/dir");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, "blerg ~/dir".len);
    try expectEql(tokens.len, 3);
    try expect(tokens[2].kind == .path);
    try expect(eql(u8, tokens[2].str, "~/dir"));
    a.free(tokens);

    t.reset();
    try t.consumes("blerg /home/user/something");
    titr = t.iterator();
    tokens = try titr.toSlice(a);
    try expectEql(t.raw.items.len, "blerg /home/user/something".len);
    try expectEql(tokens.len, 3);
    try expect(tokens[2].kind == .path);
    try expect(eql(u8, tokens[2].str, "/home/user/something"));
    a.free(tokens);
}

test "replace token" {
    var a = std.testing.allocator;
    var t = Tokenizer.init(std.testing.allocator);
    defer t.raze();
    try expect(std.mem.eql(u8, t.raw.items, ""));

    try t.consumes("one two three");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expect(tokens.len == 5);

    try std.testing.expectEqualStrings(tokens[2].cannon(), "two");
    t.c_idx = 7;
    try t.maybeReplace(&CompOption{
        .str = "two",
        .kind = null,
    });

    try t.maybeReplace(&CompOption{
        .str = "TWO",
    });
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);

    try std.testing.expectEqualStrings(t.raw.items, "one TWO three");
    try std.testing.expectEqualStrings(tokens[2].cannon(), "TWO");
    try expect(tokens.len == 5);

    try t.maybeReplace(&CompOption{
        .str = "TWO THREE",
    });
    titr = t.iterator();
    a.free(tokens);
    tokens = try titr.toSlice(a);

    for (tokens) |tkn| {
        _ = tkn;
        //std.debug.print("--- {}\n", .{tkn});
    }

    try expectEql(tokens.len, 7);
    try std.testing.expectEqualStrings(tokens[2].cannon(), "TWO");
    try std.testing.expectEqualStrings(tokens[3].cannon(), "\\ ");
    try std.testing.expectEqualStrings(tokens[4].cannon(), "THREE");
    try std.testing.expectEqualStrings(t.raw.items, "one TWO\\ THREE three");
    a.free(tokens);
}

test "breaking" {
    var a = std.testing.allocator;
    var t = Tokenizer.init(std.testing.allocator);
    defer t.raze();

    try t.consumes("alias la='ls -la'");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expectEql(tokens.len, 4);
    a.free(tokens);
}

test "tokeniterator 0" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    try eqlStr("one", ti.first().cannon());
    _ = ti.skip();
    try eqlStr("two", ti.next().?.cannon());
    _ = ti.skip();
    try eqlStr("three", ti.next().?.cannon());
    try std.testing.expect(ti.next() == null);
}

test "tokeniterator 1" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    try eqlStr("one", ti.first().cannon());
    _ = ti.next();
    try eqlStr("two", ti.next().?.cannon());
    _ = ti.next();
    try eqlStr("three", ti.next().?.cannon());
    try std.testing.expect(ti.next() == null);
}

test "tokeniterator 2" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    var slice = try ti.toSlice(std.testing.allocator);
    defer std.testing.allocator.free(slice);
    try std.testing.expect(slice.len == 5);
    try eqlStr("one", slice[0].cannon());
}

test "tokeniterator 3" {
    var ti = TokenIterator{
        .raw = "one two three",
    };

    var slice = try ti.toSlice(std.testing.allocator);
    defer std.testing.allocator.free(slice);
    try std.testing.expect(slice.len == 5);

    try eqlStr("one", slice[0].cannon());
    try eqlStr(" ", slice[1].cannon());
}

test "token pipeline" {
    var ti = TokenIterator{
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

    try eqlStr(ti.next().?.cannon(), "|");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 7);

    try eqlStr(ti.next().?.cannon(), "|");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 10);

    try eqlStr(ti.next().?.cannon(), ";");
    while (ti.nextExec()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 16);
}

test "token pipeline slice" {
    var ti = TokenIterator{
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
    try eqlStr("echo", slice[1].cannon());
    try eqlStr("this", slice[3].cannon());
    try eqlStr("works", slice[5].cannon());
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
    try eqlStr("echo", slice[1].cannon());
    try eqlStr("this", slice[3].cannon());
    try eqlStr("works", slice[5].cannon());
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
    try std.testing.expectEqual(len, 3);

    try eqlStr("ls", ti.first().cannon());
    ti.skip();
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
    try std.testing.expectEqual(len, 3);

    try eqlStr("ls", ti.first().cannon());
    ti.skip();
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
    try std.testing.expectEqual(len, 3);

    try eqlStr("ls", ti.first().cannon());
    ti.skip();
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
    try std.testing.expectEqual(len, 3);

    try eqlStr("ls", ti.first().cannon());
    ti.skip();
    var iot = ti.next().?;
    try eqlStr("file.txt", iot.cannon());
    try std.testing.expect(iot.kind.io == .Append);
    ti = TokenIterator{ .raw = "ls >>file.txt" };
    try eqlStr("ls", ti.first().cannon());
    ti.skip();
    iot = ti.next().?;
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
    try std.testing.expectEqual(len, 3);

    var ls = ti.first();
    try eqlStr("ls", ls.cannon());
    ti.skip();
    var in_file = ti.next().?;
    try std.testing.expect(in_file.kind == .io);
    try eqlStr("file.txt", in_file.cannon());
}

test "token < file extra ws" {
    var ti = TokenIterator{
        .raw = "ls <               file.txt",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 3);

    try eqlStr("ls", ti.first().cannon());
    ti.skip();
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
    try std.testing.expectEqual(len, 5);

    try eqlStr("ls", ti.first().cannon());
    const n = ti.next().?;
    ti.skip();
    try eqlStr("&&", n.cannon());
    try std.testing.expect(n.kind == .oper);
    try std.testing.expect(n.kind.oper == .Success);
    ti.skip();
    try eqlStr("success", ti.next().?.cannon());
}

test "token ||" {
    var ti = TokenIterator{
        .raw = "ls || fail",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }
    try std.testing.expectEqual(len, 5);

    try eqlStr("ls", ti.first().cannon());
    ti.skip();
    const n = ti.next().?;
    try eqlStr("||", n.cannon());
    try std.testing.expect(n.kind == .oper);
    try std.testing.expect(n.kind.oper == .Fail);
    ti.skip();
    try eqlStr("fail", ti.next().?.cannon());
}

test "token vari" {
    var t = try Token.vari("$string");

    try eqlStr("string", t.cannon());
}

test "token vari words" {
    var t = try Token.vari("$string ");
    try eqlStr("string", t.cannon());

    t = try Token.vari("$string993");
    try eqlStr("string993", t.cannon());

    t = try Token.vari("$string 993");
    try eqlStr("string", t.cannon());

    t = try Token.vari("$string{} 993");
    try eqlStr("string", t.cannon());

    t = try Token.vari("$string+");
    try eqlStr("string", t.cannon());

    t = try Token.vari("$string:");
    try eqlStr("string", t.cannon());

    t = try Token.vari("$string~");
    try eqlStr("string", t.cannon());

    t = try Token.vari("$string-");
    try eqlStr("string", t.cannon());
}

test "token vari braces" {
    var t = try Token.any("$STRING");
    try eqlStr("STRING", t.cannon());

    t = try Token.any("${STRING}");
    try eqlStr("STRING", t.cannon());

    t = try Token.any("${STRING}extra");
    try eqlStr("STRING", t.cannon());

    t = try Token.any("${STR_ING}extra");
    try eqlStr("STR_ING", t.cannon());

    var itr = TokenIterator{ .raw = "${STR_ING}extra" };
    var count: usize = 0;
    while (itr.next()) |_| count += 1;
    try expectEql(count, 2);
}

test "dollar posix" {
    var t = try Token.any("$!");
    try expect(t.kind == .vari);
    try eqlStr("!", t.cannon());
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
    t.raze();
}

test "dropWhitespace" {
    var t = Tokenizer.init(std.testing.allocator);
    defer t.raze();
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
    defer t.raze();
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
    defer t.raze();
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

    t.reset();
    try t.consumes("ls -la /some/abs/directory/thats/long");

    try eqlStr("ls -la /some/abs/directory/thats/long", t.raw.items);
    try std.testing.expect(try t.dropWord() == 4);
    try eqlStr("ls -la /some/abs/directory/thats/", t.raw.items);
    try std.testing.expect(try t.dropWord() == 6);
    try eqlStr("ls -la /some/abs/directory/", t.raw.items);
    try std.testing.expectEqual(try t.dropWord(), 10);
    try eqlStr("ls -la /some/abs/", t.raw.items);
    try std.testing.expect(try t.dropWord() == 4);
    try eqlStr("ls -la /some/", t.raw.items);
    try std.testing.expect(try t.dropWord() == 5);
    try eqlStr("ls -la /", t.raw.items);
    try std.testing.expectEqual(try t.dropWord(), 5);
    try eqlStr("ls ", t.raw.items);
}

test "ualphanum" {
    const t = try Token.uAlphaNum("word word");
    try std.testing.expect(t.str.len == 4);
    try std.testing.expectEqualStrings("word", t.cannon());
}

test "any" {
    var t = try Token.any("word");
    try std.testing.expectEqualStrings("word", t.cannon());
}

test "inline quotes" {
    var t = try Token.any("--inline='quoted string'");
    try std.testing.expectEqualStrings("--inline=", t.cannon());

    var itr = TokenIterator{ .raw = "--inline='quoted string'" };
    try eqlStr("--inline=", itr.next().?.cannon());
    try eqlStr("quoted string", itr.next().?.cannon());
}

test "escapes" {
    var t = try Token.any("--inline=quoted\\ string");
    try std.testing.expectEqualStrings("--inline=quoted", t.cannon());

    t = try Token.any("--inline=quoted\\\\ string");
    try std.testing.expectEqualStrings("--inline=quoted", t.cannon());

    t = try Token.any("one\\ two");
    try std.testing.expectEqualStrings("one", t.cannon());

    t = try Token.any("one\\\\ two");
    try std.testing.expectEqualStrings("one", t.cannon());
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
        try std.testing.expect(t.kind == .resr);
    }
}

test "subp" {
    var t = try Token.any("$(which cat)");

    try std.testing.expectEqualStrings("$(which cat)", t.cannon());
    try std.testing.expect(t.kind == .subp);

    t = try Token.any("$( echo 'lol good luck buddy)' )");

    try std.testing.expectEqualStrings("$( echo 'lol good luck buddy)' )", t.cannon());
    try std.testing.expect(t.kind == .subp);

    t = try Token.any("echo $(pwd))");
    try std.testing.expectEqualStrings("echo", t.cannon());
    try std.testing.expect(t.kind == .word);

    t = try Token.any("$(pwd))");
    try std.testing.expectEqualStrings("$(pwd)", t.cannon());
    try std.testing.expect(t.kind == .subp);
}

test "make safe" {
    var a = std.testing.allocator;
    var tk = Tokenizer.init(a);

    try std.testing.expect(null == try tk.makeSafe("string"));

    var str = try tk.makeSafe("str ing");
    defer a.free(str.?);
    try std.testing.expectEqualStrings("str\\ ing", str.?);
}

test "comment" {
    //var a = std.testing.allocator;
    var tk = try Token.any("# comment");

    try std.testing.expectEqualStrings("# comment", tk.str);
    try std.testing.expectEqualStrings("", tk.cannon());

    var itr = TokenIterator{ .raw = " echo #comment" };

    itr.skip();
    try std.testing.expectEqualStrings("echo", itr.next().?.cannon());
    itr.skip();
    try std.testing.expectEqualStrings("", itr.next().?.cannon());
    try std.testing.expect(null == itr.next());

    itr = TokenIterator{ .raw = " echo #comment\ncd home" };

    itr.skip();
    try std.testing.expectEqualStrings("echo", itr.next().?.cannon());
    itr.skip();
    try std.testing.expectEqualStrings("", itr.next().?.cannon());
    try std.testing.expectEqualStrings("cd", itr.next().?.cannon());
    itr.skip();
    try std.testing.expectEqualStrings("home", itr.next().?.cannon());
    try std.testing.expect(null == itr.next());
}

test "backslash" {
    var itr = TokenIterator{ .raw = "this\\ is some text" };

    var count: usize = 0;
    while (itr.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(count, 7);

    try eqlStr("this", itr.first().cannon());
    try eqlStr("\\ ", itr.next().?.cannon());
    try eqlStr("is", itr.next().?.cannon());
    try eqlStr(" ", itr.next().?.cannon());
    try eqlStr("some", itr.next().?.cannon());
    try eqlStr(" ", itr.next().?.cannon());
    try eqlStr("text", itr.next().?.cannon());
}

test "logic" {
    const if_str =
        \\if true
        \\then
        \\    echo "something"
        \\fi
    ;

    var ifs = try Token.logic(if_str);
    try eqlStr(if_str, ifs.cannon());

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
    try eqlStr(case_str, cases.cannon());

    const for_str =
        \\for num in $NUMS
        \\do
        \\    echo "that number is far too small!"
        \\done
    ;

    var fors = try Token.logic(for_str);
    try eqlStr(for_str, fors.cannon());

    const while_str =
        \\while false;
        \\do
        \\    echo "something crazy"
        \\done
    ;

    var whiles = try Token.logic(while_str);
    try eqlStr(while_str, whiles.cannon());
}

test "invalid logic" {
    const if_str =
        \\if true
        \\then
        \\    echo "something"
        \\done
    ;

    var ifs = Token.logic(if_str);
    try std.testing.expectError(TokenError.OpenLogic, ifs);

    const case_str =
        \\case $WORD in
        \\    "blerg") echo "hahaha";
        \\    ;;
        \\    "other") panic_carefully;
        \\fi
    ;

    var cases = Token.logic(case_str);
    try std.testing.expectError(TokenError.OpenLogic, cases);

    const for_str =
        \\for num in $NUMS
        \\do
        \\    echo "that number is far too small!"
        \\until
    ;

    var fors = Token.logic(for_str);
    try std.testing.expectError(TokenError.OpenLogic, fors);

    const while_str =
        \\while false;
        \\do
        \\    echo "something crazy"
        \\true
    ;

    var whiles = Token.logic(while_str);
    try std.testing.expectError(TokenError.OpenLogic, whiles);
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
    try eqlStr(if_str, ifs.cannon());

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
    try eqlStr(case_str, cases.cannon());

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
    try eqlStr(for_str, fors.cannon());

    const while_str =
        \\while false;
        \\do
        \\    case
        \\    esac
        \\true
        \\ done
    ;

    var whiles = try Token.logic(while_str);
    try eqlStr(while_str, whiles.cannon());
}

test "naughty strings" {
    const while_str = "thingy (b.argv.next()) |_| {}";

    var itr = TokenIterator{ .raw = while_str };

    var count: usize = 0;
    while (itr.next()) |t| {
        if (false) log.err("{}\n", .{t});
        count += 1;
    }
    try expectEql(count, 9);
}

test "escape newline" {
    var a = std.testing.allocator;

    var tzr = Tokenizer.init(a);
    defer tzr.raze();

    try tzr.consumes("zig build test");
    const e = tzr.consumec('\n');
    try std.testing.expectError(Error.Exec, e);
    const ee = tzr.consumes("\n");
    try std.testing.expectError(Error.Exec, ee);
    _ = try tzr.consumec('\\');
    try tzr.consumes("\n"); // expect no error
}
