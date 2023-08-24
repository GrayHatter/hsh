const std = @import("std");
const Allocator = std.mem.Allocator;
const os = std.os;
const Queue = std.atomic.Queue;
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
    info: os.siginfo_t,
};

pub const SI_CODE = enum(u6) {
    EXITED = 1,
    KILLED,
    DUMPED,
    TRAPPED,
    STOPPED,
    CONTINUED,
};

var root_alloc: Allocator = undefined;
var alloc: Allocator = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;
var fbuffer: []u8 = undefined;
var queue: Queue(Signal) = Queue(Signal).init();

export fn sig_cb(sig: c_int, info: *const os.siginfo_t, _: ?*const anyopaque) callconv(.C) void {
    log.trace(
        \\
        \\ ===================
        \\ = Incoming Signal =
        \\ ===================
        \\ sig int ({})
        \\
    , .{sig});
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
    // Using an arena allocator here to try to solve the deadlock when "freeing"
    // heap space inside a signal.
    root_alloc = a;
    fbuffer = try a.alloc(u8, @sizeOf(Queue(Signal).Node) * 20);
    fba = std.heap.FixedBufferAllocator.init(fbuffer);
    alloc = fba.allocator();

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
            .flags = SA.NOCLDWAIT | SA.RESTART,
        }, null);
    }
}

pub const SigEvent = enum {
    none,
    clear,
};

pub fn do(hsh: *HSH) SigEvent {
    while (get()) |node| {
        var sig = node.data;
        const pid = sig.info.fields.common.first.piduid.pid;
        switch (sig.signal) {
            std.os.SIG.INT => {
                hsh.tkn.reset();
                _ = hsh.draw.write("^C\n\r") catch {};
                if (hsh.hist) |*hist| {
                    hist.cnt = 0;
                }
                return .clear;
            },
            std.os.SIG.CHLD => {
                const child = jobs.get(pid) catch {
                    log.warn("Unknown child on {} {}\n", .{ sig.info.code, pid });
                    continue;
                };
                switch (@as(SI_CODE, @enumFromInt(sig.info.code))) {
                    .STOPPED => {
                        if (child.pause(hsh.tty.getAttr())) {
                            hsh.tty.setRaw() catch unreachable;
                        }
                    },
                    .EXITED,
                    .KILLED,
                    => {
                        if (child.exit(@intCast(sig.info.fields.common.second.sigchld.status))) {
                            hsh.tty.setRaw() catch unreachable;
                        }
                    },
                    .CONTINUED => {
                        if (child.forground()) |tio| {
                            hsh.tty.setTTY(tio);
                        }
                    },
                    .DUMPED, .TRAPPED => {
                        log.err("CHLD CRASH on {}\n", .{pid});
                        child.crash(@intCast(sig.info.fields.common.second.sigchld.status));
                    },
                }
            },
            std.os.SIG.TSTP => {
                if (pid != 0) {
                    const child = jobs.get(pid) catch {
                        log.warn("Unknown child on {} {}\n", .{ sig.info.code, pid });
                        return .none;
                    };
                    child.waiting();
                }
                log.err("SIGNAL TSTP {} => ({any})", .{ pid, sig.info });
            },
            std.os.SIG.CONT => {
                log.warn("Unexpected cont from pid({})\n", .{pid});
                hsh.waiting = false;
            },
            std.os.SIG.WINCH => {
                hsh.draw.term_size = hsh.tty.geom() catch unreachable;
            },
            std.os.SIG.USR1 => {
                _ = jobs.haltActive() catch @panic("Signal unable to pause job");
                hsh.tty.setRaw() catch unreachable;
                log.err("Assuming control of TTY!\n", .{});
            },
            std.os.SIG.TTOU => {
                log.err("TTOU RIP us!\n", .{});
                //hsh.tty.pwnTTY();
            },
            std.os.SIG.TTIN => {
                log.err("TTIN RIP us! ({} -> {})\n", .{ hsh.pid, pid });
                hsh.waiting = true;
                //hsh.tty.pwnTTY();
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
    return .none;
}

pub fn block() void {
    var sigset: std.os.linux.sigset_t = .{0} ** 32;
    std.os.linux.sigaddset(&sigset, os.SIG.CHLD);
    _ = std.os.linux.sigprocmask(os.SIG.BLOCK, &sigset, null);
}

pub fn unblock() void {
    var sigset: std.os.linux.sigset_t = .{0} ** 32;
    std.os.linux.sigaddset(&sigset, os.SIG.CHLD);
    _ = std.os.linux.sigprocmask(os.SIG.UNBLOCK, &sigset, null);
}

pub fn raze() void {
    fba.reset();
    root_alloc.free(fbuffer);
}
