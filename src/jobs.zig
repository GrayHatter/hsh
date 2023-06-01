const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HSH = @import("hsh.zig").HSH;

pub const Error = error{
    Unknown,
    Memory,
    JobNotFound,
};

pub const Status = enum {
    RIP, // reaped (user notified)
    Ded, // zombie
    Paused, // SIGSTOP
    Waiting, // Stopped needs to output
    Piped,
    Background, // in background
    Running, // foreground
    Child,
    Unknown, // :<
};

pub const Job = struct {
    name: ?[]const u8,
    pid: std.os.pid_t = -1,
    pgid: std.os.pid_t = -1,
    exit_code: u8 = 0,
    status: Status = .Unknown,
    termattr: std.os.termios = undefined,

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
            self.exit_code,
        });
    }
};

pub const Jobs = ArrayList(Job);

pub var jobs: Jobs = undefined;
//const alloc: Allocator = undefined;

pub fn init(a: Allocator) *Jobs {
    //alloc = a;
    jobs = Jobs.init(a);
    return &jobs;
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
            .Paused,
            .Waiting,
            => {
                return j;
            },
            else => continue,
        }
    }
    return null;
}

pub fn contNext(h: *HSH, comptime fg: bool) Error!void {
    const job: ?*Job = try getWaiting();
    if (job) |j| {
        if (fg) {
            h.tty.pushTTY(j.termattr) catch return Error.Memory;
        } else {}
        std.os.kill(j.pid, std.os.SIG.CONT) catch return Error.Unknown;
    }
}

pub fn getBg(a: Allocator) Error!ArrayList(Job) {
    var out = ArrayList(Job).init(a);
    for (jobs.items) |j| {
        switch (j.status) {
            .Background,
            .Waiting,
            .Paused,
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
        if (j.status == .Running) {
            return &j;
        }
    }
    return null;
}
