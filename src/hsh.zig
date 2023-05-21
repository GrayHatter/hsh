const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Drawable = @import("draw.zig").Drawable;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TTY = @import("tty.zig").TTY;
const builtin = @import("builtin");
const ArrayList = std.ArrayList;
const Signals = @import("signals.zig");
const Queue = std.atomic.Queue;
const jobs = @import("jobs.zig");

pub const Error = error{
    Unknown,
    Memory,
    FSysGeneric,
    Other,
};
const E = Error;

pub const Features = enum {
    Debugging,
    TabComplete,
    Colorize,
};

pub const hshFeature = struct {
    Debugging: bool = builtin.mode == std.builtin.OptimizeMode.Debug,
    TabComplete: ?bool = true,
    Colorize: ?bool = null,
};

// Until tagged structs are a thing, enforce these to be equal at compile time
// it's probably not important for the order to be equal... but here we are :)
comptime {
    std.debug.assert(@typeInfo(Features).Enum.fields.len == @typeInfo(hshFeature).Struct.fields.len);
    for (@typeInfo(Features).Enum.fields, 0..) |field, i| {
        std.debug.assert(std.mem.eql(u8, field.name, @typeInfo(hshFeature).Struct.fields[i].name));
        //@compileLog("{s}\n", .{field.name});
    }
}

const hshfs = struct {
    cwd: std.fs.Dir,
    cwdi: std.fs.IterableDir,
    cwd_name: []u8 = undefined,
    cwd_short: []u8 = undefined,
    confdir: ?[]const u8 = null,
    home_name: ?[]const u8 = null,
    path_env: ?[]const u8 = null,
    paths: ArrayList([]const u8),
};

