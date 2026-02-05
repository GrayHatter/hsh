pub const Arg = union(enum) {
    parsed: Parsed,
    resolved: Resolved,

    pub const empty: Arg = .{ .resolved = .{ .str = &.{} } };
};

pub const Construct = enum {
    alias,
    builtin,
    dollar,
    empty,
    fmt_str,
    glob,
    glob_multi,
    glob_path,
    io_mode,
    op_mode,
    path,
    subcommand,
    word,
};

pub const Parsed = union(Construct) {
    alias: Base,
    builtin: Base,
    dollar: Base,
    empty: void,
    fmt_str: Base,
    glob: Base,
    glob_multi: Base,
    glob_path: Base,
    io_mode: IoMode,
    op_mode: OpMode,
    path: Base,
    subcommand: Base,
    word: Base,

    pub const Base = struct {
        str: []const u8,
        continues: bool = true,
    };

    pub const OpMode = struct {
        mode: Token.OpKind,
        continues: bool = false,
    };

    pub const IoMode = struct {
        mode: Token.IOKind,
        continues: bool = false,
    };

    pub fn anyStr(p: Parsed) []const u8 {
        return switch (p) {
            .io_mode => "",
            .op_mode => "",
            .empty => &.{},
            inline else => |el| el.str,
        };
    }

    pub fn discontinue(p: *Parsed) void {
        switch (p.*) {
            .empty => unreachable,
            inline else => |*el| el.continues = false,
        }
    }

    pub fn continues(p: Parsed) bool {
        return switch (p) {
            .empty => unreachable,
            inline else => |el| el.continues,
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

    pub fn dupe(r: Resolved, a: Allocator) !Arg {
        return .{ .resolved = .{
            .str = try a.dupe(u8, r.str),
            .construct = r.construct,
            .allocated = r.allocated,
            .io = r.io,
            .op = r.op,
        } };
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
    pub fn first(itr: *Iterator) *const Arg {
        itr.restart();
        return itr.next() orelse &itr.resolved.items[0];
    }

    pub fn peek(itr: *Iterator) ?*const Arg {
        if (itr.r_index < itr.resolved.items.len) {
            return &itr.resolved.items[itr.r_index];
        }

        while (itr.t_index < itr.tokens.len) {
            const token = itr.tokens[itr.t_index];
            switch (token.kind) {
                .ws => {
                    itr.t_index += 1;
                    if (itr.r_index > 0)
                        itr.resolved.items[itr.r_index - 1].parsed.discontinue();
                    continue;
                },
                .oper => {
                    if (itr.r_index > 0) itr.resolved.items[itr.r_index - 1].parsed.discontinue();
                },
                else => {},
            }
            itr.parse(token) catch unreachable;

            //if (itr.resolved.items[itr.r_index].parsed == .comment) unreachable;
            itr.t_index += 1;
            return itr.peek();
        }
        return null;
    }

    /// Returns next Token, omitting, or splitting them as needed.
    pub fn next(itr: *Iterator) ?*const Arg {
        if (itr.r_index < itr.resolved.items.len) {
            defer itr.r_index += 1;
            return itr.peek();
        }

        while (itr.t_index < itr.tokens.len) {
            return itr.peek();
        }
        return null;
    }

    fn aliasedAdd(itr: *Iterator, str: []const u8) void {
        std.debug.assert(itr.aliases_len < itr.aliases.len);
        itr.aliases[itr.aliases_len] = str;
        itr.aliases_len += 1;
    }

    pub fn resolveAll(itr: *Iterator, a: Allocator, io: Io) !void {
        while (itr.next()) |_| {}

        var i: usize = 0;
        var auto_continue = false;
        while (i < itr.resolved.items.len) {
            var current: *Arg = &itr.resolved.items[i];
            const continues = auto_continue or (current.* == .parsed and current.parsed.continues());
            if (auto_continue) log.debug("auto continue \n", .{});
            if (current.* == .parsed) {
                log.debug("resolving '{s}' {} \n", .{ current.parsed.anyStr(), current });
            } else {
                log.debug("re-resolving '{s}' {} \n", .{ current.resolved.str, current });
            }
            try itr.resolveOne(current, a, io);
            if (current.resolved.construct == .empty) {
                _ = itr.resolved.orderedRemove(i);
                continue;
            }
            if (continues and i + 1 < itr.resolved.items.len) {
                var cont = itr.resolved.orderedRemove(i + 1);
                auto_continue = cont.parsed.continues();
                log.debug("adding '{s}' {} \n", .{ cont.parsed.anyStr(), cont });
                try itr.resolveOne(&cont, a, io);
                const str = try concat(a, u8, &[_][]const u8{ current.resolved.str, cont.resolved.str });
                a.free(current.resolved.str);
                a.free(cont.resolved.str);
                current.resolved.str = str;

                continue;
            }
            i += 1;
        }
        itr.r_index = 0;
    }

    fn resolveOne(itr: *Iterator, arg: *Arg, a: Allocator, io: Io) !void {
        switch (arg.*) {
            .resolved => {},
            .parsed => |pr| switch (pr) {
                .glob => |glob| {
                    const resolved = Resolver.glob(glob.str, a, io);
                    defer a.free(resolved);
                    if (resolved.len == 0) {
                        arg.* = .{ .resolved = .{ .str = &.{}, .construct = .empty } };
                        return;
                    }
                    arg.* = .{ .resolved = .{ .str = resolved[0], .construct = .path } };
                    const idx: usize = arg - itr.resolved.items.ptr;
                    for (resolved[1..], 1 + idx..) |rs, i| {
                        try itr.resolved.insertBounded(i, .{ .resolved = .{ .str = rs, .construct = .path } });
                    }
                },

                .path => |path| {
                    log.debug("path {s}\n", .{path.str});
                    arg.* = try Resolver.path(path.str, a, io);
                },
                .dollar => |dollar| {
                    log.debug("dollar {s}\n", .{dollar.str});
                    arg.* = try Resolver.variable(dollar.str, a);
                    log.debug("rlsv {s}\n", .{arg.resolved.str});
                },
                .io_mode => |mode| arg.* = .{
                    .resolved = .{ .str = &.{}, .construct = .io_mode, .io = mode.mode },
                },
                .op_mode => |mode| arg.* = .{
                    .resolved = .{ .str = &.{}, .construct = .op_mode, .op = mode.mode },
                },
                .empty => unreachable,
                inline else => |el, t| {
                    arg.* = .{ .resolved = .{
                        .str = try a.dupe(u8, el.str),
                        .construct = t,
                    } };
                },
            },
        }
    }

    fn parseAlias(itr: *Iterator, token: Token) !void {
        log.debug("called \n", .{});
        for (itr.aliases[0..itr.aliases_len]) |res| {
            if (eql(u8, token.str, res)) {
                try itr.resolved.appendBounded(.{ .parsed = .{
                    .word = .{ .str = res },
                } });
                return;
            }
        }

        itr.aliasedAdd(token.str);

        var sub_itr: TokenIterator = .{ .raw = Resolver.alias(token.str) catch {
            try itr.resolved.appendBounded(.{ .parsed = .{
                .word = .{ .str = token.str },
            } });
            return;
        } };
        const sub_first = sub_itr.first();
        try itr.parseAlias(sub_first);

        if (sub_itr.peek()) |pk| if (!pk.kind.continues())
            itr.resolved.items[itr.resolved.items.len - 1].parsed.discontinue();

        while (sub_itr.next()) |stkn| {
            const cont = if (sub_itr.peek()) |pk| !pk.kind.continues() else false;
            if (stkn.kind == .ws) continue;
            try itr.resolved.appendBounded(.{ .parsed = .{
                .word = .{ .str = stkn.str, .continues = cont },
            } });
        }
    }

    fn parse(itr: *Iterator, t: Token) !void {
        if (itr.t_index == 0 and t.kind == .word) return itr.parseAlias(t);

        // TODO hack while I refactor next() to concat tokens

        switch (t.kind) {
            .nos, .err, .ws => unreachable,
            .vari => try itr.parseVariable(t.str),
            .io => |io_m| {
                log.debug("found io '{s}'\n", .{t.str});
                switch (io_m) {
                    else => try itr.resolved.appendBounded(.{ .parsed = .{
                        .io_mode = .{ .mode = io_m },
                    } }),
                }
            },
            .logic => unreachable,
            .oper => |oper| {
                log.debug("found opr '{s}'\n", .{t.str});
                switch (oper) {
                    .pipe => try itr.resolved.appendBounded(.{ .parsed = .{
                        .op_mode = .{ .mode = oper, .continues = false },
                    } }),
                    else => unreachable,
                }
            },
            .subp => unreachable,
            .resr => unreachable,
            .comment => {},
            .path => try itr.resolved.appendBounded(
                .{ .parsed = .{ .path = .{ .str = t.str } } },
            ),
            .escp => try itr.resolved.appendBounded(
                .{ .parsed = .{ .word = .{ .str = t.str[1..2] } } },
            ),
            .quote, .brace => |q| {
                switch (q) {
                    ')', '}', ']' => try itr.resolved.appendBounded(
                        .{ .parsed = .{ .word = .{ .str = t.str } } },
                    ),

                    '"' => try itr.resolved.appendBounded(
                        .{ .parsed = .{ .word = .{ .str = t.str[1 .. t.str.len - 1] } } },
                    ),

                    '\'' => try itr.resolved.appendBounded(
                        .{ .parsed = .{ .word = .{ .str = t.str[1 .. t.str.len - 1] } } },
                    ),

                    else => unreachable,
                }
            },
            .word => {
                if (findScalar(u8, t.str, '$')) |_| {
                    unreachable;
                    //try itr.resolved.appendBounded(.{ .parsed = .{
                    //    .word = .{ .str = t.str[0..idx] },
                    //} });
                    //const dollar = try itr.parseVariable(t.str[idx..]);
                    //try itr.resolved.appendBounded(.{ .parsed = dollar });
                    //try itr.parse(.make(t.str[idx + dollar.anyStr().len ..], t.kind));
                } else if (findScalar(u8, t.str, '*')) |_| {
                    try itr.parseGlob(t.str);
                } else {
                    try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = t.str } } });
                }
            },
        }
    }

    fn parseIo() !void {}

    fn parseVariable(itr: *Iterator, str: []const u8) !void {
        std.debug.assert(str[0] == '$');
        if (str.len == 0) {
            try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = str } } });
            return;
        }

        switch (str[1]) {
            '(' => if (findScalar(u8, str, ')')) |idx|
                try itr.resolved.appendBounded(.{ .parsed = .{ .subcommand = .{ .str = str[0 .. idx + 1] } } })
            else
                try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = str } } }),
            '{' => if (findScalar(u8, str, '}')) |idx|
                try itr.resolved.appendBounded(.{ .parsed = .{ .dollar = .{ .str = str[0 .. idx + 1] } } })
            else
                try itr.resolved.appendBounded(.{ .parsed = .{ .word = .{ .str = str } } }),
            else => try itr.resolved.appendBounded(.{ .parsed = .{ .dollar = .{ .str = str } } }),
        }
    }

    fn parseGlob(itr: *Iterator, str: []const u8) !void {
        if (find(u8, str, "*") == null) unreachable;
        if (find(u8, str, "**") != null) return error.NotImplemented;

        if (find(u8, str, "/")) |_| {
            //unreachable;
            //var bitr = std.mem.splitBackwardsAny(u8, str, "/");
            //const glob = bitr.first();
            //const dir = bitr.rest();
            //if (Resolver.globAt(itr.alloc, dir, glob)) |names| {
            //    for (names) |name| {
            //        if (!startsWith(u8, str, ".") and startsWith(u8, name, ".")) {
            //            continue;
            //        }
            //        const path = try std.mem.join(itr.alloc, "/", &[2][]const u8{ dir, name });
            try itr.resolved.appendBounded(
                .{ .parsed = .{ .glob_path = .{ .str = str, .continues = false } } },
            );
        } else {
            try itr.resolved.appendBounded(
                .{ .parsed = .{ .glob = .{ .str = str, .continues = false } } },
            );
            //if (Resolver.glob(str)) |names| {
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

    pub fn clone(source: *const Iterator, a: Allocator) !Iterator {
        var out = source.*;

        out.resolved = .initBuffer(try a.alloc(Arg, source.resolved.items.len));

        for (source.resolved.items) |src| switch (src) {
            .parsed => unreachable, // not implemented
            .resolved => |rs| try out.resolved.appendBounded(try rs.dupe(a)),
        };

        return out;
    }
};

pub const Resolver = struct {
    pub fn iterate(a: Allocator, tokens: []Token) !Iterator {
        var start: usize = 0;
        while (tokens[start].kind == .ws) : (start += 1) {}
        if (tokens[start..].len == 0) return error.Empty;
        return .{
            .resolved = try .initCapacity(a, 300),
            .tokens = tokens[start..],
        };
    }

    fn alias(str: []const u8) ![]const u8 {
        return (Alias.find(str) orelse return error.Empty).value;
    }

    pub fn word(t: Token) !Arg {
        if (findScalar(u8, t.str, '\\')) |_| {
            return .{ .parsed = .{ .fmt_str = .{ .str = t.str } } };
        }

        if (t.str[0] == '~' or findScalar(u8, t.str, '/') != null) {
            return .{ .parsed = .{ .path = .{ .str = t.str } } };
        }

        return .{ .parsed = .{ .word = .{ .str = t.str } } };
    }

    /// Caller owns memory for both list of names, and each name
    fn globAt(a: Allocator, d: []const u8, str: []const u8) ![][]u8 {
        var dir = if (d[0] == '/')
            try std.fs.openDirAbsolute(d, .{ .iterate = true })
        else
            try std.fs.cwd().openDir(d, .{ .iterate = true });
        defer dir.close();
        return Fs.globAt(a, dir, str) catch @panic("this error not implemented");
    }

    /// Caller owns memory for both list of names, and each name
    fn glob(str: []const u8, a: Allocator, io: Io) [][]u8 {
        return if (eql(u8, str, ".*"))
            Fs.globCwd(str, .include_dot, a, io) catch @panic("this error not implemented")
        else
            Fs.globCwd(str, .default, a, io) catch @panic("this error not implemented");
    }

    fn variable(str: []const u8, a: Allocator) !Arg {
        switch (str[0]) {
            '$' => {
                const cut = if (str.len > 3 and str[1] == '{') str[2 .. str.len - 1] else str[1..];
                if (Variables.get(cut)) |v| {
                    return .{ .resolved = .{
                        .str = try a.dupe(u8, v),
                        .construct = .dollar,
                    } };
                } else {
                    return .{ .resolved = .{ .str = &.{}, .construct = .dollar } };
                }
            },
            else => return .{ .resolved = .{
                .str = try a.dupe(u8, str),
                .construct = .dollar,
            } },
        }
    }

    fn path(str: []const u8, a: Allocator, _: Io) !Arg {
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

    fn subCommand(h: *Hsh, a: Allocator, tkn: Token) !Token {
        var local = tkn;
        const cmd = tkn.str[2 .. tkn.str.len - 1];
        std.debug.assert(tkn.str[0] == '$');
        std.debug.assert(tkn.str[1] == '(');

        var itr = TokenIterator{ .raw = cmd };
        const argv_t = try itr.toSlice(a);
        defer a.free(argv_t);
        var list = ArrayList([]const u8){};
        for (argv_t) |t| {
            try list.append(a, t.str);
        }
        const argv = try list.toOwnedSlice(a);
        defer a.free(argv);
        local.parsed = true;

        const out = exec.child(h, argv, a) catch {
            local.resolved = try a.dupe(u8, local.str);
            return local;
        };

        local.resolved = try std.mem.join(a, "\n", out.stdout);
        for (out.stdout) |line| a.free(line);
        a.free(out.stdout);
        return local;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualDeep = std.testing.expectEqualDeep;

test "iterator nows" {
    var a = std.testing.allocator;
    var t: Tokenizer = Tokenizer{};
    defer t.raze();

    t.consumeSlice("\"this is some text\" more text");
    var itr = t.iterator();
    const ts = try itr.toSlice(a);
    defer a.free(ts);
    var ptr = try Resolver.iterate(a, ts);
    try ptr.resolveAll(a, undefined);
    defer ptr.raze(a);
    var i: usize = 0;
    while (ptr.next()) |t_| {
        log.debug("{}\n", .{t_});
        i += 1;
    }
    try expectEqual(3, i);
}

test "breaking" {
    var a = std.testing.allocator;
    var t = Tokenizer{};
    defer t.raze();

    t.consumeSlice("alias la='ls -la'");
    var titr = t.iterator();
    const tokens = try titr.toSlice(a);
    //try expectEqual(tokens.len, 4);

    try expectEqualStrings("alias", tokens[0].str);
    try expectEqualStrings("la=", tokens[2].str);
    try expectEqualStrings("'ls -la'", tokens[3].str);

    var itr = try Resolver.iterate(a, tokens);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    var count: usize = 0;
    while (itr.next()) |_| {
        count += 1;
    }
    try expectEqual(count, 2);
    itr.restart();
    try expectEqualStrings("alias", itr.next().?.resolved.str);
    try expectEqualStrings("la=ls -la", itr.next().?.resolved.str);

    a.free(tokens);
}

test "iterator alias is builtin" {
    const a = std.testing.allocator;

    var ts = [_]Token{
        .make("alias", .word),
    };

    var itr = try Resolver.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    try expectEqualStrings("alias", itr.first().resolved.str);
    try expectEqual(null, itr.next());
}

test "iterator aliased" {
    const a = std.testing.allocator;
    Alias.init();
    defer Alias.raze(a);
    Alias.testingAdd("la", "ls -la", a);

    var ts = [_]Token{
        .make("la", .word),
        .make(" ", .ws),
        .make("src", .word),
    };

    var itr = try Resolver.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    try expect(eql(u8, itr.first().resolved.str, "ls"));
    try expect(eql(u8, itr.next().?.resolved.str, "-la"));
    try expect(eql(u8, itr.next().?.resolved.str, "src"));
    try expect(itr.next() == null);
}

test "iterator aliased self" {
    const a = std.testing.allocator;

    Alias.init();
    defer Alias.raze(a);
    Alias.testingAdd("la", "ls -la", a);

    var ts = [_]Token{
        .make("la", .word),
        .make(" ", .ws),
        .make("src", .word),
    };

    var itr = try Resolver.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    try expectEqualStrings("ls", itr.first().resolved.str);
    try expectEqualStrings("-la", itr.next().?.resolved.str);
    try expectEqualStrings("src", itr.next().?.resolved.str);
    try expectEqual(null, itr.next());
}

test "iterator aliased recurse" {
    const a = std.testing.allocator;
    Alias.init();
    defer Alias.raze(a);
    Alias.testingAdd("la", "ls -la", a);
    Alias.testingAdd("ls", "ls --color=auto", a);

    var ts = [_]Token{
        .make("la", .word),
        .make(" ", .ws),
        .make("src", .word),
    };

    var itr = try Resolver.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    const first = itr.first().resolved.str;
    try expectEqualStrings("ls", first);
    try expectEqualStrings("--color=auto", itr.next().?.resolved.str);
    try expectEqualStrings("-la", itr.next().?.resolved.str);
    try expectEqualStrings("src", itr.next().?.resolved.str);
    try expectEqual(null, itr.next());
}

test "parse vars" {
    const a = std.testing.allocator;

    var ts = [5]Token{
        try .any("echo"),
        try .any(" "),
        try .any("$string"),
        try .any(" "),
        try .any("blerg"),
    };

    var itr = try Resolver.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    const first = itr.first().resolved.str;
    try expectEqualStrings("echo", first);
    try expectEqualStrings("", itr.next().?.resolved.str);
    try expectEqualStrings("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse vars existing" {
    const a = std.testing.allocator;
    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("string", "correct", a);
    try expectEqualStrings("correct", Variables.get("string").?);

    var ts: [3]Token = .{
        try Token.any("echo"),
        try Token.any("$string"),
        try Token.any("blerg"),
    };

    var itr = try Resolver.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    try expectEqualStrings("echocorrectblerg", itr.first().resolved.str);
    try expectEqual(null, itr.next());
}

test "parse vars existing with white space" {
    const a = std.testing.allocator;
    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("string", "correct", a);
    try expectEqualStrings("correct", Variables.get("string").?);

    var ts = [5]Token{
        try .any("echo"),
        try .any(" "),
        try .any("$string"),
        try .any(" "),
        try .any("blerg"),
    };
    try expectEqual(Token{ .str = "$string", .kind = .vari }, ts[2]);

    var itr = try Resolver.iterate(a, &ts);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    const first = itr.first().resolved.str;
    try expectEqualStrings("echo", first);
    var tst = itr.next().?;
    try expectEqualStrings("correct", tst.resolved.str);
    try expectEqualStrings("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse vars existing braces" {
    var a = std.testing.allocator;
    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("string", "value", a);
    try expectEqualStrings("value", Variables.get("string").?);

    var ti = TokenIterator{ .raw = "echo ${string}extra blerg" };
    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    const first = itr.first().resolved.str;
    try expectEqualStrings("echo", first);
    try expectEqualStrings("valueextra", itr.next().?.resolved.str);
    try expectEqualStrings("blerg", itr.next().?.resolved.str);
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

    try expectEqualStrings("value", Variables.get("string").?);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    const first = itr.first().resolved.str;
    try expectEqualStrings("echo", first);
    try expectEqualStrings("extravalue", itr.next().?.resolved.str);
    try expectEqualStrings("blerg", itr.next().?.resolved.str);
    try expectEqual(null, itr.next());
}

test "parse vars existing braces inline both" {
    var a = std.testing.allocator;
    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("string", "value", a);

    try expectEqualStrings("value", Variables.get("string").?);

    var ti = TokenIterator{ .raw = "echo extra${string}thingy blerg" };
    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    var i: usize = 0;
    while (itr.next()) |_| {
        //std.debug.print("{}\n", .{t});
        i += 1;
    }
    try expectEqual(i, 3);
    const first = itr.first().resolved.str;
    try expectEqualStrings("echo", first);

    try expectEqualStrings("extravaluethingy", itr.next().?.resolved.str);
    try expectEqualStrings("blerg", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse dollar dollar bills y'all" {
    const a = std.testing.allocator;

    var tkns = [_]Token{
        .make("echo", .word),
        .make(" ", .ws),
        .make("$!", .vari),
        .make(" ", .ws),
        .make("other", .word),
    };

    var itr = try Resolver.iterate(a, &tkns);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    // $! not supported yet
    //try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    //try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    //try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    //try std.testing.expect(itr.next() == null);
    //itr.raze(a);

    itr.raze(a);
    tkns = [_]Token{
        .make("echo", .word),
        .make(" ", .ws),
        try .quoteSingle("'$!'"),
        .make(" ", .ws),
        .make("other", .word),
    };

    itr = try Resolver.iterate(a, &tkns);
    try itr.resolveAll(a, undefined);
    // $! not supported yet
    //try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    //try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") != null);
    //try std.testing.expect(std.mem.indexOf(u8, itr.next().?.resolved.str, "!") == null);
    //try std.testing.expect(itr.next() == null);

    itr.raze(a);
    tkns = [_]Token{
        .make("echo", .word),
        .make(" ", .ws),
        try .quoteDouble("\"$!\""),
        .make(" ", .ws),
        .make("other", .word),
    };

    itr = try Resolver.iterate(a, &tkns);
    try itr.resolveAll(a, undefined);
    try expectEqualStrings("echo", itr.next().?.resolved.str);
    try expectEqualStrings("$!", itr.next().?.resolved.str);
    try expectEqualStrings("other", itr.next().?.resolved.str);
    try expectEqual(null, itr.next());
}

test "parse path" {
    var a = std.testing.allocator;

    var ti = TokenIterator{ .raw = "ls ~" };
    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    // Home is not set up, so don't resolve
    const first = itr.first().resolved.str;
    try expectEqualStrings("ls", first);
    try expectEqual(.path, itr.peek().?.resolved.construct);
    try expectEqualStrings("~", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse path ~" {
    var a = std.testing.allocator;
    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    var ti = TokenIterator{ .raw = "ls ~" };
    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    const first = itr.first().resolved.str;
    try expectEqualStrings("ls", first);
    try expectEqual(.path, itr.peek().?.resolved.construct);
    try expectEqualStrings("/home/user", itr.next().?.resolved.str);
    try expect(itr.next() == null);
}

test "parse path ~/" {
    var a = std.testing.allocator;
    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    var ti = TokenIterator{ .raw = "ls ~/" };
    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    const first = itr.first().resolved.str;
    try expectEqualStrings("ls", first);

    try expectEqual(.path, itr.peek().?.resolved.construct);
    try expectEqualStrings("/home/user/", itr.next().?.resolved.str);
    try expectEqual(null, itr.next());
}

test "parse path ~/place" {
    var a = std.testing.allocator;

    var ti = TokenIterator{ .raw = "ls ~/place" };

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    const first = itr.first().resolved.str;
    try expectEqualStrings("ls", first);

    try expectEqual(.path, itr.peek().?.resolved.construct);
    try expectEqualStrings("/home/user/place", itr.next().?.resolved.str);
    try expectEqual(null, itr.next());
}

test "parse path /~/otherplace" {
    var a = std.testing.allocator;
    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", "/home/user", a);

    var ti = TokenIterator{ .raw = "ls /~/otherplace" };
    const slice = try ti.toSlice(a);
    defer a.free(slice);
    try std.testing.expectEqual(3, slice.len);

    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    try expectEqualStrings("ls", itr.first().resolved.str);

    try expectEqual(.path, itr.peek().?.resolved.construct);
    try expectEqualStrings("/~/otherplace", itr.next().?.resolved.str);
    try expectEqual(null, itr.next());
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
    const olddir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer std.process.setCurrentDir(io, olddir) catch @panic("this test crashed the file system :/ sorry!");
    try std.process.setCurrentDir(io, tmpCwd.dir);

    var names: ArrayList([]u8) = .{};
    defer names.deinit(a);
    while (try di.next(io)) |each| {
        // default glob should exclude dots
        if (each.name[0] == '.') continue;
        try names.append(a, try a.dupe(u8, each.name));
    }
    try expectEqual(5, names.items.len);

    var ti = TokenIterator{ .raw = "echo *" };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, io);
    defer itr.raze(a);

    try expectEqualStrings("echo", itr.first().resolved.str);
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (eql(u8, name, next.resolved.str)) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else {
            std.debug.print("unmatched path {s}\n", .{next.resolved.str});
            for (names.items) |n| std.debug.print("unmatched name {s}\n", .{n});
            return error.TestingUnmatchedName;
        }
    }
    try expectEqual(0, names.items.len);
    try expectEqual(null, itr.next());
}

test "glob .*" {
    var a = std.testing.allocator;
    const io = std.testing.io;

    var tmpCwd = std.testing.tmpDir(.{ .iterate = true });
    defer tmpCwd.cleanup();
    _ = try tmpCwd.dir.createFile(io, "blerg", .{});
    _ = try tmpCwd.dir.createFile(io, ".blerg", .{});
    _ = try tmpCwd.dir.createFile(io, "no_wai", .{});
    _ = try tmpCwd.dir.createFile(io, "ya-wai", .{});
    var di = tmpCwd.dir.iterate();
    const olddir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer std.process.setCurrentDir(io, olddir) catch @panic("this test crashed the file system :/ sorry!");
    try std.process.setCurrentDir(io, tmpCwd.dir);

    var names: ArrayList([]u8) = .{};
    while (try di.next(io)) |each| try names.append(a, try a.dupe(u8, each.name));
    try expectEqual(4, names.items.len);
    defer names.deinit(a);

    var ti = TokenIterator{ .raw = "echo .* *" };

    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, io);
    defer itr.raze(a);

    try std.testing.expectEqualStrings("echo", itr.first().resolved.str);
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, next.resolved.str)) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else {
            std.debug.print("unmatched path '{s}'\n", .{next.resolved.str});
            for (names.items) |n| std.debug.print("unmatched name '{s}'\n", .{n});
            return error.TestingUnmatchedName;
        }
    }
    try expectEqual(0, names.items.len);
    try expectEqual(null, itr.next());
}

test "glob ~/*" {
    if (true) return error.SkipZigTest;
    var a = std.testing.allocator;
    const io = std.testing.io;

    var tmpCwd = std.testing.tmpDir(.{ .iterate = true });
    defer tmpCwd.cleanup();
    const baseCwd = try tmpCwd.dir.realPathFileAlloc(io, ".", a);
    defer a.free(baseCwd);

    Variables.init(a);
    defer Variables.raze(a);
    try Variables.put("HOME", baseCwd, a);

    _ = try tmpCwd.dir.createFile(io, "blerg", .{});

    var di = tmpCwd.dir.iterate();
    var names: ArrayList([]u8) = .{};
    defer names.deinit(a);

    while (try di.next(io)) |each| {
        if (each.name[0] == '.') continue;
        try names.append(a, try a.dupe(u8, each.name));
    }
    errdefer for (names.items) |each| a.free(each);

    var ti = TokenIterator{ .raw = "echo ~/* " };
    const slice = try ti.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);

    try std.testing.expectEqualStrings("echo", itr.first().resolved.str);
    found: while (itr.next()) |next| {
        if (names.items.len == 0) return error.TestingSizeMismatch;
        for (names.items, 0..) |name, i| {
            if (std.mem.endsWith(u8, next.resolved.str, name)) {
                a.free(names.swapRemove(i));
                continue :found;
            }
        } else {
            std.debug.print("unmatched path '{s}'\n", .{next.resolved.str});
            for (names.items) |n| std.debug.print("unmatched name '{s}'\n", .{n});
            return error.TestingUnmatchedName;
        }
    }
    try expectEqual(0, names.items.len);
    try expectEqual(null, itr.next());
}

test "escapes" {
    var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "one\\\\ two" };
    var first = t.first();
    try std.testing.expectEqualStrings("one", first.str);

    const slice = try t.toSlice(a);
    defer a.free(slice);
    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    try expectEqualStrings("one\\", itr.next().?.resolved.str);
}

test "escapes 2" {
    var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "--inline=escaped\\ string" };

    var slice = try t.toSlice(a);
    defer a.free(slice);

    try expectEqualDeep(Token{ .str = "--inline=escaped", .kind = .word }, slice[0]);
    try expectEqualDeep(Token{ .str = "\\ ", .kind = .{ .escp = ' ' } }, slice[1]);
    try expectEqualDeep(Token{ .str = "string", .kind = .word }, slice[2]);

    var itr = try Resolver.iterate(a, slice);
    try itr.resolveAll(a, undefined);
    defer itr.raze(a);
    try expectEqualStrings("--inline=escaped string", itr.next().?.resolved.str);
}

test "sub process" {
    //var a = std.testing.allocator;

    var t = TokenIterator{ .raw = "which $(echo 'ls')" };
    var first = t.first();
    try expectEqualStrings("which", first.str);
    try expectEqualStrings(" ", t.next().?.str);

    try expectEqualStrings("$(echo 'ls')", t.next().?.str);

    // TODO build a better test harness for this
    // var p = try Resolver.single(&a, @constCast(next));
    // try std.testing.expectEqualStrings("ls", p.str);
    // a.free(p.resolved.?);
}

test "naughty strings parsed" {
    var a = std.testing.allocator;
    const while_str = "thingy (b.argv.next()) |_| {}";

    var itr = TokenIterator{ .raw = while_str };

    const slice = try itr.toSlice(a);
    defer a.free(slice);

    var pitr = try Resolver.iterate(a, slice);
    try pitr.resolveAll(a, undefined);
    defer pitr.raze(a);

    //std.debug.print("debug {}\n", .{pitr.next().?});
    //std.debug.print("debug {}\n", .{pitr.next().?});
    //std.debug.print("debug {}\n", .{pitr.next().?});
    //std.debug.print("debug {}\n", .{pitr.next().?});
    //std.debug.print("debug {}\n", .{pitr.next().?});
    //pitr.restart();

    try expectEqualStrings("thingy", pitr.next().?.resolved.str);
    try expectEqualStrings("(b.argv.next())", pitr.next().?.resolved.str);
    try expectEqual(.op_mode, pitr.next().?.resolved.construct);
    try expectEqualStrings("_", pitr.next().?.resolved.str);
    try expectEqual(.op_mode, pitr.next().?.resolved.construct);
    try expectEqualStrings("{}", pitr.next().?.resolved.str);
}

test "comment" {
    var a = std.testing.allocator;
    var tkn_itr = TokenIterator{ .raw = "# comment" };
    const slice = try tkn_itr.toSlice(a);
    defer a.free(slice);
    try expectEqualStrings("# comment", slice[0].str);
    try expectEqual(slice[0].kind, .comment);

    var pitr = try Resolver.iterate(a, slice);
    try pitr.resolveAll(a, undefined);
    defer pitr.raze(a);
    try expectEqual(null, pitr.next());
}

test "comment 2" {
    var a = std.testing.allocator;
    var tkn_itr = Token.Iterator{ .raw = " echo #comment\ncd home" };
    try expectEqualStrings(" ", tkn_itr.next().?.str);
    try expectEqualStrings("echo", tkn_itr.next().?.str);
    try expectEqualStrings(" ", tkn_itr.next().?.str);
    try expectEqualStrings("#comment", tkn_itr.next().?.str);
    try expectEqualStrings("\n", tkn_itr.next().?.str);
    try expectEqualStrings("cd", tkn_itr.next().?.str);
    try expectEqualStrings(" ", tkn_itr.next().?.str);
    try expectEqualStrings("home", tkn_itr.next().?.str);
    tkn_itr.restart();
    const slice = try tkn_itr.toSlice(a);
    defer a.free(slice);

    var pitr = try Resolver.iterate(a, slice);
    try pitr.resolveAll(a, undefined);
    defer pitr.raze(a);
    try expectEqualStrings("echo", pitr.next().?.resolved.str);
    try expectEqualStrings("cd", pitr.next().?.resolved.str);
    try expectEqualStrings("home", pitr.next().?.resolved.str);
    try expect(null == pitr.next());
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
const concat = std.mem.concat;
const eql = std.mem.eql;
