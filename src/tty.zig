const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const os = std.os;
const mem = std.mem;
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
    in: Reader,
    out: Writer,
    attrs: ArrayList(os.termios),

    /// Calling init multiple times is UB
    pub fn init(a: Allocator) !TTY {
        // TODO figure out how to handle multiple calls to current_tty?
        const tty = os.open("/dev/tty", os.linux.O.RDWR, 0) catch unreachable;

        var self = TTY{
            .alloc = a,
            .dev = tty,
            .in = std.io.getStdIn().reader(),
            .out = std.io.getStdOut().writer(),
            .attrs = ArrayList(os.termios).init(a),
        };

        const current = self.getAttr();
        try self.pushTTY(current);
        try self.pushRaw();
        current_tty = self;

        // Cursor focus

        return self;
    }

    fn getAttr(self: *TTY) os.termios {
        return os.tcgetattr(self.dev) catch unreachable;
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

    pub fn pushOrig(self: *TTY) !void {
        try self.pushTTY(self.attrs.items[0]);
        try self.command(.ReqMouseEvents, false);
        try self.command(.ModOtherKeys, false);
    }

    pub fn pushRaw(self: *TTY) !void {
        try self.pushTTY(makeRaw(self.attrs.items[0]));
        try self.command(.ReqMouseEvents, true);
        try self.command(.ModOtherKeys, true);
    }

    pub fn pushTTY(self: *TTY, tios: os.termios) !void {
        try self.attrs.append(self.getAttr());
        try os.tcsetattr(self.dev, .DRAIN, tios);
    }

    pub fn popTTY(self: *TTY) !os.termios {
        // Not using assert, because this is *always* an dangerously invalid state!
        if (self.attrs.items.len <= 1) @panic("popTTY");
        const old = try os.tcgetattr(self.dev);
        const tail = self.attrs.pop();
        os.tcsetattr(self.dev, .DRAIN, tail) catch |err| {
            log.err("TTY ERROR encountered, {} when popping.\n", .{err});
            return err;
        };
        return old;
    }

    pub fn setOwner(self: *TTY, pgrp: std.os.pid_t) !void {
        _ = try std.os.tcsetpgrp(self.dev, pgrp);
    }

    pub fn pwnTTY(self: *TTY) void {
        const pid = std.os.linux.getpid();
        const ssid = custom_syscalls.getsid(0);
        log.debug("pwning {} and {} \n", .{ pid, ssid });
        if (ssid != pid) {
            _ = custom_syscalls.setpgid(pid, pid);
        }
        log.debug("pwning tc \n", .{});
        //_ = custom_syscalls.tcsetpgrp(self.dev, &pid);
        //var res = custom_syscalls.tcsetpgrp(self.dev, &pid);
        const res = std.os.tcsetpgrp(self.dev, pid) catch |err| {
            log.err("Unable to tcsetpgrp to {}, error was: {}\n", .{ pid, err });
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

    pub fn cpos(tty: i32) !Cord {
        std.debug.print("\x1B[6n", .{});
        var buffer: [10]u8 = undefined;
        const len = try os.read(tty, &buffer);
        var splits = mem.split(u8, buffer[2..], ";");
        var x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
        var y: usize = 0;
        if (splits.next()) |thing| {
            y = std.fmt.parseInt(usize, thing[0 .. len - 3], 10) catch 0;
        }
        return .{
            .x = x,
            .y = y,
        };
    }

    pub fn geom(self: *TTY) !Cord {
        var size: os.linux.winsize = mem.zeroes(os.linux.winsize);
        const err = os.system.ioctl(self.dev, os.linux.T.IOCGWINSZ, @ptrToInt(&size));
        if (os.errno(err) != .SUCCESS) {
            return os.unexpectedErrno(@intToEnum(os.system.E, err));
        }
        return .{
            .x = size.ws_col,
            .y = size.ws_row,
        };
    }

    pub fn raze(self: *TTY) void {
        if (self.attrs.items.len == 0) return;
        while (self.attrs.items.len > 1) {
            _ = self.popTTY() catch continue;
        }
        std.debug.assert(self.attrs.items.len == 1);
        const last = self.attrs.pop();
        os.tcsetattr(self.dev, .NOW, last) catch |err| {
            std.debug.print(
                "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
                .{err},
            );
        };
        self.attrs.clearAndFree();
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
