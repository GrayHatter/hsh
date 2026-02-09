const Options = ArrayList(Completion.Option);

pub fn suggest(cs: *Completion, token: ?*const Token, all_tokens: []Token, fs: Fs, a: Allocator, io: Io) error{OutOfMemory}!void {
    _ = all_tokens;
    _ = fs;
    Signals.block();
    defer Signals.unblock();
    const exec = Exec.child(&.{ "/usr/bin/git", "status", "--porcelain=v2" }, a) catch return;
    defer exec.raze();
    var reader = exec.stdout.reader(io, try a.alloc(u8, 65536));
    defer a.free(reader.interface.buffer);
    var r = &reader.interface;
    defer {
        var job_: Jobs.Job = .init(exec.pid, null);
        _ = job_.waitFor() catch unreachable;
    }

    const F = struct { path: []const u8, name: []const u8, unstaged: Status };
    var files_b: [256]F = undefined;
    var files: ArrayList(F) = .initBuffer(&files_b);

    var dir_prefix: ?[]const u8 = null;
    var token_search: ?[]const u8 = null;
    if (token) |t| {
        if (findScalarLast(u8, t.str, '/')) |last| {
            dir_prefix = t.str[0 .. last + 1];
            if (last + 1 < t.str.len) {
                token_search = t.str[last + 1 ..];
            }
        }
    }

    log.debug("git '{s}' '{s}'\n", .{
        dir_prefix orelse "[null]",
        token_search orelse "[null]",
    });

    while (r.takeSentinel('\n')) |line| {
        switch (line[0]) {
            '1' => {
                //log.err("", .{line[2]}
                const staged: Status = @enumFromInt(line[2]);
                _ = staged;
                const unstaged: Status = @enumFromInt(line[3]);
                const filename = line[113..];
                if (dir_prefix) |dir_pre| {
                    if (!startsWith(u8, filename, dir_pre)) continue;
                }
                switch (unstaged) {
                    .nothing, .nothing_v2, .ignored => {},
                    else => {
                        if (findScalarLast(u8, filename, '/')) |last| {
                            try files.appendBounded(.{
                                .path = filename[0 .. last + 1],
                                .name = filename[last + 1 ..],
                                .unstaged = unstaged,
                            });
                        } else {
                            try files.appendBounded(.{
                                .path = &.{},
                                .name = filename,
                                .unstaged = unstaged,
                            });
                        }
                    },
                }
            },
            '2' => log.warn("V2 unsupported from git status\n '{s}'", .{line}),
            else => return log.err("Unexpected output from git status\n '{s}'", .{line}),
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return,
    }

    if (dir_prefix) |dir_pre| {
        var last_path: []const u8 = &.{};
        for (files.items) |file| {
            if (cutPrefix(u8, file.path, dir_pre)) |cut| {
                log.debug("git 4 '{s}' ('{s}') '{s}'\n", .{ file.path, dir_pre, cut });
                if (cut.len > 0) {
                    const str = if (findScalar(u8, cut, '/')) |slash|
                        cut[0..slash]
                    else
                        cut;
                    log.debug("git 8 '{s}' '{s}'\n", .{ last_path, str });
                    if (last_path.len > 0 and eql(u8, last_path, str)) continue;
                    last_path = str;
                    if (str.len > 0) {
                        try cs.options.append(a, .{
                            .str = try a.dupe(u8, str),
                            .prefix = &.{},
                            .kind = .{ .git = .dir },
                        });
                    } else {
                        try cs.options.append(a, .{
                            .str = try a.dupe(u8, file.name),
                            .prefix = file.path,
                            .kind = .{ .git = .file },
                        });
                    }
                } else {
                    try cs.options.append(a, .{
                        .str = try a.dupe(u8, file.name),
                        .prefix = file.path,
                        .kind = .{ .git = .file },
                    });
                }
            } else {
                log.debug("git 3 '{s}'\n", .{file.path});
                try cs.options.append(a, .{
                    .str = try a.dupe(u8, file.name),
                    .prefix = try a.dupe(u8, file.path),
                    .kind = .{ .git = .file },
                });
            }
        }
    } else {
        var last_path: []const u8 = &.{};
        for (files.items) |file| {
            log.debug("git 2 '{s}'\n", .{file.path});
            const str = if (findScalar(u8, file.path, '/')) |slash|
                file.path[0..slash]
            else
                file.path;
            if (last_path.len > 0 and eql(u8, last_path, str)) continue;

            try cs.options.append(a, .{
                .str = try a.dupe(u8, str),
                .prefix = &.{},
                .kind = .{ .git = .dir },
            });
            last_path = str;
        }
    }
    log.debug("git count '{}'\n", .{cs.options.items.len});
    //for (cs.options.items) |item| {
    //    log.debug("git item '{}'\n", .{item});
    //}
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

pub fn filter(cs: *Completion, cur_token: ?*const Token, all_tokens: []Token) void {
    _ = cs;
    _ = cur_token;
    _ = all_tokens;
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
const eql = std.mem.eql;
const cutPrefix = std.mem.cutPrefix;
const assert = std.debug.assert;
const Jobs = @import("../jobs.zig");
const Signals = @import("../signals.zig");
