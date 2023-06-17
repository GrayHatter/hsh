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
const Context = @import("context.zig");
const fs = @import("fs.zig");
const Variables = @import("variables.zig");
const log = @import("log");

pub const Error = error{
    Unknown,
    Memory,
    EOF,
    CorruptFile,
    Other,
} || fs.Error;
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

test "fs" {
    const a = std.testing.allocator;
    var env = std.process.getEnvMap(a) catch return E.Unknown; // TODO err handling
    //var p = try findPath(a, &env) orelse unreachable;
    //var buf: [200]u8 = undefined;
    //std.debug.print("path {s}\n", .{try p.realpath(".", &buf)});
    _ = try openRcFile(a, &env);
    defer env.deinit();
}

fn openRcFile(a: Allocator, env: *std.process.EnvMap) !?std.fs.File {
    return try fs.findPath(a, env, ".hshrc", false);
}

fn openHistFile(a: Allocator, env: *std.process.EnvMap) !?std.fs.File {
    return try fs.findPath(a, env, ".hsh_history", false);
}

/// caller owns memory
fn readLine(a: *Allocator, r: std.fs.File.Reader) ![]u8 {
    var buf = a.alloc(u8, 1024) catch return Error.Memory;
    errdefer a.free(buf);
    if (r.readUntilDelimiterOrEof(buf, '\n')) |line| {
        if (line) |l| {
            if (!a.resize(buf, l.len)) @panic("resize\n");
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

fn initBuiltins(hsh: *HSH) !void {
    savestates = ArrayList(State).init(hsh.alloc);
    bi.aliases.init(hsh.alloc);
    bi.Set.init(hsh.alloc);
}

fn razeBuiltins(h: *HSH) void {
    bi.aliases.raze(h.alloc);
    bi.Set.raze();
}

fn initHSH(hsh: *HSH) !void {
    try initBuiltins(hsh);

    try Context.init(&hsh.alloc);

    // Include hshrc
    if (hsh.hfs.rc) |rc_| {
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
            var titr = Parser.parse(&a, tokenizer.tokens.items) catch continue;
            if (titr.first().kind != .Builtin) {
                log.warning("Unknown rc line \n    {s}\n", .{line});
                continue;
            }

            const bi_func = bi.strExec(titr.first().cannon());
            titr.restart();
            _ = bi_func(hsh, &titr) catch |err| {
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

    Variables.init(hsh.alloc);
    Variables.load(hsh.env) catch return E.Memory;
}

fn razeHSH(h: *HSH) void {
    Variables.raze();
    razeBuiltins(h);
}

var savestates: ArrayList(State) = undefined;

pub fn addState(s: State) E!void {
    savestates.append(s) catch return E.Memory;
}

fn writeLine(f: std.fs.File, line: []const u8) !usize {
    const size = try f.write(line);
    return size;
}

fn writeState(h: *HSH, saves: []State) !void {
    const outf = h.hfs.rc orelse return E.FSysGeneric;

    for (saves) |*s| {
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
    const cpos = outf.getPos() catch return E.FSysGeneric;
    outf.setEndPos(cpos) catch return E.FSysGeneric;
}

pub const HSH = struct {
    alloc: Allocator,
    features: hshFeature,
    env: std.process.EnvMap,
    hfs: fs,
    pid: std.os.pid_t,
    pgrp: std.os.pid_t = -1,
    jobs: *jobs.Jobs,
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

        const path = if (env.get("PATH")) |p| a.dupe(u8, p) catch null else null;
        var cwd = std.fs.cwd().realpathAlloc(a, ".") catch return E.Memory;
        var cwd_short = cwd;
        if (env.get("HOME")) |home| {
            if (std.mem.startsWith(u8, cwd, home)) {
                cwd_short = a.dupe(u8, cwd[home.len - 1 ..]) catch return E.Memory;
                cwd_short[0] = '~';
            }
        }

        var conf = try getConfigs(a, &env);
        var hsh = HSH{
            .alloc = a,
            .features = .{},
            .env = env,
            .pid = std.os.linux.getpid(),
            .jobs = jobs.init(a),
            .hfs = .{
                .rc = conf[0],
                .dirs = .{
                    .cwd = std.fs.cwd().openIterableDir(".", .{}) catch return E.Memory,
                },
                .names = .{
                    .cwd = cwd,
                    .cwd_short = cwd_short,
                    .home = env.get("HOME"),
                    .path = path,
                    .paths = initPath(a, path) catch return E.Memory,
                },
            },
            .hist = if (conf[1]) |cfd| History{ .file = cfd } else null,
        };

        try initHSH(&hsh);
        return hsh;
        //__hsh = hsh;
        //return hsh;
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
        if (hsh.hfs.rc) |rc| rc.seekTo(0) catch unreachable;
        writeState(hsh, savestates.items) catch {};
        if (hsh.hfs.rc) |rrc| rrc.close();

        razeHSH(hsh);

        hsh.razeFs();
    }

    fn razeFs(hsh: *HSH) void {
        hsh.alloc.free(hsh.hfs.names.cwd);
        hsh.alloc.free(hsh.hfs.names.cwd_short);
        hsh.hfs.names.paths.clearAndFree();
        hsh.alloc.free(hsh.hfs.names.path.?);
    }

    pub fn find_confdir(_: HSH) []const u8 {}

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
        while (Signals.get()) |node| {
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
                        //std.debug.print("Unknown child on {} {}\n", .{ sig.info.code, pid });
                        continue;
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
        }
    }
};
