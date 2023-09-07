const std = @import("std");
const log = @import("log");
const Allocator = std.mem.Allocator;
const tokens = @import("token.zig");
const Token = tokens.Token;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

pub const Error = tokenizer.Error;

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
        var lower: [6]u8 = undefined;
        inline for (@typeInfo(Reserved).Enum.fields) |f| {
            const name = std.ascii.lowerString(&lower, f.name);
            if (std.mem.eql(u8, str, name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

const If = struct {};
const For = struct {};
const Case = struct {};

/// Clause and body can only be populated when correctly opened and closed.
const While = struct {
    clause: ?[]const u8,
    body: ?[]const u8,

    fn mkClause(str: []const u8) ![]const u8 {
        var start: usize = 0;
        var offset: usize = start;
        var end: usize = start;
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

    pub fn build(logic: *Token) !While {
        std.debug.assert(logic.kind == .logic);
        const str = logic.str;
        const base = Reserved.fromStr(str[0..5]);
        var clause: ?[]const u8 = null;
        std.debug.assert(base != null and base.? == .While);
        if (mkClause(str[5..])) |c| {
            clause = c;
        } else |err| return err;

        return .{
            .clause = clause,
            .body = null,
        };
    }
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
}
