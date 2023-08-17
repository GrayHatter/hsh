const std = @import("std");
const log = @import("log");
const fs = @import("fs.zig");
const HSH = @import("hsh.zig").HSH;

pub const Event = enum {
    nos,
    read,
    write,
    open,
    pub fn fromInt(in: u32) Event {
        return switch (in) {
            1 => .read,
            2 => .write,
            32 => .open,
            else => .nos,
        };
    }
};

const INotify = @This();
pub const Callback = *const fn (h: *HSH, evt: Event) void;

wdes: i32,
path: []const u8,
callback: ?Callback,

pub fn init(infd: i32, path: []const u8, cb: ?Callback) !INotify {
    return .{
        .wdes = try std.os.inotify_add_watch(infd, path, std.os.linux.IN.ALL_EVENTS),
        .path = path,
        .callback = cb,
    };
}

pub fn raze(self: *INotify, a: std.mem.Allocator) void {
    a.free(self.path);
}

pub fn event(self: *INotify, h: *HSH, inevt: *const std.os.linux.inotify_event) void {
    const evt: Event = Event.fromInt(inevt.mask);
    log.debug("inotify event for {} {any}\n", .{ self.wdes, inevt });
    if (self.callback) |cb| {
        cb(h, evt);
    }
}
