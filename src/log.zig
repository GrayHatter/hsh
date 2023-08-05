const std = @import("std");

pub const Log = @This();

pub const Level = enum(u4) {
    panic = 0,
    critical,
    err,
    warning,
    notice,
    info,
    debug,
    trace,
};

pub var verbosity: Level = .warning;

/// TODO NO_COLOR support
pub fn hshLogFn(
    comptime level: Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(verbosity) < @intFromEnum(level)) return;
    const prefix = comptime switch (level) {
        .err => "[\x1B[31merr\x1B[39m] ",
        .warning => "[\x1B[33mwrn\x1B[39m] ",
        .info => "[\x1B[32minf\x1B[39m] ",
        .debug => "[\x1B[24mdbg\x1B[39m] ",
        else => "[ NOS ] ",
    };

    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr().writer();
    stderr.print(prefix ++ format, args) catch return;
}

pub fn err(comptime format: []const u8, args: anytype) void {
    hshLogFn(.err, .default, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    hshLogFn(.warning, .default, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    hshLogFn(.info, .default, format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    hshLogFn(.debug, .default, format, args);
}

pub fn trace(comptime format: []const u8, args: anytype) void {
    hshLogFn(.trace, .default, format, args);
}

pub fn dump(args: anytype) void {
    hshLogFn(.critical, .default, "{}\n", .{args});
}

pub fn dumpstr(args: anytype) void {
    hshLogFn(.critical, .default, "{s}\n", .{args});
}
