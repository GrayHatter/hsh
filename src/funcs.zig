const Funcs = @This();

var funcs: std.ArrayList(Funcs) = .{};

pub fn init(_: std.mem.Allocator) void {}

fn save(_: *hsh.HSH, _: *std.Io.Writer) ?[][]const u8 {
    return null;
}

pub fn exists(str: []const u8) bool {
    return str.len >= 1 and false; // No functions actually exist yet
}

const std = @import("std");
const hsh = @import("hsh.zig");
