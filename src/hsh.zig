const std = @import("std");
const mem = @import("mem.zig");
const Allocator = mem.Allocator;
const Drawable = @import("draw.zig").Drawable;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TTY = @import("tty.zig").TTY;
const builtin = @import("builtin");
const ArrayList = std.ArrayList;
const Signals = @import("signals.zig");
const Queue = std.atomic.Queue;
const jobs = @import("jobs.zig");
const parser = @import("parse.zig");
const Parser = parser.Parser;
const bi = @import("builtins.zig");
const State = @import("state.zig");
const History = @import("history.zig");

pub const Error = error{
    Unknown,
    Memory,
    EOF,
    FSysMissing,
    FSysGeneric,
    CorruptFile,
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

test "fs" {
    const a = std.testing.allocator;
    var env = std.process.getEnvMap(a) catch return E.Unknown; // TODO err handling
    //var p = try findPath(a, &env) orelse unreachable;
    //var buf: [200]u8 = undefined;
    //std.debug.print("path {s}\n", .{try p.realpath(".", &buf)});
    _ = try openRcFile(a, &env);
    defer env.deinit();
}

fn openishFile(dir: std.fs.Dir, name: []const u8, comptime create: bool) ?std.fs.File {
    if (create) {
        return dir.createFile(name, .{ .read = true, .truncate = false }) catch return null;
    } else {
        return dir.openFile(name, .{ .mode = .read_write }) catch return null;
    }
}

/// Caller owns returned file
fn findPath(a: Allocator, env: *std.process.EnvMap, name: []const u8, comptime create: bool) !std.fs.File {
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

    return E.FSysMissing;
}

fn openRcFile(a: Allocator, env: *std.process.EnvMap) !?std.fs.File {
    return try findPath(a, env, ".hshrc", false);
}

fn openHistFile(a: Allocator, env: *std.process.EnvMap) !?std.fs.File {
    return try findPath(a, env, ".hsh_history", false);
}

/// caller owns memory
fn readLine(a: *Allocator, r: std.fs.File.Reader) ![]u8 {
    var buf = a.alloc(u8, 1024) catch return Error.Memory;
    errdefer a.free(buf);
    if (r.readUntilDelimiterOrEof(buf, '\n')) |line| {
        if (line) |l| {
            return l;
        } else {
            return Error.EOF;
        }
    } else |err| return err;
}

fn getConfigs(A: Allocator, env: *std.process.EnvMap) !struct { ?std.fs.File, ?std.fs.File } {
    var a = A;
    var rc = openRcFile(a, env) catch null;
    var hs = openHistFile(a, env) catch null;

    return .{ rc, hs };
}

fn setupBuiltins(hsh: *HSH) !void {
    savestates = ArrayList(State).init(hsh.alloc);
    bi.aliases.init(hsh.alloc);
    bi.Set.init();
}

fn initHSH(hsh: *HSH) !void {
    try setupBuiltins(hsh);

    if (hsh.rc) |rc_| {
        var r = rc_.reader();
        var a = hsh.alloc;

        var tokenizer = Tokenizer.init(a);
        while (readLine(&a, r)) |line| {
            defer a.free(line);
            if (line.len > 0 and line[0] == '#') {
                continue;
            }
            defer tokenizer.reset();
            tokenizer.consumes(line) catch continue;
            _ = tokenizer.tokenize() catch continue;
            var titr = Parser.parse(&a, tokenizer.tokens.items, false) catch continue;
            if (titr.first().type != .Builtin) continue;

            const bi_func = bi.strExec(titr.first().cannon());
            titr.restart();
            bi_func(hsh, &titr) catch |err| {
                std.debug.print("rc parse error {}\n", .{err});
            };
            //std.debug.print("tokens {any}\n", .{tokenizer.tokens.items});
        } else |err| {
            if (err != Error.EOF) {
                std.debug.print("error {}\n", .{err});
                unreachable;
            }
        }
    }
}

var savestates: ArrayList(State) = undefined;

pub fn addState(s: State) E!void {
    savestates.append(s) catch return E.Memory;
}

fn writeLine(f: std.fs.File, line: []const u8) !usize {
    const size = try f.write(line);
    return size;
}

fn writeState(h: *HSH, s: *State) !void {
    const outf = h.rc orelse return E.FSysGeneric;
    const data: ?[][]const u8 = s.save(h);

    if (data) |dd| {
        _ = try writeLine(outf, "# [ ");
        _ = try writeLine(outf, s.name);
        _ = try writeLine(outf, " ]\n");
        for (dd) |line| {
            _ = try writeLine(outf, line);
            h.alloc.free(line);
        }
        _ = try writeLine(outf, "\n\n");
    } else {
        _ = try writeLine(outf, "# [ ");
        _ = try writeLine(outf, s.name);
        _ = try writeLine(outf, " ] didn't provide any save data\n");
    }
}

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
    hist: ?History,
    tty: TTY = undefined,
    draw: Drawable = undefined,
    tkn: Tokenizer = undefined,
    input: i32 = 0,
    changes: []u8 = undefined,

    pub fn init(a: Allocator) Error!HSH {
        // I'm pulling all of env out at startup only because that's the first
        // example I found. It's probably sub optimal, but ¯\_(ツ)_/¯. We may
        // decide we care enough to fix this, or not. The internet seems to think
        // it's a mistake to alter the env for a running process.
        var env = std.process.getEnvMap(a) catch return E.Unknown; // TODO err handling

        var conf = try getConfigs(a, &env);
        var hsh = HSH{
            .alloc = a,
            .features = .{},
            .env = env,
            .pid = std.os.linux.getpid(),
            .sig_queue = Queue(Signals.Signal).init(),
            .jobs = jobs.init(a),
            .rc = conf[0],
            .hist = if (conf[1]) |cfd| History{ .hist = cfd } else null,
        };
        hsh.initFs() catch return E.FSysGeneric;

        try initHSH(&hsh);
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

    fn hshState(_: *HSH, _: *HSH) ?[][]const u8 {
        return null;
    }

    pub fn raze(hsh: *HSH) void {
        hsh.env.deinit();
        if (hsh.hist) |hist| hist.raze();

        hsh.rc.?.seekTo(0) catch unreachable;
        for (savestates.items) |*saver| {
            writeState(hsh, saver) catch continue;
        }

        if (hsh.rc) |rrc| rrc.close();
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
                    hsh.draw.reset();
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
