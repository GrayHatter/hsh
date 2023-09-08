const std = @import("std");
const log = @import("log");
const Allocator = std.mem.Allocator;
const tokens = @import("token.zig");
const Token = tokens.Token;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

const Error = tokenizer.Error || error{OutOfMemory};

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
        inline for (@typeInfo(Reserved).Enum.fields) |f| {
            const name = std.ascii.lowerString(&lower, f.name);
            if (std.mem.eql(u8, str, name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

const If = struct {
    alloc: Allocator,
    clause: ?[]const u8,
    body: ?[]const u8,
    elif: ?*Elif,

    const Elif = union(enum) {
        elif: If,
        elses: []const u8,
    };

    fn mkClause(str: []const u8) ![]const u8 {
        var offset: usize = 0;
        var end: usize = 0;
        while (offset < str.len) {
            const t = try Tokenizer.any(str[offset..]);
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
            const t = try Tokenizer.any(str[offset..]);
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
        var elfi = try Tokenizer.any(str);
        if (elfi.kind == .resr) {
            switch (elfi.kind.resr) {
                .Fi => return null,
                .Else => {
                    var elif = try a.create(Elif);
                    var fi = try Tokenizer.any(str[str.len - 2 ..]);
                    if (fi.kind != .resr or fi.kind.resr != .Fi) {
                        return Error.InvalidLogic;
                    }
                    elif.* = .{ .elses = str[0 .. str.len - 2] };
                    return elif;
                },
                .Elif => {
                    var elif = try a.create(Elif);
                    elif.* = .{ .elif = try mkIf(a, str) };
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
        if (Reserved.fromStr(str[0..2])) |base| {
            std.debug.assert(base == .If);
        } else if (Reserved.fromStr(str[0..4])) |base| {
            offset = 4;
            std.debug.assert(base == .Elif);
        } else unreachable;

        const clause = try mkClause(str[offset..]);
        offset += clause.len;
        const then = try Tokenizer.any(str[offset..]);
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

    pub fn raze(self: *If) void {
        if (self.elif) |e| {
            if (e.* == .elif) {
                e.elif.raze();
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
            const t = try Tokenizer.any(str[offset..]);
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
            const t = try Tokenizer.any(str[offset..]);
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
        const do = try Tokenizer.any(str[offset..]);
        offset += do.str.len;
        // ASSERT
        const body: ?[]const u8 = try mkBody(str[offset..]);

        return .{
            .clause = clause,
            .body = body,
        };
    }

    pub fn raze() void {}
};

pub const Logicizer = struct {
    alloc: Allocator,
    token: Token,

    pub fn init(a: Allocator, t: Token) Logicizer {
        return .{
            .alloc = a,
            .token = t,
        };
    }
};

test "if" {
    var a = std.testing.allocator;
    const if_str =
        \\if true
        \\then
        \\    echo "something"
        \\fi
    ;

    var ifs = try Tokenizer.logic(if_str);
    var if_block = try If.build(a, &ifs);
    defer if_block.raze();
    try std.testing.expect(if_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const hope_true = try Tokenizer.any(if_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", hope_true.str);
    const ws = try Tokenizer.any(if_block.body.?);
    const hope_echo = try Tokenizer.any(if_block.body.?[ws.str.len..]);
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

    var elses = try Tokenizer.logic(else_str);
    var else_block = try If.build(a, &elses);
    defer else_block.raze();
    try std.testing.expect(else_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const else_hope_true = try Tokenizer.any(else_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", else_hope_true.str);
    const else_ws = try Tokenizer.any(else_block.body.?);
    const else_hope_echo = try Tokenizer.any(else_block.body.?[else_ws.str.len..]);
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

    var elifs = try Tokenizer.logic(elif_str);
    var elif_block = try If.build(a, &elifs);
    defer elif_block.raze();
    try std.testing.expect(elif_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const elif_hope_true = try Tokenizer.any(elif_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", elif_hope_true.str);
    const elif_ws = try Tokenizer.any(elif_block.body.?);
    const elif_hope_echo = try Tokenizer.any(elif_block.body.?[elif_ws.str.len..]);
    try std.testing.expectEqualStrings("echo", elif_hope_echo.str);
    try std.testing.expect(elif_block.elif != null);
    try std.testing.expect(elif_block.elif.?.* == .elif);
    try std.testing.expectEqualStrings(" something_true; ", elif_block.elif.?.*.elif.clause.?);
    const ws2 = try Tokenizer.any(elif_block.elif.?.*.elif.body.?[1..]);
    const elif_hope_print = try Tokenizer.any(elif_block.elif.?.*.elif.body.?[ws2.str.len + 1 ..]);
    try std.testing.expectEqualStrings("print", elif_hope_print.str);
    try std.testing.expectEqualStrings("print \"nothing\"\n", elif_block.elif.?.*.elif.body.?[ws2.str.len + 1 ..]);
    try std.testing.expect(elif_block.elif.?.*.elif.elif == null);

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

    var elif_elses = try Tokenizer.logic(elif_else_str);
    var elif_else_block = try If.build(a, &elif_elses);
    defer elif_else_block.raze();
    try std.testing.expect(elif_else_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const elif_else_hope_true = try Tokenizer.any(elif_else_block.clause.?[1..]);
    try std.testing.expectEqualStrings("true", elif_else_hope_true.str);
    const elif_else_ws = try Tokenizer.any(elif_else_block.body.?);
    const elif_else_hope_echo = try Tokenizer.any(elif_else_block.body.?[elif_else_ws.str.len..]);
    try std.testing.expectEqualStrings("echo", elif_else_hope_echo.str);
    try std.testing.expect(elif_else_block.elif != null);
    try std.testing.expect(elif_else_block.elif.?.* == .elif);
    const ee_elif = elif_else_block.elif.?.*;
    try std.testing.expectEqualStrings(" something_true; ", ee_elif.elif.clause.?);
    const ws3 = try Tokenizer.any(ee_elif.elif.body.?[1..]);
    const elif_else_hope_print = try Tokenizer.any(ee_elif.elif.body.?[ws3.str.len + 1 ..]);
    try std.testing.expectEqualStrings("print", elif_else_hope_print.str);
    try std.testing.expectEqualStrings("print \"nothing\"\n", elif_block.elif.?.*.elif.body.?[ws3.str.len + 1 ..]);
    try std.testing.expect(elif_block.elif.?.*.elif.elif == null);
    try std.testing.expect(ee_elif.elif.elif != null);
    try std.testing.expectEqualStrings("   which \"undefined\"\n", ee_elif.elif.elif.?.elses[ws3.str.len + 1 ..]);
}

test "while" {
    const while_str =
        \\while false;
        \\do
        \\    echo "something crazy"
        \\done
    ;

    var whiles = try Tokenizer.logic(while_str);
    var while_block = try While.build(&whiles);
    try std.testing.expect(while_block.clause != null);
    // we just accept the whitespace here, it's not our job to parse it out
    const hope_false = try Tokenizer.any(while_block.clause.?[1..]);
    try std.testing.expectEqualStrings("false", hope_false.str);
    const ws = try Tokenizer.any(while_block.body.?);
    const hope_echo = try Tokenizer.any(while_block.body.?[ws.str.len..]);
    try std.testing.expectEqualStrings("echo", hope_echo.str);
}