// var __hsh: ?*HSH = null;
// pub fn globalEnabled(comptime f: Features) bool {
//     if (__hsh) |hsh| {
//         hsh.enabled(f);
//     }
//     return true;
// }
pub const HSH = struct {
    alloc: Allocator,
    features: hshFeature,
    env: std.process.EnvMap,
    fs: hshfs = undefined,
    pid: std.os.pid_t,
    pgrp: std.os.pid_t = -1,
    sig_queue: Queue(Signals.Signal),
    jobs: *jobs.Jobs,
    rc: ?std.fs.File = null,
    history: ?std.fs.File = null,
    tty: TTY = undefined,
    draw: Drawable = undefined,
    tkn: Tokenizer = undefined,
    input: i32 = 0,

    pub fn init(a: Allocator) Error!HSH {
        // I'm pulling all of env out at startup only because that's the first
        // example I found. It's probably sub optimal, but ¯\_(ツ)_/¯. We may
        // decide we care enough to fix this, or not. The internet seems to think
        // it's a mistake to alter the env for a running process.
        var env = std.process.getEnvMap(a) catch return E.Unknown; // TODO err handling
        var home = env.get("HOME");
        var rc: std.fs.File = undefined;
        var history: std.fs.File = undefined;
        if (home) |h| {
            // TODO sanity checks
            const dir = std.fs.openDirAbsolute(h, .{}) catch return E.FSysGeneric;
            rc = dir.createFile(
                ".hshrc",
                .{ .read = true, .truncate = false },
            ) catch return E.FSysGeneric;
            history = dir.createFile(
                ".hsh_history",
                .{ .read = true, .truncate = false },
            ) catch return E.FSysGeneric;
            history.seekFromEnd(0) catch unreachable;
        }
        var hsh = HSH{
            .alloc = a,
            .features = .{},
            .env = env,
            .pid = std.os.linux.getpid(),
            .sig_queue = Queue(Signals.Signal).init(),
            .jobs = jobs.init(a),
            .rc = rc,
            .history = history,
        };
        hsh.initFs() catch return E.FSysGeneric;
        return hsh;
        //__hsh = hsh;
        //return hsh;
    }

    fn initFs(hsh: *HSH) !void {
        var fs = &hsh.fs;
        const env = hsh.env;
        fs.cwd = std.fs.cwd();
        fs.cwdi = try fs.cwd.openIterableDir(".", .{});
        fs.cwd_name = try fs.cwd.realpathAlloc(hsh.alloc, ".");

        fs.home_name = env.get("HOME");
        const penv = env.get("PATH");

        fs.path_env = if (penv) |_| hsh.alloc.dupe(u8, penv.?) catch null else null;

        fs.cwd_short = fs.cwd_name;
        if (fs.home_name) |home| {
            if (std.mem.startsWith(u8, fs.cwd_name, home)) {
                fs.cwd_short = hsh.alloc.dupe(u8, fs.cwd_name[home.len - 1 ..]) catch return E.Memory;
                fs.cwd_short[0] = '~';
            }
        }

        fs.paths = initPath(hsh.alloc, fs.path_env) catch return E.Memory;
    }

    fn initPath(a: Allocator, path_env: ?[]const u8) !ArrayList([]const u8) {
        var paths = ArrayList([]const u8).init(a);
        if (path_env) |env| {
            var mpaths = std.mem.tokenize(u8, env, ":");
            while (mpaths.next()) |path| {
                try paths.append(path);
            }
        }
        return paths;
    }

    pub fn updateFs(hsh: *HSH) void {
        hsh.razeFs();
        hsh.initFs() catch unreachable;
    }

    pub fn enabled(hsh: *const HSH, comptime f: Features) bool {
        return switch (f) {
            .Debugging => if (hsh.features.Debugging) true else false,
            .TabComplete => hsh.feature.TabComplete,
            .Colorize => hsh.features.Colorize orelse true,
        };
    }

    pub fn raze(hsh: *HSH) void {
        hsh.env.deinit();
        if (hsh.rc) |rrc| rrc.close();
        if (hsh.history) |h| h.close();
    }

    fn razeFs(hsh: *HSH) void {
        hsh.alloc.free(hsh.fs.cwd_name);
        hsh.alloc.free(hsh.fs.cwd_short);
        hsh.fs.paths.clearAndFree();
        if (hsh.fs.path_env) |env| hsh.alloc.free(env);
    }

    pub fn find_confdir(_: HSH) []const u8 {}
    pub fn cd(_: HSH, _: []u8) ![]u8 {}

    fn stopChildren(hsh: *HSH) void {
        for (hsh.jobs.items) |*j| {
            if (j.*.status == .Running) {
                j.status = .Paused;
                // do something
            }
        }
    }
    fn sleep(_: *HSH) void {
        // TODO make this adaptive and smrt
        std.time.sleep(10 * 1000 * 1000);
    }

    pub fn spin(hsh: *HSH) void {
        hsh.doSignals();
        while (jobs.getFg()) |_| {
            hsh.doSignals();
            hsh.sleep();
        }
    }

    const SI_CODE = enum(u6) { EXITED = 1, KILLED, DUMPED, TRAPPED, STOPPED, CONTINUED };

    fn doSignals(hsh: *HSH) void {
        while (hsh.sig_queue.get()) |node| {
            var sig = node.data;
            const pid = sig.info.fields.common.first.piduid.pid;
            switch (sig.signal) {
                std.os.SIG.INT => {
                    std.debug.print("^C\n\r", .{});
                    hsh.tkn.reset();
                    //std.debug.print("\n\rSIGNAL INT(oopsies)\n", .{});
                },
                std.os.SIG.CHLD => {
                    const child = jobs.get(pid) catch {
                        // TODO we should never not know about a job, but it's not a
                        // reason to die just yet.
                        std.debug.print("Unknown child on {} {}\n", .{ sig.info.code, pid });
                        return;
                    };
                    switch (@intToEnum(SI_CODE, sig.info.code)) {
                        SI_CODE.STOPPED => {
                            if (child.*.status == .Running) {
                                child.*.termattr = hsh.tty.popTTY() catch unreachable;
                            }
                            child.*.status = .Paused;
                        },
                        SI_CODE.EXITED,
                        SI_CODE.KILLED,
                        => {
                            if (child.*.status == .Running) {
                                child.*.termattr = hsh.tty.popTTY() catch |e| {
                                    std.debug.print("Unable to pop for (reasons) {}\n", .{e});
                                    unreachable;
                                };
                            }
                            const status = sig.info.fields.common.second.sigchld.status;
                            child.*.exit_code = @bitCast(u8, @truncate(i8, status));
                            child.*.status = .Ded;
                        },
                        SI_CODE.CONTINUED => {
                            child.*.status = .Running;
                        },
                        else => {
                            std.debug.print("Unknown child event for {} {}\n", .{ sig.info.code, pid });
                        },
                    }
                },
                std.os.SIG.TSTP => {
                    if (pid != 0) {
                        const child = jobs.get(pid) catch {
                            // TODO we should never not know about a job, but it's not a
                            // reason to die just yet.
                            std.debug.print("Unknown child on {} {}\n", .{ pid, sig.info.code });
                            return;
                        };
                        if (child.*.status == .Running) {
                            child.*.termattr = hsh.tty.popTTY() catch unreachable;
                        }
                        child.*.status = .Waiting;
                    }
                    std.debug.print("\n\rSIGNAL TSTP {} => ({any})", .{ pid, sig.info });
                    //std.debug.print("\n{}\n", .{child});
                },
                std.os.SIG.CONT => {
                    std.debug.print("\nUnexpected cont from pid({})\n", .{pid});
                },
                std.os.SIG.WINCH => {
                    hsh.draw.term_size = hsh.tty.geom() catch unreachable;
                },
                std.os.SIG.USR1 => {
                    hsh.stopChildren();
                    hsh.tty.pushRaw() catch unreachable;
                    std.debug.print("\r\nAssuming control of TTY!\n", .{});
                },
                else => {
                    std.debug.print("\n\rUnknown signal {} => ({})\n", .{ sig.signal, sig.info });
                    std.debug.print("\n\r dump = {}\n", .{std.fmt.fmtSliceHexUpper(std.mem.asBytes(&sig.info))});
                    std.debug.print("\n\rpid = {}", .{sig.info.fields.common.first.piduid.pid});
                    std.debug.print("\n\ruid = {}", .{sig.info.fields.common.first.piduid.uid});
                    std.debug.print("\n", .{});
                },
            }

            hsh.alloc.free(@as(*[1]Queue(Signals.Signal).Node, node));
        }
    }
};
