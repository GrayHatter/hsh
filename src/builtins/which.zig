// I know, but I'm not writing the api right now :/
var path: [2048]u8 = undefined;

fn executable(str: []const u8, a: Allocator, io: Io) ?[]const u8 {
    return Exec.makeAbsExecutable(str, a, io) catch return null;
}

/// TODO implement real version
pub fn call(_: *Hsh, itr: *ParsedIterator, a: Allocator, io: Io) bi.Err!u8 {
    defer itr.raze(a);
    const w = itr.first().resolved.str;
    std.debug.assert(std.mem.eql(u8, "which", w));
    var cannon = (itr.next() orelse return 2).resolved.str;
    if (bi.Alias.find(cannon)) |al| {
        try bi.print("{s} is aliased to {s}\n", .{ cannon, al.value });
        // TODO whitespace != [space]
        const mi = std.mem.indexOf(u8, al.value, " ");
        if (mi) |i| cannon = al.value[0..i];
    }

    if (bi.exists(cannon)) {
        try bi.print("{s} is a builtin\n", .{cannon});
        return 0;
    }
    if (executable(cannon, a, io)) |exe| {
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
const ParsedIterator = @import("../parse.zig").Iterator;
const Exec = @import("../exec.zig");
