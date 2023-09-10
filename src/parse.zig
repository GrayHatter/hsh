const std = @import("std");
const log = @import("log");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenIterator = tokenizer.TokenIterator;
const Builtins = @import("builtins.zig");
const Aliases = Builtins.Aliases;
const Variables = @import("variables.zig");
const fs = @import("fs.zig");
const exec = @import("exec.zig");

pub const Error = error{
    Unknown,
    Memory,
    OutOfMemory,
    ParseFailed,
    OpenGroup,
    Empty,
};

pub const Parsed = struct {
    alloc: Allocator,
    str: []u8,
    capacity: usize,
    io: ?tokenizer.IOKind,
    op: ?tokenizer.OpKind,

    pub fn init(self: *Parsed, a: Allocator) void {
        self.alloc = a;
        self.str.len = 0;
        self.capacity = 0;
        self.io = null;
        self.op = null;
    }

    pub fn cannon(self: *const Parsed) []const u8 {
        return self.str;
    }

    pub fn add(self: *Parsed, str: []const u8) !void {
        const new = self.str.len + str.len;
        while (new > self.capacity) {
            try self.expandCap();
        }
        const old = self.str.len;
        self.str.len = new;
        @memcpy(self.str[old..][0..str.len], str);
    }

    /// if resize/realloc fails, this object becomes undefined
    fn expandCap(self: *Parsed) !void {
        if (self.capacity == 0) {
            self.capacity = 8;
            self.str = try self.alloc.alloc(u8, self.capacity);
            self.str.len = 0;
        }

        const oldlen = self.str.len;
        const target = @max(8, self.capacity * 2);
        self.str.len = self.capacity;
        if (self.alloc.resize(self.str, target)) {
            self.capacity = target;
            return;
        }
        var new = try self.alloc.realloc(self.str, target);
        self.str = new;
        self.str.len = oldlen;
        self.capacity = target;
    }

    pub fn raze(self: *Parsed) void {
        if (self.capacity == 0) return;
        self.str.len = self.capacity;
        self.alloc.free(self.str);
        self.str.len = 0;
        self.capacity = 0;
    }
};

