const Git = @This();

pub const ctx: context.Ctx = .{
    .name = "git",
    .kind = .git,
    .init = init,
    .raze = raze,
    .fetch = fetch,
    .update = update,
};

var buffer: [0x20]u8 = undefined;
var next: []const u8 = undefined;

fn init() error{InitFailed}!void {}

fn fetch(_: *const Hsh) Lexeme {
    return .str(next);
}

fn update(h: *Hsh, a: std.mem.Allocator, io: Io) error{ OutOfMemory, UpdateFailed }!void {
    const result = exec.childZ(&[_:null]?[*:0]const u8{
        "git",
        "status",
        "--porcelain",
    }, h, a, io) catch unreachable;
    defer a.free(result.stdout);

    next = std.fmt.bufPrint(&buffer, "{} changed files", .{result.stdout.len}) catch unreachable;
}

fn raze(_: std.mem.Allocator) void {}

const std = @import("std");
const Io = std.Io;
const Hsh = @import("../hsh.zig");
const context = @import("../context.zig");
const exec = @import("../exec.zig");
const Lexeme = @import("../draw.zig").Lexeme;
