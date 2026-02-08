stdin: *Reader,
spin: ?*const fn (*const Input, Allocator, Io) bool = null,

const Input = @This();

pub const Event = Keys.Event;

pub fn init(stdin: i32) Input {
    return .{ .stdin = stdin };
}

pub fn nonInteractive(input: *const Input) !Event {
    const byte: u8 = input.stdin.takeByte() catch |err| {
        log.err("unable to read {}", .{err});
        return error.Io;
    };

    return Keys.Event.init(byte, input.stdin) catch unreachable;
}

pub fn interactive(in: *const Input, a: Allocator, io: Io) !Event {
    while (true) {
        const byte = in.stdin.takeByte() catch |err| switch (err) {
            error.EndOfStream => if (in.spin) |spin| {
                if (spin(in, a, io))
                    return error.Signaled
                else
                    continue;
            } else continue,
            else => {
                log.err("unable to read {}\n\n", .{err});
                return error.Io;
            },
        };

        return Keys.Event.init(byte, in.stdin) catch unreachable;
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const log = @import("log.zig");
const Keys = @import("keys.zig");
const parser = @import("parse.zig");
