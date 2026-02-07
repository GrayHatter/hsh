var buffer: [30]Signal = undefined;
var queue: std.ArrayList(Signal) = .initBuffer(&buffer);

const Self = @This();

const cust_siginfo = extern struct {
    signo: isize,
    errno: isize,
    code: isize,
};

pub const Signal = struct {
    signal: system.SIG,
    info: system.siginfo_t,
};

pub const SI_CODE = enum(u6) {
    EXITED = 1,
    KILLED,
    DUMPED,
    TRAPPED,
    STOPPED,
    CONTINUED,
};

var flags: struct {
    int: u8 = 0,
    winch: bool = true,
} = .{};

export fn sig_cb(sig: system.SIG, info: *const system.siginfo_t, _: ?*const anyopaque) callconv(.c) void {
    log.trace(
        \\
        \\ ===================
        \\ = Incoming Signal =
        \\ ===================
        \\ sig int ({})
        \\
    , .{sig});

    switch (sig) {
        system.SIG.INT => flags.int +|= 1,
        system.SIG.WINCH => flags.winch = true,
        else => queue.appendBounded(Signal{ .signal = sig, .info = info.* }) catch unreachable,
    }
}

pub fn get() ?Signal {
    if (queue.pop()) |node| {
        return node;
    }
    return null;
}

pub fn init() !void {
    const SA = system.SA;
    // zsh blocks and unblocks winch signals during most processing, collecting
    // them only when needed. It's likely something we should do as well
    const wanted = [_]system.SIG{
        .HUP, .INT, .USR1, .QUIT, .TERM, .CHLD, .CONT, .TSTP, .TTIN, .TTOU, .WINCH,
    };

    for (wanted) |sig| {
        system.sigaction(sig, &system.Sigaction{
            .handler = .{ .sigaction = sig_cb },
            .mask = system.sigemptyset(),
            .flags = SA.SIGINFO | SA.RESTART,
        }, null);
    }

    const ignored = [_]system.SIG{ .TTIN, .TTOU };
    for (ignored) |sig| {
        system.sigaction(sig, &system.Sigaction{
            .handler = .{ .handler = system.SIG.IGN },
            .mask = system.sigemptyset(),
            .flags = SA.RESTART,
        }, null);
    }
}

pub const SigEvent = enum {
    none,
    clear,
};

pub fn do(hsh: *Hsh) SigEvent {
    while (flags.int > 0) {
        flags.int -|= 1;
        // TODO do something
        //hsh.tkn.reset();
        hsh.draw.writer.writeAll("^C\n\r") catch {};
        //if (hsh.hist) |*hist| {
        //    hist.cnt = 0;
        //}
        return .clear;
    }

    while (get()) |sig| {
        const info = sig.info;
        const first = info.fields.common.first;
        const second = info.fields.common.second;
        const pid = first.piduid.pid;
        switch (sig.signal) {
            .INT => unreachable,
            .WINCH => unreachable,
            .CHLD => {
                const child = hsh.jobs.getPtr(pid) catch {
                    log.warn("Unknown child on {} {}\n", .{ info.code, pid });
                    continue;
                };
                switch (@as(system.CLD, @enumFromInt(info.code))) {
                    .EXITED => child.status = .{ .exited = @intCast(second.sigchld.status) },
                    .KILLED, .DUMPED, .TRAPPED => {
                        log.err("SIGNAL CHLD {} CRASH on {x}\n", .{ child.pid, second.sigchld.status });
                        child.status = .{ .crashed = @intCast(second.sigchld.status) };
                    },
                    .STOPPED => child.status = .{ .paused = .paused },
                    .CONTINUED => child.status = .{ .running = .background }, // just guessing here
                    else => {
                        //log.warn("child code on {}\n", .{info.code});
                        //child.status = .fromsystem.@bitCast(sig.info.fields.common.second.sigchld.status));
                        switch (child.status) {
                            .crashed => |cc| log.err("SIGNAL CHLD {} CRASH on {}\n", .{ child.pid, cc }),
                            .exited => |ec| log.debug("Child exited {}\n", .{ec}),
                            .running => log.debug("Child cont signal\n", .{}),
                            .paused => {},
                            .unknown => unreachable,
                        }
                    },
                }
            },
            .TSTP => {
                if (pid != 0) {
                    const child = hsh.jobs.getPtr(pid) catch {
                        log.warn("Unknown child on {} {}\n", .{ sig.info.code, pid });
                        return .none;
                    };
                    child.status = .fromLinux(@bitCast(sig.info.fields.common.second.sigchld.status));
                }
                log.err("SIGNAL TSTP {} => ({any})", .{ pid, sig.info });
            },
            .CONT => {
                log.warn("Unexpected cont from pid({})\n", .{pid});
                hsh.waiting = false;
            },
            .USR1 => {
                _ = hsh.jobs.haltActive() catch @panic("Signal unable to pause job");
                hsh.tty.set(.raw) catch unreachable;
                log.err("Assuming control of TTY!\n", .{});
            },
            .TTOU => log.err("TTOU RIP us!\n", .{}),
            .TTIN => {
                log.err("TTIN RIP us! ({} -> {})\n", .{ hsh.pid, pid });
                hsh.waiting = true;
            },
            else => {
                log.err("Unknown signal {} => ({})\n", .{ sig.signal, sig.info });
                log.err(" dump = {x}\n", .{std.mem.asBytes(&sig.info)});
                log.err("pid = {}", .{sig.info.fields.common.first.piduid.pid});
                log.err("uid = {}", .{sig.info.fields.common.first.piduid.uid});
                log.err("\n", .{});
                @panic("unexpected signal");
            },
        }
    }
    if (flags.winch) {
        hsh.draw.term_size = hsh.tty.geom() catch unreachable;
        flags.winch = false;
    }
    return .none;
}

pub fn block() void {
    var sigset: system.sigset_t = .{0};
    system.sigaddset(&sigset, system.SIG.CHLD);
    _ = system.sigprocmask(system.SIG.BLOCK, &sigset, null);
}

pub fn unblock() void {
    var sigset: system.sigset_t = .{0};
    system.sigaddset(&sigset, system.SIG.CHLD);
    _ = system.sigprocmask(system.SIG.UNBLOCK, &sigset, null);
}

pub fn raze() void {}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Hsh = @import("hsh.zig");
const log = @import("log.zig");
const system = @import("system.zig");
