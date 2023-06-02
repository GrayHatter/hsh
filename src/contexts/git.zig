const std = @import("std");
const HSH = @import("../hsh.zig").HSH;
const context = @import("../context.zig");
const exec = @import("../exec.zig");
const Error = context.Error;
const Draw = context.Draw;
const Lexeme = Draw.Lexeme;
const LexTree = Draw.LexTree;

const Self = @This();

pub const ctx: context.Ctx = .{
    .name = "git",
    .kind = .git,
    .init = init,
    .fetch = fetch,
    .update = update,
};

var buffer: [0x20]u8 = undefined;
var next: []const u8 = undefined;

fn init() Error!void {}

fn fetch(_: *const HSH) Error!Lexeme {
    return Lexeme{ .char = next };
}

fn update(h: *HSH) Error!void {
    var result = exec.child(
        h,
        &[_:null]?[*:0]const u8{
            "git",
            "status",
            "--porcelain",
        },
    ) catch unreachable;
    for (result.stdout) |line| {
        h.alloc.free(line);
    }
    next = std.fmt.bufPrint(&buffer, "{} changed files", .{result.stdout.len}) catch return Error.Memory;
}
