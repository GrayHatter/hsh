const Keys = @This();

pub const Key = enum(u8) {
    // zig fmt: off
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
    // zig fmt: on

    pub fn toMod(k: Key) KeyMod {
        return .{ .evt = .{ .key = k } };
    }

    /// Single Shift Three
    fn sst(r: *Reader) !Key {
        switch (try r.takeByte()) {
            'P' => return .F1,
            'Q' => return .F2,
            'R' => return .F3,
            'S' => return .F4,
            else => |c| {
                log.err("unexpected single shift three char 0x{X}\n", .{c});
                return error.UnknownEvent;
            },
        }
    }

    fn csi_vt(in: []const u8) !Key {
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
            else => return error.UnknownEvent,
        }
        return error.UnknownEvent;
    }
};

pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,

    pub fn init(bits: u8) Mods {
        return .{
            .shift = (bits & 1) != 0,
            .alt = (bits & 2) != 0,
            .ctrl = (bits & 4) != 0,
            .meta = (bits & 8) != 0,
        };
    }

    pub fn any(m: Mods) bool {
        return m.shift or m.alt or m.ctrl or m.meta;
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

    pub fn init(c: u8, r: *Reader) !Event {
        switch (c) {
            0x1B => return try esc(r),
            else => return .{ .ascii = c },
        }
    }

    pub fn fromKey(k: Key) Event {
        return .{ .keysm = .{ .evt = .{ .key = k } } };
    }

    pub fn fromAscii(a: ASCII) Event {
        return .{ .keysm = .{ .evt = .{ .ascii = a } } };
    }

    pub fn fromMouse(m: Mouse) Event {
        return .{ .mouse = m };
    }

    fn esc(r: *Reader) !Event {
        if (r.bufferedLen() == 0) return Event.fromKey(.esc);
        switch (try r.takeByte()) {
            0x1B => unreachable, // I assume this is unreachable now? // return Event.fromKey(.esc),
            '[' => return csi(r),
            'O' => return Event.fromKey(try .sst(r)),
            else => |byte| {
                log.warn("\n\nunknown input: escape {c} {d}\n", .{ byte, byte });
                return Event{
                    .keysm = .{
                        .evt = .{ .ascii = byte },
                        .mods = .init(2),
                    },
                };
            },
        }
    }

    /// Control Sequence Introducer
    fn csi(r: *Reader) !Event {
        var buffer = try r.peekGreedy(1);
        for (buffer, 1..) |byte, i|
            switch (byte) {
                '~', 'a'...'z', 'A'...'Z' => {
                    buffer = buffer[0..i];
                    break;
                },
                else => continue,
            };
        r.toss(buffer.len);

        switch (buffer[buffer.len - 1]) {
            '~' => return .fromKey(try .csi_vt(buffer[0 .. buffer.len - 1])), // intentionally dropping ~
            'a'...'z', 'A'...'Z' => return csi_xterm(buffer),
            else => std.debug.print("\n\nunknown\n{any}\n\n\n", .{buffer}),
        }
        return error.UnknownEvent;
    }

    fn csi_xterm(buffer: []const u8) !Event {
        switch (buffer[0]) {
            'A' => return .fromKey(.up),
            'B' => return .fromKey(.down),
            'C' => return .fromKey(.right),
            'D' => return .fromKey(.left),
            'H' => return .fromKey(.home),
            'F' => return .fromKey(.end),
            'I' => return .fromMouse(.in),
            'O' => return .fromMouse(.out),
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
                return .{ .keysm = .{
                    .evt = .{ .key = key },
                    .mods = .init(mod_bits),
                } };
            },
            'Z' => { // I hate this, but #YOLO
                if (buffer.len > 1) unreachable;
                return .{ .keysm = .{
                    .evt = .{ .ascii = 0x09 },
                    .mods = .init(1),
                } };
            },
            else => |unk| {
                log.err("\n\n{c}\n\n", .{unk});
                unreachable;
            },
        }
    }
};

const std = @import("std");
const log = @import("log.zig");
const Reader = std.Io.Reader;
