const std = @import("std");
const hsh = @import("hsh.zig");
const State = @import("state.zig");

pub const Funcs = @This();

var funcs: std.ArrayList(Funcs) = undefined;

pub const _funcs = &funcs;

pub fn init(a: std.mem.Allocator) void {
    funcs = std.ArrayList(Funcs).init(a);
    hsh.addState(State{
        .name = "exports",
        .ctx = &funcs,
        .api = &.{ .save = save },
    }) catch unreachable;
}

fn save(_: *hsh.HSH, _: *anyopaque) ?[][]const u8 {
    return null;
}


