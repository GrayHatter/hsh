pub const Error = error{
    Unknown,
    Memory,
    OutOfMemory,
    ParseFailed,
    OpenGroup,
    Empty,
};

pub const Arg = union(enum) {
    parsed: Parsed,
    resolved: Resolved,

    pub const empty: Arg = .{ .resolved = .{ .str = &.{} } };
};

pub const Construct = enum {
    alias,
    builtin,
    dollar,
    glob,
    io_mode,
    multi_glob,
    path,
    result_logic,
    subcommand,
    word,
    fmt_str,
};

pub const Parsed = union(Construct) {
    alias: Base,
    builtin: Base,
    dollar: Base,
    glob: Base,
    io_mode: Base,
    multi_glob: Base,
    path: Base,
    result_logic: Base,
    subcommand: Base,
    word: Base,
    fmt_str: Base,

    pub const Base = struct {
        str: []const u8,
    };

    pub fn anyStr(p: Parsed) []const u8 {
        return switch (p) {
            inline else => |el| el.str,
        };
    }
};

pub const Resolved = struct {
    str: []const u8,
    construct: Construct = .word,
    allocated: bool = false,
    io: ?Token.IOKind = null,
    op: ?Token.OpKind = null,

    pub fn raze(r: *Resolved, a: Allocator) void {
        if (r.allocated) a.free(r.str);
    }
};

