const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Drawable = @import("draw.zig").Drawable;

pub const HSH = struct {
    alloc: Allocator,
    env: std.process.EnvMap,
    confdir: ?[]const u8 = null,
    rc: ?std.fs.File = null,
    history: ?std.fs.File = null,
    draw: Drawable = undefined,
    input: i32 = 0,

    pub fn init(a: Allocator) !HSH {
        // I'm pulling all of env out at startup only because that's the first
        // example I found. It's probably sub optimal, but ¯\_(ツ)_/¯. We may
        // decide we care enough to fix this, or not. The internet seems to think
        // it's a mistake to alter the env for a running process.
        var env = try std.process.getEnvMap(a); // TODO err handling
        var home = env.get("HOME");
        var rc: std.fs.File = undefined;
        var history: std.fs.File = undefined;
        if (home) |h| {
            // TODO sanity checks
            const dir = try std.fs.openDirAbsolute(h, .{});
            rc = try dir.createFile(".hshrc", .{ .read = true, .truncate = false });
            history = try dir.createFile(".hsh_history", .{ .read = true, .truncate = false });
            history.seekFromEnd(0) catch unreachable;
        }
        return HSH{
            .alloc = a,
            .env = env,
            .rc = rc,
            .history = history,
        };
    }

    pub fn raze(hsh: *HSH) void {
        hsh.env.deinit();
        if (hsh.rc) |rrc| rrc.close();
        if (hsh.history) |h| h.close();
    }

    pub fn find_confdir(_: HSH) []const u8 {}
};
