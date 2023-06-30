usingnamespace std.fs;
const std = @import("std");
const mem = @import("mem.zig");
const Allocator = mem.Allocator;
const log = @import("log");

pub const fs = @This();
const Names = struct {
    cwd: []u8,
    cwd_short: []u8,
    home: ?[]const u8,
    path: ?[]const u8,
    paths: std.ArrayList([]const u8),

    /// TODO still Leaks
    fn update(self: *Names, a: mem.Allocator) !void {
        self.cwd = try std.fs.cwd().realpathAlloc(a, ".");
        self.cwd_short = self.cwd;
        if (self.home) |home| {
            if (std.mem.startsWith(u8, self.cwd, home)) {
                self.cwd_short = try a.dupe(u8, self.cwd[home.len - 1 ..]);
                self.cwd_short[0] = '~';
            }
        }
    }

    fn raze(self: *Names, a: mem.Allocator) void {
        a.free(self.cwd);
        if (self.cwd.ptr != self.cwd_short.ptr) {
            a.free(self.cwd_short);
        }
    }
};
const Dirs = struct {
    cwd: std.fs.IterableDir,
    conf: ?std.fs.IterableDir = null,

    fn update(self: *Dirs) !void {
        self.cwd = try std.fs.cwd().openIterableDir(".", .{});
    }

    fn raze(self: *Dirs) void {
        self.cwd.close();
    }
};

const Watching = struct {
    in_fd: ?i32,
    wdes: [1]?i32,
};

alloc: mem.Allocator = undefined,
rc: ?std.fs.File = null,
history: ?std.fs.File = null,
dirs: Dirs,
names: Names,
watches: Watching,

pub const Error = error{
    System,
    Missing,
    Perm,
    Other,
};

pub fn init(a: mem.Allocator, env: std.process.EnvMap) !fs {
    var conf = try getConfigs(a, &env);
    var paths = std.ArrayList([]const u8).init(a);
    if (env.get("PATH")) |penv| {
        var mpaths = std.mem.tokenize(u8, penv, ":");
        while (mpaths.next()) |mpath| {
            try paths.append(mpath);
        }
    }

    const inotify_fd = std.os.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK) catch null;

    var self = fs{
        .alloc = a,
        .rc = conf[0],
        .history = conf[1],
        .dirs = .{
            .cwd = try std.fs.cwd().openIterableDir(".", .{}),
        },
        .names = .{
            .cwd = undefined,
            .cwd_short = undefined,
            .home = env.get("HOME"),
            .path = env.get("PATH"),
            .paths = paths,
        },
        .watches = .{
            .in_fd = inotify_fd,
            .wdes = [_]?i32{
                null,
            },
        },
    };

    try self.names.update(self.alloc);
    if (env.get("HOME")) |home| {
        if (a.alloc(u8, home.len + "/.config/hsh/hshrc".len)) |path| {
            @memcpy(path[0..home.len], home);
            @memcpy(path[home.len..], "/.config/hsh/hshrc");
            try self.watchAdd(path, std.os.linux.IN.ALL_EVENTS);
            a.free(path);
        } else |err| return err;
    }
    return self;
}

pub fn watchAdd(self: *fs, name: []const u8, mask: u32) !void {
    if (self.watches.in_fd) |fd| {
        self.watches.wdes[0] = std.os.inotify_add_watch(fd, name, mask) catch null;
    }
}

pub fn watchDel(_: *fs, _: i32) void {}

pub fn watchCheck(self: *fs) ?[]u8 {
    if (self.watches.in_fd) |fd| {
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        const rcount = std.os.read(fd, &buf) catch return null;
        if (rcount > 0) {
            if (rcount < @sizeOf(std.os.linux.inotify_event)) {
                log.err(
                    "inotify read size too small @{} expected {}\n",
                    .{ rcount, @sizeOf(std.os.linux.inotify_event) },
                );
                return null;
            }
            var event = @ptrCast(*const std.os.linux.inotify_event, &buf);
            log.debug("inotify event {any}\n", .{event});
        }
    }
    return null;
}

pub fn raze(self: *fs, a: mem.Allocator) void {
    self.dirs.raze();
    self.names.raze(a);
    if (self.rc) |rc| rc.close();
    // don't close self.history, it's not owned by us
}

pub fn cd(self: *fs, trgt: []const u8) !void {
    // std.debug.print("cd path {s} default {s}\n", .{ &path, hsh.fs.home_name });
    const dir = if (trgt.len == 0 and self.names.home != null)
        try self.dirs.cwd.dir.openDir(self.names.home.?, .{})
    else
        try self.dirs.cwd.dir.openDir(trgt, .{});

    dir.setAsCwd() catch |e| {
        log.err("cwd failed! {}", .{e});
        return e;
    };

    try self.names.update(self.alloc);
    try self.dirs.update();
}

