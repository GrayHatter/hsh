const std = @import("std");
const log = @import("log");
const HSH = @import("hsh.zig").HSH;
const Keys = @import("keys.zig");
const parser = @import("parse.zig");
const Parser = parser.Parser;

const Input = @This();

pub const Action = enum {
    none,
    exec,
    exit_hsh,
};

pub const Control = enum {
    none,
    esc,

    up,
    down,
    home,
    end,
    back,
    word,
    left,
    right,
    pgup,
    pgdn,

    backspace,
    delete,
    newline,
    tab,
    // Shell Control
    bell,
    delete_word,
    end_of_text,
    external_editor,
    reset_term,

    pub fn fromKey(k: Keys.Key) Control {
        return switch (k) {
            .esc => .esc,
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            .home => .home,
            .end => .end,
            .pgdn => .pgdn,
            .pgup => .pgup,
            else => unreachable,
        };
    }
};

const errors = error{
    io,
    signaled,
    end_of_text,
};

pub const Event = union(enum) {
    action: Action,
    char: u8,
    control: Control,
    mouse: Keys.Mouse,
};

stdin: std.posix.fd_t,
spin: ?*const fn (?*HSH) bool = null,
hsh: ?*HSH = null,
next: ?Event = null,

pub fn init(stdin: std.posix.fd_t) Input {
    return .{
        .stdin = stdin,
    };
}

fn read(input: Input, buf: []u8) !usize {
    return std.posix.read(input.stdin, buf);
    // switch (std.posix.errno(rc)) {
    //     .SUCCESS => return @intCast(rc),
    //     .INTR => return error.Interupted,
    //     .AGAIN => return error.WouldBlock,
    //     .BADF => return error.NotOpenForReading, // Can be a race condition.
    //     .IO => return error.InputOutput,
    //     .ISDIR => return error.IsDir,
    //     .NOBUFS => return error.SystemResources,
    //     .NOMEM => return error.SystemResources,
    //     .CONNRESET => return error.ConnectionResetByPeer,
    //     .TIMEDOUT => return error.ConnectionTimedOut,
    //     else => |err| {
    //         std.debug.print("unexpected read err {}\n", .{err});
    //         @panic("unknown read error\n");
    //     },
    // }
}

fn ctrlCode(b: u8) Control {
    return switch (b) {
        0x03 => unreachable,
        //try hsh.tty.out.print("^C\n\n", .{});
        //tkn.reset();
        //return .prompt;
        0x04 => .end_of_text,
        0x05 => .external_editor,
        // TODO Currently hack af, this could use some more love!
        0x07 => .bell,
        0x08 => .delete_word,
        0x09 => |_| .tab,
        //return in.completing(hsh, tkn, Keys.Event.ascii(c).keysm) catch unreachable;
        0x0A, 0x0D => .newline,
        0x0C => .reset_term,
        //try hsh.tty.out.print("^L (reset term)\x1B[J\n", .{}),
        //0x0E => try hsh.tty.out.print("shift in\r\n", .{}),
        //0x0F => try hsh.tty.out.print("^shift out\r\n", .{}),
        //0x12 => try hsh.tty.out.print("^R\r\n", .{}), // DC2
        //0x13 => try hsh.tty.out.print("^S\r\n", .{}), // DC3
        //0x14 => try hsh.tty.out.print("^T\r\n", .{}), // DC4
        //// this is supposed to be ^v but it's ^x on mine an another system
        //0x16 => try hsh.tty.out.print("^X\r\n", .{}), // SYN
        //0x18 => {
        //    //try hsh.tty.out.print("^X (or something else?)\r\n", .{}); // CAN
        //    return .external_editor;
        //},
        //0x1A => try hsh.tty.out.print("^Z\r\n", .{}),
        0x17 => .delete_word,
        // ^w
        //    _ = try tkn.dropWord();
        //    return .redraw;
        //},
        else => |x| {
            log.err("Unknown ctrl code 0x{x}", .{x});
            unreachable;
        },
    };
}

fn event(km: Keys.KeyMod) Event {
    switch (km.evt) {
        .ascii => |a| switch (a) {
            '.' => {
                if (km.mods.alt) log.err("<A-.> not yet implemented\n", .{});

                return .{ .action = .none };
            },
            else => {
                log.err("unknown ascii {}\n", .{a});
                return .{ .action = .none };
            },
        },
        .key => |k| switch (k) {
            .esc,
            .up,
            .down,
            .left,
            .right,
            .home,
            .end,
            .pgup,
            .pgdn,
            => |r| {
                return .{ .control = Control.fromKey(r) };
            },
            .delete => return .{ .control = .delete },
            else => {
                log.err("unknown control key {}\n", .{k});
                return .{ .action = .none };
            },
        },
    }
    comptime unreachable;
}

fn utf8(key: Keys.ASCII) u8 {
    return key;
}

fn ascii(key: Keys.ASCII) Event {
    switch (key) {
        0x00...0x1F => return .{ .control = ctrlCode(key) },
        // Normal printable ascii
        ' '...'~' => |b| return .{ .char = b },
        0x7F => return .{ .control = .backspace },
        0x80...0xFF => return .{ .char = utf8(key) },
    }
    return .{ .control = .none };
}

fn toChar(k: Keys.Event) errors!Event {
    switch (k) {
        .ascii => |as| return ascii(as),
        .keysm => |ks| return event(ks),
        .mouse => |ms| {
            _ = ms;
            unreachable;
        },
    }
}

pub fn nonInteractive(input: *Input) errors!Event {
    var buffer: [1]u8 = undefined;

    const nbyte: usize = input.read(&buffer) catch |err| {
        log.err("unable to read {}", .{err});
        return error.io;
    };
    if (nbyte == 0) return error.end_of_text;

    if (Keys.translate(buffer[0], input.stdin)) |key| {
        return toChar(key);
    } else |_| unreachable;
}

pub fn interactive(input: Input) errors!Event {
    var buffer: [1]u8 = undefined;

    var nbyte: usize = input.read(&buffer) catch |err| {
        log.err("unable to read {}", .{err});
        return error.io;
    };
    while (nbyte == 0) {
        if (input.spin) |spin| if (spin(input.hsh)) return error.signaled;
        nbyte = input.read(&buffer) catch |err| {
            log.err("unable to read {}", .{err});
            return error.io;
        };
    }

    if (Keys.translate(buffer[0], input.stdin)) |key| {
        return toChar(key);
    } else |_| unreachable;
}
