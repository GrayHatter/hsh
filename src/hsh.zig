const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Drawable = @import("draw.zig").Drawable;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TTY = @import("tty.zig").TTY;
const builtin = @import("builtin");
const ArrayList = std.ArrayList;
const Signals = @import("signals.zig");
const Stack = std.atomic.Stack;

pub const Error = error{
    Unknown,
    Memory,
    JobNotFound,
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
    home_name: []const u8 = undefined,
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

pub const JobStatus = enum {
    RIP, // reaped
    Ded, // zombie
    Paused, // SIGSTOP
    Waiting, // Stopped needs to output
    Piped,
    Background, // in background
    Running, // foreground
    Unknown, // :<
};

pub const Job = struct {
    name: ?[]const u8,
    pid: std.os.pid_t = -1,
    status: JobStatus = .Unknown,
};

pub const HSH = struct {
    alloc: Allocator,
    features: hshFeature,
    env: std.process.EnvMap,
    fs: hshfs,
    pid: std.os.pid_t,
    sig_stack: Stack(Signals.Signal),
    jobs: ArrayList(Job),
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
        return HSH{
            .alloc = a,
            .features = .{},
            .env = env,
            .fs = initFs(a, env) catch return E.FSysGeneric,
            .pid = std.os.linux.getpid(),
            .sig_stack = Stack(Signals.Signal).init(),
            .jobs = ArrayList(Job).init(a),
            .rc = rc,
            .history = history,
        };
        //__hsh = hsh;
        //return hsh;
    }

    fn initFs(a: Allocator, env: std.process.EnvMap) !hshfs {
        var cwd = std.fs.cwd();
        var cwdi = try cwd.openIterableDir(".", .{});
        var name = try cwd.realpathAlloc(a, ".");
        const h = env.get("HOME");
        var short = if (h != null and std.mem.startsWith(u8, name, h.?)) n: {
            var tmp = try a.dupe(u8, name[h.?.len - 1 ..]);
            tmp[0] = '~';
            break :n tmp;
        } else name;

        const penv = env.get("PATH");
        const path_env = if (penv) |_| a.dupe(u8, penv.?) catch null else null;

        return hshfs{
            .cwd = cwd,
            .cwdi = cwdi,
            .cwd_name = name,
            .cwd_short = short,
            .home_name = h orelse "",
            .path_env = path_env,
            .paths = try initPath(a, path_env),
        };
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
        var cwd = std.fs.cwd();
        var cwdi = cwd.openIterableDir(".", .{}) catch unreachable;
        var name = cwd.realpathAlloc(hsh.alloc, ".") catch unreachable;
        const h = hsh.fs.home_name;
        var short = if (std.mem.startsWith(u8, name, h)) n: {
            var tmp = hsh.alloc.dupe(u8, name[h.len - 1 ..]) catch unreachable;
            tmp[0] = '~';
            break :n tmp;
        } else name;

        hsh.fs.cwd = cwd;
        hsh.fs.cwdi = cwdi;
        hsh.fs.cwd_name = name;
        hsh.fs.cwd_short = short;
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

    pub fn getJob(hsh: *HSH, jid: std.os.pid_t) Error!*Job {
        for (hsh.jobs.items) |*j| {
            if (j.*.pid == jid) {
                return j;
            }
        }
        return Error.JobNotFound;
    }

    pub fn newJob(hsh: *HSH, pid: std.os.pid_t, s: JobStatus) Error!void {
        hsh.jobs.append(Job{
            .name = null,
            .pid = pid,
            .status = s,
        }) catch return E.Memory;
    }

    pub fn getFgJob(hsh: *const HSH) ?*const Job {
        for (hsh.jobs.items) |j| {
            if (j.status == .Running) {
                return &j;
            }
        }
        return null;
    }

    pub fn spin(hsh: *HSH) void {
        while (hsh.getFgJob()) |_| {
            hsh.doSignals();
            std.time.sleep(10 * 1000 * 1000);
        }
    }

    pub fn doSignals(hsh: *HSH) void {
        while (hsh.sig_stack.pop()) |node| {
            var sig = node.data;
            switch (sig.signal) {
                std.os.SIG.INT => {
                    std.debug.print("^C\n\r", .{});
                    hsh.tkn.reset();
                    //std.debug.print("\n\rSIGNAL INT(oopsies)\n", .{});
                },
                std.os.SIG.CHLD => {
                    const child = hsh.getJob(sig.info.fields.common.first.piduid.pid) catch {
                        // TODO we should never not know about a job, but it's not a
                        // reason to die just yet.
                        return;
                    };
                    child.*.status = .Ded;
                },
                std.os.SIG.TSTP => {
                    const child = hsh.getJob(sig.info.fields.common.first.piduid.pid) catch {
                        // TODO we should never not know about a job, but it's not a
                        // reason to die just yet.
                        return;
                    };
                    child.*.status = .Waiting;

                    //std.debug.print("\n\rSIGNAL TSTP => ({})\n", .{sig.info});
                },
                std.os.SIG.CONT => std.debug.print("\n\rSIGNAL CONT => ({})\n", .{sig.info}),
                std.os.SIG.WINCH => {
                    hsh.draw.term_size = hsh.tty.geom() catch unreachable;
                },
                else => {
                    std.debug.print("\n\rUnknown signal {} => ({})\n", .{ sig.signal, sig.info });
                    std.debug.print("\n\r dump = {}\n", .{std.fmt.fmtSliceHexUpper(std.mem.asBytes(&sig.info))});
                    std.debug.print("\n\rpid = {}", .{sig.info.fields.common.first.piduid.pid});
                    std.debug.print("\n\ruid = {}", .{sig.info.fields.common.first.piduid.uid});
                    std.debug.print("\n", .{});
                },
            }

            hsh.alloc.free(@as(*[1]Stack(Signals.Signal).Node, node));
        }
    }
};