/// In effect a duplicate of std.mem.split iterator
pub const ParsedIterator = struct {
    // I hate that this requires an allocator :( but the ratio of thinking
    // to writing is already too high
    alloc: Allocator,
    r_index: usize = 0,
    resolved: []Parsed, // this will become Parsed at some point.
    t_index: usize = 0,
    tokens: []const Token,
    aliases: [][]const u8,
    const Self = @This();

    /// Restart iterator, and assumes length >= 1
    pub fn first(self: *Self) *const Parsed {
        self.restart();
        return self.next() orelse &self.resolved[0];
    }

    /// Returns next Token, omitting, or splitting them as needed.
    pub fn next(self: *Self) ?*const Parsed {
        if (self.r_index < self.resolved.len) {
            defer self.r_index += 1;
            return &self.resolved[self.r_index];
        }

        if (self.t_index >= self.tokens.len) {
            return null;
        }

        var token = self.tokens[self.t_index];
        if (token.kind == .ws) {
            self.t_index += 1;
            return self.next();
        }

        const start = self.resolved.len;
        var rslvd = self.alloc.realloc(self.resolved, start + 1) catch unreachable;
        rslvd[start].init(self.alloc);
        self.resolved = rslvd;
        while (self.t_index < self.tokens.len) {
            token = self.tokens[self.t_index];
            if (token.kind == .ws) {
                self.t_index += 1;
                return self.next();
            }
            defer self.t_index += 1;
            var r_tokens: []Token = self.resolve(token) catch rt: {
                var set = self.alloc.alloc(Token, 1) catch unreachable;
                set[0] = token;
                break :rt set;
            };
            defer self.alloc.free(r_tokens);

            if (r_tokens.len > 1) {
                rslvd = self.alloc.realloc(self.resolved, start + r_tokens.len) catch unreachable;
                for (r_tokens, rslvd[start..]) |src, *dst| {
                    dst.init(self.alloc);
                    dst.add(src.cannon()) catch unreachable;
                    if (src.resolved) |r| self.alloc.free(r);
                }
                self.resolved = rslvd;
                return self.next();
            }
            rslvd[start].add(r_tokens[0].cannon()) catch unreachable;
            if (r_tokens[0].resolved) |r| self.alloc.free(r);
        }
        return self.next();
    }

    fn aliasedAdd(self: *Self, str: []const u8) void {
        self.aliases = self.alloc.realloc(
            self.aliases,
            self.aliases.len + 1,
        ) catch unreachable;
        self.aliases[self.aliases.len - 1] = str;
    }

    fn resolveAlias(self: *Self, token: Token) Error![]Token {
        var tokens = ArrayList(Token).init(self.alloc);
        for (self.aliases) |res| {
            if (std.mem.eql(u8, token.cannon(), res)) {
                try tokens.append(token);
                return tokens.toOwnedSlice();
            }
        }

        self.aliasedAdd(token.cannon());
        var a_itr = TokenIterator{ .raw = Parser.alias(token) catch token.str };
        var aliases = try self.resolveAlias(a_itr.first().*);
        defer self.alloc.free(aliases);
        for (aliases) |stkn| {
            try tokens.append(stkn);
        }

        while (a_itr.next()) |stkn| {
            if (stkn.kind == .ws) continue;
            try tokens.append(stkn.*);
        }
        return try tokens.toOwnedSlice();
    }

    fn resolve(self: *Self, t: Token) Error![]Token {
        if (self.t_index == 0) return self.resolveAlias(t);

        var tokens = ArrayList(Token).init(self.alloc);
        var local = t;

        // TODO hack while I refactor next() to concat tokens
        if (t.kind == .ws) {
            //try tokens.append(t);
            return try tokens.toOwnedSlice();
        }

        if (std.mem.indexOf(u8, local.cannon(), "$") != null or local.kind == .vari) {
            var skip: usize = 0;
            var list = std.ArrayList(u8).init(self.alloc);
            for (t.str, 0..) |c, i| {
                if (skip > 0) {
                    skip -|= 1;
                    continue;
                }
                switch (c) {
                    '$' => {
                        var res: Token = undefined;
                        if (t.str[i + 1] == '(') {
                            res = Tokenizer.cmdsub(t.str[i..]) catch {
                                try list.append(c);
                                continue;
                            };
                        } else {
                            res = Tokenizer.vari(t.str[i..]) catch {
                                try list.append(c);
                                continue;
                            };
                        }
                        skip = res.str.len - 1;
                        const resolved = Parser.single(self.alloc, res) catch continue;
                        if (resolved.resolved) |str| {
                            try list.appendSlice(str);
                            self.alloc.free(str);
                        } else {
                            try list.appendSlice(resolved.cannon());
                        }
                    },
                    else => try list.append(c),
                }
            }
            const owned = try list.toOwnedSlice();

            try tokens.append(Token{ .str = "", .resolved = owned });
        } else if (std.mem.indexOf(u8, local.cannon(), "*")) |_| {
            var real = try Parser.single(self.alloc, local);
            defer if (real.resolved) |r| self.alloc.free(r);
            var globs = try self.resolveGlob(real);
            defer self.alloc.free(globs);
            for (globs) |glob| try tokens.append(glob);
        } else {
            var real = try Parser.single(self.alloc, local);
            try tokens.append(real);
        }
        return try tokens.toOwnedSlice();
    }

    fn resolveGlob(self: *Self, token: Token) ![]Token {
        if (std.mem.indexOf(u8, token.cannon(), "*")) |_| {} else unreachable;

        var tokens = ArrayList(Token).init(self.alloc);
        if (std.mem.indexOf(u8, token.cannon(), "/")) |_| {
            var bitr = std.mem.splitBackwards(u8, token.cannon(), "/");
            var glob = bitr.first();
            var dir = bitr.rest();
            if (Parser.globAt(self.alloc, dir, glob)) |names| {
                for (names) |name| {
                    defer self.alloc.free(name);
                    if (!std.mem.startsWith(u8, token.cannon(), ".") and
                        std.mem.startsWith(u8, name, "."))
                    {
                        continue;
                    }
                    var path = try std.mem.join(self.alloc, "/", &[2][]const u8{ dir, name });
                    try tokens.append(Token{ .str = "", .resolved = path });
                }
                self.alloc.free(names);
            } else |e| {
                if (e != Error.Empty) {
                    log.err("error resolving glob {}\n", .{e});
                    //unreachable;
                }
            }
        } else {
            if (Parser.glob(self.alloc, token.cannon())) |names| {
                for (names) |name| {
                    if (!std.mem.startsWith(u8, token.cannon(), ".") and
                        std.mem.startsWith(u8, name, "."))
                    {
                        self.alloc.free(name);
                        continue;
                    }
                    try tokens.append(Token{ .str = "", .resolved = name });
                }
                self.alloc.free(names);
            } else |e| {
                if (e != Error.Empty) {
                    std.debug.print("error resolving glob {}\n", .{e});
                    unreachable;
                }
            }
        }
        return try tokens.toOwnedSlice();
    }

    /// Resets the iterator to the initial slice.
    pub fn restart(self: *Self) void {
        self.r_index = 0;
    }

    pub fn raze(self: *Self) void {
        self.t_index = 0;
        self.r_index = 0;
        if (self.aliases.len > 0) {
            self.alloc.free(self.aliases);
        }
        self.aliases = self.alloc.alloc([]u8, 0) catch @panic("Alloc 0 can't fail");
        for (self.resolved) |*token| {
            token.raze();
        }
        if (self.resolved.len > 0) {
            self.alloc.free(self.resolved);
        }
        self.resolved = self.alloc.alloc(Parsed, 0) catch @panic("Alloc 0 can't fail");
    }
};

