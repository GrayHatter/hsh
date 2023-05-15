const std = @import("std");

pub fn readAt(cnt: usize, hist: std.fs.File, buffer: *std.ArrayList(u8)) !bool {
    var row = cnt;
    var len: usize = try hist.getEndPos();
    try hist.seekFromEnd(-1);
    var pos = len;
    var buf: [1]u8 = undefined;
    while (row > 0 and pos > 0) {
        hist.seekBy(-2) catch {
            hist.seekBy(-1) catch break;
            break;
        };
        _ = try hist.read(&buf);
        if (buf[0] == '\n') row -= 1;
        pos = try hist.getPos();
    }
    pos = try hist.getPos();
    try hist.reader().readUntilDelimiterArrayList(buffer, '\n', 1 << 16);
    return pos == 0;
}
