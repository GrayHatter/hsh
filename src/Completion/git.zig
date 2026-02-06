const Options = ArrayList(Completion.Option);

pub fn suggest(cs: *Completion, tokens: []Token, t_idx: ?usize, fs: Fs, a: Allocator, io: Io) error{OutOfMemory}!void {
    _ = tokens;
    _ = t_idx;
    _ = fs;
    const exec = Exec.child(&.{ "/usr/bin/git", "status", "--porcelain=v2" }, a) catch return;
    defer exec.raze();
    var r_b: [2048]u8 = undefined;
    var reader = exec.stdout.reader(io, &r_b);
    var r = &reader.interface;

    errdefer {
        var job_: Jobs.Job = .init(exec.pid, null);
        _ = job_.waitFor() catch unreachable;
    }
    while (r.takeSentinel('\n')) |line| {
        switch (line[0]) {
            '1' => {
                //log.err("", .{line[2]}
                const staged: Status = @enumFromInt(line[2]);
                _ = staged;
                const unstaged: Status = @enumFromInt(line[3]);
                const filename = line[113..];
                switch (unstaged) {
                    .nothing, .nothing_v2, .ignored => {},
                    else => {
                        try cs.options.append(a, .{ .git = .{
                            .str = try a.dupe(u8, filename),
                            .prefix = &.{},
                            .kind = .file,
                        } });
                    },
                }
            },
            '2' => log.warn("V2 unsupported from git status\n '{s}'", .{line}),
            else => return log.err("Unexpected output from git status\n '{s}'", .{line}),
        }
    } else |_| return;
}

const Status = enum(u8) {
    // ' ' [AMD] not updated
    // M [ MTD] updated in index
    // T [ MTD] type changed in index
    // A [ MTD] added to index
    // D [] deleted from index
    // R [ MTD] renamed in index
    // C [ MTD] copied in index
    // [MTARC] ' ' index and work tree matches
    // [ MTARC] M work tree changed since index
    // [ MTARC] T type changed in work tree since index
    // [ MTARC] D deleted in work tree
    // ' ' R renamed in work tree
    // ' ' C copied in work tree
    // D D unmerged, both deleted
    // A U unmerged, added by us
    // U D unmerged, deleted by them
    // U A unmerged, added by them
    // D U unmerged, deleted by us
    // A A unmerged, both added
    // U U unmerged, both modified
    // ? ? untracked
    // ! ! ignored
    nothing = ' ',
    nothing_v2 = '.',
    modified = 'M',
    type_change = 'T',
    added = 'A',
    deleted = 'D',
    renamed = 'R',
    copied = 'C',
    updated = 'U',
    untracked = '?',
    ignored = '!',
};

pub fn filter(cs: *Completion, tokens: []Token, t_idx: ?usize) void {
    _ = cs;
    _ = tokens;
    _ = t_idx;
    //unreachable;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Completion = @import("../Completion.zig");
const Fs = @import("../fs.zig");
const Token = @import("../token.zig");
const log = @import("../log.zig");
const Exec = @import("../exec.zig");
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const findScalarLast = std.mem.findScalarLast;
const trim = std.mem.trim;
const assert = std.debug.assert;
const Jobs = @import("../jobs.zig");
