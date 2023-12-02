const std = @import("std");

pub usingnamespace std.fs;
const Allocator = mem.Allocator;

const mem = @import("mem.zig");
const log = @import("log");
const INotify = @import("inotify.zig");
const HSH = @import("hsh.zig").HSH;
const rand = @import("random.zig");
const vars = @import("variables.zig");

pub const fs = @This();

pub const Error = error{
    System,
    Missing,
    Perm,
    NoClobber,
    Other,
};

const Names = struct {
    cwd: []u8,
    cwd_short: []u8,
    home: ?[]const u8,
    path: ?[]const u8,
    paths: std.ArrayList([]const u8),

    /// TODO still Leaks
    fn update(self: *Names, a: mem.Allocator) !void {
        a.free(self.cwd);
        a.free(self.cwd_short);
        self.cwd = try std.fs.cwd().realpathAlloc(a, ".");
        if (self.home) |home| {
            if (std.mem.startsWith(u8, self.cwd, home)) {
                self.cwd_short = try a.dupe(u8, self.cwd[home.len - 1 ..]);
                self.cwd_short[0] = '~';
            } else {
                self.cwd_short = try a.dupe(u8, self.cwd);
            }
        } else {
            self.cwd_short = try a.dupe(u8, self.cwd);
        }
    }

    fn raze(self: *Names, a: mem.Allocator) void {
        a.free(self.cwd);
        if (self.cwd.ptr != self.cwd_short.ptr) {
            a.free(self.cwd_short);
        }
        self.paths.clearAndFree();
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

alloc: mem.Allocator = undefined,
rc: ?std.fs.File = null,
history: ?std.fs.File = null,
dirs: Dirs,
names: Names,
inotify_fd: ?i32,
watches: [1]?INotify,

pub fn init(a: mem.Allocator, env: std.process.EnvMap) !fs {
    var paths = std.ArrayList([]const u8).init(a);
    if (env.get("PATH")) |penv| {
        var mpaths = std.mem.tokenize(u8, penv, ":");
        while (mpaths.next()) |mpath| {
            try paths.append(mpath);
        }
    }

    var self = fs{
        .alloc = a,
        .rc = findCoreFile(a, &env, .rc),
        .dirs = .{
            .cwd = try std.fs.cwd().openIterableDir(".", .{}),
        },
        .names = .{
            .cwd = try a.dupe(u8, "???"),
            .cwd_short = try a.dupe(u8, "???"),
            .home = env.get("HOME"),
            .path = env.get("PATH"),
            .paths = paths,
        },
        .inotify_fd = std.os.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK) catch null,
        .watches = .{null},
    };

    try self.names.update(self.alloc);
    return self;
}

pub fn inotifyInstall(self: *fs, target: []const u8, cb: ?INotify.Callback) !void {
    if (self.inotify_fd) |infd| {
        if (self.alloc.dupe(u8, target)) |path| {
            errdefer self.alloc.free(path);
            // TODO dynamic size
            self.watches[0] = INotify.init(infd, path, cb) catch |e| {
                log.err("unable to setup inotify for {s}\n", .{path});
                return e;
            };
        } else |err| return err;
    }
}

pub fn inotifyInstallRc(self: *fs, cb: ?INotify.Callback) !void {
    if (self.rc) |_| {
        if (self.names.home) |home| {
            // I know... I'm sorry you had to read this too
            const cfile = "/.config/hsh/hshrc";
            const path = try self.alloc.alloc(u8, home.len + cfile.len);
            defer self.alloc.free(path);
            @memcpy(path[0..home.len], home);
            @memcpy(path[home.len..], cfile);
            try self.inotifyInstall(path, cb);
        }
    }
}

/// TODO rename and maybe refactor
pub fn checkINotify(self: *fs, h: *HSH) bool {
    if (self.inotify_fd) |fd| {
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        const rcount = std.os.read(fd, &buf) catch return true;
        if (rcount > 0) {
            if (rcount < @sizeOf(std.os.linux.inotify_event)) {
                log.err(
                    "inotify read size too small @{} expected {}\n",
                    .{ rcount, @sizeOf(std.os.linux.inotify_event) },
                );
                return true;
            }
            var event: *const std.os.linux.inotify_event = @ptrCast(&buf);
            // TODO optimize
            for (&self.watches) |*watch| {
                if (watch.*) |*wd| {
                    if (wd.wdes == event.wd) {
                        wd.event(h, event);
                    }
                }
            }
        }
    }
    return true;
}

pub fn raze(self: *fs, a: mem.Allocator) void {
    self.dirs.raze();
    self.names.raze(a);
    if (self.rc) |rc| rc.close();
    // TODO inotify_fd
    for (&self.watches) |*watch| {
        if (watch.*) |*w| {
            w.raze(self.alloc);
        }
    }
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

/// Caller should close the file when finished
pub fn mktemp(a: std.mem.Allocator, data: ?[]const u8) ![]u8 {
    rand.init();

    var name = try a.dupe(u8, "/tmp/.hsh_txt________");
    try rand.string(name[14..]);

    const file = std.fs.createFileAbsolute(name, .{}) catch {
        return Error.System;
    };
    defer file.close();

    if (data) |d| {
        if (d.len > 0) {
            file.writeAll(d) catch return Error.Other;
            file.sync() catch return Error.Other;
        }
    }

    return name;
}

fn fileAt(
    dir: std.fs.Dir,
    name: []const u8,
    comptime ccreate: bool,
    comptime rw: bool,
    comptime truncate: bool,
) ?std.fs.File {
    if (ccreate) {
        return dir.createFile(
            name,
            .{ .read = true, .truncate = truncate },
        ) catch return null;
    } else {
        return dir.openFile(
            name,
            .{ .mode = if (rw) .read_write else .read_only },
        ) catch return null;
    }
}

pub fn writeFileAt(dir: std.fs.Dir, name: []const u8, comptime ccreate: bool) ?std.fs.File {
    return fileAt(dir, name, ccreate, true, false);
}

pub fn writeFile(name: []const u8, comptime ccreate: bool) ?std.fs.File {
    return fileAt(std.fs.cwd(), name, ccreate, true, false);
}

pub fn openFileAt(dir: std.fs.Dir, name: []const u8, comptime ccreate: bool) ?std.fs.File {
    return fileAt(dir, name, ccreate, false, false);
}

pub fn openFile(name: []const u8, comptime ccreate: bool) ?std.fs.File {
    return fileAt(std.fs.cwd(), name, ccreate, false, false);
}

pub fn create(name: []const u8) ?std.fs.File {
    return fileAt(std.fs.cwd(), name, true, false, false);
}

pub fn reCreate(name: []const u8) ?std.fs.File {
    return fileAt(std.fs.cwd(), name, true, false, true);
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
pub fn findPath(
    a: Allocator,
    env: *const std.process.EnvMap,
    name: []const u8,
    comptime ccreate: bool,
) !std.fs.File {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        var out = try a.dupe(u8, xdg);
        out = try mem.concatPath(a, out, "hsh");
        defer a.free(out);
        if (std.fs.openDirAbsolute(out, .{})) |d| {
            if (writeFileAt(d, name, ccreate)) |file| return file;
        } else |_| {
            log.debug("unable to open {s}\n", .{out});
        }
    } else if (env.get("HOME")) |home| {
        var main = try a.dupe(u8, home);
        defer a.free(main);
        if (std.fs.openDirAbsolute(home, .{})) |h| {
            if (h.openDir(".config", .{})) |hc| {
                if (hc.openDir("hsh", .{})) |hch| {
                    if (writeFileAt(hch, name[1..], ccreate)) |file| {
                        return file;
                    }
                } else |e| log.debug("unable to open {s} {}\n", .{ "hsh", e });
                //return hc;
            } else |e| log.debug("unable to open {s} {}\n", .{ "conf", e });
            if (writeFileAt(h, name, ccreate)) |file| {
                return file;
            }
        } else |e| log.debug("unable to open {s} {}\n", .{ "home", e });
    }

    return Error.Missing;
}

pub fn openFileStdout(name: []const u8, append: bool) !std.fs.File {
    if (append) {
        var file = openFile(name, true) orelse unreachable;
        file.seekFromEnd(0) catch unreachable;
        return file;
    }

    // TODO don't use string here
    if (vars.getKind("noclobber", .internal)) |noclobber| {
        if (std.mem.eql(u8, noclobber.str, "true")) {
            if (std.fs.cwd().openFile(name, .{ .mode = .read_only })) |file| {
                file.close();
                return Error.NoClobber;
            } else |err| {
                switch (err) {
                    std.fs.File.OpenError.FileNotFound => {
                        if (openFile(name, true)) |file| {
                            return file;
                        }
                    },
                    else => return err,
                }
            }
            return Error.NoClobber;
        }
    }

    if (reCreate(name)) |file| {
        return file;
    }
    unreachable;
}

pub const CoreFiles = enum {
    rc,
    history,
};

/// TODO fix this API, it's awful
/// nah... let's make it worse
pub fn findCoreFile(a: Allocator, env: *const std.process.EnvMap, cf: CoreFiles) ?std.fs.File {
    return switch (cf) {
        .rc => openRcFile(a, env) catch null,
        .history => openHistFile(a, env) catch null,
    };
}

fn openRcFile(a: Allocator, env: *const std.process.EnvMap) !?std.fs.File {
    return try findPath(a, env, ".hshrc", false);
}

fn openHistFile(a: Allocator, env: *const std.process.EnvMap) !?std.fs.File {
    const p = findPath(a, env, ".hsh_history", false) catch |e| {
        if (e != Error.Missing) return e;
        return try findPath(a, env, ".hsh_history", true);
    };
    // I've been seeing some strange behavior in history I don't fully
    // understand. This probably won't fix it, but I'm gonna try it anyways
    p.seekFromEnd(0) catch {};
    return p;
}

test "fs" {
    const a = std.testing.allocator;
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    //var p = try findPath(a, &env) orelse unreachable;
    //var buf: [200]u8 = undefined;
    //std.debug.print("path {s}\n", .{try p.realpath(".", &buf)});
    if (openRcFile(a, &env)) |_| {
        // pass
    } else |err| {
        if (err != Error.Missing) return err;
    }
}
