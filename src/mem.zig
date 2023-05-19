const std = @import("std");
pub const Allocator = std.mem.Allocator;

pub fn dupePadded(a: Allocator, str: []const u8, w: usize) ![]u8 {
    const width = @max(str.len, w);
    var dupe = try a.alloc(u8, width);
    @memcpy(dupe[0..str.len], str);
    @memset(dupe[str.len..width], ' ');
    return dupe;
}
