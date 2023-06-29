const std = @import("std");
const HSH = @import("../hsh.zig").HSH;
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const print = bi.print;
//const log = @import("log");

pub fn echo(_: *HSH, pi: *ParsedIterator) Err!u8 {
    std.debug.assert(std.mem.eql(u8, "echo", pi.first().cannon()));
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