pub const Parser = struct {
    alloc: Allocator,

    pub fn parse(a: Allocator, tokens: []Token) Error!ParsedIterator {
        var start: usize = 0;
        for (tokens) |t| {
            if (t.kind == .ws) {
                start += 1;
            } else {
                break;
            }
        }
        if (tokens[start..].len == 0) return Error.Empty;
        return ParsedIterator{
            .alloc = a,
            .resolved = a.alloc(Parsed, 0) catch return Error.Memory,
            .tokens = tokens[start..],
            .aliases = a.alloc([]u8, 0) catch return Error.Memory,
        };
    }

    pub fn single(a: Allocator, token: Token) Error!Token {
        if (token.str.len == 0) return token;

        var local = token;
        switch (token.kind) {
            .quote => {
                var needle = [2]u8{ '\\', token.subtoken };
                if (mem.indexOfScalar(u8, token.str, '\\')) |_| {} else return token;

                var i: usize = 0;
                var backing = ArrayList(u8).init(a);
                backing.appendSlice(token.cannon()) catch return Error.Memory;
                while (i + 1 < backing.items.len) : (i += 1) {
                    if (backing.items[i] == '\\') {
                        if (mem.indexOfAny(u8, backing.items[i + 1 .. i + 2], &needle)) |_| {
                            _ = backing.orderedRemove(i);
                        }
                    }
                }
                local.resolved = backing.toOwnedSlice() catch return Error.Memory;
                return local;
            },
            .vari => {
                return try variable(a, token);
            },
            .word, .path => {
                return try word(a, token);
            },
            .subp => {
                if (token.parsed) return token;
                return try subcmd(a, token);
            },
            else => {
                switch (token.str[0]) {
                    '$' => return token,
                    else => return token,
                }
            },
        }
    }

    fn resolve(token: Token) Error!Token {
        _ = try alias(token);
        return token;
    }

    fn alias(token: Token) Error![]const u8 {
        if (Aliases.find(token.cannon())) |a| {
            return a.value;
        }
        return Error.Empty;
    }

    fn word(a: Allocator, t: Token) Error!Token {
        var local = t;
        if (std.mem.indexOf(u8, t.str, "\\")) |_| {
            std.debug.assert(t.resolved == null);
            var new = ArrayList(u8).init(a);
            var esc = false;
            for (local.cannon()) |c| {
                if (c == '\\' and !esc) {
                    esc = true;
                    continue;
                }
                esc = false;
                new.append(c) catch @panic("memory error");
            }
            local.resolved = new.toOwnedSlice() catch @panic("memory error");
        }

        if (local.cannon()[0] == '~' or mem.indexOf(u8, local.cannon(), "/") != null) {
            return path(a, local);
        }

        return local;
    }

    /// Caller owns memory for both list of names, and each name
    fn globAt(a: Allocator, d: []const u8, str: []const u8) Error![][]u8 {
        var dir = if (d[0] == '/')
            std.fs.openIterableDirAbsolute(d, .{}) catch return Error.Unknown
        else
            std.fs.cwd().openIterableDir(d, .{}) catch return Error.Unknown;
        defer dir.close();
        return fs.globAt(a, dir, str) catch @panic("this error not implemented");
    }

    /// Caller owns memory for both list of names, and each name
    fn glob(a: Allocator, str: []const u8) Error![][]u8 {
        return fs.globCwd(a, str) catch @panic("this error not implemented");
    }

    fn variable(a: Allocator, tkn: Token) Error!Token {
        var local = tkn;
        if (Variables.getStr(tkn.cannon())) |v| {
            local.resolved = try a.dupe(u8, v);
        } else {
            // TODO this probably should emit an error of some kind?
            local.resolved = try a.dupe(u8, "");
        }
        return local;
    }

    fn path(a: Allocator, t: Token) Error!Token {
        var local = t;
        local.kind = .path;
        if (local.cannon()[0] == '~') {
            if (Variables.getStr("HOME")) |v| {
                var list: ArrayList(u8) = undefined;
                if (local.resolved) |r| {
                    list = ArrayList(u8).fromOwnedSlice(a, r);
                } else {
                    list = ArrayList(u8).init(a);
                    list.appendSlice(local.cannon()) catch return Error.Memory;
                }

                list.replaceRange(0, 1, v) catch return Error.Memory;
                local.resolved = list.toOwnedSlice() catch return Error.Memory;
            }
        }
        return local;
    }

    fn subcmd(a: Allocator, tkn: Token) Error!Token {
        var local = tkn;
        var cmd = tkn.str[2 .. tkn.str.len - 1];
        std.debug.assert(tkn.str[0] == '$');
        std.debug.assert(tkn.str[1] == '(');

        var itr = TokenIterator{ .raw = cmd };
        var argv_t = itr.toSlice(a) catch return Error.Memory;
        defer a.free(argv_t);
        var list = ArrayList([]const u8).init(a);
        for (argv_t) |t| {
            list.append(t.cannon()) catch return Error.Memory;
        }
        var argv = list.toOwnedSlice() catch return Error.Memory;
        defer a.free(argv);
        local.parsed = true;

        var out = exec.child(a, argv) catch {
            local.resolved = a.dupe(u8, local.str) catch return Error.Memory;
            return local;
        };

        local.resolved = std.mem.join(a, "\n", out.stdout) catch return Error.Memory;
        for (out.stdout) |line| a.free(line);
        a.free(out.stdout);
        return local;
    }
};

