fd: ?Io.File,
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
            .fd = f.file,
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
    if (h.fd) |f| f.close(io) else return;
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

pub const CmdMap = std.StringHashMapUnmanaged(u8);

// CmdMap is returned unsorted
// map keys remained owned by `History`, and do not outlive `History`
pub fn usedCommands(h: *const History, a: Allocator) !CmdMap {
    var set: CmdMap = .{};
    for (h.lines.items) |line| {
        const bin = if (findScalar(u8, line, ' ')) |i| line[0..i] else trim(u8, line, whitespace);
        if (findAny(u8, bin, BREAKING_CHAR)) |_| continue;
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

// /// Moves position of stream without resetting it
// fn samesame(any: anytype, line: []const u8) !bool {
//     if (line.len > 2048) return false;
//
//     var stream = any;
//     const size = line.len + 2;
//     const seekby: isize = -@as(isize, @intCast(size));
//     stream.seekBy(seekby) catch return false;
//     var buf: [2048]u8 = undefined;
//     const read = stream.reader().read(buf[0..size]) catch return false;
//     if (read < size) return false;
//     if (buf[0] != '\n') return false;
//     if (!std.mem.eql(u8, buf[1 .. size - 1], line)) return false;
//     return true;
// }

// Line.len must be > 0
//pub fn push(self: *History, line: []const u8) !void {
//    defer self.cnt = 0;
//    std.debug.assert(line.len > 0);
//    var file = self.file;
//    try file.seekFromEnd(0);
//    if (try samesame(file, line)) {
//        try file.seekFromEnd(0);
//        return;
//    }
//
//    try file.seekFromEnd(0);
//    _ = try file.write(line);
//    if (line[line.len - 1] != '\n') _ = try file.write("\n");
//    _ = try file.sync();
//}

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
