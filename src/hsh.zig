env: Environ,
fs: Fs,
tty: Tty,
draw: Draw,
prompt: Prompt,
features: Features,
waiting: bool = false,
pid: system.pid_t,
pgrp: system.pid_t = -1,
jobs: Jobs,

const Hsh = @This();

pub const Error = error{
    Unknown,
    OutOfMemory,
    Memory,
    EOF,
    CorruptFile,
    FSError,
    Other,
    InitFailed,
};

pub const Feature = enum {
    debugging,
    tab_complete,
    colorize,
};

pub const Features = struct {
    debugging: bool = builtin.mode == std.builtin.OptimizeMode.Debug,
    tab_complete: ?bool = true,
    colorize: ?bool = null,
};

// Until tagged structs are a thing, enforce these to be equal at compile time
// it's probably not important for the order to be equal... but here we are :)
comptime {
    for (@typeInfo(Feature).@"enum".fields, @typeInfo(Features).@"struct".fields) |feat, hfeat| {
        if (!std.mem.eql(u8, feat.name, hfeat.name))
            @compileError("Feature mismatch " ++ feat.name ++ "\n");
    }
}

/// caller owns memory
fn readLine(a: Allocator, r: *std.Io.Reader) ![]u8 {
    if (r.takeSentinel('\n')) |line| {
        return try a.dupe(u8, line);
    } else |err| return err;
}

/// TODO delete this helper
pub fn readRCINotify(h: *Hsh, e: INEvent, a: Allocator, io: Io) void {
    // This isn't the right way, but I'm doing it this way because I'll hate
    // this enough to fix it later.
    if (e == .write and false) { // FIXME disable during debugging
        log.warn("Re-Reading RC file (write detected)\n", .{});
        readFromRC(h, a, io) catch {
            log.err("write failed during inotify event\n", .{});
        };
    }
}

fn readFromRC(hsh: *Hsh, a: Allocator, io: Io) !void {
    var r_b: [2048]u8 = undefined;
    if (hsh.fs.rc) |rc| {
        var r = rc.file.reader(io, &r_b);

        r.seekTo(0) catch return error.FSError;
        while (readLine(a, &r.interface)) |line| {
            defer a.free(line);
            if (line.len == 0 or line[0] == '#') continue;

            log.trace("reading line `` {s} ``\n", .{line});
            if (line.len > 0 and line[0] == '#') {
                continue;
            }
            var titr = Token.Iterator{ .raw = line };
            const tokens = titr.toSlice(a) catch return error.Memory;
            defer a.free(tokens);
            var pitr = Resolver.iterate(a, tokens) catch continue;
            try pitr.resolveAll(a, io);
            defer pitr.raze(a);

            if (!shellbuiltin.exists(pitr.first().resolved.str)) {
                log.warn("Unknown rc line \n    {s}\n", .{line});
                continue;
            }

            const bi_func = shellbuiltin.strExec(titr.first().str);
            _ = bi_func(hsh, &pitr, a, io) catch |err| {
                log.err("rc parse error {}\n", .{err});
            };
            pitr.raze(a);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => {
                log.err("error {}\n", .{err});

                return err;
            },
        }
    }
}

fn writeLine(f: std.fs.File, line: []const u8) !usize {
    const size = try f.write(line);
    return size;
}

//fn writeState(h: *Hsh ) !void {
//    const outf = h.fs.rc orelse return error.Other;
//
//    for () |*s| {
//        const data: ?[][]const u8 = s.save(h);
//
//        if (data) |dd| {
//            _ = try writeLine(outf, "# [ ");
//            _ = try writeLine(outf, s.name);
//            _ = try writeLine(outf, " ]\n");
//            for (dd) |line| {
//                _ = try writeLine(outf, line);
//                h.alloc.free(line);
//            }
//            _ = try writeLine(outf, "\n\n");
//            h.alloc.free(dd);
//        } else {
//            _ = try writeLine(outf, "# [ ");
//            _ = try writeLine(outf, s.name);
//            _ = try writeLine(outf, " ] didn't provide any save data\n");
//        }
//    }
//    const cpos = outf.getPos() catch return error.Other;
//    outf.setEndPos(cpos) catch return error.Other;
//}

