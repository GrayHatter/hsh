const std = @import("std");
const Hsh = @import("../hsh.zig");
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const bi = @import("../builtins.zig");
const print = bi.print;
const Err = bi.Err;

pub fn init() void {}

pub fn raze() void {}

pub fn pipeline(h: *Hsh, titr: *ParsedIterator) Err!u8 {
    _ = h;
    _ = titr;
    try print("pipeline is not yet implemented\n", .{});
    return 0;
}
