pub const git = @import("extensions/git.zig");

pub fn execSuccess(txt: void) void {
    _ = txt; // not implemented
}

pub fn dirChange(new: Fs.Named.Dir) void {
    _ = new; // not implemented
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const Fs = @import("Fs.zig");
