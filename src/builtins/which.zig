const std = @import("std");
const bi = @import("../builtins.zig");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const Exec = @import("../exec.zig");

// I know, but I'm not writing the api right now :/
var path: [2048]u8 = undefined;

fn executable(str: []const u8) ?[]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(&path);
    var a = fba.allocator();
    return Exec.makeAbsExecutable(a, str) catch return null;
}

/// TODO implement real version
pub fn which(_: *HSH, itr: *ParsedIterator) bi.Err!u8 {
    defer itr.close();
    const w = itr.first().cannon();
    std.debug.assert(std.mem.eql(u8, "which", w));
    var cannon = (itr.next() orelse return 2).cannon();
    if (bi.Aliases.find(cannon)) |a| {
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
