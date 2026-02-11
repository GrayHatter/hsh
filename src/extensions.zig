pub const git = @import("extensions/git.zig");

pub fn dirChange(new: Fs.Named.Dir) void {
    _ = new; // not implemented
}

const Fs = @import("Fs.zig");
