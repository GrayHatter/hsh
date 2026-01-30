cursor: u32 = 0,
cursor_reposition: bool = true,
writer: *Writer,
unbuffered: *Writer,
before: DrawBuf = undefined,
b: DrawBuf = undefined,
right: DrawBuf = undefined,
after: DrawBuf = undefined,
term_size: Cord = .{},
lines: u16 = 0,
internal: []u8,

pub const Layout = @import("draw/layout.zig");

const draw_buffer_size = 4096 * 4;

pub const Cord = struct {
    x: isize = 0,
    y: isize = 0,
};

const Layer = enum {
    norm,
    top,
    bottom,
    temp,
    null, // "Nop" layer
};

pub const Attr = enum {
    reset,
    bold,
    dim,
    italic,
    underline,
    reverse,
    reverse_bold, // Not in standard
    reverse_dim,
    strikeout,
};

pub const Color = enum {
    none,
    black,
    white,
    gray,
    red,
    blue,
    green,
};

pub const Style = struct {
    attr: ?Attr = null,
    fg: ?Color = null,
    bg: ?Color = null,

    pub const BoldGreen: Style = .{ .attr = .bold, .fg = .green };
    pub const Green: Style = .{ .fg = .green };
};

pub const Lexeme = struct {
    bytes: []const u8,
    padding: ?Padding = null,
    style: ?Style = null,

    pub const Padding = struct {
        bytes: u8 = ' ',
        left: i32 = 0,
        right: i32 = 0,
    };

    pub fn str(s: []const u8) Lexeme {
        return .{ .bytes = s };
    }

    pub fn styled(s: []const u8, sty: Style) Lexeme {
        return .{ .bytes = s, .style = sty };
    }
};

var colorize: bool = true;

var movebuf: [32]u8 = undefined;
const Direction = enum {
    Up,
    Down,
    Left,
    Right,
    Absolute,
};

pub const Drawable = @This();

pub fn init(a: Allocator, hsh: *Hsh) !Drawable {
    colorize = hsh.enabled(Features.Colorize);
    const buffer = try a.alloc(u8, draw_buffer_size);
    return .{
        .writer = &hsh.tty.out.w.interface,
        .unbuffered = &hsh.tty.out.unbuffered.interface,
        .before = .initBuffer(buffer[0..][0 .. draw_buffer_size / 4]),
        .b = .initBuffer(buffer[draw_buffer_size / 4 * 1 ..][0 .. draw_buffer_size / 4]),
        .right = .initBuffer(buffer[draw_buffer_size / 4 * 2 ..][0 .. draw_buffer_size / 4]),
        .after = .initBuffer(buffer[draw_buffer_size / 4 * 3 ..][0 .. draw_buffer_size / 4]),
        .internal = buffer,
    };
}

pub fn key(d: *Drawable, c: u8) !void {
    try d.unbuffered.writeByte(c);
}

pub fn move(d: *Drawable, comptime dir: Direction, width: u16) !void {
    if (width == 0) return;
    try d.writer.print(comptime switch (dir) {
        .Up => "\x1B[{}A",
        .Down => "\x1B[{}B",
        .Left => "\x1B[{}D",
        .Right => "\x1B[{}C",
        .Absolute => "\x1B[{}G",
    }, .{width});
}

pub fn clear(d: *Drawable) void {
    d.before.clearRetainingCapacity();
    d.after.clearRetainingCapacity();
    d.right.clearRetainingCapacity();
    d.b.clearRetainingCapacity();
}

pub fn reset(d: *Drawable) void {
    d.clear();
    d.lines = 0;
    d.cursor = 0;
}

pub fn raze(d: *Drawable, a: Allocator) void {
    a.free(d.internal);
}

fn setAttr(buf: *DrawBuf, attr: ?Attr) void {
    if (attr) |a| {
        switch (a) {
            .bold => buf.appendSliceBounded("\x1B[1m") catch unreachable,
            .dim => buf.appendSliceBounded("\x1B[2m") catch unreachable,
            .reverse => buf.appendSliceBounded("\x1B[7m") catch unreachable,
            .reverse_bold => buf.appendSliceBounded("\x1B[1m\x1B[7m") catch unreachable,
            .reverse_dim => buf.appendSliceBounded("\x1B[2m\x1B[7m") catch unreachable,
            else => buf.appendSliceBounded("\x1B[0m") catch unreachable,
        }
    }
}

