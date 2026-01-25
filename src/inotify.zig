wdes: i32,
path: []const u8,
callback: ?Callback,

const INotify = @This();

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

pub const Callback = *const fn (*Hsh, Event, Allocator, Io) void;

pub fn init(infd: i32, path: []const u8, cb: ?Callback) !INotify {
    return .{
        .wdes = try std.posix.inotify_add_watch(infd, path, linux.IN.ALL_EVENTS),
        .path = path,
        .callback = cb,
    };
}

pub fn raze(self: *INotify) void {
    _ = self;
}

pub fn event(self: *INotify, h: *Hsh, inevt: linux.inotify_event, a: Allocator, io: Io) void {
    const evt: Event = Event.fromInt(inevt.mask);
    log.debug("inotify event for {} {any}\n", .{ self.wdes, inevt });
    if (self.callback) |cb| {
        cb(h, evt, a, io);
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const log = @import("log.zig");
const Hsh = @import("hsh.zig");
