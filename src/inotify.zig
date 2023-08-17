const std = @import("std");
const log = @import("log");
const fs = @import("fs.zig");

pub const Event = enum {
    open,
    write,
};

const INotify = @This();
pub const in_callback = *const fn (evt: Event) void;

wdes: i32,
path: []const u8,
callback: ?in_callback,

pub fn init(infd: i32, path: []const u8, cb: ?in_callback) !INotify {
    return .{
        .wdes = try std.os.inotify_add_watch(infd, path, std.os.linux.IN.ALL_EVENTS),
        .path = path,
        .callback = cb,
    };
}

pub fn raze(self: *INotify, a: std.mem.Allocator) void {
    a.free(self.path);
}

pub fn event(self: *INotify, inevt: *const std.os.linux.inotify_event) void {
    const evt: Event = if (inevt.mask == 32) .open else .write;
    log.debug("inotify event for {} {any}\n", .{ self.wdes, inevt });
    if (self.callback) |cb| {
        cb(evt);
    }
}
