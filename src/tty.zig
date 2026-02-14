dev: ?File,
in: RStack,
out: WStack,
orig_attr: ?system.termios,
pid: system.pid_t = undefined,
owner: ?system.pid_t = null,

const Tty = @This();

pub const Mode = union(enum) {
    normal: void,
    raw: void,
    child_tio: system.termios,

    pub fn child(tio: system.termios) Mode {
        return .{ .child_tio = tio };
    }
};

pub const VTCmds = enum {
    CurPosGet,
    CurPosSet,
    ModOtherKeys,
    ReqMouseEvents,
    S8C1T,
    DECCKM,
};

pub const RStack = struct {
    fd: File,
    r: Reader,
    unbuffered: Reader,
};

pub const WStack = struct {
    fd: File,
    w: Writer,
    unbuffered: Writer,
};

var _current: ?Tty = null;

/// Calling init multiple times is UB
pub fn init(in_buffer: []u8, out_buffer: []u8, io: Io) Tty {
    std.debug.assert(_current == null);
    const sys_stdout = std.Io.File.stdout();

    const dev: ?File = if (sys_stdout.isTty(io) catch false)
        Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch null
    else
        null;

    const in_tty = if (dev) |d| d else Io.File.stdin();
    const out_tty = if (dev) |d| d else Io.File.stdout();

    const t = Tty{
        .dev = dev,
        .in = .{
            .fd = in_tty,
            .r = in_tty.readerStreaming(io, in_buffer),
            .unbuffered = in_tty.readerStreaming(io, &.{}),
        },
        .out = .{
            .fd = out_tty,
            .w = out_tty.writerStreaming(io, out_buffer),
            .unbuffered = in_tty.writerStreaming(io, &.{}),
        },
        .orig_attr = tcAttr(dev.?.handle),
    };

    _current = t;
    return t;
}

pub fn current() *Tty {
    return &(_current orelse unreachable);
}

fn tcAttr(tty_fd: i32) ?system.termios {
    return system.tcgetattr(tty_fd) catch null;
}

pub fn getAttr(t: *Tty) ?system.termios {
    return tcAttr((t.dev orelse return null).handle);
}

fn makeRaw(orig: ?system.termios) system.termios {
    var next = orig orelse system.termios{
        .oflag = .{ .OPOST = true, .ONLCR = true },
        .cflag = .{ .CSIZE = .CS8, .CREAD = true, .CLOCAL = true },
        .lflag = .{ .ISIG = true, .ICANON = true, .ECHO = true, .IEXTEN = true, .ECHOE = true },
        .iflag = .{ .BRKINT = true, .ICRNL = true, .IMAXBEL = true },
        .line = 0,
        .cc = [_]u8{0} ** system.NCCS,
        .ispeed = .B9600,
        .ospeed = .B9600,
    };
    next.iflag.IXON = false;
    next.iflag.BRKINT = false;
    next.iflag.INPCK = false;
    next.iflag.ISTRIP = false;
    next.lflag.ECHO = false;
    next.lflag.ECHONL = false;
    next.lflag.ICANON = false;
    next.lflag.IEXTEN = false;
    next.cc[@intFromEnum(system.V.TIME)] = 1; // 0.1 sec resolution
    next.cc[@intFromEnum(system.V.MIN)] = 0;
    return next;
}

fn setTtyWhen(t: *Tty, mtio: ?system.termios, when: system.TCSA) !void {
    const fd = t.dev orelse return error.NoTtyDevice;
    if (mtio) |tio| try system.tcsetattr(fd.handle, when, tio);
}

pub fn set(t: *Tty, m: Mode) !void {
    if (t.dev == null) unreachable;
    switch (m) {
        .normal => {
            try t.setTtyWhen(t.orig_attr, .DRAIN);
            // try t.command(.ReqMouseEvents, false);
            try t.command(.ModOtherKeys, false);
            //try t.command(.S8C1T, false);
            try t.command(.DECCKM, false);
        },
        .raw => {
            try t.setTtyWhen(makeRaw(t.orig_attr), .DRAIN);
            // try t.command(.ReqMouseEvents, true);
            try t.command(.ModOtherKeys, true);
            //try t.command(.S8C1T, true);
            try t.command(.DECCKM, false);
        },
        .child_tio => |tio| {
            try t.setTtyWhen(tio, .DRAIN);
        },
    }
}

pub fn setOwner(t: *Tty, mpgrp: ?system.pid_t) !void {
    if (t.owner == null) return;
    const pgrp = mpgrp orelse t.pid;
    const fd = t.dev orelse return error.NoTtyDevice;
    _ = try system.tcsetpgrp(fd.handle, pgrp);
}

