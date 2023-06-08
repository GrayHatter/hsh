const std = @import("std");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const bi = @import("../builtins.zig");
const Err = bi.Err;

pub fn init() void {}

pub fn raze() void {}

fn file() !std.fs.File {}

pub fn pipeline(h: *HSH, titr: *ParsedIterator) Err!u8 {
    _ = h;
    _ = titr;
    return 0;
}
