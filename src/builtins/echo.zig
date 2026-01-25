pub fn call(_: *Hsh, pi: *ParsedIterator, _: std.mem.Allocator, _: std.Io) Err!u8 {
    std.debug.assert(std.mem.eql(u8, "echo", pi.first().cannon()));
    defer pi.raze();
    var newline = true;
    if (pi.next()) |next| {
        if (std.mem.eql(u8, "-n", next.cannon())) {
            newline = false;
        } else {
            try print("{s} ", .{next.cannon()});
        }
    }
    while (pi.next()) |next| {
        try print("{s} ", .{next.cannon()});
    }
    if (newline) try print("\n", .{});
    return 0;
}

const std = @import("std");
const Hsh = @import("../hsh.zig");
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const print = bi.print;
//const log = @import("log");
