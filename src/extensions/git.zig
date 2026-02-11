const git = @This();

pub fn getStatus(w: *std.Io.Writer, io: std.Io) !usize {
    Signals.block();
    defer Signals.unblock();
    const exec = try Exec.childExec(&.{
        "/usr/bin/git",
        "--no-optional-locks",
        "status",
        "--porcelain=v2",
    });
    defer exec.raze();
    defer {
        var job_: Jobs.Job = .init(exec.pid, null);
        _ = job_.waitFor() catch unreachable;
    }

    var reader = exec.stdout.reader(io, &.{});
    return try reader.interface.stream(w, .unlimited);
}

pub const Change = struct {
    version: Version,
    index: Code,
    tree: Code,
    submod: SubModChange,
    modes: FileModes,
    obj_sha: struct {
        head: [20]u8,
        index: [20]u8,
    },
    name: []const u8,
    // non-null when code == .two
    score: ?[]const u8,
    // non-null when code == .two
    orig_name: ?[]const u8,

    pub fn parse(line: [:'\n']const u8) !Change {
        if (line.len < 113) return error.IncompleteLine;

        const ver: Version = switch (line[0]) {
            '1' => .change,
            '2' => .move_copy,
            'u' => .unmerged,
            else => return error.UnsupportedLineVersion,
        };

        const index: Code = @enumFromInt(line[2]);
        const tree: Code = @enumFromInt(line[3]);
        const submod: SubModChange = try .parse(line[5..9]);
        const modes: FileModes = .{
            .head = try .parse(line[10..16]),
            .index = try .parse(line[17..23]),
            .tree = try .parse(line[24..30]),
        };
        var obj_head: [20]u8 = undefined;
        if (line[71] != ' ') @panic("git sha2 detected\n");

        var obj_index: [20]u8 = undefined;
        for (0..20) |i| {
            obj_head[i] = parseInt(u8, line[31 + i * 2 ..][0..2], 16) catch return error.InvalidObjectName;
            obj_index[i] = parseInt(u8, line[72 + i * 2 ..][0..2], 16) catch return error.InvalidObjectName;
        }
        const name: []const u8, const score: ?[]const u8, const orig_name: ?[]const u8 = switch (ver) {
            .change => .{ line[113..], null, null },
            .move_copy => return error.VersionNotImplemented,
            .unmerged => return error.VersionNotImplemented,
            .untracked => return error.VersionNotImplemented,
            .ignored => return error.VersionNotImplemented,
        };

        return .{
            .version = ver,
            .index = index,
            .tree = tree,
            .submod = submod,
            .modes = modes,
            .obj_sha = .{
                .head = obj_head,
                .index = obj_index,
            },
            .name = name,
            .score = score,
            .orig_name = orig_name,
        };
    }

    pub const Version = enum(u8) {
        change = '1',
        move_copy = '2',
        unmerged = 'u',
        untracked = '?',
        ignored = '!',
    };

    pub const Code = enum(u8) {
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

    pub const SubModChange = struct {
        is_mod: bool,
        commit: bool,
        index: bool,
        tree: bool,

        pub fn parse(sm: *const [4]u8) !SubModChange {
            if (sm[0] != 'S' and sm[0] != 'N') return error.InvalidSubModuleCode;
            return .{
                .is_mod = sm[0] == 'S',
                .commit = sm[1] != '.',
                .index = sm[2] != '.',
                .tree = sm[3] != '.',
            };
        }

        pub const none: SubModChange = .{
            .is_mod = false,
            .commit = false,
            .index = false,
            .tree = false,
        };
    };

    pub const FileModes = packed struct {
        head: Mode,
        index: Mode,
        tree: Mode,

        pub const Mode = packed struct {
            ftype: u12,
            u: u4,
            g: u4,
            o: u4,

            pub fn parse(code: *const [6]u8) !Mode {
                return .{
                    .ftype = parseInt(u12, code[0..3], 8) catch return error.InvalidFileMode,
                    .u = parseInt(u4, code[3..4], 8) catch return error.InvalidFileMode,
                    .g = parseInt(u4, code[4..5], 8) catch return error.InvalidFileMode,
                    .o = parseInt(u4, code[5..6], 8) catch return error.InvalidFileMode,
                };
            }
        };
    };
};

test Change {
    const line = "1 .M N... 100644 100644 100644 6da35da1d5045e0cd387718502dff2e9e0b1e417 6da35da1d5045e0cd387718502dff2e9e0b1e417 src/extensions/git.zig\n"[0..135 :'\n'];
    const c: Change = try .parse(line);
    const expected: Change = .{
        .version = .change,
        .index = .nothing_v2,
        .tree = .modified,
        .submod = .none,
        .modes = .{
            .head = .{ .ftype = 0o100, .u = 0o6, .g = 0o4, .o = 0o4 },
            .index = .{ .ftype = 0o100, .u = 0o6, .g = 0o4, .o = 0o4 },
            .tree = .{ .ftype = 0o100, .u = 0o6, .g = 0o4, .o = 0o4 },
        },
        .obj_sha = .{
            .head = .{ 109, 163, 93, 161, 213, 4, 94, 12, 211, 135, 113, 133, 2, 223, 242, 233, 224, 177, 228, 23 },
            .index = .{ 109, 163, 93, 161, 213, 4, 94, 12, 211, 135, 113, 133, 2, 223, 242, 233, 224, 177, 228, 23 },
        },
        .name = "src/extensions/git.zig",
        .score = null,
        .orig_name = null,
    };
    try std.testing.expectEqualDeep(expected, c);
}

test {
    _ = &std.testing.refAllDecls(git);
}

const std = @import("std");
const Reader = std.Io.Reader;
const parseInt = std.fmt.parseInt;
const log = @import("../log.zig");
const Exec = @import("../exec.zig");
const Jobs = @import("../jobs.zig");
const Signals = @import("../signals.zig");
