stdin: *Reader,
spin: ?*const fn (*const Input, Allocator, Io) bool = null,
next: ?Event = null,

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
};

pub const CtrlMod = struct {
    c: Control,
    mod: Keys.Mods = .{},

    pub fn fromChr(comptime c: u8) CtrlMod {
        return .{ .c = switch (c) {
            0x7F => .backspace,
            else => comptime unreachable,
        } };
    }

    pub fn fromKey(k: Keys.Key, mods: Keys.Mods) CtrlMod {
        return .{
            .c = switch (k) {
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
            },
            .mod = mods,
        };
    }
};

pub const Event = union(enum) {
    action: Action,
    char: u8,
    control: CtrlMod,
    mouse: Keys.Mouse,
};

pub fn init(stdin: std.posix.fd_t) Input {
    return .{ .stdin = stdin };
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
        0x09 => .tab,
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
                return .{ .control = CtrlMod.fromKey(r, km.mods) };
            },
            .delete => return .{ .control = CtrlMod.fromKey(.delete, .{}) },
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
        0x00...0x1F => return .{ .control = .{ .c = ctrlCode(key) } },
        // Normal printable ascii
        ' '...'~' => |b| return .{ .char = b },
        0x7F => return .{ .control = CtrlMod.fromChr(0x7F) },
        0x80...0xFF => return .{ .char = utf8(key) },
    }
    return .{ .control = .none };
}

fn toChar(k: Keys.Event) Event {
    switch (k) {
        .ascii => |as| return ascii(as),
        .keysm => |ks| return event(ks),
        .mouse => |ms| {
            _ = ms;
            unreachable;
        },
    }
}

pub fn nonInteractive(input: *const Input) !Event {
    const byte: u8 = input.stdin.takeByte() catch |err| {
        log.err("unable to read {}", .{err});
        return error.Io;
    };

    return toChar(Keys.translate(byte, input.stdin) catch unreachable);
}

pub fn interactive(in: *const Input, a: Allocator, io: Io) !Event {
    while (true) {
        const byte = in.stdin.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (in.spin) |spin| {
                    if (spin(in, a, io))
                        return error.Signaled;
                }
                continue;
            },
            else => {
                log.err("unable to read {}\n\n", .{err});
                return error.Io;
            },
        };

        return toChar(Keys.translate(byte, in.stdin) catch unreachable);
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const log = @import("log.zig");
const Keys = @import("keys.zig");
const parser = @import("parse.zig");
