const std = @import("std");

/// Uninitialized at start, but "usable".
var prng = std.rand.DefaultPrng.init(0);
var rand: std.rand.Random = prng.random();

pub fn init() void {
    const time = std.time.microTimestamp();
    prng.seed(@bitCast(time));
    rand = prng.random();
}

pub fn string(target: []u8) !void {
    for (target) |*t| {
        t.* = rand.int(u8);
        while (t.* < 'a' or t.* > 'z') {
            t.* = rand.int(u8);
        }
    }
}