const expect = std.testing.expect;
const expectEql = std.testing.expectEqual;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
const eqlStr = std.testing.expectEqualStrings;

test "iterator nows" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("\"this is some text\" more text");
    var itr = t.iterator();
    var ts = try itr.toSlice(a);
    defer a.free(ts);
    var ptr = try Parser.parse(a, ts);
    defer ptr.raze();
    var i: usize = 0;
    while (ptr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
}
test "breaking" {
    var a = std.testing.allocator;
    var t = Tokenizer.init(std.testing.allocator);
    defer t.reset();

    try t.consumes("alias la='ls -la'");
    var titr = t.iterator();
    var tokens = try titr.toSlice(a);
    try expectEql(tokens.len, 4);

    titr.restart();
    try eqlStr("alias", titr.next().?.cannon());
    try eqlStr(" ", titr.next().?.cannon());
    try eqlStr("la=", titr.next().?.cannon());
    try eqlStr("ls -la", titr.next().?.cannon());
    try expectEql(titr.next(), null);

    var pitr = try Parser.parse(a, tokens);
    defer pitr.raze();

    var count: usize = 0;
    while (pitr.next()) |_| {
        count += 1;
    }
    try expectEql(count, 2);
    pitr.restart();
    try eqlStr("alias", pitr.next().?.cannon());
    try eqlStr("la=ls -la", pitr.next().?.cannon());

    a.free(tokens);
}

test "iterator alias is builtin" {
    var a = std.testing.allocator;

    var ts = [_]Token{
        Token{ .kind = .word, .str = "alias" },
    };

    var itr = try Parser.parse(a, &ts);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 1);
    try std.testing.expectEqualStrings("alias", itr.first().cannon());
    try expect(itr.next() == null);
}

test "iterator aliased" {
    var a = std.testing.allocator;
    Aliases.init(a);
    var als = &Aliases.aliases;
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.parse(a, &ts);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().cannon(), "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try expect(eql(u8, itr.next().?.cannon(), "src"));
    try expect(itr.next() == null);
}