pub const Iterator = struct {
    r_index: usize = 0,
    resolved: ArrayList(Arg), // this will become Parsed at some point.
    t_index: usize = 0,
    tokens: []const Token,
    aliases: [40][]const u8 = @splat(&.{}),
    aliases_len: usize = 0,
    // command subexec may have side-effects which would be incompatible with
    // completion suggestions.
    exec_allowed: bool = true,

    /// Restart iterator, and assumes length >= 1
    pub fn first(self: *Iterator) *const Arg {
        self.restart();
        return self.next() orelse &self.resolved.items[0];
    }

    /// Returns next Token, omitting, or splitting them as needed.
    pub fn next(self: *Iterator) ?*const Arg {
        if (self.r_index < self.resolved.items.len) {
            defer self.r_index += 1;
            return &self.resolved.items[self.r_index];
        }

        if (self.t_index >= self.tokens.len) {
            return null;
        }

        while (self.t_index < self.tokens.len) {
            var token = self.tokens[self.t_index];
            if (token.kind == .ws) {
                self.t_index += 1;
                continue;
            }
            defer self.t_index += 1;
            self.parse(token) catch unreachable;
            return self.next();
        }
        return self.next();
    }

    fn aliasedAdd(itr: *Iterator, str: []const u8) void {
        std.debug.assert(itr.aliases_len < itr.aliases.len);
        itr.aliases[itr.aliases_len] = str;
        itr.aliases_len += 1;
    }

    pub fn resolveAll(itr: *Iterator, a: Allocator, _: Io) !void {
        while (itr.next()) |_| {}
        for (itr.resolved.items) |*prsd| switch (prsd.*) {
            .resolved => {},
            .parsed => |pr| switch (pr) {
                .path => |path| {
                    log.err("path {s}\n", .{path.str});
                    prsd.* = try Parser.path(path.str, a);
                },
                inline else => |el, t| {
                    prsd.* = .{ .resolved = .{
                        .str = try a.dupe(u8, el.str),
                        .construct = t,
                    } };
                },
            },
        };
        itr.r_index = 0;
    }

    fn resolveAlias(itr: *Iterator, token: Token) Error!void {
        for (itr.aliases[0..itr.aliases_len]) |res| {
            if (eql(u8, token.str, res)) {
                try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = res } } });
                return;
            }
        }
        itr.aliasedAdd(token.str);

        var sub_itr: TokenIterator = .{ .raw = Parser.alias(token) catch token.str };
        const sub_first = sub_itr.first().*;
        try itr.resolveAlias(sub_first);

        while (sub_itr.next()) |stkn| {
            if (stkn.kind == .ws) continue;
            try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = stkn.str } } });
        }
    }

    fn parse(itr: *Iterator, t: Token) Error!void {
        if (itr.t_index == 0) return itr.resolveAlias(t);

        // TODO hack while I refactor next() to concat tokens
        if (t.kind == .ws) {
            //try tokens.append(t);
            return;
        }

        if (t.kind == .quote and t.subtoken == '\'') {
            try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = t.str } } });
            return;
        }

        if (t.kind == .vari) {
            const dollar = try itr.parseDollar(t.str);
            try itr.resolved.appendBounded(.{ .parsed = dollar });
        } else if (find(u8, t.str, "$")) |idx| {
            try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = t.str[0..idx] } } });
            const dollar = try itr.parseDollar(t.str[idx..]);
            try itr.resolved.appendBounded(.{ .parsed = dollar });
            try itr.parse(.make(t.str[idx + dollar.anyStr().len ..], t.kind));
        } else if (find(u8, t.str, "*")) |_| {
            try itr.resolveGlob(t.str);
        } else {
            const real = try Parser.single(t);
            try itr.resolved.appendBounded(real);
        }
    }

    fn parseDollar(_: *Iterator, str: []const u8) !Parsed {
        std.debug.assert(str[0] == '$');
        if (str.len == 0) return .{ .word = .{ .str = str } };
        switch (str[1]) {
            '(' => {
                if (findScalar(u8, str, ')')) |idx| {
                    return .{ .subcommand = .{ .str = str[0..idx] } };
                }
                return .{ .word = .{ .str = str } };
            },
            else => return .{ .word = .{ .str = str } },
        }
        return error.Unknown;
    }

    fn resolveGlob(_: *Iterator, str: []const u8) !void {
        if (find(u8, str, "*")) |_| {} else unreachable;

        if (find(u8, str, "/")) |_| {
            unreachable;
            //var bitr = std.mem.splitBackwardsAny(u8, str, "/");
            //const glob = bitr.first();
            //const dir = bitr.rest();
            //if (Parser.globAt(itr.alloc, dir, glob)) |names| {
            //    for (names) |name| {
            //        if (!startsWith(u8, str, ".") and startsWith(u8, name, ".")) {
            //            continue;
            //        }
            //        const path = try std.mem.join(itr.alloc, "/", &[2][]const u8{ dir, name });
            //        try itr.resolved.appendBounded(.{ .str = "", .resolved = path });
            //    }
            //} else |e| {
            //    if (e != Error.Empty) {
            //        log.err("error resolving glob {}\n", .{e});
            //        //unreachable;
            //    }
            //}
        } else {
            unreachable;
            //if (Parser.glob(str)) |names| {
            //    for (names) |name| {
            //        if (!startsWith(u8, str, ".") and startsWith(u8, name, ".")) {
            //            continue;
            //        }
            //        try itr.resolved.appendBounded(.{ .str = "", .resolved = name });
            //    }
            //} else |e| {
            //    if (e != Error.Empty) {
            //        std.debug.print("error resolving glob {}\n", .{e});
            //        unreachable;
            //    }
            //}
        }
    }

    /// Resets the iterator to the initial slice.
    pub fn restart(self: *Iterator) void {
        self.r_index = 0;
    }

    pub fn raze(self: *Iterator, a: Allocator) void {
        self.t_index = 0;
        self.r_index = 0;
        self.aliases_len = 0;
        for (self.resolved.items) |*prs| switch (prs.*) {
            .parsed => {},
            .resolved => |rs| a.free(rs.str),
        };
        self.resolved.clearAndFree(a);
    }
};

