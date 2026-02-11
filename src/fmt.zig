pub fn dir(dir_str: []const u8, w: *Writer) !void {
    var str = dir_str;
    if (Fs.g_fs) |fs| {
        if (cutPrefix(u8, str, fs.home.name)) |cut| {
            try w.writeByte('~');
            str = cut;
        }
    }
    try w.print("{s}", .{str});
}

pub const FmtType = struct { bytes: []const u8, fmtFn: *const FmtFn };

pub const FmtFn = fn ([]const u8, *Writer) Writer.Error!void;

pub fn Alt(fmtFn: *const FmtFn) type {
    return struct {
        bytes: []const u8,

        pub inline fn format(self: @This(), w: *Writer) Writer.Error!void {
            try fmtFn(self.bytes, w);
        }
    };
}

const std = @import("std");
const Writer = std.Io.Writer;
const Fs = @import("Fs.zig");
const cutPrefix = std.mem.cutPrefix;
