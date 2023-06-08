const std = @import("std");
const mem = @import("mem.zig");
const Allocator = mem.Allocator;
usingnamespace std.fs;

pub const Error = error{
    System,
    Missing,
    Perm,
    Other,
};

fn openishFile(dir: std.fs.Dir, name: []const u8, comptime create: bool) ?std.fs.File {
    if (create) {
        return dir.createFile(name, .{ .read = true, .truncate = false }) catch return null;
    } else {
        return dir.openFile(name, .{ .mode = .read_write }) catch return null;
    }
}

/// Caller owns returned file
pub fn findPath(a: Allocator, env: *std.process.EnvMap, name: []const u8, comptime create: bool) !std.fs.File {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        var out = try a.dupe(u8, xdg);
        out = try mem.concatPath(a, out, "hsh");
        defer a.free(out);
        if (std.fs.openDirAbsolute(out, .{})) |d| {
            if (openishFile(d, name, create)) |file| return file;
        } else |_| {
            std.debug.print("unable to open {s}\n", .{out});
        }
    } else if (env.get("HOME")) |home| {
        var main = try a.dupe(u8, home);
        defer a.free(main);
        if (std.fs.openDirAbsolute(home, .{})) |h| {
            if (h.openDir(".config", .{})) |hc| {
                if (hc.openDir("hsh", .{})) |hch| {
                    if (openishFile(hch, name[1..], create)) |file| {
                        return file;
                    }
                } else |e| std.debug.print("unable to open {s} {}\n", .{ "hsh", e });
                //return hc;
            } else |e| std.debug.print("unable to open {s} {}\n", .{ "conf", e });
            if (openishFile(h, name, create)) |file| {
                return file;
            }
        } else |e| std.debug.print("unable to open {s} {}\n", .{ "home", e });
    }

    return Error.Missing;
}
