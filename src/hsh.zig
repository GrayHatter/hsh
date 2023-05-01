const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Drawable = @import("draw.zig").Drawable;

const hshfs = struct {
    cwd: std.fs.Dir,
    cwdi: std.fs.IterableDir,
    cwd_name: []u8 = undefined,
    cwd_short: []u8 = undefined,
    confdir: ?[]const u8 = null,
};

pub const HSH = struct {
    alloc: Allocator,
    env: std.process.EnvMap,
    fs: hshfs,
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
            .fs = try init_fs(a, env),
            .rc = rc,
            .history = history,
        };
    }

    fn init_fs(a: Allocator, env: std.process.EnvMap) !hshfs {
        var cwd = std.fs.cwd();
        var cwdi = try cwd.openIterableDir(".", .{});
        var name = try cwd.realpathAlloc(a, ".");
        const h = env.get("HOME");
        std.debug.print("{s}\n", .{h.?});
        var short = if (h != null and std.mem.startsWith(u8, name, h.?)) n: {
            var tmp = try a.dupe(u8, name[h.?.len - 1 ..]);
            tmp[0] = '~';
            break :n tmp;
        } else name;
        std.debug.print("{s}\n", .{short});

        return hshfs{
            .cwd = cwd,
            .cwdi = cwdi,
            .cwd_name = name,
            .cwd_short = short,
        };
    }

    pub fn raze(hsh: *HSH) void {
        hsh.env.deinit();
        if (hsh.rc) |rrc| rrc.close();
        if (hsh.history) |h| h.close();
    }

    fn raze_fs(hsh: *HSH) void {
        hsh.alloc.free(hsh.fs.cwd_name);
        hsh.alloc.free(hsh.fs.cwd_short);
    }

    pub fn find_confdir(_: HSH) []const u8 {}
    pub fn cd(_: HSH, _: []u8) ![]u8 {}
};
