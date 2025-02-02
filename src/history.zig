const std = @import("std");
const fs = @import("fs.zig");

pub const History = @This();

alloc: ?std.mem.Allocator = null,
seen_list: ?std.ArrayList([]const u8) = null,
file: ?std.fs.File,

fn seenAdd(self: *History, seen: []const u8) void {
    if (self.seen_list) |*sl| {
        const dupe = self.alloc.?.dupe(u8, seen) catch unreachable;
        sl.append(dupe) catch unreachable;
    }
}

fn seenReset(self: *History) void {
    if (self.seen_list) |*sl| {
        for (sl.items) |item| {
            self.alloc.?.free(item);
        }
        sl.clearAndFree();
    }
}

fn seenExists(self: *History, this: []const u8) bool {
    if (self.seen_list) |*sl| {
        for (sl.items) |item| {
            if (std.mem.eql(u8, item, this)) return true;
        }
    }
    return false;
}

pub fn init(f: ?std.fs.File, a: ?std.mem.Allocator) History {
    return .{
        .file = f,
        .alloc = a,
        .seen_list = if (a) |aa| std.ArrayList([]const u8).init(aa) else null,
    };
}

pub fn atTop(self: *History) bool {
    return 0 == self.file.?.getPos() catch false;
}

/// Returns true when there's is assumed to be more history
/// Final file pos is undefined
fn readLine(self: *History, buffer: ?*std.ArrayList(u8)) !bool {
    var hfile = self.file orelse return false;
    const b = buffer orelse return (hfile.getPos() catch 0) != 0;
    const pos = try hfile.getPos();
    try hfile.reader().readUntilDelimiterArrayList(b, '\n', 1 << 16);
    return pos != 0;
}

/// Returns false if read started at beginning of the file with the assumption
/// there's no more data, if buffer is null, final cursor position is at the
/// start of the line it would have read. If buffer is valid, the cursor
/// position will have increased some amount. (Repeated calls with a valid
/// buffer will likely return the same line)
fn readLinePrev(self: *History, buffer: ?*std.ArrayList(u8)) !bool {
    var hfile = self.file orelse return false;
    const cursor = try hfile.getPos();
    var buf: [1]u8 = undefined;
    while (cursor > 0) {
        hfile.seekBy(-2) catch {
            hfile.seekBy(-1) catch break;
            break;
        };
        _ = try hfile.read(&buf);
        if (buf[0] == '\n') break;
    }
    return self.readLine(buffer);
}

pub fn readAt(self: *History, position: usize, buffer: *std.ArrayList(u8)) bool {
    var hfile = self.file orelse return false;
    var row = position;
    hfile.seekFromEnd(0) catch return false;
    while (row > 0) {
        if (!(readLinePrev(self, null) catch false)) break;
        row -= 1;
    }
    return readLinePrev(self, buffer) catch false;
}

pub fn readAtFiltered(
    self: *History,
    position: usize,
    search: []const u8,
    buffer: *std.ArrayList(u8),
) bool {
    var hfile = self.file orelse return false;
    var row = position;
    hfile.seekFromEnd(-1) catch return false;
    defer self.seenReset();
    while (row > 0) {
        const mdata = readLinePrev(self, buffer) catch return false;
        if (!self.seenExists(buffer.items)) {
            if (std.mem.startsWith(u8, buffer.items, search)) {
                row -= 1;
                self.seenAdd(buffer.items);
            }
        }
        if (!mdata or row == 0) return false;
        // skip this for next read
        _ = readLinePrev(self, null) catch return false;
    }
    return readLinePrev(self, buffer) catch false;
}

/// Moves position of stream without resetting it
fn samesame(any: anytype, line: []const u8) !bool {
    if (line.len > 2048) return false;

    var stream = any;
    const size = line.len + 2;
    const seekby: isize = -@as(isize, @intCast(size));
    stream.seekBy(seekby) catch return false;
    var buf: [2048]u8 = undefined;
    const read = stream.reader().read(buf[0..size]) catch return false;
    if (read < size) return false;
    if (buf[0] != '\n') return false;
    if (!std.mem.eql(u8, buf[1 .. size - 1], line)) return false;
    return true;
}

/// Line.len must be > 0
pub fn push(self: *History, line: []const u8) !void {
    defer self.cnt = 0;
    std.debug.assert(line.len > 0);
    var file = self.file;
    try file.seekFromEnd(0);
    if (try samesame(file, line)) {
        try file.seekFromEnd(0);
        return;
    }

    try file.seekFromEnd(0);
    _ = try file.write(line);
    if (line[line.len - 1] != '\n') _ = try file.write("\n");
    _ = try file.sync();
}

pub fn raze(self: History) void {
    self.file.close();
}

test "samesame" {
    const src: []const u8 =
        \\this is line one
        \\this is line two
        \\this is line three
        \\this is line 4
        \\
    ;
    const line = "this is line 4";

    const fbs = std.io.FixedBufferStream(@TypeOf(src)){
        .buffer = src,
        .pos = src.len,
    };
    //var fbr = fbs.reader();
    //var h = History{ .file = fbs };

    try std.testing.expect(try samesame(fbs, line));
}
