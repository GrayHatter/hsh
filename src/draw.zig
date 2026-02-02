cursor: u32 = 0,
cursor_reposition: bool = true,
writer: *Writer,
unbuffered: *Writer,
before: Writer = undefined,
b: Writer = undefined,
right: Writer = undefined,
after: Writer = undefined,
term_size: Cord = .{},
lines: u16 = 0,
internal: []u8,

pub const Layout = @import("draw/layout.zig");

const draw_buffer_size = 8192 * 4 * 16;

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

    pub fn format(a: Attr, w: *Writer) !void {
        switch (a) {
            .bold => try w.writeAll("\x1B[1m"),
            .dim => try w.writeAll("\x1B[2m"),
            .reverse => try w.writeAll("\x1B[7m"),
            .reverse_bold => try w.writeAll("\x1B[1m\x1B[7m"),
            .reverse_dim => try w.writeAll("\x1B[2m\x1B[7m"),
            else => try w.writeAll("\x1B[0m"),
        }
    }
};

pub const Color = enum {
    none,
    black,
    white,
    gray,
    red,
    blue,
    green,

    pub fn fmtBg(c: Color, w: *Writer) !void {
        try w.writeAll(switch (c) {
            .red => "\x1B[41m",
            .blue => "\x1B[34m",
            .green => "\x1B[42m",
            else => "\x1B[39m",
        });
    }

    pub fn fmtFg(c: Color, w: *Writer) !void {
        try w.writeAll(switch (c) {
            .red => "\x1B[31m",
            .blue => "\x1B[34m",
            .green => "\x1B[32m",
            else => "\x1B[39m",
        });
    }
};

pub const Style = struct {
    attr: ?Attr = null,
    fg: ?Color = null,
    bg: ?Color = null,

    pub const bold_green: Style = .{ .attr = .bold, .fg = .green };
    pub const green: Style = .{ .fg = .green };
    pub const bold_blue: Style = .{ .attr = .bold, .fg = .blue };
    pub const red: Style = .{ .fg = .red };
    pub const red_bg: Style = .{ .bg = .red };
    pub const red_bold: Style = .{ .fg = .red, .attr = .bold };

    pub fn format(s: Style, w: *Writer) !void {
        if (s.attr) |a| try a.format(w);
        if (s.fg) |fg| try fg.fmtFg(w);
        if (s.bg) |bg| try bg.fmtBg(w);
    }

    pub fn reset(_: Style, w: *Writer) !void {
        try Color.none.fmtBg(w);
        try Color.none.fmtFg(w);
        try Attr.reset.format(w);
    }
};

