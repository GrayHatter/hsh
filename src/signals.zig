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

const SI_CODE = enum(u6) {
    EXITED = 1,
    KILLED,
    DUMPED,
    TRAPPED,
    STOPPED,
    CONTINUED,
};

var arena: std.heap.ArenaAllocator = undefined;
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
    // Using an arena allocator here to try to solve the deadlock when "freeing"
    // heap space inside a signal.
    arena = std.heap.ArenaAllocator.init(a);
    alloc = arena.allocator();

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
                hsh.hist.?.cnt = 0;
                return .clear;
            },
            std.os.SIG.CHLD => {
                const child = jobs.get(pid) catch {
                    // TODO we should never not know about a job, but it's not a
                    // reason to die just yet.
                    //std.debug.print("Unknown child on {} {}\n", .{ sig.info.code, pid });
                    continue;
                };
                switch (@as(SI_CODE, @enumFromInt(sig.info.code))) {
                    SI_CODE.STOPPED => {
                        if (child.*.status == .Running) {
                            child.*.termattr = hsh.tty.popTTY() catch unreachable;
                        }
                        child.*.status = .Paused;
                    },
                    SI_CODE.EXITED,
                    SI_CODE.KILLED,
                    => {
                        if (child.*.status == .Running) {
                            child.*.termattr = hsh.tty.popTTY() catch |e| {
                                std.debug.print("Unable to pop for (reasons) {}\n", .{e});
                                unreachable;
                            };
                        }
                        const status = sig.info.fields.common.second.sigchld.status;
                        child.*.exit_code = @intCast(status);
                        child.*.status = .Ded;
                    },
                    SI_CODE.CONTINUED => {
                        child.*.status = .Running;
                    },
                    SI_CODE.DUMPED,
                    SI_CODE.TRAPPED,
                    => {
                        log.err("CHLD CRASH on {}\n", .{pid});
                        child.*.status = .Crashed;
                        const status = sig.info.fields.common.second.sigchld.status;
                        child.*.exit_code = @intCast(status);
                    },
                }
            },
            std.os.SIG.TSTP => {
                if (pid != 0) {
                    const child = jobs.get(pid) catch {
                        // TODO we should never not know about a job, but it's not a
                        // reason to die just yet.
                        std.debug.print("Unknown child on {} {}\n", .{ pid, sig.info.code });
                        return .none;
                    };
                    if (child.*.status == .Running) {
                        child.*.termattr = hsh.tty.popTTY() catch unreachable;
                    }
                    child.*.status = .Waiting;
                }
                log.err("SIGNAL TSTP {} => ({any})", .{ pid, sig.info });
                //std.debug.print("\n{}\n", .{child});
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
                hsh.tty.pushRaw() catch unreachable;
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
                std.debug.print("\n\rUnknown signal {} => ({})\n", .{ sig.signal, sig.info });
                std.debug.print("\n\r dump = {}\n", .{std.fmt.fmtSliceHexUpper(std.mem.asBytes(&sig.info))});
                std.debug.print("\n\rpid = {}", .{sig.info.fields.common.first.piduid.pid});
                std.debug.print("\n\ruid = {}", .{sig.info.fields.common.first.piduid.uid});
                std.debug.print("\n", .{});
                @panic("unexpected signal");
            },
        }
    }
    return .none;
}

pub fn raze() void {
    arena.deinit();
}