fn bgColor(buf: *DrawBuf, c: ?Color) void {
    if (c) |bg| {
        const color = switch (bg) {
            .red => "\x1B[41m",
            .blue => "\x1B[34m",
            .green => "\x1B[42m",
            else => "\x1B[39m",
        };
        buf.appendSliceBounded(color) catch unreachable;
    }
}

fn fgColor(buf: *DrawBuf, c: ?Color) void {
    if (c) |fg| {
        const color = switch (fg) {
            .red => "\x1B[31m",
            .blue => "\x1B[34m",
            .green => "\x1B[32m",
            else => "\x1B[39m",
        };
        buf.appendSliceBounded(color) catch unreachable;
    }
}

fn drawLexeme(buf: *DrawBuf, _: usize, _: usize, l: Lexeme) void {
    if (l.bytes.len == 0) return;
    if (colorize) {
        if (l.style) |style| {
            setAttr(buf, style.attr);
            fgColor(buf, style.fg);
            bgColor(buf, style.bg);
        }
    }
    buf.appendSliceBounded(l.bytes) catch unreachable;
    if (colorize and l.style != null) {
        bgColor(buf, .none);
        fgColor(buf, .none);
        setAttr(buf, .reset);
    }
}

fn drawLexemeMany(buf: *DrawBuf, x: usize, y: usize, s: []const Lexeme) void {
    for (s) |sib| drawLexeme(buf, x, y, sib);
}

fn drawLexemeTree(buf: *DrawBuf, x: usize, y: usize, t: []const []const Lexeme) void {
    for (t) |set| drawLexemeMany(buf, x, y, set);
}

pub fn drawBefore(d: *Drawable, t: []const Lexeme) void {
    drawLexemeMany(&d.before, 0, 0, t);
    d.before.appendSliceBounded("\x1B[K") catch unreachable;
}

pub fn drawAfter(d: *Drawable, t: []const Lexeme) void {
    d.after.appendBounded('\n') catch unreachable;
    drawLexemeMany(&d.after, 0, 0, t);
}

pub fn drawRight(d: *Drawable, tree: []const Lexeme) void {
    drawLexemeMany(&d.right, 0, 0, tree);
}

pub fn draw(d: *Drawable, tree: []const Lexeme) void {
    drawLexemeMany(&d.b, 0, 0, tree);
}

/// Renders the "prompt" line
/// hsh is based around the idea of user keyboard-driven input, so plugin should
/// provide the context, expecting not to know about, or touch the final user
/// input line
pub fn render(d: *Drawable) error{WriteFailed}!void {
    try d.writer.writeByte('\r');
    try d.move(.Up, d.lines);
    d.lines = 0;
    // TODO vert position

    if (d.before.items.len > 0) {
        try d.writer.writeAll(d.before.items);
        try d.writer.writeByte('\n');
        d.lines += @intCast(1 + count(u8, d.before.items, '\n'));
    }

    if (d.after.items.len > 0) {
        try d.writer.writeAll(d.after.items);
        const after_lines = count(u8, d.after.items, '\n');
        try d.writer.writeAll("\x1B[K");
        try d.move(.Up, @intCast(after_lines));
    }

    if (d.right.items.len > 0) {
        try d.writer.writeAll("\r\x1B[K");
        // Assumes that movement becomes a nop once at term width
        try d.move(.Absolute, @intCast(d.term_size.x));
        // printable [...] to give a blank buffer (I hate line wrapping)
        const printable = countPrintable(d.right.items);
        try d.move(.Left, @intCast(printable));
        try d.writer.writeAll(d.right.items);
    }

    try d.writer.writeAll("\r\x1B[K");
    try d.writer.writeByte('\r');
    try d.writer.writeAll(d.b.items);
    try d.move(.Left, @truncate(d.cursor));
    // TODO save backtrack line count?
    d.lines += @intCast(count(u8, d.b.items, '\n'));
    try d.writer.flush();
}

pub fn clearCtx(d: *Drawable) void {
    d.move(.Up, d.lines) catch {};
    d.writer.writeAll("\r\x1B[J") catch {};
    d.writer.writeAll(d.b.items) catch {};
    d.lines = @intCast(count(u8, d.b.items, '\n'));
}

/// Any context before the prompt line should be cleared and replaced with the
/// prompt before exec.
pub fn clear_before_exec(_: *Drawable) void {}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const DrawBuf = ArrayList(u8);
const Tty = @import("tty.zig");
const Hsh = @import("hsh.zig");
const Features = Hsh.Features;
const countPrintable = Layout.countPrintable;
const count = std.mem.countScalar;