pub const Lexeme = struct {
    bytes: []const u8,
    formatFn: ?*const fmt.FmtFn = null,
    padding: ?Padding = null,
    style: ?Style = null,

    pub const Padding = struct {
        byte: u8 = ' ',
        left: u16 = 0,
        right: u16 = 0,
    };

    pub fn str(s: []const u8) Lexeme {
        return .{ .bytes = s };
    }

    pub fn styled(s: []const u8, sty: Style) Lexeme {
        return .{ .bytes = s, .style = sty };
    }

    pub fn alt(s: []const u8, comptime fn_name: @EnumLiteral()) Lexeme {
        return .{
            .bytes = s,
            .formatFn = @field(fmt, @tagName(fn_name)),
        };
    }

    pub fn format(l: Lexeme, w: *Writer) !void {
        if (l.padding) |pad| _ = try w.splatByte(pad.byte, pad.left);

        if (l.style) |style| _ = try w.print("{f}", .{style});
        if (l.formatFn) |formatFn| {
            try formatFn(l.bytes, w);
        } else {
            try w.print("{s}", .{l.bytes});
        }
        if (l.style) |style| try style.reset(w);

        if (l.padding) |pad| _ = try w.splatByte(pad.byte, pad.right);
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
    colorize = hsh.enabled(.colorize);
    const buffer = try a.alloc(u8, draw_buffer_size);
    return .{
        .writer = &hsh.tty.out.w.interface,
        .unbuffered = &hsh.tty.out.unbuffered.interface,
        .before = .fixed(buffer[0..][0 .. draw_buffer_size / 4]),
        .b = .fixed(buffer[draw_buffer_size / 4 * 1 ..][0 .. draw_buffer_size / 4]),
        .right = .fixed(buffer[draw_buffer_size / 4 * 2 ..][0 .. draw_buffer_size / 4]),
        .after = .fixed(buffer[draw_buffer_size / 4 * 3 ..][0 .. draw_buffer_size / 4]),
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
    _ = d.before.consumeAll();
    _ = d.after.consumeAll();
    _ = d.right.consumeAll();
    _ = d.b.consumeAll();
}

pub fn reset(d: *Drawable) void {
    d.clear();
    d.lines = 0;
    d.cursor = 0;
}

pub fn raze(d: *Drawable, a: Allocator) void {
    a.free(d.internal);
}

//fn drawLexeme(buf: *Writer, _: usize, _: usize, l: Lexeme) void {
//    if (l.bytes.len == 0) return;
//    if (colorize) {
//        if (l.style) |style| {
//            setAttr(buf, style.attr);
//            fgColor(buf, style.fg);
//            bgColor(buf, style.bg);
//        }
//    }
//    buf.appendSliceBounded(l.bytes) catch unreachable;
//    if (colorize and l.style != null) {
//        bgColor(buf, .none);
//        fgColor(buf, .none);
//        setAttr(buf, .reset);
//    }
//}

fn drawLexemeMany(buf: *Writer, _: usize, _: usize, s: []const Lexeme) void {
    for (s) |sib| buf.print("{f}", .{sib}) catch unreachable;
}

fn drawLexemeTree(buf: *Writer, _: usize, _: usize, tree: []const []const Lexeme) void {
    for (tree) |t| buf.print("{f}", .{t}) catch unreachable;
}

pub fn drawBefore(d: *Drawable, t: []const Lexeme) void {
    drawLexemeMany(&d.before, 0, 0, t);
    d.before.writeAll("\x1B[K") catch unreachable;
}

pub fn drawAfter(d: *Drawable, t: []const Lexeme) void {
    d.after.writeByte('\n') catch unreachable;
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

    if (d.before.buffered().len > 0) {
        try d.writer.writeAll(d.before.buffered());
        try d.writer.writeByte('\n');
        d.lines += @intCast(1 + count(u8, d.before.buffered(), '\n'));
    }

    if (d.after.buffered().len > 0) {
        try d.writer.writeAll(d.after.buffered());
        const after_lines = count(u8, d.after.buffered(), '\n');
        try d.writer.writeAll("\x1B[K");
        try d.move(.Up, @intCast(after_lines));
    }

    if (d.right.buffered().len > 0) {
        try d.writer.writeAll("\r\x1B[K");
        // Assumes that movement becomes a nop once at term width
        try d.move(.Absolute, @intCast(d.term_size.x));
        // printable [...] to give a blank buffer (I hate line wrapping)
        const printable = countPrintable(d.right.buffered());
        try d.move(.Left, @intCast(printable));
        try d.writer.writeAll(d.right.buffered());
    }

    try d.writer.writeAll("\r\x1B[K");
    try d.writer.writeByte('\r');
    try d.writer.writeAll(d.b.buffered());
    try d.move(.Left, @truncate(d.cursor));
    // TODO save backtrack line count?
    d.lines += @intCast(count(u8, d.b.buffered(), '\n'));
    try d.writer.flush();
}

pub fn clearCtx(d: *Drawable) void {
    d.move(.Up, d.lines) catch {};
    d.writer.writeAll("\r\x1B[J") catch {};
    d.writer.writeAll(d.b.buffered()) catch {};
    d.lines = @intCast(count(u8, d.b.buffered(), '\n'));
}

/// Any context before the prompt line should be cleared and replaced with the
/// prompt before exec.
pub fn clear_before_exec(_: *Drawable) void {}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Tty = @import("tty.zig");
const Hsh = @import("hsh.zig");
const Features = Hsh.Features;
const countPrintable = Layout.countPrintable;
const count = std.mem.countScalar;
const fmt = @import("fmt.zig");
