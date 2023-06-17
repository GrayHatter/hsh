const std = @import("std");
const mem = @import("mem.zig");
const Allocator = mem.Allocator;
usingnamespace std.fs;

pub const fs = @This();

rc: ?std.fs.File = null,
dirs: struct {
    cwd: std.fs.IterableDir,
    conf: ?std.fs.IterableDir = null,
},
names: struct {
    cwd: []u8,
    cwd_short: []u8,
    home: ?[]const u8,
    path: ?[]const u8,
    paths: std.ArrayList([]const u8),
},

pub const Error = error{
    System,
    Missing,
    Perm,
    Other,
};

pub fn init() fs {
    return .{};
}

pub fn raze() void {}

pub fn openFileAt(dir: std.fs.Dir, name: []const u8, comptime create: bool) ?std.fs.File {
    if (create) {
        return dir.createFile(name, .{ .read = true, .truncate = false }) catch return null;
    } else {
        return dir.openFile(name, .{ .mode = .read_write }) catch return null;
    }
}

pub fn openFile(name: []const u8, comptime create: bool) ?std.fs.File {
    return openFileAt(std.fs.cwd(), name, create);
}

/// Caller owns returned file
pub fn findPath(a: Allocator, env: *std.process.EnvMap, name: []const u8, comptime create: bool) !std.fs.File {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        var out = try a.dupe(u8, xdg);
        out = try mem.concatPath(a, out, "hsh");
        defer a.free(out);
        if (std.fs.openDirAbsolute(out, .{})) |d| {
            if (openFileAt(d, name, create)) |file| return file;
        } else |_| {
            std.debug.print("unable to open {s}\n", .{out});
        }
    } else if (env.get("HOME")) |home| {
        var main = try a.dupe(u8, home);
        defer a.free(main);
        if (std.fs.openDirAbsolute(home, .{})) |h| {
            if (h.openDir(".config", .{})) |hc| {
                if (hc.openDir("hsh", .{})) |hch| {
                    if (openFileAt(hch, name[1..], create)) |file| {
                        return file;
                    }
                } else |e| std.debug.print("unable to open {s} {}\n", .{ "hsh", e });
                //return hc;
            } else |e| std.debug.print("unable to open {s} {}\n", .{ "conf", e });
            if (openFileAt(h, name, create)) |file| {
                return file;
            }
        } else |e| std.debug.print("unable to open {s} {}\n", .{ "home", e });
    }

    return Error.Missing;
}
