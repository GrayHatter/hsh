const std = @import("std");
pub const History = @This();

hist: std.fs.File,
cnt: usize = 0,

pub fn atTop(self: *History) bool {
    return 0 == self.hist.getPos() catch 0;
}

pub fn readAt(self: *History, buffer: *std.ArrayList(u8)) !bool {
    var hist = self.hist;
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

/// Line.len must be > 0
pub fn push(self: *History, line: []const u8) !void {
    defer self.cnt = 0;
    std.debug.assert(line.len > 0);
    var hist = self.hist;
    try hist.seekFromEnd(0);
    _ = try hist.write(line);
    if (line[line.len - 1] != '\n') _ = try hist.write("\n");
    _ = try hist.sync();
}

pub fn raze(self: History) void {
    self.hist.close();
}
