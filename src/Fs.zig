cwd: Named.Dir,
home: Named.Dir,
paths: ArrayList(Named),
config: ?Named.Dir = null,
rc: ?Named.File = null,
history: ?Named.File = null,
inotify_fd: ?i32,
watches: ArrayList(INotify),

const Fs = @This();

pub const Named = union(enum) {
    file: Named.File,
    dir: Named.Dir,
    closed_file: Closed,
    closed_dir: Closed,

    pub const Options = struct {
        iterate: bool = false,
    };

    pub const File = struct {
        name: []const u8,
        file: Fs.File,

        pub fn close(d: Named.File, io: Io) Named.Closed {
            d.file.close(io);
            return .{ .name = d.name };
        }

        pub fn raze(n: *Named.File, a: Allocator, io: Io) void {
            n.file.close(io);
            a.free(n.name);
        }
    };

    pub const Dir = struct {
        name: []const u8,
        dir: Fs.Dir,

        pub fn close(d: Named.Dir, io: Io) Named.Closed {
            d.dir.close(io);
            return .{ .name = d.name };
        }

        pub fn raze(n: *Named.Dir, a: Allocator, io: Io) void {
            n.dir.close(io);
            a.free(n.name);
        }
    };

    pub const Closed = struct {
        name: []const u8,

        pub fn openFile(c: *Closed, io: Io) !void {
            const n: *Named = @fieldParentPtr("closed_dir", c);
            const named: Named = .{ .file = .{
                .name = c.name,
                .file = try Fs.Dir.openFileAbsolute(io, c.name, .{}),
            } };
            n.* = named;
        }

        pub fn openDir(c: *Closed, io: Io) !void {
            return c.openDirItr(io, false);
        }

        pub fn openDirItr(c: *Closed, io: Io, iter: bool) !void {
            const n: *Named = @fieldParentPtr("closed_dir", c);

            const named: Named = .{ .dir = .{
                .name = c.name,
                .dir = try Fs.Dir.openDirAbsolute(io, c.name, .{ .iterate = iter }),
            } };
            n.* = named;
        }

        pub fn raze(n: *Named.Closed, a: Allocator, _: Io) void {
            a.free(n.name);
        }
    };

    pub fn open(n: *Named, io: Io) !void {
        switch (n.*) {
            .closed_file => |*f| try f.openFile(io),
            .closed_dir => |*d| try d.openDir(io),
            .dir => unreachable,
            .file => unreachable,
        }
    }

    fn openExt(n: *Named, io: Io, o: Options) !void {
        switch (n.*) {
            .closed_file => |*f| try f.openFile(io),
            .closed_dir => |*d| try d.openDirItr(io, o.iterate),
            .dir => unreachable,
            .file => unreachable,
        }
    }

    pub fn close(n: *Named, io: Io) void {
        switch (n.*) {
            .closed_file => {},
            .closed_dir => {},
            .dir => |*d| _ = d.close(io),
            .file => |*f| _ = f.close(io),
        }
    }

    pub fn raze(named: *Named, a: Allocator, io: Io) void {
        switch (named.*) {
            inline else => |*n| n.raze(a, io),
        }
    }
};

pub fn init(env: Environ, a: Allocator, io: Io) !Fs {
    var paths: ArrayList(Named) = .{};
    if (env.getPosix("PATH")) |penv| {
        var mpaths = std.mem.tokenizeAny(u8, penv, ":");
        while (mpaths.next()) |mpath| {
            if (mpath.len == 0) continue;
            try paths.append(a, .{ .closed_dir = .{ .name = mpath } });
        }
    }
    for (paths.items) |*path| {
        path.openExt(io, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => log.warn("Unable to open PATH entry '{s}'\n", .{path.closed_dir.name}),
            else => return err,
        };
    }

    var realpath: [2048]u8 = undefined;
    const len = try Dir.cwd().realPathFile(io, ".", &realpath);
    const cwd: Dir = try Dir.cwd().openDir(io, ".", .{ .iterate = true });
    var fs: Fs = .{
        .cwd = .{ .name = try a.dupe(u8, realpath[0..len]), .dir = cwd },
        .paths = paths,
        .home = if (env.getPosix("HOME")) |home|
            .{ .name = home, .dir = try Dir.openDirAbsolute(io, home, .{}) }
        else
            .{ .name = try a.dupe(u8, realpath[0..len]), .dir = try Dir.openDirAbsolute(io, realpath[0..len], .{}) },
        .inotify_fd = @intCast((system.inotify_init1(system.IN.CLOEXEC | system.IN.NONBLOCK))),
        .watches = .{},
    };

    fs.rc = fs.openRcFile(a, io) catch null;
    fs.history = fs.openHistFile(a, io) catch null;

    return fs;
}

pub var g_fs: ?*const Fs = null;

pub fn inotifyInstall(fs: *Fs, path: []const u8, cb: ?INotify.Callback, a: Allocator) !void {
    if (fs.inotify_fd) |infd| {
        // TODO dynamic size
        try fs.watches.append(a, INotify.init(infd, path, cb) catch |e| {
            log.err("unable to setup inotify for {s}\n", .{path});
            return e;
        });
    }
}

