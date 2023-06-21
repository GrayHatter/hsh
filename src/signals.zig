const std = @import("std");
const Allocator = std.mem.Allocator;
const os = std.os;
const Queue = std.atomic.Queue;
const log = @import("log");

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
var queue: Queue(Signal) = Queue(Signal).init();

export fn sig_cb(sig: c_int, info: *const os.siginfo_t, _: ?*const anyopaque) callconv(.C) void {
    if (false) { // signal debugging
        log.trace(
            \\
            \\ ===================
            \\ = Incoming Signal =
            \\ ===================
            \\ sig int {}
            \\
        , .{sig});
    }
    const sigp = alloc.create(Queue(Signal).Node) catch {
        std.debug.print(
            "ERROR: unable to allocate memory for incoming signal {}\n",
            .{sig},
        );
        unreachable;
    };
    sigp.* = Queue(Signal).Node{
        .data = Signal{
            .signal = sig,
            .info = info.*,
        },
    };

    queue.put(sigp);
}

pub fn get() ?Queue(Signal).Node {
    var node = queue.get() orelse return null;
    defer alloc.destroy(node);
    return node.*;
}

/// TODO change init to accept a GP allocator, and wrap *that* with arena
pub fn init(a: Allocator) !void {
    alloc = a;

    const SA = std.os.linux.SA;
    // zsh blocks and unblocks winch signals during most processing, collecting
    // them only when needed. It's likely something we should do as well
    const wanted = [_]u6{
        os.SIG.HUP,
        os.SIG.INT,
        os.SIG.USR1,
        os.SIG.QUIT,
        os.SIG.TERM,
        os.SIG.CHLD,
        os.SIG.CONT,
        os.SIG.TSTP,
        os.SIG.TTIN,
        os.SIG.TTOU,
        os.SIG.WINCH,
    };

    for (wanted) |sig| {
        try os.sigaction(sig, &os.Sigaction{
            .handler = .{ .sigaction = sig_cb },
            .mask = os.empty_sigset,
            .flags = SA.SIGINFO | SA.NOCLDWAIT | SA.RESTART,
        }, null);
    }

    const ignored = [_]u6{
        os.SIG.TTIN,
        os.SIG.TTOU,
    };
    for (ignored) |sig| {
        try os.sigaction(sig, &os.Sigaction{
            .handler = .{ .handler = os.SIG.IGN },
            .mask = os.empty_sigset,
            .flags = SA.SIGINFO | SA.NOCLDWAIT | SA.RESTART,
        }, null);
    }
}

pub fn raze() void {
    //arena.deinit();
}
