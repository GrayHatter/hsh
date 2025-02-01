const std = @import("std");
const log = @import("log");

pub const Error = error{
    UnknownEvent,
    IO,
};

// zig fmt: off
pub const Key = enum(u8) {
    esc,
    up,   down, left,   right,
    home, end,  insert, delete,
    pgup, pgdn,
    F0,
    F1,  F2,  F3,  F4,
    F5,  F6,  F7,  F8,
    F9,  F10, F11, F12,
    F13, F14, F15, F16,
    F17, F18, F19, F20,

    pub fn make(k: Key) KeyMod {
        return .{
            .evt = .{
                .key = k,
            },
        };
    }
};
// zig fmt: on

pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,

    pub fn any(m: *@This()) bool {
        return m.shift or m.alt or m.ctrl or m.meta;
    }

    pub fn make(bits: u8) @This() {
        return .{
            .shift = (bits & 1) != 0,
            .alt = (bits & 2) != 0,
            .ctrl = (bits & 4) != 0,
            .meta = (bits & 8) != 0,
        };
    }
};
pub const ASCII = u8;

pub const KeyMod = struct {
    evt: union(enum) {
        ascii: ASCII,
        key: Key,
    },
    mods: Mods = .{},
};

pub const Mouse = enum {
    in,
    out,
};

pub const Event = union(enum) {
    ascii: ASCII,
    keysm: KeyMod,
    mouse: Mouse,

    pub fn fromKey(k: Key) Event {
        return .{
            .keysm = .{
                .evt = .{
                    .key = k,
                },
            },
        };
    }

    pub fn fromAscii(a: ASCII) Event {
        return .{
            .keysm = .{
                .evt = .{
                    .ascii = a,
                },
            },
        };
    }
};

pub fn translate(c: u8, io: i32) Error!Event {
    switch (c) {
        0x1B => return try esc(io),
        else => return .{ .ascii = c },
    }
}

pub fn esc(io: i32) Error!Event {
    var buffer: [1]u8 = .{0x1B};
    _ = std.posix.read(io, &buffer) catch return Error.IO;
    switch (buffer[0]) {
        0x1B => return Event.fromKey(.esc),
        '[' => return csi(io),
        'O' => return Event.fromKey(try sst(io)),
        else => {
            log.warn("\n\nunknown input: escape {s} {}\n", .{ buffer, buffer[0] });
            return Event{ .keysm = .{
                .evt = .{
                    .ascii = buffer[0],
                },
                .mods = Mods.make(2),
            } };
        },
    }
    return Error.UnknownEvent;
}

/// Single Shift Three
fn sst(io: i32) Error!Key {
    var buffer: [1]u8 = undefined;
    if ((std.posix.read(io, &buffer) catch return Error.IO) != 1) unreachable;
    switch (buffer[0]) {
        'P' => return .F1,
        'Q' => return .F2,
        'R' => return .F3,
        'S' => return .F4,
        else => |c| {
            log.err("unexpected single shift three char 0x{X}\n", .{c});
            return Error.UnknownEvent;
        },
    }
}

/// Control Sequence Introducer
fn csi(io: i32) Error!Event {
    var buffer: [32]u8 = undefined;
    var i: usize = 0;
    // Iterate byte by byte to terminate as early as possible
    while (i < buffer.len) : (i += 1) {
        const len = std.posix.read(io, buffer[i .. i + 1]) catch return Error.IO;
        if (len == 0) return Error.UnknownEvent;
        switch (buffer[i]) {
            '~', 'a'...'z', 'A'...'Z' => break,
            else => continue,
        }
    }
    std.debug.assert(i != buffer.len);
    switch (buffer[i]) {
        '~' => return Event.fromKey(try csi_vt(buffer[0..i])), // intentionally dropping ~
        'a'...'z', 'A'...'Z' => return csi_xterm(buffer[0 .. i + 1]),
        else => std.debug.print("\n\nunknown\n{any}\n\n\n", .{buffer}),
    }
    return Error.UnknownEvent;
}

fn csi_xterm(buffer: []const u8) Error!Event {
    switch (buffer[0]) {
        'A' => return Event.fromKey(.up),
        'B' => return Event.fromKey(.down),
        'C' => return Event.fromKey(.right),
        'D' => return Event.fromKey(.left),
        'H' => return Event.fromKey(.home),
        'F' => return Event.fromKey(.end),
        'I' => return .{ .mouse = .in },
        'O' => return .{ .mouse = .out },
        '0'...'9' => {
            const key = (try csi_xterm(buffer[buffer.len - 1 .. buffer.len])).keysm.evt.key;
            log.debug("\n\n{s} [{any}] key {}\n\n", .{ buffer, buffer, key });
            std.debug.assert(std.mem.count(u8, buffer, ";") == 1);

            var mods = std.mem.splitAny(u8, buffer, ";");
            // Yes, I know hacky af, but I don't know all the other combos I
            // care about yet. :/
            if (!std.mem.eql(u8, "1", mods.first())) @panic("xterm is unable to parse given string");

            const rest = mods.rest();
            const mod_bits = (std.fmt.parseInt(u8, rest[0 .. rest.len - 1], 10) catch 1) -% 1;
            return .{
                .keysm = .{
                    .evt = .{ .key = key },
                    .mods = Mods.make(mod_bits),
                },
            };
        },
        'Z' => |_| { // I hate this, but #YOLO
            if (buffer.len > 1) unreachable;
            return Event{
                .keysm = .{
                    .evt = .{ .ascii = 0x09 },
                    .mods = Mods.make(1),
                },
            };
        },
        else => |unk| {
            log.err("\n\n{c}\n\n", .{unk});
            unreachable;
        },
    }
}

fn csi_vt(in: []const u8) Error!Key {
    const y: u16 = std.fmt.parseInt(u16, in, 10) catch 0;
    switch (y) {
        1 => return .home,
        2 => return .insert,
        3 => return .delete,
        4 => return .end,
        5 => return .pgup,
        6 => return .pgdn,
        7 => return .home,
        8 => return .end,
        10 => return .F0,
        11 => return .F1,
        12 => return .F2,
        13 => return .F3,
        14 => return .F4,
        15 => return .F5,
        17 => return .F6,
        18 => return .F7,
        19 => return .F8,
        20 => return .F9,
        21 => return .F10,
        23 => return .F11,
        24 => return .F12,
        25 => return .F13,
        26 => return .F14,
        28 => return .F15,
        29 => return .F16,
        31 => return .F17,
        32 => return .F18,
        33 => return .F19,
        34 => return .F20,
        9, 16, 22, 27, 30, 35 => unreachable,
        else => return Error.UnknownEvent,
    }
    return Error.UnknownEvent;
}
