fd: ?Fs.Named,
reader: Io.File.Reader,
cursor: u64,
fba: FixedBufferAllocator,
lines: ArrayList([]const u8) = .{},

const History = @This();

pub const empty: History = .{
    .fd = null,
    .cursor = 0,
    .reader = undefined,
    .fba = undefined,
};

pub fn init(file: ?Fs.Named.File, a: Allocator, io: Io) History {
    if (file) |f| {
        log.debug("hist file {} name {s}\n", .{ f.file, f.name });
        const stat = f.file.stat(io) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {
                log.err("unable to read hsh history, file system access denied\n", .{});
                return .empty;
            },
            error.Canceled => unreachable,
            error.SystemResources => unreachable,
            error.Unexpected => unreachable,
            error.Streaming => unreachable,
        };
        const cursor = stat.size;
        var h: History = .{
            .fd = .{ .file = f },
            .reader = f.file.reader(io, a.alloc(u8, 65536) catch @panic("OOM")),
            .cursor = cursor,
            .fba = .init(a.alloc(u8, @max(cursor, 65536) * 2) catch @panic("OOM")),
        };
        const fbaa = h.fba.allocator();
        while (h.reader.interface.takeSentinel('\n')) |next| {
            h.lines.append(a, fbaa.dupe(u8, next) catch unreachable) catch @panic("OOM");
        } else |_| {}
        log.debug("hist count {}\n", .{h.lines.items.len});
        return h;
    } else return .empty;
}

pub fn raze(h: History, a: Allocator, io: Io) void {
    if (h.fd) |*f| _ = @constCast(f).close(io) else return;
    if (h.fd) |_| a.free(h.reader.interface.buffer);
}

pub fn readLine(h: *History, ln_num: usize) ?[]const u8 {
    std.debug.assert(ln_num > 0);
    if (ln_num < h.lines.items.len) {
        return h.lines.items[h.lines.items.len - ln_num];
    }
    return null;
}

pub fn readLineFiltered(h: *History, req_ln_num: usize, search: []const u8) ?[]const u8 {
    var ln_num = req_ln_num;
    var seek: usize = 1;
    var line = h.readLine(seek) orelse return null;
    while (ln_num > 1) : (seek += 1) {
        line = h.readLine(seek) orelse return null;
        if (startsWith(u8, line, search)) ln_num -= 1;
    }
    return line;
}

pub const CmdMap = std.StringHashMapUnmanaged(u16);

// CmdMap is returned unsorted
// map keys remained owned by `History`, and do not outlive `History`
pub fn usedCommands(h: *const History, a: Allocator) !CmdMap {
    var set: CmdMap = .{};
    for (h.lines.items) |line| {
        const bin = if (findScalar(u8, line, ' ')) |i| line[0..i] else trim(u8, line, whitespace);
        if (bin.len > 64) continue;
        if (findAny(u8, bin, BREAKING_CHAR)) |_| continue;
        if (startsWith(u8, bin, ".")) continue;
        const gop = try set.getOrPut(a, bin);
        if (gop.found_existing) {
            gop.value_ptr.* +|= 1;
        } else {
            gop.key_ptr.* = bin;
            gop.value_ptr.* = 1;
        }
    }
    return set;
}

pub fn push(h: *History, line: []const u8, io: Io) !void {
    std.debug.assert(line.len > 0);
    if (h.fd) |fd| {
        const length = try fd.file.file.length(io);
        var b: [2048]u8 = undefined;
        var w = fd.file.file.writer(io, &b);
        try w.seekTo(length);
        _ = try w.interface.writeAll(line);
        if (line[line.len - 1] != '\n') {
            _ = try w.interface.writeByte('\n');
        }
        try w.interface.flush();
    }
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Fs = @import("Fs.zig");
const Io = std.Io;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const startsWith = std.mem.startsWith;
const log = @import("log.zig");
const trim = std.mem.trim;
const findScalar = std.mem.findScalar;
const findAny = std.mem.findAny;
const BREAKING_CHAR = @import("token.zig").BREAKING_CHAR[0..];
const whitespace = std.ascii.whitespace[0..];
