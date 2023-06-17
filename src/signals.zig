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

var arena: std.heap.ArenaAllocator = undefined;
var alloc: Allocator = undefined;
var queue: Queue(Signal) = Queue(Signal).init();

export fn sig_cb(sig: c_int, info: *const os.siginfo_t, _: ?*const anyopaque) callconv(.C) void {
    if (false) { // signal debugging
        std.debug.print(
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
pub fn init() !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    alloc = arena.allocator();

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

pub fn raze() void {
    arena.deinit();
}
