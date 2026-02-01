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

    pub const File = struct {
        name: []const u8,
        file: Fs.File,

        pub fn close(d: Named.Dir, io: Io) Named.Closed {
            d.dir.close(io);
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

        pub fn openFile(_: *Closed, _: Io) !void {
            unreachable;
        }

        pub fn openDir(c: *Closed, io: Io) !void {
            const n: *Named = @fieldParentPtr("closed_dir", c);
            n.* = .{ .dir = .{
                .name = c.name,
                .dir = try Fs.Dir.openDirAbsolute(io, c.name, .{}),
            } };
        }

        pub fn raze(n: *Named, a: Allocator, io: Io) void {
            switch (n.*) {
                .closed_file => {},
                .closed_dir => {},
                .dir => |*d| _ = d.close(io),
                .file => |*f| _ = f.close(io),
            }
            a.free(n.name);
        }
    };

    pub fn open(n: *Named, io: Io) !void {
        switch (n.*) {
            .closed_file => unreachable,
            .closed_dir => |*d| try d.openDir(io),
            .dir => unreachable,
            .file => unreachable,
        }
    }

    pub fn close(n: *Named, io: Io) void {
        switch (n.*) {
            .closed_file => unreachable,
            .closed_dir => unreachable,
            .dir => |*d| _ = d.close(io),
            .file => unreachable,
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
        path.open(io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    const cwd: Named.Dir = .{
        .dir = try Dir.cwd().openDir(io, ".", .{ .iterate = true }),
        .name = try Dir.cwd().realPathFileAlloc(io, ".", a),
    };
    var fs: Fs = .{
        .cwd = cwd,
        .paths = paths,
        .home = if (env.getPosix("HOME")) |home|
            .{
                .name = home,
                .dir = try Dir.openDirAbsolute(io, home, .{}),
            }
        else
            .{
                .name = try a.dupe(u8, cwd.name),
                .dir = try Dir.openDirAbsolute(io, cwd.name, .{}),
            },
        .inotify_fd = @intCast((linux.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK))),
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
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        const rcount = std.posix.read(fd, &buf) catch return true;
        if (rcount > 0) {
            if (rcount < @sizeOf(linux.inotify_event)) {
                log.err(
                    "inotify read size too small @{} expected {}\n",
                    .{ rcount, @sizeOf(linux.inotify_event) },
                );
                return true;
            }
            const event: *const linux.inotify_event = @ptrCast(&buf);
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
    if (fs.rc) |rc| rc.file.close(io);
    // TODO inotify_fd
    for (fs.watches.items) |*watch| {
        a.free(watch.path);
    }
    fs.watches.deinit(a);
    if (fs.history) |*h| h.raze(a, io);
}

pub fn cd(fs: *Fs, trgt: []const u8, a: Allocator, io: Io) !void {
    log.err("cd path '{s}'\n", .{trgt});
    const old_name = fs.cwd.name;

    const next = if (trgt.len == 0)
        try fs.cwd.dir.openDir(io, fs.home.name, .{})
    else
        try fs.cwd.dir.openDir(io, trgt, .{});

    fs.cwd.name = try fs.cwd.dir.realPathFileAlloc(io, ".", a);
    a.free(old_name);
    fs.cwd.dir.close(io);
    fs.cwd.dir = next;
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

fn fileAt(
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
    };
}

pub const CreateRule = enum {
    create,
    open,
};

pub fn writeFileAt(dir: Dir, name: []const u8, io: Io, comptime cr: CreateRule) ?File {
    return fileAt(dir, name, io, cr, .read_write, false);
}

pub fn writeFile(name: []const u8, io: Io, comptime cr: CreateRule) ?File {
    return fileAt(Dir.cwd(), name, io, cr, .read_write, false);
}

pub fn openFileAt(dir: Dir, name: []const u8, io: Io, comptime cr: CreateRule) ?File {
    return fileAt(dir, name, io, cr, .read_only, false);
}

pub fn openFile(name: []const u8, io: Io, comptime cr: CreateRule) ?File {
    return fileAt(Dir.cwd(), name, io, cr, .read_only, false);
}

pub fn create(name: []const u8, io: Io) ?File {
    return fileAt(Dir.cwd(), name, io, .create, .read_only, false);
}

pub fn reCreate(name: []const u8, io: Io) ?File {
    return fileAt(Dir.cwd(), name, io, .create, .read_only, true);
}

pub const GlobRule = enum {
    default,
    include_dot,
};

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

fn findPath(fs: *Fs, name: []const u8, a: Allocator, io: Io, comptime cr: CreateRule) !Named.File {
    if (fs.config) |conf| {
        const out = try allocPrint(a, "{s}/hsh", .{conf.name});
        log.debug("finding path '{s}'\n", .{out});
        if (Dir.openDirAbsolute(io, out, .{})) |d| {
            defer d.close(io);
            if (writeFileAt(d, name, io, cr)) |file| {
                return .{
                    .name = try d.realPathFileAlloc(io, name, a),
                    .file = file,
                };
            }
        } else |_| {
            log.debug("unable to open {s}\n", .{out});
        }
    } else {
        if (fs.home.dir.openDir(io, ".config", .{})) |home_cfg| {
            fs.config = .{
                .name = try fs.home.dir.realPathFileAlloc(io, ".config", a),
                .dir = home_cfg,
            };
            if (home_cfg.openDir(io, "hsh", .{})) |hch| {
                defer hch.close(io);
                if (writeFileAt(hch, name[1..], io, cr)) |file| {
                    return .{
                        .name = try a.dupe(u8, name[1..]),
                        .file = file,
                    };
                }
            } else |e| log.err("unable to open {s} {}\n", .{ "hsh", e });
            //return hc;
        } else |e| log.err("unable to open {s} {}\n", .{ "conf", e });
        if (writeFileAt(fs.home.dir, name, io, cr)) |file| {
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
        return openFile(name, io, .create) orelse unreachable;
    }

    // TODO don't use string here
    if (vars.get("noclobber")) |noclobber| {
        if (eql(u8, noclobber, "true")) {
            if (Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only })) |file| {
                file.close(io);
                return error.NoClobber;
            } else |err| {
                switch (err) {
                    File.OpenError.FileNotFound => {
                        if (openFile(name, io, .create)) |file| {
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
    return try fs.findPath(".hshrc", a, io, .open);
}

fn openHistFile(fs: *Fs, a: Allocator, io: Io) !Named.File {
    const p = fs.findPath(".hsh_history", a, io, .open) catch |e| {
        if (e != error.Missing) return e;
        return try fs.findPath(".hsh_history", a, io, .create);
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
const linux = std.os.linux;
const builtin = @import("builtin");
