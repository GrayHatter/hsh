buffer: [256]u8 = undefined,
next: []const u8 = &.{},
enabled: bool = true,

const Git = @This();

pub fn init(g: *Git) error{InitFailed}!void {
    g.* = .{};
}

pub fn fetch(g: *const Git) Lexeme {
    if (g.enabled)
        return .str(g.next)
    else
        return .str(&.{});
}

pub fn update(g: *Git, _: *Hsh, a: std.mem.Allocator, io: Io) error{ OutOfMemory, UpdateFailed }!void {
    var allocating: Writer.Allocating = try .initCapacity(a, 8196);
    defer allocating.deinit();
    _ = ext.git.getStatus(&allocating.writer, io) catch |err| switch (err) {
        error.EndOfStream => {},
        else => {
            log.err("unable to get git status {}\n", .{err});
            return;
        },
    };

    var index: usize = 0;
    var tree: usize = 0;
    var r: Io.Reader = .fixed(allocating.writer.buffered());
    while (r.takeSentinel('\n')) |line| {
        const change: ext.git.Change = ext.git.Change.parse(line) catch |err| {
            log.warn("invalid git change line {} '{s}'\n", .{ err, line });
            continue;
        };
        switch (change.index) {
            .nothing, .nothing_v2, .ignored => {},
            else => index += 1,
        }
        switch (change.tree) {
            .nothing, .nothing_v2, .ignored => {},
            else => tree += 1,
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => log.warn("status error {}\n", .{err}),
    }

    var name_b: [60]u8 = undefined;
    const name: []const u8 = ext.git.getBranch(&name_b, io) catch &.{};

    var idx_b: [8]u8 = undefined;
    var tree_b: [8]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_b, "{}", .{index}) catch unreachable;
    const tree_str = std.fmt.bufPrint(&tree_b, "{}", .{tree}) catch unreachable;
    if (index > 0 or tree > 0) {
        g.next = std.fmt.bufPrint(&g.buffer, " [{f}|{f}|{f}]", .{
            Lexeme.styled(name, .red),
            Lexeme.styled(idx_str, if (index > 0) .red else .green),
            Lexeme.styled(tree_str, if (tree > 0) .red else .green),
        }) catch unreachable;
    } else {
        g.next = std.fmt.bufPrint(&g.buffer, " [{f}]", .{Lexeme.styled(name, .green)}) catch unreachable;
    }
}

pub fn raze(_: *Git, _: std.mem.Allocator) void {}

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Hsh = @import("../hsh.zig");
const context = @import("../context.zig");
const exec = @import("../exec.zig");
const Lexeme = @import("../draw.zig").Lexeme;
const ext = @import("../extensions.zig");
const log = @import("../log.zig");
