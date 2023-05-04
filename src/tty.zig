const std = @import("std");
const os = std.os;
const mem = std.mem;
const fs = std.fs;
const File = fs.File;
const io = std.io;
const Reader = fs.File.Reader;
const Writer = fs.File.Writer;
const Cord = @import("draw.zig").Cord;

pub const OpCodes = enum {
    EraseInLine,
    CurPosGet,
    CurPosSet,
    CurMvUp,
    CurMvDn,
    CurMvLe,
    CurMvRi,
    CurHorzAbs,
};

pub var current_tty: ?TTY = undefined;

pub const TTY = struct {
    tty: i32,
    in: Reader,
    out: Writer,
    orig: os.termios,

    /// Calling init multiple times is UB
    pub fn init() !TTY {
        // TODO figure out how to handle multiple calls to current_tty?
        const tty = try os.open("/dev/tty", os.linux.O.RDWR, 0);
        const orig = try os.tcgetattr(tty);

        try pushTTY(tty, orig);
        current_tty = TTY{
            .tty = tty,
            .in = std.io.getStdIn().reader(),
            .out = std.io.getStdOut().writer(),
            .orig = orig,
        };
        return current_tty.?;
    }

    fn pushTTY(tty: i32, tos: os.termios) !void {
        var raw = tos;
        raw.lflag &= ~(os.linux.ECHO | os.linux.ICANON | os.linux.ISIG | os.linux.IEXTEN);
        raw.iflag &= ~(os.linux.IXON | os.linux.ICRNL | os.linux.BRKINT | os.linux.INPCK | os.linux.ISTRIP);
        raw.cc[os.system.V.TIME] = 5; // 0.1 sec resolution
        raw.cc[os.system.V.MIN] = 0;
        try os.tcsetattr(tty, .FLUSH, raw);
    }

    pub fn print(tty: TTY, comptime fmt: []const u8, args: anytype) !void {
        try tty.out.print(fmt, args);
    }

    pub fn opcode(tty: TTY, comptime code: OpCodes, args: anytype) !void {
        // TODO fetch info back out :/
        _ = args;
        switch (code) {
            OpCodes.EraseInLine => try tty.writeAll("\x1B[K"),
            OpCodes.CurPosGet => try tty.print("\x1B[6n"),
            OpCodes.CurMvUp => try tty.writeAll("\x1B[A"),
            OpCodes.CurMvDn => try tty.writeAll("\x1B[B"),
            OpCodes.CurMvLe => try tty.writeAll("\x1B[D"),
            OpCodes.CurMvRi => try tty.writeAll("\x1B[C"),
            OpCodes.CurHorzAbs => try tty.writeAll("\x1B[G"),
            else => unreachable,
        }
    }

    pub fn cpos(tty: i32) !Cord {
        std.debug.print("\x1B[6n", .{});
        var buffer: [10]u8 = undefined;
        const len = try os.read(tty, &buffer);
        var splits = mem.split(u8, buffer[2..], ";");
        var x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
        var y: usize = 0;
        if (splits.next()) |thing| {
            y = std.fmt.parseInt(usize, thing[0 .. len - 3], 10) catch 0;
        }
        return .{
            .x = x,
            .y = y,
        };
    }

    pub fn geom(self: *TTY) !Cord {
        var size: os.linux.winsize = mem.zeroes(os.linux.winsize);
        const err = os.system.ioctl(self.tty, os.linux.T.IOCGWINSZ, @ptrToInt(&size));
        if (os.errno(err) != .SUCCESS) {
            return os.unexpectedErrno(@intToEnum(os.system.E, err));
        }
        return .{
            .x = size.ws_col,
            .y = size.ws_row,
        };
    }

    pub fn raze(tty: TTY) void {
        os.tcsetattr(tty.tty, .FLUSH, tty.orig) catch |err| {
            std.debug.print(
                "\r\n\nTTY ERROR RAZE encountered, {} when attempting to raze.\r\n\n",
                .{err},
            );
        };
    }
};

const expect = std.testing.expect;
test "split" {
    var s = "\x1B[86;1R";
    var splits = std.mem.split(u8, s[2..], ";");
    var x: usize = std.fmt.parseInt(usize, splits.next().?, 10) catch 0;
    var y: usize = 0;
    if (splits.next()) |thing| {
        y = std.fmt.parseInt(usize, thing[0 .. thing.len - 1], 10) catch unreachable;
    }
    try expect(x == 86);
    try expect(y == 1);
}

test "CSI format" {
    // For Control Sequence Introducer, or CSI, commands, the ESC [ (written as
    // \e[ or \033[ in several programming and scripting languages) is followed
    // by any number (including none) of "parameter bytes" in the range
    // 0x30–0x3F (ASCII 0–9:;<=>?), then by any number of "intermediate bytes"
    // in the range 0x20–0x2F (ASCII space and !"#$%&'()*+,-./), then finally by
    // a single "final byte" in the range 0x40–0x7E (ASCII
    // @A–Z[\]^_`a–z{|}~).[5]: 5.4 
}
