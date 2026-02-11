const Options = ArrayList(Completion.Option);

pub fn suggest(cs: *Completion, token: ?*const Token, all_tokens: []Token, fs: Fs, a: Allocator, io: Io) error{OutOfMemory}!void {
    _ = all_tokens;
    _ = fs;
    const F = struct { path: []const u8, name: []const u8, unstaged: ext.git.Change.Code };
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

    var allocating: Writer.Allocating = .init(a);
    defer allocating.deinit();
    _ = ext.git.getStatus(&allocating.writer, io) catch |err| {
        log.err("unable to get git status {}\n", .{err});
        return;
    };
    var r: Io.Reader = .fixed(allocating.writer.buffered());

    while (r.takeSentinel('\n')) |line| {
        const change: ext.git.Change = ext.git.Change.parse(line) catch |err| {
            log.warn("invalid git change line {} '{s}'\n", .{ err, line });
            continue;
        };

        if (dir_prefix) |dir_pre| {
            if (!startsWith(u8, change.name, dir_pre)) continue;
        }
        if (findScalarLast(u8, change.name, '/')) |last| {
            try files.appendBounded(.{
                .path = change.name[0 .. last + 1],
                .name = change.name[last + 1 ..],
                .unstaged = change.tree,
            });
        } else {
            try files.appendBounded(.{
                .path = &.{},
                .name = change.name,
                .unstaged = change.tree,
            });
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
const Writer = Io.Writer;
const ext = @import("../extensions.zig");
const Completion = @import("../Completion.zig");
const Fs = @import("../Fs.zig");
const Token = @import("../token.zig");
const log = @import("../log.zig");
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const findScalarLast = std.mem.findScalarLast;
const trim = std.mem.trim;
const eql = std.mem.eql;
const cutPrefix = std.mem.cutPrefix;
const assert = std.debug.assert;
