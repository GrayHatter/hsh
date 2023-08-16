const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HSH = @import("hsh.zig").HSH;
const SI_CODE = @import("signals.zig").SI_CODE;

pub const Error = error{
    Unknown,
    Memory,
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
};

pub const Job = struct {
    name: ?[]const u8,
    pid: std.os.pid_t = -1,
    pgid: std.os.pid_t = -1,
    exit_code: ?u8 = null,
    status: Status = .unknown,
    termattr: ?std.os.termios = null,

    pub fn alive(self: Job) bool {
        return switch (self.status) {
            .paused,
            .waiting,
            .piped,
            .background,
            .running,
            .child,
            => true,
            else => false,
        };
    }

    pub fn pause(self: *Job, tio: std.os.termios) bool {
        defer self.status = .paused;
        if (self.status == .running) {
            self.termattr = tio;
            return true;
        }
        return false;
    }

    pub fn waiting(self: *Job) void {
        self.status = .waiting;
    }

    pub fn background(self: *Job, tio: std.os.termios) void {
        self.status = .background;
        self.termattr = tio;
    }

    pub fn forground(self: *Job) ?std.os.termios {
        defer self.status = .running;
        if (self.status == .background) return self.termattr;
        return null;
    }

    pub fn exit(self: *Job, code: ?u8) bool {
        defer self.status = .ded;
        self.exit_code = code;
        return self.status == .running;
    }

    pub fn crash(self: *Job, code: ?u8) void {
        self.status = .crashed;
        self.exit_code = code;
    }

    pub fn format(self: Job, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
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

pub const Jobs = ArrayList(Job);

pub var jobs: Jobs = undefined;

pub fn init(a: Allocator) *Jobs {
    jobs = Jobs.init(a);
    return &jobs;
}

pub fn raze(a: Allocator) void {
    for (jobs.items) |*job| {
        a.free(job.*.name.?);
    }
    jobs.clearAndFree();
}

pub fn get(jid: std.os.pid_t) Error!*Job {
    for (jobs.items) |*j| {
        if (j.*.pid == jid) {
            return j;
        }
    }
    return Error.JobNotFound;
}

pub fn add(j: Job) Error!void {
    jobs.append(j) catch return Error.Memory;
}

pub fn getWaiting() Error!?*Job {
    for (jobs.items) |*j| {
        switch (j.status) {
            .paused,
            .waiting,
            => {
                return j;
            },
            else => continue,
        }
    }
    return null;
}

pub fn haltActive() Error!usize {
    var count: usize = 0;
    for (jobs.items) |*j| {
        if (j.*.status == .running) {
            j.status = .paused;
            // TODO send signal
            count += 1;
        }
    }
    return count;
}

pub fn contNext(h: *HSH, comptime fg: bool) Error!void {
    const job: ?*Job = try getWaiting();
    if (job) |j| {
        if (fg) {
            if (j.termattr) |tio| {
                h.tty.setTTY(tio);
            }
        } else {}
        std.os.kill(j.pid, std.os.SIG.CONT) catch return Error.Unknown;
    }
}

pub fn getBg(a: Allocator) Error!ArrayList(Job) {
    var out = ArrayList(Job).init(a);
    for (jobs.items) |j| {
        switch (j.status) {
            .background,
            .waiting,
            .paused,
            => {
                out.append(j) catch return Error.Memory;
            },
            else => continue,
        }
    }
    return out;
}

pub fn getFg() ?*const Job {
    for (jobs.items) |j| {
        if (j.status == .running) {
            return &j;
        }
    }
    return null;
}

/// waits for the job to complete, and reports true if it exited successfully
pub fn waitFor(h: *HSH, jid: std.os.pid_t) Error!bool {
    var job = try get(jid);
    while (job.alive()) _ = h.spin();
    return job.exit_code == 0;
}
