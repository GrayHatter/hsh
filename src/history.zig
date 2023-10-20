const std = @import("std");
const fs = @import("fs.zig");
const BufArray = std.ArrayList(u8);

pub const History = @This();

file: std.fs.File,
cnt: usize = 0,

pub fn init(f: std.fs.File) History {
    return .{
        .file = f,
    };
}

pub fn atTop(self: *History) bool {
    return 0 == self.hist.getPos() catch 0;
}

/// Returns true when there's is assumed to be more history
/// Final file pos is undefined
fn readLine(self: *History, buffer: ?*BufArray) !bool {
    if (buffer == null) return try self.file.getPos() != 0;
    var hist = self.file;
    const pos = try hist.getPos();
    try hist.reader().readUntilDelimiterArrayList(buffer.?, '\n', 1 << 16);
    return pos != 0;
}

/// Returns false if read started at beginning of the file with the assumption
/// there's no more data, if buffer is null, final cursor position is at the
/// start of the line it would have read. If buffer is valid, the cursor
/// position will have increased some amount. (Repeated calls with a valid
/// buffer will likely return the same line)
fn readLinePrev(self: *History, buffer: ?*BufArray) !bool {
    var hist = self.file;
    var cursor = try hist.getPos();
    var buf: [1]u8 = undefined;
    while (cursor > 0) {
        hist.seekBy(-2) catch {
            hist.seekBy(-1) catch break;
            break;
        };
        _ = try hist.read(&buf);
        if (buf[0] == '\n') break;
    }
    return self.readLine(buffer);
}

pub fn readAt(self: *History, buffer: *BufArray) bool {
    var hist = self.file;
    var row = self.cnt;
    hist.seekFromEnd(0) catch return false;
    while (row > 0) {
        if (!(readLinePrev(self, null) catch false)) break;
        row -= 1;
    }
    return readLinePrev(self, buffer) catch false;
}

pub fn readAtFiltered(self: *History, buffer: *BufArray, str: []const u8) bool {
    var hist = self.file;
    var row = self.cnt;
    hist.seekFromEnd(-1) catch return false;
    while (row > 0) {
        const mdata = readLinePrev(self, buffer) catch return false;
        if (std.mem.startsWith(u8, buffer.items, str)) row -= 1;
        if (!mdata or row == 0) return false;
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

    var fbs = std.io.FixedBufferStream(@TypeOf(src)){
        .buffer = src,
        .pos = src.len,
    };
    //var fbr = fbs.reader();
    //var h = History{ .file = fbs };

    try std.testing.expect(try samesame(fbs, line));
}
