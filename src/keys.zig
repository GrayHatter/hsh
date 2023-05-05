const std = @import("std");
const os = std.os;
const HSH = @import("hsh.zig").HSH;

const KeyEvent = enum {
    Unknown,
    Char,
    Action,
};

const KeyAction = enum(u8) {
    Null = 0,
    Escape,
    Handled,
    Unhandled,
    ArrowUp,
    ArrowDn,
    ArrowBk,
    ArrowFw,
    Home,
    Insert,
    Delete,
    End,
    PgUp,
    PgDn,
    F0,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    F13,
    F14,
    F15,
    F16,
    F17,
    F18,
    F19,
    F20,
};

const KeyPress = union(KeyEvent) {
    Unknown: void,
    Char: u8,
    Action: KeyAction,
};

pub fn esc(hsh: *HSH) !KeyPress {
    var buffer: [1]u8 = undefined;
    const in = try os.read(hsh.input, &buffer);
    if (in != 1) return KeyPress.Unknown;
    switch (buffer[0]) {
        0x1B => return KeyPress{ .Action = .Escape },
        '[' => {
            switch (try csi(hsh)) {
                .Action => |a| {
                    switch (a) {
                        .Handled => unreachable,
                        .Unhandled => unreachable,
                        else => return KeyPress{ .Action = a },
                    }
                },
                .Unknown => unreachable,
                .Char => |c| return KeyPress{ .Char = c },
            }
        },
        'O' => return sst(hsh),
        else => std.debug.print("\r\ninput: escape {s} {}\n", .{ buffer, buffer[0] }),
    }
    return KeyPress{ .Char = buffer[0] };
}

/// Single Shift Three
fn sst(hsh: *HSH) !KeyPress {
    var buffer: [1]u8 = undefined;
    if (try os.read(hsh.input, &buffer) != 1) return KeyPress.Unknown;
    switch (buffer[0]) {
        'P' => return KeyPress{ .Action = .F1 },
        'Q' => return KeyPress{ .Action = .F2 },
        'R' => return KeyPress{ .Action = .F3 },
        'S' => return KeyPress{ .Action = .F4 },
        else => return KeyPress.Unknown,
    }
}

/// Control Sequence Introducer
fn csi(hsh: *HSH) !KeyPress {
    var buffer: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const len = try os.read(hsh.input, buffer[i .. i + 1]);
        if (len == 0) return KeyPress.Unknown;
        switch (buffer[i]) {
            '~', 'a'...'z', 'A'...'Z' => break,
            else => continue,
        }
    }
    switch (buffer[i]) {
        '~' => return csi_vt(buffer[0..i]), // intentionally dropping ~
        'a'...'z', 'A'...'Z' => return csi_xterm(buffer[0 .. i + 1]),
        else => std.debug.print("\n\nunknown\n{any}\n\n\n", .{buffer}),
    }
    return KeyPress.Unknown;
}

/// TODO remove hsh
fn csi_xterm(buffer: []const u8) KeyPress {
    switch (buffer[0]) {
        'A' => return KeyPress{ .Action = .ArrowUp },
        'B' => return KeyPress{ .Action = .ArrowDn },
        'C' => return KeyPress{ .Action = .ArrowFw },
        'D' => return KeyPress{ .Action = .ArrowBk },
        'H' => return KeyPress{ .Action = .Home },
        'F' => return KeyPress{ .Action = .End },
        else => unreachable,
    }
}

fn csi_vt(in: []const u8) KeyPress {
    var y: u16 = std.fmt.parseInt(u16, in, 10) catch 0;
    switch (y) {
        1 => return KeyPress{ .Action = .Home },
        2 => return KeyPress{ .Action = .Insert },
        3 => return KeyPress{ .Action = .Delete },
        4 => return KeyPress{ .Action = .End },
        5 => return KeyPress{ .Action = .PgUp },
        6 => return KeyPress{ .Action = .PgDn },
        7 => return KeyPress{ .Action = .Home },
        8 => return KeyPress{ .Action = .End },
        10 => return KeyPress{ .Action = .F0 },
        11 => return KeyPress{ .Action = .F1 },
        12 => return KeyPress{ .Action = .F2 },
        13 => return KeyPress{ .Action = .F3 },
        14 => return KeyPress{ .Action = .F4 },
        15 => return KeyPress{ .Action = .F5 },
        17 => return KeyPress{ .Action = .F6 },
        18 => return KeyPress{ .Action = .F7 },
        19 => return KeyPress{ .Action = .F8 },
        20 => return KeyPress{ .Action = .F9 },
        21 => return KeyPress{ .Action = .F10 },
        23 => return KeyPress{ .Action = .F11 },
        24 => return KeyPress{ .Action = .F12 },
        25 => return KeyPress{ .Action = .F13 },
        26 => return KeyPress{ .Action = .F14 },
        28 => return KeyPress{ .Action = .F15 },
        29 => return KeyPress{ .Action = .F16 },
        31 => return KeyPress{ .Action = .F17 },
        32 => return KeyPress{ .Action = .F18 },
        33 => return KeyPress{ .Action = .F19 },
        34 => return KeyPress{ .Action = .F20 },
        9, 16, 22, 27, 30, 35 => {},
        else => return KeyPress.Unknown,
    }
    return KeyPress.Unknown;
}