test "iterator aliased self" {
    var a = std.testing.allocator;
    Aliases.init(a);
    var als = &Aliases.aliases;
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .word, .str = "ls" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.parse(a, &ts);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().cannon(), "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try std.testing.expectEqualStrings("src", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "iterator aliased recurse" {
    var a = std.testing.allocator;
    Aliases.init(a);
    var als = &Aliases.aliases;
    defer Aliases.raze(a);
    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "la") catch unreachable,
        .value = a.dupe(u8, "ls -la") catch unreachable,
    });

    try als.append(Aliases.Alias{
        .name = a.dupe(u8, "ls") catch unreachable,
        .value = a.dupe(u8, "ls --color=auto") catch unreachable,
    });

    var ts = [_]Token{
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.parse(a, &ts);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 4);
    var first = itr.first().cannon();
    try expect(eql(u8, first, "ls"));
    try expect(eql(u8, itr.next().?.cannon(), "--color=auto"));
    try expect(eql(u8, itr.next().?.cannon(), "-la"));
    try expect(eql(u8, itr.next().?.cannon(), "src"));
    try expect(itr.next() == null);
}

test "parse vars" {
    var a = std.testing.allocator;

    comptime var ts = [5]Token{
        try Tokenizer.any("echo"),
        try Tokenizer.any(" "),
        try Tokenizer.any("$string"),
        try Tokenizer.any(" "),
        try Tokenizer.any("blerg"),
    };

    var itr = try Parser.parse(a, &ts);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);
    try eqlStr("", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing" {
    var a = std.testing.allocator;

    comptime var ts = [3]Token{
        try Tokenizer.any("echo"),
        try Tokenizer.any("$string"),
        try Tokenizer.any("blerg"),
    };

    Variables.init(a);
    defer Variables.raze();

    try Variables.put("string", "correct");

    try eqlStr("correct", Variables.getStr("string").?);

    var itr = try Parser.parse(a, &ts);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 1);
    var first = itr.first().cannon();
    try eqlStr("echocorrectblerg", first);
    try expect(itr.next() == null);
}

test "parse vars existing with white space" {
    var a = std.testing.allocator;

    comptime var ts = [5]Token{
        try Tokenizer.any("echo"),
        try Tokenizer.any(" "),
        try Tokenizer.any("$string"),
        try Tokenizer.any(" "),
        try Tokenizer.any("blerg"),
    };

    Variables.init(a);
    defer Variables.raze();

    try Variables.put("string", "correct");

    try eqlStr("correct", Variables.getStr("string").?);

    var itr = try Parser.parse(a, &ts);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);
    var tst = itr.next().?;
    try eqlStr("correct", tst.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo ${string}extra blerg",
    };

    Variables.init(a);
    defer Variables.raze();

    try Variables.put("string", "value");

    try eqlStr("value", Variables.getStr("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("valueextra", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces inline" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string} blerg",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("string", "value");

    try eqlStr("value", Variables.getStr("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("extravalue", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse vars existing braces inline both" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string}thingy blerg",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("string", "value");

    try eqlStr("value", Variables.getStr("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    var first = itr.first().cannon();
    try eqlStr("echo", first);

    try eqlStr("extravaluethingy", itr.next().?.cannon());
    try eqlStr("blerg", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse path" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    try eqlStr("~", itr.next().?.cannon());
    try expect(itr.next() == null);
}

test "parse path ~" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var thing = itr.next();
    //try std.testing.expect(thing.?.kind == .path);
    try eqlStr("/home/user", thing.?.cannon());
    try std.testing.expect(itr.next() == null);
}

test "parse path ~/" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var thing = itr.next();
    //try std.testing.expect(thing.?.kind == .path);
    try eqlStr("/home/user/", thing.?.cannon());
    try std.testing.expect(itr.next() == null);
}

test "parse path ~/place" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/place",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var tst = itr.next();
    //try std.testing.expect(tst.?.kind == .path);
    try eqlStr("/home/user/place", tst.?.cannon());
    try std.testing.expect(itr.next() == null);
}

test "parse path /~/otherplace" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls /~/otherplace",
    };

    Variables.init(a);
    defer Variables.raze();
    try Variables.put("HOME", "/home/user");

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    var first = itr.first().cannon();
    try eqlStr("ls", first);

    var tst = itr.next();
    //try std.testing.expect(tst.?.kind == .path);
    try eqlStr("/~/otherplace", tst.?.cannon());
    try std.testing.expect(itr.next() == null);
}

