jobs: ArrayList(Job),

const Jobs = @This();

pub const Pid = std.posix.pid_t;

pub var global: ?*Jobs = null;

pub const Error = error{
    Unknown,
    OutOfMemory,
    JobNotFound,
};

pub const Status = enum {
    rip, // reaped (user notified)
    crashed, // SIGQUIT
    ded, // zombie
    paused, // SIGSTOP
    waiting, // Stopped needs to output
    piped,
    background, // in background
    running, // foreground
    child,
    unknown, // :<

    const W = std.os.linux.W;

    pub fn fromLinux(s: Status_t) Status {
        if (W.IFSIGNALED(s)) {
            return .crashed;
        } else if (!W.IFEXITED(s)) {
            return .running;
        } else if (W.IFEXITED(s)) {
            return .ded;
        } else if (!W.IFSTOPPED(s)) {
            return .waiting;
        }
        return .unknown;
    }

    pub fn alive(s: Status) bool {
        return switch (s) {
            .paused, .waiting, .piped, .background, .running, .child => true,
            else => false,
        };
    }
};

pub const Job = struct {
    pid: Pid,
    name: ?[]const u8,
    pgid: ?Pid = null,
    exit_code: ?u8 = null,
    status: Status = .unknown,
    termattr: ?std.posix.termios = null,

    pub fn init(pid: Pid, name: ?[]const u8) Job {
        return .{
            .pid = pid,
            .name = name,
        };
    }

    pub fn waitFor(j: *Job) !void {
        const res = try waitpid(j.pid, Status.W.UNTRACED);
        j.status = .fromLinux(res.status);
        switch (j.status) {
            .crashed, .ded => {
                j.exit_code = Status.W.EXITSTATUS(res.status);
            },
            else => |t| log.err("job wait for Not Implmented {s}\n", .{@tagName(t)}),
        }
    }

    pub fn alive(self: Job) bool {
        return self.status.alive();
    }

    pub fn pause(self: *Job, tty: *Tty) bool {
        defer self.status = .paused;
        if (self.status == .running) {
            self.termattr = tty.getAttr();
            return true;
        }
        return false;
    }

    pub fn waiting(self: *Job) void {
        self.status = .waiting;
    }

    pub fn background(self: *Job, tio: std.posix.termios) void {
        self.status = .background;
        self.termattr = tio;
    }

    pub fn forground(self: *Job, tty: *Tty) bool {
        if (!self.alive()) return false;

        if (self.termattr) |tio| {
            tty.setTTY(tio);
        }
        self.status = .running;
        std.posix.kill(self.pid, std.posix.SIG.CONT) catch unreachable;
        return true;
    }

    pub fn exit(self: *Job, code: ?u8) void {
        defer self.status = .ded;
        self.exit_code = code;
    }

    pub fn crash(self: *Job, code: ?u8) void {
        self.status = .crashed;
        self.exit_code = code;
    }

    pub fn format(self: Job, out: *std.Io.Writer) !void {
        try std.fmt.format(out,
            \\Job({s}){{
            \\    name = {s},
            \\    pid = {},
            \\    exit = {},
            \\}}
            \\
        , .{
            @tagName(self.status),
            self.name orelse "none",
            self.pid,
            self.exit_code orelse 0,
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
            .paused,
            .waiting,
            => {
                return job;
            },
            else => continue,
        }
    }
    return null;
}

pub fn haltActive(j: Jobs) Error!usize {
    var count: usize = 0;
    for (j.jobs.items) |*job| {
        if (job.status == .running) {
            job.status = .paused;
            // TODO send signal
            count += 1;
        }
    }
    return count;
}

pub fn getBgPtr(j: Jobs) ?*Job {
    for (j.jobs.items) |*job| {
        switch (job.status) {
            .background,
            .waiting,
            .paused,
            => {
                return job;
            },
            else => continue,
        }
    }
    return null;
}

pub fn getBg(j: Jobs) ?*const Job {
    for (j.jobs.items) |*job| {
        switch (job.status) {
            .background,
            .waiting,
            .paused,
            => {
                return job;
            },
            else => continue,
        }
    }
    return null;
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
        const rc = std.os.linux.waitpid(pid, &status, coerced_flags);
        switch (std.posix.errno(rc)) {
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

    const s = try waitpid(pid, std.posix.W.UNTRACED);
    log.debug("status {} {} \n", .{ s.pid, s.status });
    if (s.pid == pid) {
        if (j.getPtr(s.pid)) |job| {
            if (std.posix.W.IFSIGNALED(s.status)) {
                job.crash(0);
            } else if (std.os.linux.W.IFSTOPPED(s.status)) {
                Tty.current().waitForFg();
                log.err("stop sig {}\n", .{std.os.linux.W.STOPSIG(s.status)});
                _ = job.pause(Tty.current());
                Tty.current().setRaw() catch unreachable;
            } else if (std.os.linux.W.IFEXITED(s.status)) {
                job.exit(std.os.linux.W.EXITSTATUS(s.status));
            }
            return job;
        } else |_| {
            log.debug("can't get job {} did get {} \n", .{ pid, s.pid });
        }
    } else log.debug("search != found {} did get {} \n", .{ pid, s.pid });
    return Error.JobNotFound;
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
