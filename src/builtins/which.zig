// I know, but I'm not writing the api right now :/
var path: [2048]u8 = undefined;

fn executable(str: []const u8) ?[]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(&path);
    const a = fba.allocator();
    return Exec.makeAbsExecutable(a, str) catch return null;
}

/// TODO implement real version
pub fn call(_: *Hsh, itr: *ParsedIterator, _: Allocator, _: Io) bi.Err!u8 {
    defer itr.raze();
    const w = itr.first().cannon();
    std.debug.assert(std.mem.eql(u8, "which", w));
    var cannon = (itr.next() orelse return 2).cannon();
    if (bi.Alias.find(cannon)) |a| {
        try bi.print("{s} is aliased to {s}\n", .{ cannon, a.value });
        // TODO whitespace != [space]
        const mi = std.mem.indexOf(u8, a.value, " ");
        if (mi) |i| cannon = a.value[0..i];
    }

    if (bi.exists(cannon)) {
        try bi.print("{s} is a builtin\n", .{cannon});
        return 0;
    }
    if (executable(cannon)) |exe| {
        try bi.print("{s}\n", .{exe});
        return 0;
    }
    if (bi.existsOptional(cannon)) {
        try bi.print("{s} is an optional hsh builtin; available because it doesn't exist in path\n", .{cannon});
        return 0;
    }

    try bi.print("{s} not found\n", .{cannon});
    return 1;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const bi = @import("../builtins.zig");
const Hsh = @import("../hsh.zig");
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const Exec = @import("../exec.zig");
