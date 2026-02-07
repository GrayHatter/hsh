jobs: ArrayList(Job),

const Jobs = @This();

pub const Pid = system.pid_t;

pub var global: ?*Jobs = null;

pub const Error = error{
    Unknown,
    OutOfMemory,
    JobNotFound,
};

pub const Status = union(enum) {
    paused: enum {
        paused, //waiting for signal
        waiting, // blocked with output
    },
    running: enum { forground, background, pipeline },
    exited: u8,
    crashed: u8,
    unknown: void, // :<

    const W = system.W;

    pub fn fromLinux(s: Status_t) Status {
        return if (W.IFSIGNALED(s))
            .{ .crashed = @intCast(W.EXITSTATUS(s)) }
        else if (W.IFEXITED(s))
            .{ .exited = @intCast(W.EXITSTATUS(s)) }
        else if (W.IFSTOPPED(s))
            .{ .paused = .waiting }
        else if (s & 0xffff == 0xffff) // IFCONTINUED
            .{ .running = .background } // Just guessing :/
        else
            .unknown;
    }

    pub fn alive(s: Status) bool {
        return switch (s) {
            .paused, .running => true,
            .crashed, .exited, .unknown => false,
        };
    }
};

pub const Job = struct {
    pid: Pid,
    name: ?[]const u8,
    pgid: ?Pid = null,
    status: Status = .unknown,
    termattr: ?system.termios = null,

    pub fn init(pid: Pid, name: ?[]const u8) Job {
        return .{
            .pid = pid,
            .name = name,
        };
    }

    pub fn waitFor(j: *Job) !void {
        const res = try waitpid(j.pid, Status.W.UNTRACED);
        j.status = .fromLinux(res.status);
    }

    pub fn alive(self: Job) bool {
        return self.status.alive();
    }

    pub fn sendPause(self: *Job, tty: *Tty) bool {
        defer self.status = .paused;
        if (self.status == .running) {
            self.termattr = tty.getAttr();
            return true;
        }
        return false;
    }

    pub fn sendBackground(self: *Job, tio: system.termios) !void {
        self.status = .background;
        self.termattr = tio;
        comptime unreachable; // send signal
    }

    pub fn sendForground(j: *Job, tty: *Tty) !void {
        std.debug.assert(j.status == .paused or j.status.running == .background);
        if (j.termattr) |tio| try tty.set(.child(tio));
        j.status = .{ .running = .forground };
        try system.kill(j.pid, system.SIG.CONT);
    }

    pub fn format(self: Job, out: *std.Io.Writer) !void {
        try std.fmt.format(out,
            \\Job({s}){{
            \\    name = {s},
            \\    pid = {},
            \\    exit = {any},
            \\}}
            \\
        , .{
            @tagName(self.status),
            self.name orelse "none",
            self.pid,
            self.status,
        });
    }
};

pub fn init() Jobs {
    return .{ .jobs = .{} };
}

pub fn raze(j: *Jobs, a: Allocator) void {
    for (j.jobs.items) |job| a.free(job.name.?);
    j.jobs.clearAndFree(a);
}

pub fn getPtr(j: *Jobs, jid: Pid) Error!*Job {
    for (j.jobs.items) |*job| {
        if (job.pid == jid) {
            return job;
        } else log.debug("job search {} {} \n", .{ job.pid, jid });
    }
    return error.JobNotFound;
}

pub fn get(j: Jobs, jid: Pid) Error!*const Job {
    for (j.jobs.items) |*job| {
        if (job.pid == jid) {
            return job;
        } else log.debug("job search {} {} \n", .{ job.pid, jid });
    }
    return error.JobNotFound;
}

pub fn add(jobs: *Jobs, j: Job, a: Allocator) !void {
    try jobs.jobs.append(a, j);
}

pub fn getWaiting(j: Jobs) Error!?*const Job {
    for (j.jobs.items) |*job| {
        switch (job.status) {
            .paused => return job,
            else => continue,
        }
    }
    return null;
}