pub const Parser = struct {
    alloc: Allocator,

    pub fn iterate(a: Allocator, tokens: []Token) !Iterator {
        var start: usize = 0;
        while (tokens[start].kind == .ws) : (start += 1) {}
        if (tokens[start..].len == 0) return error.Empty;
        return .{
            .resolved = try .initCapacity(a, 300),
            .tokens = tokens[start..],
        };
    }

    pub fn single(token: Token) Error!Arg {
        if (token.str.len == 0) return .empty;

        switch (token.kind) {
            .quote => {
                std.debug.print("{any}", .{token});
                unreachable;
                //var needle = [2]u8{ '\\', token.subtoken };
                //if (mem.indexOfScalar(u8, token.str, '\\')) |_| {} else return token;

                //var i: usize = 0;
                //backing.appendSliceBounded(a, token.str) catch return Error.Memory;
                //while (i + 1 < backing.items.len) : (i += 1) {
                //    if (backing.items[i] == '\\') {
                //        if (mem.indexOfAny(u8, backing.items[i + 1 .. i + 2], &needle)) |_| {
                //            _ = backing.orderedRemove(i);
                //        }
                //    }
                //}
                //local.resolved = backing.toOwnedSlice(a) catch return Error.Memory;
                //return local;
            },
            .vari => return try variable(token),
            .word, .path => return try word(token),
            .subp => {
                if (token.parsed) return .{ .parsed = .{ .word = .{ .str = token.str } } };
                return .{ .parsed = .{ .subcommand = .{ .str = token.str } } };
            },
            else => {
                switch (token.str[0]) {
                    '$' => return .{ .parsed = .{ .dollar = .{ .str = token.str } } },
                    else => return .{ .parsed = .{ .word = .{ .str = token.str } } },
                }
            },
        }
    }

    fn resolve(token: Token) Error!Token {
        _ = try alias(token);
        return token;
    }

    fn alias(token: Token) Error![]const u8 {
        return (Alias.find(token.str) orelse return Error.Empty).value;
    }

    fn word(t: Token) Error!Arg {
        if (findScalar(u8, t.str, '\\')) |_| {
            std.debug.assert(t.resolved == null);
            return .{ .parsed = .{ .fmt_str = .{ .str = t.str } } };
        }

        if (t.str[0] == '~' or findScalar(u8, t.str, '/') != null) {
            return .{ .parsed = .{ .path = .{ .str = t.str } } };
        }

        return .{ .parsed = .{ .word = .{ .str = t.str } } };
    }

    /// Caller owns memory for both list of names, and each name
    fn globAt(a: Allocator, d: []const u8, str: []const u8) Error![][]u8 {
        var dir = if (d[0] == '/')
            std.fs.openDirAbsolute(d, .{ .iterate = true }) catch return Error.Unknown
        else
            std.fs.cwd().openDir(d, .{ .iterate = true }) catch return Error.Unknown;
        defer dir.close();
        return Fs.globAt(a, dir, str) catch @panic("this error not implemented");
    }

    /// Caller owns memory for both list of names, and each name
    fn glob(a: Allocator, str: []const u8) Error![][]u8 {
        return Fs.globCwd(a, str) catch @panic("this error not implemented");
    }

    fn variable(tkn: Token) Error!Arg {
        return if (Variables.get(tkn.str)) |v| .{ .resolved = .{ .str = v } } else .empty;
    }

    fn path(str: []const u8, a: Allocator) !Arg {
        if (str[0] == '~' and (str.len == 1 or str[1] == '/')) {
            var list: ArrayList(u8) = .{};
            if (Variables.get("HOME")) |v| {
                try list.appendSlice(a, v);
                try list.appendSlice(a, str[1..]);
            } else {
                try list.appendSlice(a, str);
            }
            return .{ .resolved = .{
                .str = try list.toOwnedSlice(a),
                .construct = .path,
            } };
        }
        return .{ .resolved = .{
            .str = try a.dupe(u8, str),
            .construct = .path,
        } };
    }

    fn subcmd(h: *Hsh, a: Allocator, tkn: Token) Error!Token {
        var local = tkn;
        const cmd = tkn.str[2 .. tkn.str.len - 1];
        std.debug.assert(tkn.str[0] == '$');
        std.debug.assert(tkn.str[1] == '(');

        var itr = TokenIterator{ .raw = cmd };
        const argv_t = itr.toSlice(a) catch return Error.Memory;
        defer a.free(argv_t);
        var list = ArrayList([]const u8){};
        for (argv_t) |t| {
            list.append(a, t.str) catch return Error.Memory;
        }
        const argv = list.toOwnedSlice(a) catch return Error.Memory;
        defer a.free(argv);
        local.parsed = true;

        const out = exec.child(h, argv, a) catch {
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
    defer t.raze();

    try t.consumes("\"this is some text\" more text");
    var itr = t.iterator();
    const ts = try itr.toSlice(a);
    defer a.free(ts);
    var ptr = try Parser.iterate(a, ts);
    defer ptr.raze(a);
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
    defer t.raze();

    try t.consumes("alias la='ls -la'");
    var titr = t.iterator();
    const tokens = try titr.toSlice(a);
    try expectEql(tokens.len, 4);

    titr.restart();
    try eqlStr("alias", titr.next().?.resolved.?);
    try eqlStr(" ", titr.next().?.resolved.?);
    try eqlStr("la=", titr.next().?.resolved.?);
    try eqlStr("ls -la", titr.next().?.resolved.?);
    try expectEql(titr.next(), null);

    var itr = try Parser.iterate(a, tokens);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var count: usize = 0;
    while (itr.next()) |_| {
        count += 1;
    }
    try expectEql(count, 2);
    itr.restart();
    try eqlStr("alias", itr.next().?.resolved.str);
    try eqlStr("la=ls -la", itr.next().?.resolved.str);

    a.free(tokens);
}

test "iterator alias is builtin" {
    const a = std.testing.allocator;

    var ts = [_]Token{
        Token{ .kind = .word, .str = "alias" },
    };

    var itr = try Parser.iterate(a, &ts);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 1);
    try std.testing.expectEqualStrings("alias", itr.first().resolved.str);
    try expect(itr.next() == null);
}

test "iterator aliased" {
    var a = std.testing.allocator;
    Alias.init();
    defer Alias.raze(a);
    Alias.testingAdd(
        a.dupe(u8, "la") catch unreachable,
        a.dupe(u8, "ls -la") catch unreachable,
        a,
    );

    var ts = [_]Token{
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().resolved.str, "ls"));
    try expect(eql(u8, itr.next().?.resolved.str, "-la"));
    try expect(eql(u8, itr.next().?.resolved.str, "src"));
    try expect(itr.next() == null);
}