fn fileAt(
    dir: std.fs.Dir,
    name: []const u8,
    comptime create: bool,
    comptime rw: bool,
) ?std.fs.File {
    if (create) {
        return dir.createFile(
            name,
            .{ .read = true, .truncate = false },
        ) catch return null;
    } else {
        return dir.openFile(
            name,
            .{ .mode = if (rw) .read_write else .read_only },
        ) catch return null;
    }
}
pub fn writeFileAt(dir: std.fs.Dir, name: []const u8, comptime create: bool) ?std.fs.File {
    return fileAt(dir, name, create, true);
}

pub fn writeFile(name: []const u8, comptime create: bool) ?std.fs.File {
    return fileAt(std.fs.cwd(), name, create, true);
}

pub fn openFileAt(dir: std.fs.Dir, name: []const u8, comptime create: bool) ?std.fs.File {
    return fileAt(dir, name, create, false);
}

pub fn openFile(name: []const u8, comptime create: bool) ?std.fs.File {
    return fileAt(std.fs.cwd(), name, create, false);
}

pub fn globCwd(a: Allocator, search: []const u8) ![][]u8 {
    var dir = try std.fs.cwd().openIterableDir(".", .{});
    defer dir.close();
    return globAt(a, dir, search);
}

pub fn globAt(a: Allocator, dir: std.fs.IterableDir, search: []const u8) ![][]u8 {
    // TODO multi space glob
    std.debug.assert(std.mem.count(u8, search, "*") == 1);
    var split = std.mem.splitScalar(u8, search, '*');
    const before = split.first();
    const after = split.rest();
    var itr = dir.iterate();

    var names = try a.alloc([]u8, 10);
    errdefer a.free(names);

    // TODO leaks if error in the middle of iteration
    var count: usize = 0;
    while (try itr.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, before)) continue;
        if (!std.mem.endsWith(u8, entry.name, after)) continue;
        names[count] = try a.dupe(u8, entry.name);
        count +|= 1;
        if (count >= names.len) {
            if (!a.resize(names, names.len * 2)) {
                names = try a.realloc(names, names.len * 2);
            } else names.len *|= 2;
        }
    }
    if (!a.resize(names, count)) @panic("unable to downsize names");
    return names[0..count];
}

/// Caller owns returned file
/// TODO remove allocator
pub fn findPath(a: Allocator, env: *const std.process.EnvMap, name: []const u8, comptime create: bool) !std.fs.File {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        var out = try a.dupe(u8, xdg);
        out = try mem.concatPath(a, out, "hsh");
        defer a.free(out);
        if (std.fs.openDirAbsolute(out, .{})) |d| {
            if (writeFileAt(d, name, create)) |file| return file;
        } else |_| {
            std.debug.print("unable to open {s}\n", .{out});
        }
    } else if (env.get("HOME")) |home| {
        var main = try a.dupe(u8, home);
        defer a.free(main);
        if (std.fs.openDirAbsolute(home, .{})) |h| {
            if (h.openDir(".config", .{})) |hc| {
                if (hc.openDir("hsh", .{})) |hch| {
                    if (writeFileAt(hch, name[1..], create)) |file| {
                        return file;
                    }
                } else |e| std.debug.print("unable to open {s} {}\n", .{ "hsh", e });
                //return hc;
            } else |e| std.debug.print("unable to open {s} {}\n", .{ "conf", e });
            if (writeFileAt(h, name, create)) |file| {
                return file;
            }
        } else |e| std.debug.print("unable to open {s} {}\n", .{ "home", e });
    }

    return Error.Missing;
}

/// TODO fix this API, it's awful
fn getConfigs(A: Allocator, env: *const std.process.EnvMap) !struct { ?std.fs.File, ?std.fs.File } {
    var a = A;
    var rc = openRcFile(a, env) catch null;
    var hs = openHistFile(a, env) catch null;

    return .{ rc, hs };
}

fn openRcFile(a: Allocator, env: *const std.process.EnvMap) !?std.fs.File {
    return try findPath(a, env, ".hshrc", false);
}

fn openHistFile(a: Allocator, env: *const std.process.EnvMap) !?std.fs.File {
    return try findPath(a, env, ".hsh_history", false);
}

test "fs" {
    const a = std.testing.allocator;
    var env = try std.process.getEnvMap(a);
    //var p = try findPath(a, &env) orelse unreachable;
    //var buf: [200]u8 = undefined;
    //std.debug.print("path {s}\n", .{try p.realpath(".", &buf)});
    _ = try openRcFile(a, &env);
    defer env.deinit();
}
