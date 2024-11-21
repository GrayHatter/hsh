const std = @import("std");
const Allocator = std.mem.Allocator;
const Queue = std.TailQueue;
const HSH = @import("hsh.zig").HSH;
const log = @import("log");
const jobs = @import("jobs.zig");

const Self = @This();

const cust_siginfo = extern struct {
    signo: isize,
    errno: isize,
    code: isize,
};

pub const Signal = struct {
    signal: c_int,
    info: std.posix.siginfo_t,
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

var root_alloc: Allocator = undefined;
var alloc: Allocator = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;
var fbuffer: []u8 = undefined;
var queue: Queue(Signal) = Queue(Signal){};

export fn sig_cb(sig: c_int, info: *const std.posix.siginfo_t, _: ?*const anyopaque) callconv(.C) void {
    log.trace(
        \\
        \\ ===================
        \\ = Incoming Signal =
        \\ ===================
        \\ sig int ({})
        \\
    , .{sig});

    switch (sig) {
        std.posix.SIG.INT => flags.int +|= 1,
        std.posix.SIG.WINCH => flags.winch = true,
        else => {
            const sigp = alloc.create(Queue(Signal).Node) catch {
                std.debug.print(
                    "ERROR: unable to allocate memory for incoming signal {}\n",
                    .{sig},
                );
                unreachable;
            };
            sigp.* = Queue(Signal).Node{
                .data = Signal{ .signal = sig, .info = info.* },
            };
            queue.append(sigp);
        },
    }
}

pub fn get() ?Queue(Signal).Node {
    if (queue.pop()) |node| {
        defer alloc.destroy(node);
        return node.*;
    }
    return null;
}

/// TODO change init to accept a GP allocator, and wrap *that* with arena
pub fn init(a: Allocator) !void {
    // Using an arena allocator here to try to solve the deadlock when "freeing"
    // heap space inside a signal.
    root_alloc = a;
    fbuffer = try a.alloc(u8, @sizeOf(Queue(Signal).Node) * 20);
    fba = std.heap.FixedBufferAllocator.init(fbuffer);
    alloc = fba.allocator();

    const SA = std.posix.SA;
    // zsh blocks and unblocks winch signals during most processing, collecting
    // them only when needed. It's likely something we should do as well
    const wanted = [_]u6{
        std.posix.SIG.HUP,
        std.posix.SIG.INT,
        std.posix.SIG.USR1,
        std.posix.SIG.QUIT,
        std.posix.SIG.TERM,
        std.posix.SIG.CHLD,
        std.posix.SIG.CONT,
        std.posix.SIG.TSTP,
        std.posix.SIG.TTIN,
        std.posix.SIG.TTOU,
        std.posix.SIG.WINCH,
    };

    for (wanted) |sig| {
        try std.posix.sigaction(sig, &std.posix.Sigaction{
            .handler = .{ .sigaction = sig_cb },
            .mask = std.posix.empty_sigset,
            .flags = SA.SIGINFO | SA.RESTART,
        }, null);
    }

    const ignored = [_]u6{
        std.posix.SIG.TTIN,
        std.posix.SIG.TTOU,
    };
    for (ignored) |sig| {
        try std.posix.sigaction(sig, &std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.empty_sigset,
            .flags = SA.RESTART,
        }, null);
    }
}

pub const SigEvent = enum {
    none,
    clear,
};

pub fn do(hsh: *HSH) SigEvent {
    while (flags.int > 0) {
        flags.int -|= 1;
        // TODO do something
        //hsh.tkn.reset();
        _ = hsh.draw.write("^C\n\r") catch {};
        //if (hsh.hist) |*hist| {
        //    hist.cnt = 0;
        //}
        return .clear;
    }

    while (get()) |node| {
        var sig = node.data;
        const pid = sig.info.fields.common.first.piduid.pid;
        switch (sig.signal) {
            std.posix.SIG.INT => unreachable,
            std.posix.SIG.WINCH => unreachable,
            std.posix.SIG.CHLD => {
                const child = jobs.get(pid) catch {
                    log.warn("Unknown child on {} {}\n", .{ sig.info.code, pid });
                    continue;
                };
                switch (@as(SI_CODE, @enumFromInt(sig.info.code))) {
                    .STOPPED => {
                        _ = child.pause(&hsh.tty);
                        //hsh.tty.setRaw() catch unreachable;
                    },
                    .EXITED,
                    .KILLED,
                    => {
                        log.debug("Child exit signal\n", .{});
                        // if (child.exit(@intCast(sig.info.fields.common.second.sigchld.status))) {
                        //     hsh.tty.setRaw() catch unreachable;
                        // }
                    },
                    .CONTINUED => {
                        log.debug("Child cont signal\n", .{});
                        //_ = child.forground(&hsh.tty);
                    },
                    .DUMPED, .TRAPPED => {
                        log.err("CHLD CRASH on {}\n", .{pid});
                        child.crash(@intCast(sig.info.fields.common.second.sigchld.status));
                    },
                }
            },
            std.posix.SIG.TSTP => {
                if (pid != 0) {
                    const child = jobs.get(pid) catch {
                        log.warn("Unknown child on {} {}\n", .{ sig.info.code, pid });
                        return .none;
                    };
                    child.waiting();
                }
                log.err("SIGNAL TSTP {} => ({any})", .{ pid, sig.info });
            },
            std.posix.SIG.CONT => {
                log.warn("Unexpected cont from pid({})\n", .{pid});
                hsh.waiting = false;
            },
            std.posix.SIG.USR1 => {
                _ = jobs.haltActive() catch @panic("Signal unable to pause job");
                hsh.tty.setRaw() catch unreachable;
                log.err("Assuming control of TTY!\n", .{});
            },
            std.posix.SIG.TTOU => {
                log.err("TTOU RIP us!\n", .{});
            },
            std.posix.SIG.TTIN => {
                log.err("TTIN RIP us! ({} -> {})\n", .{ hsh.pid, pid });
                hsh.waiting = true;
            },
            else => {
                log.err("Unknown signal {} => ({})\n", .{ sig.signal, sig.info });
                log.err(" dump = {}\n", .{std.fmt.fmtSliceHexUpper(std.mem.asBytes(&sig.info))});
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
    var sigset: std.posix.sigset_t = .{0} ** 32;
    std.os.linux.sigaddset(&sigset, std.posix.SIG.CHLD);
    _ = std.os.linux.sigprocmask(std.posix.SIG.BLOCK, &sigset, null);
}

pub fn unblock() void {
    var sigset: std.posix.sigset_t = .{0} ** 32;
    std.os.linux.sigaddset(&sigset, std.posix.SIG.CHLD);
    _ = std.os.linux.sigprocmask(std.posix.SIG.UNBLOCK, &sigset, null);
}

pub fn raze() void {
    fba.reset();
    root_alloc.free(fbuffer);
}
