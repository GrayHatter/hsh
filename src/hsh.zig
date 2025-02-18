pub const Error = error{
    Unknown,
    OutOfMemory,
    Memory,
    EOF,
    CorruptFile,
    FSError,
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
    std.debug.assert(@typeInfo(Features).@"enum".fields.len == @typeInfo(hshFeature).@"struct".fields.len);
    for (@typeInfo(Features).@"enum".fields, 0..) |field, i| {
        std.debug.assert(std.mem.eql(u8, field.name, @typeInfo(hshFeature).@"struct".fields[i].name));
        //@compileLog("{s}\n", .{field.name});
    }
}

/// caller owns memory
fn readLine(a: *Allocator, r: std.fs.File.Reader) ![]u8 {
    const buf = a.alloc(u8, 1024) catch return Error.Memory;
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

/// TODO delete this helper
pub fn readRCINotify(h: *HSH, e: INEvent) void {
    // This isn't the right way, but I'm doing it this way because I'll hate
    // this enough to fix it later.
    if (e == .write) {
        log.debug("Reading RC because new write detected\n", .{});
        readFromRC(h) catch {
            log.err("write failed during inotify event\n", .{});
        };
    }
}

fn readFromRC(hsh: *HSH) E!void {
    if (hsh.hfs.rc) |rc_| {
        const r = rc_.reader();
        var a = hsh.alloc;

        rc_.seekTo(0) catch return E.FSError;
        while (readLine(&a, r)) |line| {
            defer a.free(line);
            if (line.len == 0 or line[0] == '#') continue;

            log.trace("reading line `` {s} ``\n", .{line});
            if (line.len > 0 and line[0] == '#') {
                continue;
            }
            var titr = Token.Iterator{ .raw = line };
            const tokens = titr.toSlice(a) catch return E.Memory;
            defer a.free(tokens);
            var pitr = Parser.parse(a, tokens) catch continue;

            if (!shellbuiltin.exists(pitr.first().cannon())) {
                log.warn("Unknown rc line \n    {s}\n", .{line});
                continue;
            }

            const bi_func = shellbuiltin.strExec(titr.first().cannon());
            _ = bi_func(hsh, &pitr) catch |err| {
                log.err("rc parse error {}\n", .{err});
            };
            pitr.raze();
        } else |err| {
            if (err != Error.EOF) {
                log.err("error {}\n", .{err});
                unreachable;
            }
        }
    }
}

fn initShell(h: *HSH) !void {
    Variables.init(h.alloc);

    // builtins that wish to save data depend on this being available
    savestates = std.ArrayList(State).init(h.alloc);
    try shellbuiltin.init(h.alloc);
    try Context.init(&h.alloc);
    try readFromRC(h);

    Variables.load(h.env) catch return E.Memory;
}

fn razeShell(h: *HSH) void {
    Context.raze();

    shellbuiltin.raze(h.alloc);
    savestates.clearAndFree();

    Variables.raze();
}

var savestates: std.ArrayList(State) = undefined;

pub fn addState(s: State) E!void {
    try savestates.append(s);
}

fn writeLine(f: std.fs.File, line: []const u8) !usize {
    const size = try f.write(line);
    return size;
}

fn writeState(h: *HSH, saves: []State) !void {
    const outf = h.hfs.rc orelse return E.Other;

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
            h.alloc.free(dd);
        } else {
            _ = try writeLine(outf, "# [ ");
            _ = try writeLine(outf, s.name);
            _ = try writeLine(outf, " ] didn't provide any save data\n");
        }
    }
    const cpos = outf.getPos() catch return E.Other;
    outf.setEndPos(cpos) catch return E.Other;
}

pub const HSH = struct {
    alloc: Allocator,
    features: hshFeature,
    env: std.process.EnvMap,
    hfs: fs,
    pid: std.posix.pid_t,
    pgrp: std.posix.pid_t = -1,
    jobs: *jobs.Jobs,
    tty: TTY = undefined,
    draw: Drawable = undefined,
    line: *Line = undefined,
    input: i32 = 0,
    changes: []u8 = undefined,
    waiting: bool = false,

    pub fn init(a: Allocator) Error!HSH {
        // I'm pulling all of env out at startup only because that's the first
        // example I found. It's probably sub optimal, but ¯\_(ツ)_/¯. We may
        // decide we care enough to fix this, or not. The internet seems to think
        // it's a mistake to alter the env for a running process.
        const env = std.process.getEnvMap(a) catch return E.Unknown; // TODO err handling

        var hfs = fs.init(a, env) catch return E.Memory;
        hfs.inotifyInstallRc(readRCINotify) catch {
            log.err("Unable to install rc INotify\n", .{});
        };
        // TODO there's errors other than just mem here
        var hsh = HSH{
            .alloc = a,
            .features = .{},
            .env = env,
            .pid = std.os.linux.getpid(),
            .jobs = jobs.init(a),
            .hfs = hfs,
        };

        try initShell(&hsh);
        return hsh;
    }

    pub fn enabled(hsh: *const HSH, comptime f: Features) bool {
        return switch (f) {
            .Debugging => if (hsh.features.Debugging) true else false,
            .TabComplete => hsh.feature.TabComplete,
            .Colorize => hsh.features.Colorize orelse true,
        };
    }

    pub fn raze(hsh: *HSH) void {
        if (hsh.hfs.rc) |rc| {
            rc.seekTo(0) catch @panic("unable to seek rc");
            writeState(hsh, savestates.items) catch {};
        }

        razeShell(hsh);
        hsh.env.deinit();
        jobs.raze(hsh.alloc);
        hsh.hfs.raze(hsh.alloc);
    }

    fn sleep(_: *HSH) void {
        // TODO make this adaptive and smrt
        std.time.sleep(10 * 1000 * 1000);
    }

    /// Returns true if there was an event requiring a redraw
    pub fn spin(hsh: *HSH) bool {
        var was_bg = false;
        var event = hsh.doSignals();
        while (jobs.getFg()) |_| {
            event = hsh.doSignals() or event;
            was_bg = true;
            hsh.sleep();
        }
        if (was_bg) hsh.tty.setOwner(null) catch {
            log.err("Unable to setOwner after child event\n", .{});
        };
        while (hsh.waiting) {
            event = hsh.doSignals() or event;
            hsh.sleep();
        }
        _ = hsh.hfs.checkINotify(hsh);
        return event;
    }

    fn doSignals(hsh: *HSH) bool {
        return Signals.do(hsh) != .none;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = @import("log");
const builtin = @import("builtin");

const Context = @import("context.zig");
const Drawable = @import("draw.zig").Drawable;
const INEvent = @import("inotify.zig").Event;
const Line = @import("line.zig");
const Parser = @import("parse.zig").Parser;
const Signals = @import("signals.zig");
const State = @import("state.zig");
const TTY = @import("tty.zig").TTY;
const Token = @import("token.zig");
const Variables = @import("variables.zig");
const fs = @import("fs.zig");
const jobs = @import("jobs.zig");
const shellbuiltin = @import("builtins.zig");