pub fn inotifyInstallRc(fs: *Fs, cb: ?INotify.Callback, a: Allocator) !void {
    if (fs.rc) |_| {
        const path = try allocPrint(a, "{s}/.config/hsh/hshrc", .{fs.home.name});
        errdefer a.free(path);
        try fs.inotifyInstall(path, cb, a);
    }
}

/// TODO rename and maybe refactor
pub fn checkINotify(fs: *Fs, h: *Hsh, a: Allocator, io: Io) bool {
    if (fs.inotify_fd) |fd| {
        var buf: [4096]u8 align(@alignOf(system.inotify_event)) = undefined;
        const rcount = system.read(fd, &buf) catch return true;
        if (rcount > 0) {
            if (rcount < @sizeOf(system.inotify_event)) {
                log.err(
                    "inotify read size too small @{} expected {}\n",
                    .{ rcount, @sizeOf(system.inotify_event) },
                );
                return true;
            }
            const event: *const system.inotify_event = @ptrCast(&buf);
            // TODO optimize
            for (fs.watches.items) |*watch| {
                if (watch.wdes == event.wd) {
                    watch.event(h, event.*, a, io);
                }
            }
        }
    }
    return true;
}

pub fn raze(fs: *Fs, a: Allocator, io: Io) void {
    fs.cwd.raze(a, io);
    if (fs.rc) |*rc| rc.raze(a, io);
    if (fs.history) |*h| h.raze(a, io);
    if (fs.config) |*c| c.raze(a, io);
    // path names are just indexes into the PATH var
    for (fs.paths.items) |*path| path.close(io);
    fs.paths.deinit(a);
    // TODO inotify_fd
    for (fs.watches.items) |*watch| a.free(watch.path);
    fs.watches.deinit(a);
}

pub fn cd(fs: *Fs, trgt: []const u8, a: Allocator, io: Io) !void {
    log.debug("cd path '{s}'\n", .{trgt});
    const old_name: []const u8 = fs.cwd.name;

    const next = if (trgt.len == 0)
        try Dir.openDirAbsolute(io, fs.home.name, .{})
    else
        try fs.cwd.dir.openDir(io, trgt, .{});

    var realpath: [2048]u8 = undefined;
    const len = try next.realPathFile(io, ".", &realpath);
    fs.cwd.name = try a.dupe(u8, realpath[0..len]);
    a.free(old_name);
    fs.cwd.dir.close(io);
    fs.cwd.dir = next;
    if (system.fchdir(fs.cwd.dir.handle) != 0) unreachable;
    intergr.dirChange(fs.cwd);
    log.debug("cd now '{s}'\n", .{fs.cwd.name});
}

pub fn mktemp(data: ?[]const u8, a: Allocator, io: Io) ![]u8 {
    var bytes: [7]u8 = undefined;
    io.random(&bytes);
    for (&bytes) |*b| {
        b.* = std.ascii.letters[b.* % std.ascii.letters.len];
    }

    const name = try a.dupe(u8, "/tmp/.hsh_txt" ++ bytes);

    const file = Dir.createFileAbsolute(io, name, .{}) catch {
        return error.System;
    };
    defer file.close(io);

    if (data) |d| {
        if (d.len > 0) {
            var w = file.writer(io, &.{});
            w.interface.writeAll(d) catch return error.Other;
            file.sync(io) catch return error.Other;
        }
    }

    return name;
}

fn fileFrom(
    dir: Dir,
    name: []const u8,
    io: Io,
    comptime cr: CreateRule,
    comptime mode: File.OpenMode,
    comptime truncate: bool,
) ?File {
    return switch (cr) {
        .create => dir.createFile(io, name, .{ .read = true, .truncate = truncate }) catch null,
        .open => dir.openFile(io, name, .{ .mode = mode }) catch null,
        .any => unreachable,
    };
}

pub const CreateRule = enum {
    create,
    open,
    any,
};

pub fn writableFrom(dir: Dir, name: []const u8, io: Io, comptime cr: CreateRule) ?File {
    return fileFrom(dir, name, io, cr, .read_write, false);
}

pub fn writable(name: []const u8, io: Io, comptime cr: CreateRule) ?File {
    return fileFrom(Dir.cwd(), name, io, cr, .read_write, false);
}

pub fn openFrom(dir: Dir, name: []const u8, io: Io, comptime cr: CreateRule) ?File {
    return fileFrom(dir, name, io, cr, .read_only, false);
}

pub fn open(name: []const u8, io: Io) ?File {
    return fileFrom(Dir.cwd(), name, io, .open, .read_only, false);
}

pub fn create(name: []const u8, io: Io) ?File {
    return fileFrom(Dir.cwd(), name, io, .create, .read_only, false);
}

pub fn reCreate(name: []const u8, io: Io) ?File {
    return fileFrom(Dir.cwd(), name, io, .create, .read_only, true);
}

pub const GlobRule = enum {
    default,
    include_dot,
};

pub const openDirAbsolute = Dir.openDirAbsolute;

pub fn globCwd(search: []const u8, rule: GlobRule, a: Allocator, io: Io) ![][]u8 {
    var dir = try Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    return globAt(dir, search, rule, a, io);
}

