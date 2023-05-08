const std = @import("std");
const os = std.os;
const HSH = @import("hsh.zig").HSH;

const KeyEvent = enum {
    Unknown,
    Key,
    ModKey,
    // Data,
};

// zig fmt: off
const Key = enum(u8) {
    Null = 0,
    Escape,
    Handled, Unhandled,
    Up, Down, Left, Right,
    Home, Insert, Delete, End,
    PgUp, PgDn,
    // TODO all ASCII :<
    F0,
    F1, F2, F3, F4,
    F5, F6, F7, F8,
    F9, F10, F11, F12,
    F13, F14, F15, F16,
    F17, F18, F19, F20
};
// zig fmt: on

const Modifiers = enum(u4) {
    None = 0,
    Shift = 1,
    Alt = 2, // Left only?
    // Right alt?
    Ctrl = 4,
    Meta = 8,
};

const ModKey = struct {
    mods: Modifiers = .None,
    key: Key,
};

const KeyPress = union(KeyEvent) {
    Unknown: void,
    Key: Key,
    ModKey: ModKey,
    // Data,
};

pub fn esc(hsh: *HSH) !KeyPress {
    var buffer: [1]u8 = undefined;
    const in = try os.read(hsh.input, &buffer);
    if (in != 1) return KeyPress.Unknown;
    switch (buffer[0]) {
        0x1B => return KeyPress{ .Key = .Escape },
        '[' => {
            switch (try csi(hsh)) {
                .Key => |a| {
                    switch (a) {
                        .Handled => unreachable,
                        .Unhandled => unreachable,
                        else => return KeyPress{ .Key = a },
                    }
                },
                .Unknown => unreachable,
                .ModKey => |mk| return KeyPress{ .ModKey = mk },
            }
        },
        'O' => return sst(hsh),
        else => std.debug.print("\r\ninput: escape {s} {}\n", .{ buffer, buffer[0] }),
    }
    return KeyPress.Unknown;
}

/// Single Shift Three
fn sst(hsh: *HSH) !KeyPress {
    var buffer: [1]u8 = undefined;
    if (try os.read(hsh.input, &buffer) != 1) return KeyPress.Unknown;
    switch (buffer[0]) {
        'P' => return KeyPress{ .Key = .F1 },
        'Q' => return KeyPress{ .Key = .F2 },
        'R' => return KeyPress{ .Key = .F3 },
        'S' => return KeyPress{ .Key = .F4 },
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
        'A' => return KeyPress{ .Key = .Up },
        'B' => return KeyPress{ .Key = .Down },
        'C' => return KeyPress{ .Key = .Right },
        'D' => return KeyPress{ .Key = .Left },
        'H' => return KeyPress{ .Key = .Home },
        'F' => return KeyPress{ .Key = .End },
        '0'...'9' => {
            const key = csi_xterm(buffer[buffer.len - 1 .. buffer.len]);
            std.debug.print("\n\n{s} [{any}] key {}\n\n", .{ buffer, buffer, key });
            if (key == KeyPress.Unknown) unreachable;

            if (std.mem.count(u8, buffer, ";") != 1) unreachable;

            var mods = std.mem.split(u8, buffer, ";");
            // Yes, I know hacky af, but I don't know all the other combos I
            // care about yet. :/
            if (!std.mem.eql(u8, "1", mods.first())) unreachable;
            const rest = mods.rest();
            if (std.mem.eql(u8, "5D", rest)) {
                return KeyPress{ .ModKey = ModKey{ .key = .Left } };
            } else if (std.mem.eql(u8, "5C", rest)) {
                return KeyPress{ .ModKey = ModKey{ .key = .Right } };
            } else unreachable;
            return KeyPress.Unknown;
        },
        else => unreachable,
    }
}

fn csi_vt(in: []const u8) KeyPress {
    var y: u16 = std.fmt.parseInt(u16, in, 10) catch 0;
    switch (y) {
        1 => return KeyPress{ .Key = .Home },
        2 => return KeyPress{ .Key = .Insert },
        3 => return KeyPress{ .Key = .Delete },
        4 => return KeyPress{ .Key = .End },
        5 => return KeyPress{ .Key = .PgUp },
        6 => return KeyPress{ .Key = .PgDn },
        7 => return KeyPress{ .Key = .Home },
        8 => return KeyPress{ .Key = .End },
        10 => return KeyPress{ .Key = .F0 },
        11 => return KeyPress{ .Key = .F1 },
        12 => return KeyPress{ .Key = .F2 },
        13 => return KeyPress{ .Key = .F3 },
        14 => return KeyPress{ .Key = .F4 },
        15 => return KeyPress{ .Key = .F5 },
        17 => return KeyPress{ .Key = .F6 },
        18 => return KeyPress{ .Key = .F7 },
        19 => return KeyPress{ .Key = .F8 },
        20 => return KeyPress{ .Key = .F9 },
        21 => return KeyPress{ .Key = .F10 },
        23 => return KeyPress{ .Key = .F11 },
        24 => return KeyPress{ .Key = .F12 },
        25 => return KeyPress{ .Key = .F13 },
        26 => return KeyPress{ .Key = .F14 },
        28 => return KeyPress{ .Key = .F15 },
        29 => return KeyPress{ .Key = .F16 },
        31 => return KeyPress{ .Key = .F17 },
        32 => return KeyPress{ .Key = .F18 },
        33 => return KeyPress{ .Key = .F19 },
        34 => return KeyPress{ .Key = .F20 },
        9, 16, 22, 27, 30, 35 => {},
        else => return KeyPress.Unknown,
    }
    return KeyPress.Unknown;
}