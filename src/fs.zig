cwd: Dir,
cwd_name: []const u8 = "fixme",
home: ?Named.Dir,
paths: ArrayList(Named),
conf: ?Named.Dir = null,
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
    };

    pub const Dir = struct {
        name: []const u8,
        dir: Fs.Dir,

        pub fn close(d: Named.Dir, io: Io) Named.Closed {
            d.dir.close(io);
            return .{ .name = d.name };
        }
    };

    pub const Closed = struct {
        name: []const u8,

        pub fn openFile(_: *Closed, _: Io) *Named {
            unreachable;
        }

        pub fn openDir(c: *Closed, io: Io) *Named {
            const n: *Named = @fieldParentPtr(c, "closed_dir");
            n.* = .{ .dir = .{
                .name = c.name,
                .dir = Fs.Dir.openDirAbsolute(io, c.name, .{}),
            } };
            return n;
        }
    };

    pub fn open(n: *Named, io: Io) Named {
        return switch (n) {
            .closed_file => unreachable,
            .closed_dir => |c| c.openDir(io),
            .dir => unreachable,
            .file => unreachable,
        };
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

    var fs: Fs = .{
        .cwd = try Dir.cwd().openDir(io, ".", .{ .iterate = true }),
        .paths = paths,
        .home = .{
            .name = env.getPosix("HOME") orelse unreachable,
            .dir = try Fs.Dir.openDirAbsolute(io, env.getPosix("HOME") orelse unreachable, .{}),
        },
        .inotify_fd = @intCast((linux.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK))),
        .watches = .{},
    };

    fs.rc = fs.openRcFile(a, io) catch null;
    fs.history = fs.openHistFile(a, io) catch null;

    return fs;
}

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
        if (fs.home) |home| {
            const path = try allocPrint(a, "{s}/.config/hsh/hshrc", .{home.name});
            errdefer a.free(path);
            try fs.inotifyInstall(path, cb, a);
        }
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
    //fs.dirs.raze();
    //fs.names.raze(a);
    if (fs.rc) |rc| rc.file.close(io);
    // TODO inotify_fd
    for (fs.watches.items) |*watch| {
        a.free(watch.path);
    }
    fs.watches.deinit(a);
    // don't close fs.history, it's not owned by us
}

pub fn cd(fs: *Fs, trgt: []const u8, a: Allocator, io: Io) !void {
    // std.debug.print("cd path {s} default {s}\n", .{ &path, hsh.fs.home_name });
    const next = if (trgt.len == 0 and fs.home != null)
        try fs.cwd.openDir(io, fs.home.?.name, .{})
    else
        try fs.cwd.openDir(io, trgt, .{});

    fs.cwd.close(io);
    fs.cwd = next;
    a.free(fs.cwd_name);
    fs.cwd_name = try fs.cwd.realPathFileAlloc(io, ".", a);
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

pub fn globCwd(search: []const u8, a: Allocator, io: Io) ![][]u8 {
    var dir = try Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    return globAt(dir, search, a, io);
}

pub fn globAt(dir: Dir, search: []const u8, a: Allocator, io: Io) ![][]u8 {
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
    while (try itr.next(io)) |entry| {
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
fn findPath(fs: *Fs, name: []const u8, a: Allocator, io: Io, comptime cr: CreateRule) !Named.File {
    if (fs.conf) |conf| {
        const out = try allocPrint(a, "{s}/hsh", .{conf.name});
        if (Dir.openDirAbsolute(io, out, .{})) |d| {
            if (writeFileAt(d, name, io, cr)) |file| return .{ .name = out, .file = file };
        } else |_| {
            log.debug("unable to open {s}\n", .{out});
        }
    } else if (fs.home) |home| {
        if (home.dir.openDir(io, ".config", .{})) |*hc| {
            fs.conf = .{ .name = try a.dupe(u8, ".config"), .dir = hc.* };
            if (hc.openDir(io, "hsh", .{})) |hch| {
                if (writeFileAt(hch, name[1..], io, cr)) |file| {
                    return .{ .name = try a.dupe(u8, name[1..]), .file = file };
                }
            } else |e| log.debug("unable to open {s} {}\n", .{ "hsh", e });
            //return hc;
        } else |e| log.debug("unable to open {s} {}\n", .{ "conf", e });
        if (writeFileAt(home.dir, name, io, cr)) |file| {
            return .{ .name = try a.dupe(u8, name), .file = file };
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
    if (true) return error.SkipZigTest;
    const a = std.testing.allocator;
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    //var p = try findPath(a, &env) orelse unreachable;
    //var buf: [200]u8 = undefined;
    //std.debug.print("path {s}\n", .{try p.realpath(".", &buf)});
    if (openRcFile(a, &env)) |_| {
        // pass
    } else |err| {
        if (err != error.Missing) return err;
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;
const Environ = std.process.Environ;
const eql = std.mem.eql;
const log = @import("log.zig");
const INotify = @import("inotify.zig");
const Hsh = @import("hsh.zig");
const vars = @import("variables.zig");
const allocPrint = std.fmt.allocPrint;
const linux = std.os.linux;