pub fn haltActive(j: Jobs) Error!usize {
    var count: usize = 0;
    for (j.jobs.items) |*job| {
        if (job.status == .running) {
            job.status = .{ .paused = .paused };
            // TODO send signal
            count += 1;
        }
    }
    return count;
}

pub fn getBgPtr(j: *Jobs) ?*Job {
    for (j.jobs.items) |*job| switch (job.status) {
        .running => |run| switch (run) {
            .background, .pipeline => return job,
            .forground => continue,
        },
        .paused => return job,
        else => continue,
    };
    return null;
}

pub fn getBg(j: *const Jobs) ?*const Job {
    return @constCast(j).getBgPtr();
}

pub fn getFg(j: Jobs) ?*const Job {
    for (j.jobs.items) |*job| {
        if (job.status == .running) {
            return job;
        }
    }
    return null;
}

/// I'd like to delete these, but also, I don't want hsh to be tied to zig
/// master every time I fix something in stdlib.
const builtin = @import("builtin");
const WaitError = if (@hasDecl(std.os, "WaitError")) std.os.WaitError else error{
    CHILD,
};

pub const WaitResult = struct {
    pid: Pid,
    status: u32,
};

fn waitpid(pid: Pid, flags: u32) WaitError!WaitResult {
    var status: Status_t = undefined;
    const coerced_flags = flags;
    while (true) {
        const rc = system.waitpid(pid, &status, coerced_flags);
        switch (system.errno(rc)) {
            .SUCCESS => return .{
                .pid = @as(Pid, @intCast(rc)),
                .status = @as(u32, @bitCast(status)),
            },
            .INTR => continue,
            .CHILD => return error.CHILD,
            .INVAL => unreachable, // Invalid flags.
            else => unreachable,
        }
    }
}

pub fn waitForFg(j: *Jobs) void {
    while (j.getFg()) |fg| {
        log.debug("Waiting on {}\n", .{fg.pid});
        _ = j.waitFor(fg.pid) catch {
            // Debug because jobs aren't created in some exec cases (which? ¯\_(ツ)_/¯)
            log.debug(
                "waitFor didn't find child \"{s}\" {}\n",
                .{ fg.name orelse "Unknown Job", fg.pid },
            );
            (j.getPtr(fg.pid) catch unreachable).status = .unknown;
        };
    }
}

pub fn waitFor(j: *Jobs, pid: Pid) !*const Job {
    if (pid > 0) {
        var job = try j.get(pid);
        if (!job.status.alive()) {
            return job;
        }
    }

    const s = try waitpid(pid, system.W.UNTRACED);
    log.debug("status {} {} \n", .{ s.pid, s.status });
    if (s.pid == pid) {
        if (j.getPtr(s.pid)) |job| {
            job.status = .fromLinux(s.status);
            const tty = Tty.current();
            switch (job.status) {
                .paused => |p| {
                    tty.waitForFg();
                    log.err("paused sig {s}\n", .{@tagName(p)});
                    tty.set(.raw) catch unreachable;
                },
                .crashed => |cc| {
                    tty.waitForFg();
                    log.err("crashed with sig {}\n", .{cc});
                    tty.set(.raw) catch unreachable;
                },
                .exited => |ec| {
                    tty.waitForFg();
                    log.debug("stop sig {}\n", .{ec});
                    tty.set(.raw) catch unreachable;
                },
                else => unreachable,
            }

            return job;
        } else |_| log.debug("can't get job {} did get {} \n", .{ pid, s.pid });
    } else log.debug("search != found {} did get {} \n", .{ pid, s.pid });
    return error.JobNotFound;
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const Status_t = if (builtin.link_libc) c_int else u32;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Hsh = @import("hsh.zig");
const SI_CODE = @import("signals.zig").SI_CODE;
const log = @import("log.zig");
const Tty = @import("tty.zig");
const system = @import("system.zig");