pub fn pwn(t: *Tty) !void {
    const fd = t.dev orelse return error.NoTtyDevice;
    t.pid = system.getpid();
    const ssid = system.getsid(0);
    log.debug("pwnTTY {} and {} \n", .{ t.pid, ssid });
    if (ssid != t.pid) _ = system.setpgid(t.pid, t.pid);

    const res = system.tcsetpgrp(fd.handle, t.pid) catch |err| {
        t.owner = t.pid;
        log.err("tcsetpgrp failed on pid {}, error was: {}\n", .{ t.pid, err });
        const get = system.tcgetpgrp(fd.handle) catch |err2| {
            log.err("tcgetpgrp err {}\n", .{err2});
            return err;
        };
        log.err("tcgetpgrp reports {}\n", .{get});
        unreachable;
    };
    log.debug("tc pwnd {}\n", .{res});
    const pgrp = system.tcgetpgrp(fd.handle) catch unreachable;
    log.debug("get new pgrp {}\n", .{pgrp});
}

pub fn waitForFg(t: *Tty) void {
    if (t.dev == null) return;
    var pgid: system.pid_t = @bitCast(@as(u32, @truncate(system.getpgid(0))));
    if (pgid < 0) unreachable;
    var fg = system.tcgetpgrp(t.dev.?.handle) catch |err| {
        log.err("died waiting for fg {}\n", .{err});
        @panic("panic carefully!");
    };
    while (pgid != fg) {
        system.kill(-pgid, system.SIG.TTIN) catch @panic("unable to send TTIN");
        pgid = @bitCast(@as(u32, @truncate(system.getpgid(0))));
        system.tcsetpgrp(t.dev.?.handle, pgid) catch @panic("died in loop");
        fg = system.tcgetpgrp(t.dev.?.handle) catch @panic("died in loop");
    }
}

fn print(tty: *Tty, comptime fmt: []const u8, args: anytype) !void {
    try tty.out.unbuffered.interface.print(fmt, args);
    try tty.out.unbuffered.interface.flush();
}

pub fn command(tty: *Tty, comptime code: VTCmds, comptime enable: ?bool) !void {
    // TODO fetch info back out :/
    switch (code) {
        .CurPosGet => try tty.print("\x1B[6n", .{}),
        .CurPosSet => @panic("not implemented"),
        .ModOtherKeys => try tty.print(if (enable.?) "\x1B[>4;2m" else "\x1b[>4m", .{}),
        .ReqMouseEvents => try tty.print(if (enable.?) "\x1B[?1004h" else "\x1B[?1004l", .{}),
        .S8C1T => try tty.print(if (enable.?) "\x1B G" else "\x1B F", .{}),
        .DECCKM => try tty.print(if (enable.?) "\x1B[?1h" else "\x1B[?1l", .{}),
    }
}

//pub fn cpos(tty: i32) !Cord {
//    std.debug.print("\x1B[6n", .{});
//    var buffer: [10]u8 = undefined;
//    const len = try os.read(tty, &buffer);
//    var splits = std.mem.split(u8, buffer[2..], ";");
//    var x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
//    var y: usize = 0;
//    if (splits.next()) |thing| {
//        y = std.fmt.parseInt(usize, thing[0 .. len - 3], 10) catch 0;
//    }
//    return .{
//        .x = x,
//        .y = y,
//    };
//}

pub fn geom(t: *Tty) !Cord {
    const fd = t.dev orelse return error.NoDevice;
    var size: system.winsize = std.mem.zeroes(system.winsize);
    const err = system.ioctl(fd.handle, system.T.IOCGWINSZ, @intFromPtr(&size));
    if (system.errno(err) != .SUCCESS) {
        return system.unexpectedErrno(@enumFromInt(err));
    }
    return .{ .x = size.col, .y = size.row };
}

pub fn raze(t: *Tty, a: Allocator) void {
    if (t.orig_attr) |attr| {
        t.setTtyWhen(attr, .NOW) catch |err| std.debug.print(
            "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
            .{err},
        );
    }

    a.free(t.in.r.interface.buffer);
    a.free(t.out.w.interface.buffer);
}

pub fn panic(t: *Tty) void {
    t.dev = null;
    if (_current != null and t == &(_current.?)) {
        _current = null;
    }
    // we can't call raze without an allocator
    if (t.orig_attr) |attr| {
        t.setTtyWhen(attr, .NOW) catch |err| std.debug.print(
            "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
            .{err},
        );
    }
}

const expect = std.testing.expect;
test "split" {
    var s = "\x1B[86;1R";
    var splits = std.mem.splitAny(u8, s[2..], ";");
    const x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
    var y: usize = 0;
    if (splits.next()) |thing| {
        y = std.fmt.parseInt(usize, thing[0 .. thing.len - 1], 10) catch unreachable;
    }
    try expect(x == 86);
    try expect(y == 1);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fs = std.fs;
const File = Io.File;
const Reader = File.Reader;
const Writer = File.Writer;
const Cord = @import("draw.zig").Cord;
const log = @import("log.zig");
const system = @import("system.zig");
