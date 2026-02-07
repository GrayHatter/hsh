_: void = {},

pub const zigsys = Io.Threaded;

pub const IN = os.IN;
pub const SIG = os.SIG;
pub const T = os.T;
pub const TCSA = os.TCSA;
pub const V = os.V;
pub const W = os.W;
pub const SA = os.SA;
pub const inotify_event = os.inotify_event;
pub const sigset_t = os.sigset_t;
pub const siginfo_t = os.siginfo_t;
pub const CLD = os.CLD;

pub const NCCS = posix.NCCS;
pub const STDOUT_FILENO = posix.STDOUT_FILENO;
pub const Sigaction = posix.Sigaction;
pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;
pub const termios = posix.termios;
pub const winsize = posix.winsize;

pub const pipe2 = zigsys.pipe2;

pub const abort = std.process.abort;
pub const close = os.close;
pub const dup2 = os.dup2;
pub const execve = os.execve;
pub const exit = std.process.exit;
pub const fchdir = os.fchdir;
pub const fork = os.fork;
pub const getpid = os.getpid;
//pub const inotify_add_watch = os.inotify_add_watch;
pub const inotify_init1 = os.inotify_init1;
pub const ioctl = os.ioctl;
pub const kill = posix.kill;
pub const lseek = os.lseek;
pub const setpgid = os.setpgid;
pub const sigaddset = os.sigaddset;
pub const sigemptyset = os.sigemptyset;
pub const sigprocmask = os.sigprocmask;
pub const waitpid = os.waitpid;

pub const errno = posix.errno;
pub const read = posix.read;
pub const sigaction = posix.sigaction;
pub const tcgetattr = posix.tcgetattr;
pub const tcgetpgrp = posix.tcgetpgrp;
pub const tcsetattr = posix.tcsetattr;
pub const tcsetpgrp = posix.tcsetpgrp;
pub const unexpectedErrno = posix.unexpectedErrno;
pub const inotify_add_watch = posix.inotify_add_watch;

pub const SEEK = os.SEEK;

const std = @import("std");
const Io = std.Io;
const os = std.os.linux;
const posix = std.posix;

comptime {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux)
        @compileError(
            "hsh has only been testing on linux, it's unknown to work on other OSes, patches and issues very welcome! :)\n",
        );

    if (@hasDecl(os, "getpgid"))
        @compileError("Os already provides custom getpgid");
    if (@hasDecl(os, "getsid"))
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