test "iterator aliased self" {
    var a = std.testing.allocator;

    Alias.init();
    defer Alias.raze(a);
    Alias.testingAdd(
        a.dupe(u8, "la") catch unreachable,
        a.dupe(u8, "ls -la") catch unreachable,
        a,
    );

    var ts = [_]Token{
        Token{ .kind = .word, .str = "ls" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    try expect(eql(u8, itr.first().resolved.str, "ls"));
    try expect(eql(u8, itr.next().?.resolved.str, "-la"));
    try std.testing.expectEqualStrings("src", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "iterator aliased recurse" {
    var a = std.testing.allocator;
    Alias.init();
    defer Alias.raze(a);
    Alias.testingAdd(
        a.dupe(u8, "la") catch unreachable,
        a.dupe(u8, "ls -la") catch unreachable,
        a,
    );

    Alias.testingAdd(
        a.dupe(u8, "ls") catch unreachable,
        a.dupe(u8, "ls --color=auto") catch unreachable,
        a,
    );

    var ts = [_]Token{
        Token{ .kind = .word, .str = "la" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "src" },
    };

    var itr = try Parser.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 4);
    const first = itr.first().resolved.str;
    try expect(eql(u8, first, "ls"));
    try expect(eql(u8, itr.next().?.resolved.str, "--color=auto"));
    try expect(eql(u8, itr.next().?.resolved.str, "-la"));
    try expect(eql(u8, itr.next().?.resolved.str, "src"));
    try expect(itr.next() == null);
}

test "parse vars" {
    const a = std.testing.allocator;

    var ts = [5]Token{
        try Token.any("echo"),
        try Token.any(" "),
        try Token.any("$string"),
        try Token.any(" "),
        try Token.any("blerg"),
    };

    var itr = try Parser.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    const first = itr.first().resolved.str;
    try eqlStr("echo", first);
    try eqlStr("", itr.next().?.resolved.str);
    try eqlStr("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse vars existing" {
    const a = std.testing.allocator;

    var ts = [3]Token{
        try Token.any("echo"),
        try Token.any("$string"),
        try Token.any("blerg"),
    };

    Variables.init(a);
    defer Variables.raze(a);

    try Variables.put("string", "correct", a);

    try eqlStr("correct", Variables.get("string").?);

    var itr = try Parser.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 1);
    const first = itr.first().resolved.str;
    try eqlStr("echocorrectblerg", first);
    try expect(itr.next() == null);
}

test "parse vars existing with white space" {
    const a = std.testing.allocator;

    var ts = [5]Token{
        try Token.any("echo"),
        try Token.any(" "),
        try Token.any("$string"),
        try Token.any(" "),
        try Token.any("blerg"),
    };

    Variables.init(a);
    defer Variables.raze(a);

    try Variables.put("string", "correct", a);

    try eqlStr("correct", Variables.get("string").?);

    var itr = try Parser.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 3);
    const first = itr.first().resolved.str;
    try eqlStr("echo", first);
    var tst = itr.next().?;
    try eqlStr("correct", tst.resolved.str);
    try eqlStr("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse vars existing braces" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo ${string}extra blerg",
    };

    Variables.init(a);
    defer Variables.raze(a);

    try Variables.put("string", "value", a);

    try eqlStr("value", Variables.get("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    const first = itr.first().resolved.str;
    try eqlStr("echo", first);

    try eqlStr("valueextra", itr.next().?.resolved.str);
    try eqlStr("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse vars existing braces inline" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string} blerg",
    };

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("string", "value", a);

    try eqlStr("value", Variables.get("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    const first = itr.first().resolved.str;
    try eqlStr("echo", first);

    try eqlStr("extravalue", itr.next().?.resolved.str);
    try eqlStr("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse vars existing braces inline both" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "echo extra${string}thingy blerg",
    };

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("string", "value", a);

    try eqlStr("value", Variables.get("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 3);
    const first = itr.first().resolved.str;
    try eqlStr("echo", first);

    try eqlStr("extravaluethingy", itr.next().?.resolved.str);
    try eqlStr("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse dollar dollar bills y'all" {
    const a = std.testing.allocator;

    var tkns = [_]Token{
        Token.make("echo", .word),
        Token.make(" ", .ws),
        Token.make("$!", .vari),
        Token.make(" ", .ws),
        Token.make("other", .word),
    };

    var itr = try Parser.iterate(a, &tkns);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(itr.next() == null);
    itr.raze(a);

    tkns = [_]Token{
        Token.make("echo", .word),
        Token.make(" ", .ws),
        try Token.quoteSingle("'$!'"),
        Token.make(" ", .ws),
        Token.make("other", .word),
    };

    itr = try Parser.iterate(a, &tkns);
    try itr.resolveAll(a, undefined);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") != null);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(itr.next() == null);
    itr.raze(a);

    tkns = [_]Token{
        Token.make("echo", .word),
        Token.make(" ", .ws),
        try Token.quoteDouble("\"$!\""),
        Token.make(" ", .ws),
        Token.make("other", .word),
    };

    itr = try Parser.iterate(a, &tkns);
    try itr.resolveAll(a, undefined);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    try std.testing.expect(itr.next() == null);
}

test "parse path" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    const first = itr.first().resolved.str;
    try eqlStr("ls", first);

    try eqlStr("~", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse path ~" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~",
    };

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 2);
    const first = itr.first().resolved.str;
    try eqlStr("ls", first);

    var thing = itr.next();
    //try std.testing.expect(thing.?.kind == .path);
    try eqlStr("/home/user", thing.?.resolved.str);
    try std.testing.expect(itr.next() == null);
}

test "parse path ~/" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/",
    };

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t_});
        i += 1;
    }
    try expectEql(i, 2);
    const first = itr.first().resolved.str;
    try eqlStr("ls", first);

    var thing = itr.next();
    //try std.testing.expect(thing.?.kind == .path);
    try eqlStr("/home/user/", thing.?.resolved.str);
    try std.testing.expect(itr.next() == null);
}

test "parse path ~/place" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls ~/place",
    };

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    const first = itr.first().resolved.str;
    try eqlStr("ls", first);

    var tst = itr.next();
    //try std.testing.expect(tst.?.kind == .path);
    try eqlStr("/home/user/place", tst.?.resolved.str);
    try std.testing.expect(itr.next() == null);
}

test "parse path /~/otherplace" {
    var a = std.testing.allocator;

    var ti = TokenIterator{
        .raw = "ls /~/otherplace",
    };

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEql(i, 2);
    const first = itr.first().resolved.str;
    try eqlStr("ls", first);

    var tst = itr.next();
    //try std.testing.expect(tst.?.kind == .path);
    try eqlStr("/~/otherplace", tst.?.resolved.str);
    try std.testing.expect(itr.next() == null);
}

test "glob" {
    var a = std.testing.allocator;
    const io = std.testing.io;

    var tmpCwd = std.testing.tmpDir(.{ .iterate = true });
    defer tmpCwd.cleanup();
    _ = try tmpCwd.dir.createFile(io, "blerg", .{});
    _ = try tmpCwd.dir.createFile(io, ".blerg", .{});
    _ = try tmpCwd.dir.createFile(io, "blerg2", .{});
    _ = try tmpCwd.dir.createFile(io, "w00t", .{});
    _ = try tmpCwd.dir.createFile(io, "no_wai", .{});
    _ = try tmpCwd.dir.createFile(io, "ya-wai", .{});
    var di = tmpCwd.dir.iterate();

    var names = std.array_list.Managed([]u8).init(a);

    while (try di.next(io)) |each| {
        if (each.name[0] == '.') continue;
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 5), names.items.len);

    var ti = TokenIterator{
        .raw = "echo *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 6), count);

    try std.testing.expectEqualStrings("echo", itr.first().resolved.str);
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.resolved.str)) {
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
    const io = std.testing.io;

    var tmpCwd = std.testing.tmpDir(.{ .iterate = true });
    defer tmpCwd.cleanup();
    _ = try tmpCwd.dir.createFile(io, "blerg", .{});
    _ = try tmpCwd.dir.createFile(io, ".blerg", .{});
    _ = try tmpCwd.dir.createFile(io, "no_wai", .{});
    _ = try tmpCwd.dir.createFile(io, "ya-wai", .{});
    var di = tmpCwd.dir.iterate();

    var names = std.array_list.Managed([]u8).init(a);

    while (try di.next(io)) |each| {
        try names.append(try a.dupe(u8, each.name));
    }
    try std.testing.expectEqual(@as(usize, 4), names.items.len);

    var ti = TokenIterator{
        .raw = "echo .* *",
    };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, 5), count);

    try std.testing.expectEqualStrings("echo", itr.first().resolved.str);
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.resolved.str)) {
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
    const io = std.testing.io;

    Variables.init(a);
    defer Variables.raze(a);

    var tmpCwd = std.testing.tmpDir(.{ .iterate = true });
    defer tmpCwd.cleanup();
    const baseCwd = try tmpCwd.dir.realPathFileAlloc(io, ".", a);
    defer a.free(baseCwd);

    _ = try tmpCwd.dir.createFile(io, "blerg", .{});

    try Variables.put("HOME", baseCwd, a);

    var di = tmpCwd.dir.iterate();
    var names = std.array_list.Managed([]u8).init(a);

    while (try di.next(io)) |each| {
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
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var count: usize = 0;
    while (itr.next()) |next| {
        count += 1;
        //std.debug.print("loop {s} {any}\n", .{ next.resolved.str, next.kind });
        _ = next;
    }
    try std.testing.expectEqual(@as(usize, names.items.len + 1), count);

    try std.testing.expectEqualStrings("echo", itr.first().resolved.str);
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.endsWith(u8, next.resolved.str, name)) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else {
            std.debug.print("unmatched {s}\n", .{next.resolved.str});
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
    try std.testing.expectEqualStrings("one", first.str);

    var slice = try t.toSlice(a);
    defer a.free(slice);
    var itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    try eqlStr("one\\", itr.next().?.resolved.str);

    a.free(slice);
    itr.raze(a);

    t = TokenIterator{ .raw = "--inline=quoted\\ string" };
    slice = try t.toSlice(a);
    itr = try Parser.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    try eqlStr("--inline=quoted string", itr.next().?.resolved.str);
}

test "sub process" {
    //var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "which $(echo 'ls')" };
    var first = t.first();
    try std.testing.expectEqualStrings("which", first.str);
    t.skip();
    var next = t.next() orelse return error.Invalid;

    try std.testing.expectEqualStrings("$(echo 'ls')", next.resolved.?);

    // TODO build a better test harness for this
    // var p = try Parser.single(&a, @constCast(next));
    // try std.testing.expectEqualStrings("ls", p.str);
    // a.free(p.resolved.?);
}

test "naughty strings parsed" {
    var a = std.testing.allocator;
    const while_str = "thingy (b.argv.next()) |_| {}";

    var itr = TokenIterator{ .raw = while_str };

    const slice = try itr.toSlice(a);
    defer a.free(slice);

    var pitr = try Parser.iterate(a, slice);
    try pitr.resolveAll(a, undefined);
    defer pitr.raze(a);

    var count: usize = 0;
    while (pitr.next()) |t| {
        if (false) log.err("{}\n", .{t});
        count += 1;
    }
    try expectEql(count, 4);
}

const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const mem = std.mem;
const log = @import("log.zig");
const Hsh = @import("hsh.zig");
const Tokenizer = @import("tokenizer.zig");
const Token = @import("token.zig");
const TokenIterator = Token.Iterator;
const Builtins = @import("builtins.zig");
const Alias = Builtins.Alias;
const Variables = @import("variables.zig");
const Fs = @import("fs.zig");
const exec = @import("exec.zig");
const find = std.mem.find;
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
