const std = @import("std");
pub const History = @This();

file: std.fs.File,
cnt: usize = 0,

pub fn atTop(self: *History) bool {
    return 0 == self.hist.getPos() catch 0;
}

pub fn readAt(self: *History, buffer: *std.ArrayList(u8)) !bool {
    var hist = self.file;
    var row = self.cnt;
    try hist.seekFromEnd(-1);
    var cursor = try hist.getEndPos();
    var buf: [1]u8 = undefined;
    while (row > 0 and cursor > 0) {
        hist.seekBy(-2) catch {
            hist.seekBy(-1) catch break;
            break;
        };
        _ = try hist.read(&buf);
        if (buf[0] == '\n') row -= 1;
        cursor = try hist.getPos();
    }
    cursor = try hist.getPos();
    try hist.reader().readUntilDelimiterArrayList(buffer, '\n', 1 << 16);
    return cursor == 0;
}

/// Moves position of stream without resetting it
fn samesame(any: anytype, line: []const u8) !bool {
    if (line.len > 2048) return false;

    var stream = any;
    const size = line.len + 2;

    try stream.seekBy(-@intCast(i64, size));
    var buf: [2048]u8 = undefined;
    const read = try stream.reader().read(buf[0..size]);
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
