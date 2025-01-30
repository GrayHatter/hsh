const std = @import("std");
const log = @import("log");
const Allocator = std.mem.Allocator;
const tokens = @import("token.zig");
const Token = tokens.Token;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const exec_ = @import("exec.zig");

const HSH = @import("hsh.zig").HSH;

const Error = tokens.Error || error{
    OutOfMemory,
    ExecFailure,
};

const Self = @This();

pub const Reserved = enum {
    Case,
    Esac,
    If,
    Then,
    Elif,
    Else,
    Fi,
    While,
    Do,
    Done,
    For,
    In,
    Until,

    pub fn fromStr(str: []const u8) ?Reserved {
        std.debug.assert(str.len <= 5);
        var lower: [6]u8 = undefined;
        inline for (@typeInfo(Reserved).@"enum".fields) |f| {
            const name = std.ascii.lowerString(&lower, f.name);
            if (std.mem.eql(u8, str, name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

fn execBody(a: Allocator, h: *HSH, body: []const u8) !void {
    var tzr = Tokenizer.init(a);
    defer tzr.raze();
    for (body) |b| {
        tzr.consumec(b) catch |err| {
            if (err == tokenizer.Error.Exec) {
                try exec_.exec(h, tzr.raw.items);
                tzr.reset();
            }
        };
    }
}

const If = struct {
    alloc: Allocator,
    clause: ?[]const u8,
    body: ?[]const u8,
    elif: ?*Elif,

    const Elif = union(enum) {
        elifs: If,
        elses: []const u8,
    };

    fn mkClause(str: []const u8) ![]const u8 {
        var offset: usize = 0;
        var end: usize = 0;
        while (offset < str.len) {
            const t = try Token.any(str[offset..]);
            offset += t.str.len;
            if (t.kind == .resr and t.kind.resr == .Then) {
                return str[0..end];
            }
            end += t.str.len;
        }
        return Error.InvalidLogic;
    }

    fn mkBody(str: []const u8) ![]const u8 {
        var offset: usize = 0;
        var end: usize = 0;
        while (offset < str.len) {
            const t = try Token.any(str[offset..]);
            offset += t.str.len;
            if (t.kind == .resr) {
                return switch (t.kind.resr) {
                    .Elif, .Else, .Fi => str[0..end],
                    else => Error.InvalidLogic,
                };
            }
            end += t.str.len;
        }
        return Error.InvalidLogic;
    }

    fn mkElif(a: Allocator, str: []const u8) Error!?*Elif {
        if (str.len == 0) return null;
        const elfi = try Token.any(str);
        if (elfi.kind == .resr) {
            switch (elfi.kind.resr) {
                .Fi => return null,
                .Else => {
                    // find else;
                    var offset: usize = 0;
                    if (std.mem.indexOf(u8, str, "else")) |off| {
                        offset = off + 4;
                    } else return Error.InvalidLogic;
                    // find fi;
                    const fi = try Token.any(str[str.len - 2 ..]);
                    if (fi.kind != .resr or fi.kind.resr != .Fi) {
                        return Error.InvalidLogic;
                    }

                    const elif = try a.create(Elif);
                    elif.* = .{ .elses = str[offset .. str.len - 2] };
                    return elif;
                },
                .Elif => {
                    const elif = try a.create(Elif);
                    elif.* = .{ .elifs = try mkIf(a, str) };
                    return elif;
                },
                else => return Error.InvalidLogic,
            }
        } else {
            return Error.InvalidLogic;
        }
    }

    pub fn mkIf(a: Allocator, str: []const u8) !If {
        var offset: usize = 2;
        const word = try Token.word(str);
        switch (word.kind) {
            .resr => |base| {
                switch (base) {
                    .If => offset = 2,
                    .Elif => offset = 4,
                    else => |e| {
                        log.warn("Invalid logic {s} isn't understood here\n", .{@tagName(e)});
                        return Error.InvalidLogic;
                    },
                }
            },
            else => {
                log.warn("Invalid logic {s} isn't understood here\n", .{word.cannon()});
                return Error.InvalidLogic;
            },
        }
        const clause = try mkClause(str[offset..]);
        offset += clause.len;
        const then = try Token.any(str[offset..]);
        offset += then.str.len;
        // ASSERT
        const body = try mkBody(str[offset..]);
        offset += body.len;
        return .{
            .alloc = a,
            .clause = clause,
            .body = body,
            .elif = try mkElif(a, str[offset..]),
        };
    }

    pub fn build(a: Allocator, logic: *const Token) !If {
        std.debug.assert(logic.kind == .logic);
        const str = logic.str;
        return mkIf(a, str);
    }

    fn execClause(self: *If) Error!bool {
        const clause = self.clause orelse return Error.InvalidLogic;
        log.debug("testing logic clasue \n    {s}\n", .{clause});
        const child = exec_.childParsed(self.alloc, clause) catch |err| {
            log.err("Unexpected error ({}) when attempting to run logic\n", .{err});
            return Error.ExecFailure;
        };
        const ec = child.job.exit_code orelse {
            log.err("Logic exec called for an invalid job state.\n", .{});
            return Error.ExecFailure;
        };
        return ec == 0;
    }

    /// If null logic completed successfully, if an If pointer is returned
    /// caller should call exec on the returned pointer.
    pub fn exec(self: *If, h: *HSH) Error!?*If {
        if (self.execClause() catch return null) {
            execBody(self.alloc, h, self.body.?) catch |err| {
                log.err(
                    "Unexpected error ({}) when attempting to run logic main body\n",
                    .{err},
                );
            };
        } else {
            if (self.elif) |elif| {
                switch (elif.*) {
                    .elses => |elses| {
                        execBody(self.alloc, h, elses) catch |err| {
                            log.err(
                                "Unexpected error ({}) when attempting to run logic else body\n",
                                .{err},
                            );
                        };
                    },
                    .elifs => |*elifs| return elifs,
                }
            }
        }
        return null;
    }

    pub fn raze(self: *If) void {
        if (self.elif) |e| {
            if (e.* == .elifs) {
                e.elifs.raze();
            }
            self.alloc.destroy(e);
        }
    }
};

const For = struct {};
const Case = struct {};

/// Clause and body can only be populated when correctly opened and closed.
const While = struct {
    clause: ?[]const u8,
    body: ?[]const u8,

    fn mkClause(str: []const u8) ![]const u8 {
        var offset: usize = 0;
        var end: usize = 0;
        while (offset < str.len) {
            const t = try Token.any(str[offset..]);
            offset += t.str.len;
            if (t.kind == .resr and t.kind.resr == .Do) {
                return str[0..end];
            }
            end += t.str.len;
        }
        return Error.InvalidLogic;
    }

    fn mkBody(str: []const u8) ![]const u8 {
        var offset: usize = 0;
        var end: usize = 0;
        while (offset < str.len) {
            const t = try Token.any(str[offset..]);
            offset += t.str.len;
            if (t.kind == .resr and t.kind.resr == .Done) {
                return str[0..end];
            }
            end += t.str.len;
        }
        return Error.InvalidLogic;
    }

    pub fn build(logic: *const Token) !While {
        std.debug.assert(logic.kind == .logic);
        const str = logic.str;
        var offset: usize = 5;
        const base = Reserved.fromStr(str[0..offset]);
        std.debug.assert(base != null and base.? == .While);
        const clause: ?[]const u8 = try mkClause(str[offset..]);
        offset += clause.?.len;
        const do = try Token.any(str[offset..]);
        offset += do.str.len;
        // ASSERT
        const body: ?[]const u8 = try mkBody(str[offset..]);

        return .{
            .clause = clause,
            .body = body,
        };
    }

    pub fn exec() void {
        unreachable;
    }

    pub fn raze() void {}
};

pub const Logicizer = struct {
    alloc: Allocator,
    token: Token,
    logic: Logics,
    current: Logics,

    pub const Logics = union(enum) {
        if_: If,
        elif_: *If,
        while_: While,
    };

    pub fn init(a: Allocator, t: Token) !Logicizer {
        if (Reserved.fromStr(t.str[0..2])) |base| {
            std.debug.assert(base == .If);
        }

        const built = try If.build(a, &t);
        return .{
            .alloc = a,
            .token = t,
            .logic = .{ .if_ = built },
            .current = .{ .if_ = built },
        };
    }

    /// This API may not exist soon... feeling brave?
    pub fn exec(self: *Logicizer, h: *HSH) Error!?*Logicizer {
        switch (self.current) {
            .if_ => |*if_| {
                if (if_.exec(h)) |exec_if| {
                    if (exec_if) |ex| {
                        self.current = .{ .elif_ = ex };
                        return self;
                    }
                    return null;
                } else |err| return err;
            },
            .elif_ => |elif_| {
                if (elif_.exec(h)) |exec_if| {
                    if (exec_if) |ex| {
                        self.current = .{ .elif_ = ex };
                        return self;
                    }
                    return null;
                } else |err| return err;
            },
            .while_ => |_| {
                unreachable;
            },
        }
    }

    pub fn raze(self: *Logicizer) void {
        switch (self.logic) {
            .if_ => |*if_| if_.raze(),
            .elif_ => |elif_| elif_.raze(),
            .while_ => |_| {}, //while_.raze(),
        }
    }
};

test "if" {
    const a = std.testing.allocator;
    const if_str =
        \\if true
        \\then
        \\    echo "something"
        \\fi
    ;

    var ifs = try Token.logic(if_str);
    var if_block = try If.build(a, &ifs);
    defer if_block.raze();
    try std.testing.expect(if_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const hope_true = try Token.any(if_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", hope_true.str);
    const ws = try Token.any(if_block.body.?);
    const hope_echo = try Token.any(if_block.body.?[ws.str.len..]);
    try std.testing.expectEqualStrings("echo", hope_echo.str);
    try std.testing.expect(if_block.elif == null);

    const else_str =
        \\if true
        \\then
        \\    echo "something"
        \\else
        \\    echo "nothing"
        \\fi
    ;

    var elses = try Token.logic(else_str);
    var else_block = try If.build(a, &elses);
    defer else_block.raze();
    try std.testing.expect(else_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const else_hope_true = try Token.any(else_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", else_hope_true.str);
    const else_ws = try Token.any(else_block.body.?);
    const else_hope_echo = try Token.any(else_block.body.?[else_ws.str.len..]);
    try std.testing.expectEqualStrings("echo", else_hope_echo.str);
    try std.testing.expect(else_block.elif != null);
    try std.testing.expect(else_block.elif.?.* == .elses);

    const elif_str =
        \\if true
        \\then
        \\    echo "something"
        \\elif something_true; then;
        \\    print "nothing"
        \\fi
    ;

    var elifs = try Token.logic(elif_str);
    var elif_block = try If.build(a, &elifs);
    defer elif_block.raze();
    try std.testing.expect(elif_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const elif_hope_true = try Token.any(elif_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", elif_hope_true.str);
    const elif_ws = try Token.any(elif_block.body.?);
    const elif_hope_echo = try Token.any(elif_block.body.?[elif_ws.str.len..]);
    try std.testing.expectEqualStrings("echo", elif_hope_echo.str);
    try std.testing.expect(elif_block.elif != null);
    try std.testing.expect(elif_block.elif.?.* == .elifs);
    try std.testing.expectEqualStrings(" something_true; ", elif_block.elif.?.*.elifs.clause.?);
    const ws2 = try Token.any(elif_block.elif.?.*.elifs.body.?[1..]);
    const elif_hope_print = try Token.any(elif_block.elif.?.*.elifs.body.?[ws2.str.len + 1 ..]);
    try std.testing.expectEqualStrings("print", elif_hope_print.str);
    try std.testing.expectEqualStrings("print \"nothing\"\n", elif_block.elif.?.*.elifs.body.?[ws2.str.len + 1 ..]);
    try std.testing.expect(elif_block.elif.?.*.elifs.elif == null);

    const elif_else_str =
        \\if true
        \\then
        \\    echo "something"
        \\elif something_true; then;
        \\    print "nothing"
        \\else
        \\    which "undefined"
        \\fi
    ;

    var elif_elses = try Token.logic(elif_else_str);
    var elif_else_block = try If.build(a, &elif_elses);
    defer elif_else_block.raze();
    try std.testing.expect(elif_else_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const elif_else_hope_true = try Token.any(elif_else_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", elif_else_hope_true.str);
    const elif_else_ws = try Token.any(elif_else_block.body.?);
    const elif_else_hope_echo = try Token.any(elif_else_block.body.?[elif_else_ws.str.len..]);
    try std.testing.expectEqualStrings("echo", elif_else_hope_echo.str);
    try std.testing.expect(elif_else_block.elif != null);
    try std.testing.expect(elif_else_block.elif.?.* == .elifs);
    const ee_elif = elif_else_block.elif.?.*;
    try std.testing.expectEqualStrings(" something_true; ", ee_elif.elifs.clause.?);
    // skip the ;
    const ws_len = (try Token.any(ee_elif.elifs.body.?[1..])).str.len + 1;
    try std.testing.expectEqualStrings("print \"nothing\"\n", elif_block.elif.?.*.elifs.body.?[ws_len..]);
    const elif_else_hope_print = try Token.any(ee_elif.elifs.body.?[ws_len..]);
    try std.testing.expectEqualStrings("print", elif_else_hope_print.str);
    try std.testing.expect(elif_block.elif.?.*.elifs.elif == null);
    try std.testing.expect(ee_elif.elifs.elif != null);
    try std.testing.expectEqualStrings("\n    which \"undefined\"\n", ee_elif.elifs.elif.?.elses);
}

test "while" {
    const while_str =
        \\while false;
        \\do
        \\    echo "something crazy"
        \\done
    ;

    var whiles = try Token.logic(while_str);
    var while_block = try While.build(&whiles);
    try std.testing.expect(while_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const hope_false = try Token.any(while_block.clause.?[1..]);
    try std.testing.expectEqualStrings("false", hope_false.str);
    const ws = try Token.any(while_block.body.?);
    const hope_echo = try Token.any(while_block.body.?[ws.str.len..]);
    try std.testing.expectEqualStrings("echo", hope_echo.str);
}