test "glob" {
    var a = std.testing.allocator;

    var oldcwd = std.fs.cwd();
    var basecwd = try oldcwd.realpathAlloc(a, ".");
    defer {
        var dir = std.fs.openDirAbsolute(basecwd, .{}) catch unreachable;
        dir.setAsCwd() catch {};
        a.free(basecwd);
    }

    var tmpCwd = std.testing.tmpIterableDir(.{});
    defer tmpCwd.cleanup();
    try tmpCwd.iterable_dir.dir.setAsCwd();
    _ = try tmpCwd.iterable_dir.dir.createFile("blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile(".blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("blerg2", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("w00t", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("no_wai", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("ya-wai", .{});
    var di = tmpCwd.iterable_dir.iterate();

    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        if (each.name[0] == '.') continue;
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 5), names.items.len);

    var ti = TokenIterator{
        .raw = "echo *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 6), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.cannon())) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else return error.TestingUnmatchedName;
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "glob ." {
    var a = std.testing.allocator;

    var oldcwd = std.fs.cwd();
    var basecwd = try oldcwd.realpathAlloc(a, ".");
    defer {
        var dir = std.fs.openDirAbsolute(basecwd, .{}) catch unreachable;
        dir.setAsCwd() catch {};
        a.free(basecwd);
    }

    var tmpCwd = std.testing.tmpIterableDir(.{});
    defer tmpCwd.cleanup();
    try tmpCwd.iterable_dir.dir.setAsCwd();
    _ = try tmpCwd.iterable_dir.dir.createFile("blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile(".blerg", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("no_wai", .{});
    _ = try tmpCwd.iterable_dir.dir.createFile("ya-wai", .{});
    var di = tmpCwd.iterable_dir.iterate();

    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 4), names.items.len);

    var ti = TokenIterator{
        .raw = "echo .* *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 5), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.cannon())) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else return error.TestingUnmatchedName;
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "glob ~/*" {
    var a = std.testing.allocator;

    Variables.init(a);
    defer Variables.raze();

    var tmpCwd = std.testing.tmpIterableDir(.{});
    defer tmpCwd.cleanup();
    var baseCwd = try tmpCwd.iterable_dir.dir.realpathAlloc(a, ".");
    defer a.free(baseCwd);

    _ = try tmpCwd.iterable_dir.dir.createFile("blerg", .{});

    try Variables.put("HOME", baseCwd);

    var di = tmpCwd.iterable_dir.iterate();
    var names = std.ArrayList([]u8).init(a);

    while (try di.next()) |each| {
        if (each.name[0] == '.') continue;
        try names.append(try a.dupe(u8, each.name));
    }
    errdefer {
        for (names.items) |each| {
            a.free(each);
        }
        names.clearAndFree();
    }

    var ti = TokenIterator{
        .raw = "echo ~/* ",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.parse(a, slice);
    defer itr.raze();

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        //std.debug.print("loop {s} {any}\n", .{ next.cannon(), next.kind });
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, names.items.len + 1), count);

    try std.testing.expectEqualStrings("echo", itr.first().cannon());
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.endsWith(u8, next.cannon(), name)) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else {
            std.debug.print("unmatched {s}\n", .{next.cannon()});
            return error.TestingUnmatchedName;
        }
    }
    try std.testing.expect(names.items.len == 0);
    try std.testing.expect(itr.next() == null);
    names.clearAndFree();
}

test "escapes" {
    var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "one\\\\ two" };
    var first = t.first();
    try std.testing.expectEqualStrings("one", first.cannon());

    var slice = try t.toSlice(a);
    defer a.free(slice);
    var pitr = try Parser.parse(a, slice);
    defer pitr.raze();
    try eqlStr("one\\", pitr.next().?.cannon());

    a.free(slice);
    pitr.raze();

    t = TokenIterator{ .raw = "--inline=quoted\\ string" };
    slice = try t.toSlice(a);
    pitr = try Parser.parse(a, slice);
    try eqlStr("--inline=quoted string", pitr.next().?.cannon());
}

test "sub process" {
    //var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "which $(echo 'ls')" };
    var first = t.first();
    try std.testing.expectEqualStrings("which", first.cannon());
    t.skip();
    var next = t.next() orelse return error.Invalid;

    try std.testing.expectEqualStrings("$(echo 'ls')", next.cannon());

    // TODO build a better test harness for this
    // var p = try Parser.single(&a, @constCast(next));
    // try std.testing.expectEqualStrings("ls", p.cannon());
    // a.free(p.resolved.?);
}
