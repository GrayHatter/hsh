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
}

pub fn tcgetpgrp(fd: fd_t, pgrp: *pid_t) usize {
    return std.os.linux.syscall3(
        .ioctl,
        @bitCast(usize, @as(isize, fd)),
        std.os.linux.T.IOCGPGRP,
        @ptrToInt(pgrp),
    );
}

pub fn tcsetpgrp(fd: fd_t, pgrp: *const pid_t) usize {
    return std.os.linux.syscall3(
        .ioctl,
        @bitCast(usize, @as(isize, fd)),
        std.os.linux.T.IOCSPGRP,
        @ptrToInt(pgrp),
    );
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
