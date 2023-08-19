const std = @import("std");
const Allocator = std.mem.Allocator;
const os = std.os;
const fs = std.fs;
const File = fs.File;
const io = std.io;
const Reader = fs.File.Reader;
const Writer = fs.File.Writer;
const Cord = @import("draw.zig").Cord;
const custom_syscalls = @import("syscalls.zig");
const pid_t = std.os.linux.pid_t;
const fd_t = std.os.fd_t;
const log = @import("log");
const TCSA = std.os.linux.TCSA;

pub const VTCmds = enum {
    CurPosGet,
    CurPosSet,
    ModOtherKeys,
    ReqMouseEvents,
};

pub var current_tty: ?TTY = undefined;

pub const TTY = struct {
    alloc: Allocator,
    dev: i32,
    is_tty: bool,
    in: Reader,
    out: Writer,
    orig_attr: os.termios,
    pid: std.os.pid_t = undefined,

    /// Calling init multiple times is UB
    pub fn init(a: Allocator) !TTY {
        // TODO figure out how to handle multiple calls to current_tty?
        const tty = os.open("/dev/tty", os.linux.O.RDWR, 0) catch unreachable;

        var self = TTY{
            .alloc = a,
            .dev = tty,
            .is_tty = std.io.getStdOut().isTty() and std.io.getStdIn().isTty(),
            .in = std.io.getStdIn().reader(),
            .out = std.io.getStdOut().writer(),
            .orig_attr = tcAttr(tty),
        };

        current_tty = self;
        return self;
    }

    fn tcAttr(tty_fd: i32) os.termios {
        return os.tcgetattr(tty_fd) catch unreachable;
    }

    pub fn getAttr(self: *TTY) os.termios {
        return tcAttr(self.dev);
    }

    fn makeRaw(orig: os.termios) os.termios {
        var next = orig;
        next.iflag &= ~(os.linux.IXON |
            os.linux.BRKINT | os.linux.INPCK | os.linux.ISTRIP);
        next.iflag |= os.linux.ICRNL;
        //next.lflag &= ~(os.linux.ECHO | os.linux.ICANON | os.linux.ISIG | os.linux.IEXTEN);
        next.lflag &= ~(os.linux.ECHO | os.linux.ECHONL | os.linux.ICANON | os.linux.IEXTEN);
        next.cc[os.system.V.TIME] = 1; // 0.1 sec resolution
        next.cc[os.system.V.MIN] = 0;
        return next;
    }

    fn setTTYWhen(self: *TTY, tio: os.termios, when: TCSA) !void {
        try os.tcsetattr(self.dev, when, tio);
    }

    pub fn setTTY(self: *TTY, tio: os.termios) void {
        self.setTTYWhen(tio, .DRAIN) catch |err| {
            log.err("TTY ERROR encountered, {} when popping.\n", .{err});
        };
    }

    pub fn setOrig(self: *TTY) !void {
        try self.setTTYWhen(self.orig_attr, .DRAIN);
        // try self.command(.ReqMouseEvents, false);
        try self.command(.ModOtherKeys, false);
    }

    pub fn setRaw(self: *TTY) !void {
        try self.setTTYWhen(makeRaw(self.orig_attr), .DRAIN);
        // try self.command(.ReqMouseEvents, true);
        try self.command(.ModOtherKeys, true);
    }

    pub fn setOwner(self: *TTY, mpgrp: ?std.os.pid_t) !void {
        const pgrp = mpgrp orelse self.pid;
        _ = try std.os.tcsetpgrp(self.dev, pgrp);
    }

    pub fn pwnTTY(self: *TTY) void {
        self.pid = std.os.linux.getpid();
        const ssid = custom_syscalls.getsid(0);
        log.debug("pwning {} and {} \n", .{ self.pid, ssid });
        if (ssid != self.pid) {
            _ = custom_syscalls.setpgid(self.pid, self.pid);
        }
        log.debug("pwning tc \n", .{});
        //_ = custom_syscalls.tcsetpgrp(self.dev, &pid);
        //var res = custom_syscalls.tcsetpgrp(self.dev, &pid);
        const res = std.os.tcsetpgrp(self.dev, self.pid) catch |err| {
            log.err("Unable to tcsetpgrp to {}, error was: {}\n", .{ self.pid, err });
            log.err("Will attempt to tcgetpgrp\n", .{});
            const get = std.os.tcgetpgrp(self.dev) catch |err2| {
                log.err("tcgetpgrp err {}\n", .{err2});
                return;
            };
            log.err("tcgetpgrp reports {}\n", .{get});
            unreachable;
        };
        log.debug("tc pwnd {}\n", .{res});
        //_ = custom_syscalls.tcgetpgrp(self.dev, &pgrp);
        const pgrp = std.os.tcgetpgrp(self.dev) catch unreachable;
        log.debug("get new pgrp {}\n", .{pgrp});
    }

    pub fn waitForFg(self: *TTY) void {
        var pgid = custom_syscalls.getpgid(0);
        var fg = std.os.tcgetpgrp(self.dev) catch |err| {
            log.err("died waiting for fg {}\n", .{err});
            @panic("panic carefully!");
        };
        while (pgid != fg) {
            std.os.kill(-pgid, std.os.SIG.TTIN) catch {
                @panic("unable to send TTIN");
            };
            pgid = custom_syscalls.getpgid(0);
            std.os.tcsetpgrp(self.dev, pgid) catch {
                @panic("died in loop");
            };
            fg = std.os.tcgetpgrp(self.dev) catch {
                @panic("died in loop");
            };
        }
    }

    pub fn print(tty: TTY, comptime fmt: []const u8, args: anytype) !void {
        try tty.out.print(fmt, args);
    }

    pub fn command(tty: TTY, comptime code: VTCmds, comptime enable: ?bool) !void {
        // TODO fetch info back out :/
        switch (code) {
            VTCmds.CurPosGet => try tty.print("\x1B[6n", .{}),
            VTCmds.CurPosSet => @panic("not implemented"),
            VTCmds.ModOtherKeys => {
                try tty.print(if (enable.?) "\x1B[>4;2m" else "\x1b[>4m", .{});
            },
            VTCmds.ReqMouseEvents => {
                try tty.print(if (enable.?) "\x1B[?1004h" else "\x1B[?1004l", .{});
            },
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

    pub fn geom(self: *TTY) !Cord {
        var size: os.linux.winsize = std.mem.zeroes(os.linux.winsize);
        const err = os.system.ioctl(self.dev, os.linux.T.IOCGWINSZ, @intFromPtr(&size));
        if (os.errno(err) != .SUCCESS) {
            return os.unexpectedErrno(@enumFromInt(err));
        }
        return .{
            .x = size.ws_col,
            .y = size.ws_row,
        };
    }

    pub fn raze(self: *TTY) void {
        self.setTTYWhen(self.orig_attr, .NOW) catch |err| {
            std.debug.print(
                "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
                .{err},
            );
        };
    }
};

const expect = std.testing.expect;
test "split" {
    var s = "\x1B[86;1R";
    var splits = std.mem.split(u8, s[2..], ";");
    var x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
    var y: usize = 0;
    if (splits.next()) |thing| {
        y = std.fmt.parseInt(usize, thing[0 .. thing.len - 1], 10) catch unreachable;
    }
    try expect(x == 86);
    try expect(y == 1);
}
