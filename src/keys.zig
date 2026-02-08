const Keys = @This();

pub const Ascii = u8;
pub const Ascii2 = enum(u8) {
    nul = 0x00,
    soh = 0x01,
    stx = 0x02,
    etx = 0x03,
    eot = 0x04,
    enq = 0x05,
    ack = 0x06,
    bel = 0x07,
    bs = 0x08,
    ht = 0x09,
    lf = 0x0a,
    vt = 0x0b,
    ff = 0x0c,
    cr = 0x0d,
    so = 0x0e,
    si = 0x0f,
    dle = 0x10,
    dc1 = 0x11,
    dc2 = 0x12,
    dc3 = 0x13,
    dc4 = 0x14,
    nak = 0x15,
    syn = 0x16,
    etb = 0x17,
    can = 0x18,
    em = 0x19,
    sub = 0x1a,
    esc = 0x1b,
    fs = 0x1c,
    gs = 0x1d,
    rs = 0x1e,
    us = 0x1f,
    space = 0x20,
    bang = 0x21,
    quote_double = 0x22,
    hash = 0x23,
    dollar = 0x24,
    percent = 0x25,
    ampersand = 0x26,
    quote_single = 0x27,
    paren_left = 0x28,
    paren_right = 0x29,
    star = 0x2a,
    plus = 0x2b,
    comma = 0x2c,
    dash = 0x2d,
    dot = 0x2e,
    slash = 0x2f,
    zero = 0x30,
    one = 0x31,
    two = 0x32,
    three = 0x33,
    four = 0x34,
    five = 0x35,
    six = 0x36,
    sever = 0x37,
    eight = 0x38,
    nine = 0x39,
    colon = 0x3a,
    semicolon = 0x3b,
    @"<" = 0x3c,
    equal = 0x3d,
    @">" = 0x3e,
    question = 0x3f,
    at = 0x40,
    A = 0x41,
    B = 0x42,
    C = 0x43,
    D = 0x44,
    E = 0x45,
    F = 0x46,
    G = 0x47,
    H = 0x48,
    I = 0x49,
    J = 0x4a,
    K = 0x4b,
    L = 0x4c,
    M = 0x4d,
    N = 0x4e,
    O = 0x4f,
    P = 0x50,
    Q = 0x51,
    R = 0x52,
    S = 0x53,
    T = 0x54,
    U = 0x55,
    V = 0x56,
    W = 0x57,
    X = 0x58,
    Y = 0x59,
    Z = 0x5a,
    bracket_square_left = 0x5b,
    backslash = 0x5c,
    bracket_square_right = 0x5d,
    caret = 0x5e,
    underscore = 0x5f,
    backtick = 0x60,
    a = 0x61,
    b = 0x62,
    c = 0x63,
    d = 0x64,
    e = 0x65,
    f = 0x66,
    g = 0x67,
    h = 0x68,
    i = 0x69,
    j = 0x6a,
    k = 0x6b,
    l = 0x6c,
    m = 0x6d,
    n = 0x6e,
    o = 0x6f,
    p = 0x70,
    q = 0x71,
    r = 0x72,
    s = 0x73,
    t = 0x74,
    u = 0x75,
    v = 0x76,
    w = 0x77,
    x = 0x78,
    y = 0x79,
    z = 0x7a,
    bracket_curly_left = 0x7b,
    @"|" = 0x7c,
    bracket_curly_right = 0x7d,
    tilda = 0x7e,
    del = 0x7f,
    _,
};

pub const Mouse = enum { in, out };

pub const Key = enum(u8) {
    // zig fmt: off
    end_of_text = 0x04,
    external_editor = 0x05, // enquiry
                            bell = 0x07,
    newline = 0x0a,
    reset_term = 0x0c, // form feed
    carriage_return = 0x0d,
    esc = 0x1b,
    delete_word = 0x17,  // end of transmission
    tab = 0x09,
    // delete in ascii, but "terminals"
    backspace = 0x7f,
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

    fn vtCsi(in: []const u8) !Key {
        const y: u16 = parseInt(u16, in, 10) catch 0;
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
            else => return error.UnknownVtCsi,
        }
        return error.UnknownVtCsi;
    }
};

pub const Mods = packed struct(u4) {
    _shift: bool = false,
    _alt: bool = false,
    _ctrl: bool = false,
    _meta: bool = false,

    pub const none: Mods = .{};
    pub const shift: Mods = .{ ._shift = true };
    pub const alt: Mods = .{ ._alt = true };
    pub const ctrl: Mods = .{ ._ctrl = true };
    pub const meta: Mods = .{ ._meta = true };
    pub const ctrl_shift: Mods = .{ ._ctrl = true, ._shift = true };

    pub fn init(bits: u8) Mods {
        return .{
            ._shift = (bits & 1) != 0,
            ._alt = (bits & 2) != 0,
            ._ctrl = (bits & 4) != 0,
            ._meta = (bits & 8) != 0,
        };
    }

    pub fn any(m: Mods) bool {
        return m.shift or m.alt or m.ctrl or m.meta;
    }
};

