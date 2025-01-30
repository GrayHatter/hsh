const std = @import("std");
const pid_t = std.os.linux.pid_t;
const fd_t = std.os.fd_t;

comptime {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux)
        @compileError("This is untested, and likely unsafe anywhere else");

    if (@hasDecl(std.os.linux, "getsid"))
        @compileError("Os already provides custom getsid");
}

pub fn getsid(pid: pid_t) pid_t {
    return @bitCast(
        @as(u32, @truncate(
            std.os.linux.syscall1(.getsid, @bitCast(@as(isize, pid))),
        )),
    );
}

pub fn getpgid(pid: pid_t) pid_t {
    return @truncate(@as(isize, @bitCast(
        std.os.linux.syscall1(.getpgid, @bitCast(@as(isize, pid))),
    )));
}
