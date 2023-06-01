const std = @import("std");
const HSH = @import("../hsh.zig").HSH;
const context = @import("../context.zig");
const exec = @import("../exec.zig");
const Error = context.Error;
const Draw = context.Draw;
const Lexeme = Draw.Lexeme;
const LexTree = Draw.LexTree;

const Self = @This();

pub fn get(h: *HSH) Error!Lexeme {
    var result = exec.child(
        h,
        &[_:null]?[*:0]const u8{
            "git",
            "status",
            "--porcelain",
        },
    ) catch unreachable;
    var buf = h.alloc.alloc(u8, 0x20) catch return Error.Memory;
    for (result.stdout) |line| {
        h.alloc.free(line);
    }
    const char = std.fmt.bufPrint(buf, "{} changed files", .{result.stdout.len}) catch return Error.Memory;
    return Lexeme{ .char = char };
}
