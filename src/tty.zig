dev: ?File,
in: RStack,
out: WStack,
orig_attr: ?std.posix.termios,
pid: std.posix.pid_t = undefined,
owner: ?std.posix.pid_t = null,

const Tty = @This();

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

pub var current_tty: ?Tty = null;

/// Calling init multiple times is UB
pub fn init(a: Allocator, io: Io) !Tty {
    std.debug.assert(current_tty == null);
    const sys_stdout = std.Io.File.stdout();

    const dev: ?File = if (try sys_stdout.isTty(io))
        Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch unreachable
    else
        null;

    const in_tty = if (dev) |d| d else std.Io.File.stdin();
    const out_tty = if (dev) |d| d else std.Io.File.stdout();

    const in_b = try a.alloc(u8, 2048);
    const out_b = try a.alloc(u8, 2048);
    const t = Tty{
        .dev = dev,
        .in = .{
            .fd = in_tty,
            .r = in_tty.readerStreaming(io, in_b),
            .unbuffered = in_tty.readerStreaming(io, &.{}),
        },
        .out = .{
            .fd = out_tty,
            .w = out_tty.writerStreaming(io, out_b),
            .unbuffered = in_tty.writerStreaming(io, &.{}),
        },
        .orig_attr = tcAttr(dev.?.handle),
    };

    current_tty = t;
    return t;
}

fn tcAttr(tty_fd: i32) ?std.posix.termios {
    return std.posix.tcgetattr(tty_fd) catch null;
}

pub fn getAttr(t: *Tty) ?std.posix.termios {
    return tcAttr((t.dev orelse return null).handle);
}

fn makeRaw(orig: ?std.posix.termios) std.posix.termios {
    var next = orig orelse std.posix.termios{
        .oflag = .{ .OPOST = true, .ONLCR = true },
        .cflag = .{ .CSIZE = .CS8, .CREAD = true, .CLOCAL = true },
        .lflag = .{ .ISIG = true, .ICANON = true, .ECHO = true, .IEXTEN = true, .ECHOE = true },
        .iflag = .{ .BRKINT = true, .ICRNL = true, .IMAXBEL = true },
        .line = 0,
        .cc = [_]u8{0} ** std.posix.NCCS,
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
    next.cc[@intFromEnum(std.posix.system.V.TIME)] = 1; // 0.1 sec resolution
    next.cc[@intFromEnum(std.posix.system.V.MIN)] = 0;
    return next;
}

fn setTTYWhen(t: *Tty, mtio: ?std.posix.termios, when: TCSA) !void {
    const fd = t.dev orelse return error.NoTtyDevice;
    if (mtio) |tio| try std.posix.tcsetattr(fd.handle, when, tio);
}

pub fn setTTY(t: *Tty, tio: ?std.posix.termios) void {
    t.setTTYWhen(tio, .DRAIN) catch |err| {
        log.err("TTY ERROR encountered, {} when popping.\n", .{err});
    };
}

pub fn setOrig(t: *Tty) !void {
    if (t.dev == null) return;
    try t.setTTYWhen(t.orig_attr, .DRAIN);
    // try t.command(.ReqMouseEvents, false);
    try t.command(.ModOtherKeys, false);
    //try t.command(.S8C1T, false);
    try t.command(.DECCKM, false);
}

pub fn setRaw(t: *Tty) !void {
    if (t.dev == null) return;
    try t.setTTYWhen(makeRaw(t.orig_attr), .DRAIN);
    // try t.command(.ReqMouseEvents, true);
    try t.command(.ModOtherKeys, true);
    //try t.command(.S8C1T, true);
    try t.command(.DECCKM, false);
}

pub fn setOwner(t: *Tty, mpgrp: ?std.posix.pid_t) !void {
    if (t.owner == null) return;
    const pgrp = mpgrp orelse t.pid;
    const fd = t.dev orelse return error.NoTtyDevice;
    _ = try std.posix.tcsetpgrp(fd.handle, pgrp);
}

pub fn pwnTTY(t: *Tty) !void {
    const fd = t.dev orelse return error.NoTtyDevice;
    t.pid = std.os.linux.getpid();
    const ssid = custom_syscalls.getsid(0);
    log.debug("pwnTTY {} and {} \n", .{ t.pid, ssid });
    if (ssid != t.pid) _ = std.os.linux.setpgid(t.pid, t.pid);

    const res = std.posix.tcsetpgrp(fd.handle, t.pid) catch |err| {
        t.owner = t.pid;
        log.err("tcsetpgrp failed on pid {}, error was: {}\n", .{ t.pid, err });
        const get = std.posix.tcgetpgrp(fd.handle) catch |err2| {
            log.err("tcgetpgrp err {}\n", .{err2});
            return err;
        };
        log.err("tcgetpgrp reports {}\n", .{get});
        unreachable;
    };
    log.debug("tc pwnd {}\n", .{res});
    const pgrp = std.posix.tcgetpgrp(fd.handle) catch unreachable;
    log.debug("get new pgrp {}\n", .{pgrp});
}

pub fn waitForFg(t: *Tty) void {
    if (t.dev == null) return;
    var pgid = custom_syscalls.getpgid(0);
    var fg = std.posix.tcgetpgrp(t.dev.?.handle) catch |err| {
        log.err("died waiting for fg {}\n", .{err});
        @panic("panic carefully!");
    };
    while (pgid != fg) {
        std.posix.kill(-pgid, std.posix.SIG.TTIN) catch @panic("unable to send TTIN");
        pgid = custom_syscalls.getpgid(0);
        std.posix.tcsetpgrp(t.dev.?.handle, pgid) catch @panic("died in loop");
        fg = std.posix.tcgetpgrp(t.dev.?.handle) catch @panic("died in loop");
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
        .ModOtherKeys => {
            try tty.print(if (enable.?) "\x1B[>4;2m" else "\x1b[>4m", .{});
        },
        .ReqMouseEvents => {
            try tty.print(if (enable.?) "\x1B[?1004h" else "\x1B[?1004l", .{});
        },
        .S8C1T => {
            try tty.print(if (enable.?) "\x1B G" else "\x1B F", .{});
        },
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
    const fd = t.dev orelse return error.NoTtyDevice;
    var size: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
    const err = std.posix.system.ioctl(fd.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.posix.errno(err) != .SUCCESS) {
        return std.posix.unexpectedErrno(@enumFromInt(err));
    }
    return .{ .x = size.col, .y = size.row };
}

pub fn raze(t: *Tty) void {
    if (t.orig_attr) |attr| {
        t.setTTYWhen(attr, .NOW) catch |err| {
            std.debug.print(
                "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
                .{err},
            );
        };
    }
}

pub fn panic(t: *Tty) void {
    var tty = t.*;
    t.dev = null;
    tty.raze();
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
const custom_syscalls = @import("syscalls.zig");
const pid_t = std.posix.pid_t;
const fd_t = std.posix.fd_t;
const log = @import("log.zig");
const TCSA = std.os.linux.TCSA;