fn initCommon(env: Environ, a: Allocator, io: Io) !Hsh {
    Variables.init(a);
    Variables.load(env, a) catch return error.Memory;
    // builtins that wish to save data depend on this being available
    shellbuiltin.init(a);
    try Context.init();

    if (Fs.open("/etc/hostname", io)) |*file| {
        defer file.close(io);
        var b: [128]u8 = undefined;
        var r = file.reader(io, &b);
        if (r.interface.takeDelimiter('\n') catch null) |host_w| {
            const host = trim(u8, host_w, " \t");
            if (host.len > 0) {
                try Variables.put("HOSTNAME", host, a);
            }
        }
    } else log.err("unable to read hostname\n", .{});

    return .{
        .features = .{},
        .env = env,
        .pid = system.getpid(),
        .jobs = .init(),
        .fs = try .init(env, a, io),
        .tty = undefined,
        .prompt = undefined,
        .draw = undefined,
    };
}

pub fn initStateless(env: Environ, a: Allocator, io: Io) !Hsh {
    var hsh: Hsh = try .initCommon(env, a, io);

    hsh.tty = .init(try a.alloc(u8, 256), try a.alloc(u8, 256), io);
    return hsh;
}

pub fn init(env: Environ, a: Allocator, io: Io) !Hsh {
    var hsh: Hsh = try .initCommon(env, a, io);

    const hostname: ?[]const u8 = Variables.get("HOSTNAME");
    hsh.prompt = .init(env.getPosix("USER") orelse "[env error]", hostname);
    hsh.tty = .init(try a.alloc(u8, 2048), try a.alloc(u8, 2048), io);

    hsh.fs.inotifyInstallRc(readRCINotify, a) catch {
        log.err("Unable to install rc INotify\n", .{});
    };

    try readFromRC(&hsh, a, io);
    return hsh;
}

pub fn enabled(hsh: *const Hsh, comptime f: Feature) bool {
    return switch (f) {
        .debugging => if (hsh.features.debugging) true else false,
        .tab_complete => hsh.features.tab_complete,
        .colorize => hsh.features.colorize orelse true,
    };
}

pub fn raze(hsh: *Hsh, a: Allocator, io: Io) void {
    var b: [2048]u8 = undefined;
    if (hsh.fs.rc) |rc| {
        var fw = rc.file.writer(io, &b);
        fw.seekTo(0) catch @panic("unable to seek rc");
        //shellbuiltin.save(hsh, &fw.interface) catch unreachable;
        //fw.interface.flush() catch unreachable;
    }
    Context.raze(a);
    hsh.draw.raze(a);
    hsh.jobs.raze(a);
    hsh.razeStateless(a, io);
}

pub fn razeStateless(hsh: *Hsh, a: Allocator, io: Io) void {
    shellbuiltin.raze(a);
    Variables.raze(a);
    hsh.fs.raze(a, io);
    hsh.tty.raze(a);
}

fn sleep(_: *Hsh) void {
    // TODO make this adaptive and smrt
    //std.time.sleep(10 * 1000 * 1000);
    unreachable;
}

/// Returns true if there was an event requiring a redraw
pub fn spin(hsh: *Hsh, a: Allocator, io: Io) bool {
    var was_bg = false;
    var event = hsh.doSignals();
    while (hsh.jobs.getFg()) |_| {
        event = hsh.doSignals() or event;
        was_bg = true;
        hsh.sleep();
    }
    _ = Jobs.waitSpin();
    if (was_bg) hsh.tty.setOwner(null) catch {
        log.err("Unable to setOwner after child event\n", .{});
    };
    while (hsh.waiting) {
        event = hsh.doSignals() or event;
        hsh.sleep();
    }
    _ = hsh.fs.checkINotify(hsh, a, io);
    return event;
}

fn doSignals(hsh: *Hsh) bool {
    if (Signals.do(hsh)) |sig| switch (sig) {
        .sigint => return true,
        .unexpected => unreachable,
    };
    return false;
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Environ = std.process.Environ;

const builtin = @import("builtin");

const log = @import("log.zig");
const Context = @import("context.zig");
const Draw = @import("draw.zig");
const Prompt = @import("Prompt.zig");
const INEvent = @import("inotify.zig").Event;
const Line = @import("line.zig");
const Resolver = @import("parse.zig").Resolver;
const Signals = @import("signals.zig");
const Tty = @import("tty.zig");
const Token = @import("token.zig");
const Variables = @import("variables.zig");
const Fs = @import("Fs.zig");
const Jobs = @import("jobs.zig");
const shellbuiltin = @import("builtins.zig");
const trim = std.mem.trim;
const system = @import("system.zig");