pub fn globAt(dir: Dir, search: []const u8, rule: GlobRule, a: Allocator, io: Io) ![][]u8 {
    // TODO multi space glob
    std.debug.assert(std.mem.count(u8, search, "*") == 1);
    const idx = findScalar(u8, search, '*').?;
    const before = search[0..idx];
    const after = search[idx + 1 ..];
    var itr = dir.iterate();

    var names: ArrayList([]u8) = try .initCapacity(a, 20);
    errdefer names.deinit(a);
    errdefer for (names.items) |itm| a.free(itm);

    // TODO leaks if error in the middle of iteration
    while (try itr.next(io)) |entry| {
        switch (rule) {
            .default => if (entry.name.len == 0 or entry.name[0] == '.') continue,
            .include_dot => {},
        }
        if (!startsWith(u8, entry.name, before)) continue;
        if (!endsWith(u8, entry.name, after)) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(a);
}

fn findHshPath(fs: *Fs, name: []const u8, a: Allocator, io: Io, comptime cr: CreateRule) !Named.File {
    if (fs.config) |conf| {
        var hsh_b: [2048]u8 = undefined;
        const out = try bufPrint(&hsh_b, "{s}/hsh", .{conf.name});
        log.debug("finding path '{s}'\n", .{out});
        if (Dir.openDirAbsolute(io, out, .{})) |d| {
            defer d.close(io);
            if (writableFrom(d, name, io, cr)) |file| {
                var realpath: [2048]u8 = undefined;
                const len = try d.realPathFile(io, name, &realpath);
                return .{ .name = try a.dupe(u8, realpath[0..len]), .file = file };
            }
        } else |_| {
            log.debug("unable to open {s}\n", .{out});
        }
    } else {
        if (fs.home.dir.openDir(io, ".config", .{})) |home_cfg| {
            var realpath: [2048]u8 = undefined;
            const len = try fs.home.dir.realPathFile(io, ".config", &realpath);
            fs.config = .{ .name = try a.dupe(u8, realpath[0..len]), .dir = home_cfg };
            if (home_cfg.openDir(io, "hsh", .{})) |hch| {
                defer hch.close(io);
                if (writableFrom(hch, name[1..], io, cr)) |file| {
                    return .{
                        .name = try a.dupe(u8, name[1..]),
                        .file = file,
                    };
                }
            } else |e| log.err("unable to open {s} {}\n", .{ "hsh", e });
            //return hc;
        } else |e| log.err("unable to open {s} {}\n", .{ "conf", e });
        if (writableFrom(fs.home.dir, name, io, cr)) |file| {
            return .{
                .name = try a.dupe(u8, name),
                .file = file,
            };
        }
    }

    return error.Missing;
}

pub fn openFileStdout(name: []const u8, io: Io, append: bool) !File {
    if (append) {
        return writable(name, io, .create) orelse unreachable;
    }

    // TODO don't use string here
    if (vars.get("noclobber")) |noclobber| {
        if (eql(u8, noclobber, "true")) {
            if (Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only })) |file| {
                file.close(io);
                return error.NoClobber;
            } else |err| {
                switch (err) {
                    error.FileNotFound => {
                        if (writable(name, io, .create)) |file| {
                            return file;
                        }
                    },
                    else => return err,
                }
            }
            return error.NoClobber;
        }
    }

    if (reCreate(name, io)) |file| {
        return file;
    }
    unreachable;
}

fn openRcFile(fs: *Fs, a: Allocator, io: Io) !Named.File {
    return try fs.findHshPath(".hshrc", a, io, .open);
}

fn openHistFile(fs: *Fs, a: Allocator, io: Io) !Named.File {
    const p = fs.findHshPath(".hsh_history", a, io, .open) catch |e| {
        if (e != error.Missing) return e;
        return try fs.findHshPath(".hsh_history", a, io, .create);
    };
    // I've been seeing some strange behavior in history I don't fully
    // understand. This probably won't fix it, but I'm gonna try it anyways
    //p.seekFromEnd(0) catch {};
    return p;
}

test "fs" {
    _ = std.testing.refAllDecls(@This());
}

pub fn testingFs() Fs {
    const paths = struct {
        pub var p = [_]Named{
            .{ .dir = .{ .name = "/usr/bin", .dir = undefined } },
        };
    };
    if (!builtin.is_test) unreachable;
    return .{
        .cwd = .{ .dir = undefined, .name = "testing/cwd" },
        .home = .{ .name = "/home/user", .dir = Dir.cwd().openDir(std.testing.io, ".", .{}) catch unreachable },
        .paths = .{ .items = &paths.p },
        .config = undefined,
        .rc = undefined,
        .history = undefined,
        .inotify_fd = undefined,
        .watches = .{},
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;
const Environ = std.process.Environ;
const eql = std.mem.eql;
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const log = @import("log.zig");
const INotify = @import("inotify.zig");
const Hsh = @import("hsh.zig");
const vars = @import("variables.zig");
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const builtin = @import("builtin");
const system = @import("system.zig");
const intergr = @import("intergrations.zig");
