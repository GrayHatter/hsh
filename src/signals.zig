const std = @import("std");
const Allocator = std.mem.Allocator;
const os = std.os;
const Queue = std.atomic.Queue;

const Self = @This();

const cust_siginfo = extern struct {
    signo: isize,
    errno: isize,
    code: isize,
};

pub const Signal = struct {
    signal: c_int,
    info: os.siginfo_t,
};

var alloc: Allocator = undefined;
var queue: *Queue(Signal) = undefined;

export fn sig_cb(sig: c_int, info: *const os.siginfo_t, _: ?*const anyopaque) callconv(.C) void {
    const sigp = alloc.alloc(Queue(Signal).Node, 1) catch {
        std.debug.print(
            "ERROR: unable to allocate memory for incoming signal {}\n",
            .{sig},
        );
        unreachable;
    };
    sigp[0].data.signal = sig;
    sigp[0].data.info = info.*;
    queue.put(&sigp[0]);
}

pub fn init(a: Allocator, q: *Queue(Signal)) !void {
    alloc = a;
    queue = q;

    // zsh blocks and unblocks winch signals during most processing, collecting
    // them only when needed. It's likely something we should do as well
    const signals = [_]u6{
        os.SIG.HUP,
        os.SIG.INT,
        os.SIG.USR1,
        os.SIG.QUIT,
        os.SIG.TERM,
        os.SIG.CHLD,
        os.SIG.CONT,
        os.SIG.TSTP,
        os.SIG.WINCH,
    };

    const SA = std.os.linux.SA;
    for (signals) |sig| {
        try os.sigaction(sig, &os.Sigaction{
            .handler = .{ .sigaction = sig_cb },
            .mask = os.empty_sigset,
            .flags = SA.SIGINFO | SA.NOCLDWAIT,
        }, null);
    }
}
