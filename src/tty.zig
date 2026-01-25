alloc: Allocator,
dev: i32,
is_tty: bool,
in: Reader,
out: Writer,
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

pub var current_tty: ?Tty = null;

/// Calling init multiple times is UB
pub fn init(a: Allocator, io: Io) !Tty {
    // TODO figure out how to handle multiple calls to current_tty?

    const is_tty = Io.File.stdout().isTty(io) catch unreachable and Io.File.stdin().isTty(io) catch unreachable;

    const tty = if (is_tty)
        Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch std.Io.File.stdout()
    else
        std.Io.File.stdout();

    std.debug.assert(current_tty == null);

    const self = Tty{
        .alloc = a,
        .dev = tty.handle,
        .is_tty = is_tty,
        .in = Io.File.stdin().reader(io, try a.alloc(u8, 2048)),
        .out = Io.File.stdout().writer(io, try a.alloc(u8, 2048)),
        .orig_attr = tcAttr(tty.handle),
    };

    current_tty = self;
    return self;
}

fn tcAttr(tty_fd: i32) ?std.posix.termios {
    return std.posix.tcgetattr(tty_fd) catch null;
}

pub fn getAttr(self: *Tty) ?std.posix.termios {
    return tcAttr(self.dev);
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

fn setTTYWhen(self: *Tty, mtio: ?std.posix.termios, when: TCSA) !void {
    if (mtio) |tio| try std.posix.tcsetattr(self.dev, when, tio);
}

pub fn setTTY(self: *Tty, tio: ?std.posix.termios) void {
    self.setTTYWhen(tio, .DRAIN) catch |err| {
        log.err("TTY ERROR encountered, {} when popping.\n", .{err});
    };
}

pub fn setOrig(self: *Tty) !void {
    if (!self.is_tty) return;
    try self.setTTYWhen(self.orig_attr, .DRAIN);
    // try self.command(.ReqMouseEvents, false);
    try self.command(.ModOtherKeys, false);
    //try self.command(.S8C1T, false);
    try self.command(.DECCKM, false);
}

pub fn setRaw(self: *Tty) !void {
    if (!self.is_tty) return;
    try self.setTTYWhen(makeRaw(self.orig_attr), .DRAIN);
    // try self.command(.ReqMouseEvents, true);
    try self.command(.ModOtherKeys, true);
    //try self.command(.S8C1T, true);
    try self.command(.DECCKM, false);
}

pub fn setOwner(self: *Tty, mpgrp: ?std.posix.pid_t) !void {
    if (!self.is_tty or self.owner == null) return;
    const pgrp = mpgrp orelse self.pid;
    _ = try std.posix.tcsetpgrp(self.dev, pgrp);
}

pub fn pwnTTY(self: *Tty) void {
    self.pid = std.os.linux.getpid();
    const ssid = custom_syscalls.getsid(0);
    log.debug("pwnTTY {} and {} \n", .{ self.pid, ssid });
    if (ssid != self.pid) _ = std.os.linux.setpgid(self.pid, self.pid);

    const res = std.posix.tcsetpgrp(self.dev, self.pid) catch |err| {
        self.owner = self.pid;
        log.err("tcsetpgrp failed on pid {}, error was: {}\n", .{ self.pid, err });
        const get = std.posix.tcgetpgrp(self.dev) catch |err2| {
            log.err("tcgetpgrp err {}\n", .{err2});
            return;
        };
        log.err("tcgetpgrp reports {}\n", .{get});
        unreachable;
    };
    log.debug("tc pwnd {}\n", .{res});
    const pgrp = std.posix.tcgetpgrp(self.dev) catch unreachable;
    log.debug("get new pgrp {}\n", .{pgrp});
}

pub fn waitForFg(self: *Tty) void {
    if (!self.is_tty) return;
    var pgid = custom_syscalls.getpgid(0);
    var fg = std.posix.tcgetpgrp(self.dev) catch |err| {
        log.err("died waiting for fg {}\n", .{err});
        @panic("panic carefully!");
    };
    while (pgid != fg) {
        std.posix.kill(-pgid, std.posix.SIG.TTIN) catch {
            @panic("unable to send TTIN");
        };
        pgid = custom_syscalls.getpgid(0);
        std.posix.tcsetpgrp(self.dev, pgid) catch {
            @panic("died in loop");
        };
        fg = std.posix.tcgetpgrp(self.dev) catch {
            @panic("died in loop");
        };
    }
}

pub fn print(tty: *Tty, comptime fmt: []const u8, args: anytype) !void {
    try tty.out.interface.print(fmt, args);
    try tty.out.interface.flush();
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

pub fn geom(self: *Tty) !Cord {
    var size: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
    const err = std.posix.system.ioctl(self.dev, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.posix.errno(err) != .SUCCESS) {
        return std.posix.unexpectedErrno(@enumFromInt(err));
    }
    return .{
        .x = size.col,
        .y = size.row,
    };
}

pub fn raze(self: *Tty) void {
    if (self.orig_attr) |attr| {
        self.setTTYWhen(attr, .NOW) catch |err| {
            std.debug.print(
                "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
                .{err},
            );
        };
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
const custom_syscalls = @import("syscalls.zig");
const pid_t = std.posix.pid_t;
const fd_t = std.posix.fd_t;
const log = @import("log.zig");
const TCSA = std.os.linux.TCSA;
