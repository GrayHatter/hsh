const std = @import("std");
const pid_t = std.os.linux.pid_t;
const fd_t = std.os.fd_t;

comptime {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux)
        @compileError("This is untested, and likely unsafe anywhere else");

    if (@hasDecl(std.os.linux, "tcgetpgrp"))
        @compileError("Os already provides custom tcgetpgrp");

    if (@hasDecl(std.os.linux, "ctsetpgrp"))
        @compileError("Os already provides custom ctsetpgrp");

    if (@hasDecl(std.os.linux, "getsid"))
        @compileError("Os already provides custom getsid");

    if (@hasDecl(std.os.linux, "setpgid"))
        @compileError("Os already provides custom setpgid");

    if (@enumToInt(ioctl.TCGETS) != std.os.linux.T.CGETS)
        @compileError("IOCTL mismatch");
}

const ioctl = enum(usize) {
    TCGETS = 0x5401,
    TCSETS = 0x5402,
    TCSETSW = 0x5403,
    TCSETSF = 0x5404,
    TCGETA = 0x5405,
    TCSETA = 0x5406,
    TCSETAW = 0x5407,
    TCSETAF = 0x5408,
    TCSBRK = 0x5409,
    TCXONC = 0x540A,
    TCFLSH = 0x540B,
    TIOCEXCL = 0x540C,
    TIOCNXCL = 0x540D,
    TIOCSCTTY = 0x540E,
    TIOCGPGRP = 0x540F,
    TIOCSPGRP = 0x5410,
};

pub fn tcgetpgrp(fd: fd_t) pid_t {
    var gpid: pid_t = 0;
    _ = std.os.linux.syscall3(
        .ioctl,
        @bitCast(usize, @as(isize, fd)),
        @enumToInt(ioctl.TIOCGPGRP),
        @ptrToInt(&gpid),
    );
    return gpid;
}

pub fn tcsetpgrp(fd: fd_t, pgrp: pid_t) isize {
    return @bitCast(isize, std.os.linux.syscall3(
        .ioctl,
        @bitCast(usize, @as(isize, fd)),
        @enumToInt(ioctl.TIOCSPGRP),
        @bitCast(usize, @as(isize, pgrp)),
    ));
}

pub fn getsid(pid: pid_t) pid_t {
    return @bitCast(pid_t, @truncate(
        u32,
        std.os.linux.syscall1(.getsid, @bitCast(usize, @as(isize, pid))),
    ));
}

pub fn setpgid(pid: pid_t, pgid: pid_t) usize {
    return @bitCast(usize, @truncate(usize, std.os.linux.syscall2(
        .getpgid,
        @bitCast(usize, @as(isize, pid)),
        @bitCast(usize, @as(isize, pgid)),
    )));
}