pub const Event = struct {
    evt: Action,
    mods: Mods,

    pub const Action = union(enum) {
        ascii: Ascii,
        key: Key,
        mouse: Mouse,
    };

    pub fn init(c: u8, r: *Reader) !Event {
        switch (c) {
            0x1B => return try esc(r),
            else => return .ascii(c),
        }
    }

    pub fn ascii(a: Ascii) Event {
        return switch (a) {
            0x00...0x1F => |ctl| switch (ctl) {
                0x03 => unreachable,
                0x04 => .key(.end_of_text),
                0x05 => .key(.external_editor),
                0x07 => .key(.bell),
                0x08 => .key(.delete_word),
                0x09 => .key(.tab),
                0x0A => .key(.newline),
                0x0D => .key(.carriage_return),
                0x0C => .key(.reset_term),
                0x17 => .key(.delete_word),
                else => unreachable, // FIXME
                //try print("^L (reset term)\x1B[J\n", .{}),
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
                // ^w
                //    _ = try tkn.dropWord();
                //    return .redraw;
                //},
            },
            ' '...'~' => |b| .{ .evt = .{ .ascii = b }, .mods = .none },
            0x7F => .key(.backspace),
            0x80...0xFF => .utf8(a),
        };
        //return .{ .evt = .{ .ascii = a }, .mods = .none };
    }

    pub fn utf8(_: u8) Event {
        unreachable;
    }

    pub fn key(k: Key) Event {
        return .{ .evt = .{ .key = k }, .mods = .none };
    }

    pub fn fromMouse(m: Mouse) Event {
        return .{ .evt = .{ .mouse = m }, .mods = .none };
    }

    fn esc(r: *Reader) !Event {
        if (r.bufferedLen() == 0) return .key(.esc);
        return switch (try r.takeByte()) {
            0x1B => .key(.esc),
            '[' => csi(r),
            'O' => Event.key(try .sst(r)),
            else => |byte| {
                log.warn("\n\nunknown input: escape {c} {d}\n", .{ byte, byte });
                return .{
                    .evt = .{ .ascii = byte },
                    .mods = .alt,
                };
            },
        };
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
            '~' => return .key(try .vtCsi(buffer[0 .. buffer.len - 1])), // intentionally dropping ~
            'a'...'z', 'A'...'Z' => return xtermCsi(buffer),
            else => std.debug.print("\n\nunknown\n{any}\n\n\n", .{buffer}),
        }
        return error.UnknownEvent;
    }

    fn xtermCsi(buffer: []const u8) !Event {
        switch (buffer[0]) {
            'A' => return .key(.up),
            'B' => return .key(.down),
            'C' => return .key(.right),
            'D' => return .key(.left),
            'H' => return .key(.home),
            'F' => return .key(.end),
            'I' => return .fromMouse(.in),
            'O' => return .fromMouse(.out),
            '0'...'9' => {
                const newkey = (try xtermCsi(buffer[buffer.len - 1 .. buffer.len])).evt.key;
                log.debug("\n\n{s} [{any}] key {}\n\n", .{ buffer, buffer, newkey });
                assert(countScalar(u8, buffer, ';') == 1);

                if (findScalar(u8, buffer, ';')) |idx| {
                    // Yes, I know hacky af, but I don't know all the other combos I
                    // care about yet. :/
                    if (idx != 1) @panic("xterm is unable to parse given string");
                    if (buffer[0] != '1') @panic("xterm is unable to parse given string");

                    const rest = buffer[idx + 1 ..];
                    const mod_bits = (parseInt(u8, rest[0 .. rest.len - 1], 10) catch 1) -% 1;
                    return .{ .evt = .{ .key = newkey }, .mods = .init(mod_bits) };
                } else return error.IncompleteCsi;
            },
            'Z' => { // I hate this, but #YOLO
                if (buffer.len > 1) unreachable;
                return .{
                    .evt = .{ .ascii = 0x09 },
                    .mods = .shift,
                };
            },
            else => |unk| {
                log.err("Invalid xtermCsi '{c}'\n\n", .{unk});
                unreachable;
            },
        }
    }
};

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const log = @import("log.zig");
const Reader = std.Io.Reader;
const assert = std.debug.assert;
const parseInt = std.fmt.parseInt;
const findScalar = std.mem.findScalar;
const countScalar = std.mem.countScalar;
