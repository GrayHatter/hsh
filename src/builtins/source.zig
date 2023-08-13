const HSH = @import("../hsh.zig").HSH;
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const print = bi.print;

pub fn source(h: *HSH, titr: *ParsedIterator) Err!u8 {
    _ = h;
    _ = titr;
    print("source not yet implemented\n", .{}) catch return Err.Unknown;
    return 1;
}
