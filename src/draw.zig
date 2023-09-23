const std = @import("std");
const Allocator = std.mem.Allocator;
const TTY = @import("tty.zig").TTY;
const ArrayList = std.ArrayList;
const hsh_ = @import("hsh.zig");
const HSH = hsh_.HSH;
const Features = hsh_.Features;
const countPrintable = Layout.countPrintable;

pub const Layout = @import("draw/layout.zig");

const DrawBuf = ArrayList(u8);

pub const Cord = struct {
    x: isize = 0,
    y: isize = 0,
};

pub const Err = error{
    Unknown,
    OutOfMemory,
    WriterIO,
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
};

pub const Lexeme = struct {
    char: []const u8,
    style: Style = .{},
};

const LexSibling = []Lexeme;

pub const LexTree = union(enum) {
    lex: Lexeme,
    siblings: LexSibling,
    children: []LexTree,
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

pub const Drawable = struct {
    alloc: Allocator,
    tty: *TTY,
    hsh: *HSH,
    cursor: u32 = 0,
    cursor_reposition: bool = true,
    before: DrawBuf = undefined,
    b: DrawBuf = undefined,
    right: DrawBuf = undefined,
    after: DrawBuf = undefined,
    term_size: Cord = .{},
    lines: u16 = 0,

    pub fn init(hsh: *HSH) Err!Drawable {
        colorize = hsh.enabled(Features.Colorize);
        return .{
            .alloc = hsh.alloc,
            .tty = &hsh.tty,
            .hsh = hsh,
            .before = DrawBuf.init(hsh.alloc),
            .b = DrawBuf.init(hsh.alloc),
            .right = DrawBuf.init(hsh.alloc),
            .after = DrawBuf.init(hsh.alloc),
        };
    }

    pub fn write(d: *Drawable, out: []const u8) Err!usize {
        return d.tty.out.write(out) catch Err.WriterIO;
    }

    pub fn move(_: *Drawable, comptime dir: Direction, count: u16) []const u8 {
        if (count == 0) return "";
        const fmt = comptime switch (dir) {
            .Up => "\x1B[{}A",
            .Down => "\x1B[{}B",
            .Left => "\x1B[{}D",
            .Right => "\x1B[{}C",
            .Absolute => "\x1B[{}G",
        };

        return std.fmt.bufPrint(&movebuf, fmt, .{count}) catch return &movebuf; // #YOLO
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

    pub fn raze(d: *Drawable) void {
        d.before.clearAndFree();
        d.after.clearAndFree();
        d.right.clearAndFree();
        d.b.clearAndFree();
    }
};

fn setAttr(buf: *DrawBuf, attr: ?Attr) Err!void {
    if (attr) |a| {
        switch (a) {
            .bold => try buf.appendSlice("\x1B[1m"),
            .dim => try buf.appendSlice("\x1B[2m"),
            .reverse => try buf.appendSlice("\x1B[7m"),
            .reverse_bold => try buf.appendSlice("\x1B[1m\x1B[7m"),
            .reverse_dim => try buf.appendSlice("\x1B[2m\x1B[7m"),
            else => try buf.appendSlice("\x1B[0m"),
        }
    }
}

fn bgColor(buf: *DrawBuf, c: ?Color) Err!void {
    if (c) |bg| {
        const color = switch (bg) {
            .red => "\x1B[41m",
            .blue => "\x1B[34m",
            .green => "\x1B[42m",
            else => "\x1B[39m",
        };
        try buf.appendSlice(color);
    }
}

fn fgColor(buf: *DrawBuf, c: ?Color) Err!void {
    if (c) |fg| {
        const color = switch (fg) {
            .red => "\x1B[31m",
            .blue => "\x1B[34m",
            .green => "\x1B[32m",
            else => "\x1B[39m",
        };
        try buf.appendSlice(color);
    }
}

fn drawLexeme(buf: *DrawBuf, x: usize, y: usize, l: Lexeme) Err!void {
    if (l.char.len == 0) return;
    _ = x;
    _ = y;
    if (colorize) {
        try setAttr(buf, l.style.attr);
        try fgColor(buf, l.style.fg);
        try bgColor(buf, l.style.bg);
    }
    try buf.appendSlice(l.char);
    if (colorize) {
        try bgColor(buf, .none);
        try fgColor(buf, .none);
        try setAttr(buf, .reset);
    }
}

fn drawSibling(buf: *DrawBuf, x: usize, y: usize, s: []Lexeme) Err!void {
    for (s) |sib| {
        try drawLexeme(buf, x, y, sib);
    }
}

fn drawTree(buf: *DrawBuf, x: usize, y: usize, t: LexTree) Err!void {
    return switch (t) {
        LexTree.lex => |lex| drawLexeme(buf, x, y, lex),
        LexTree.siblings => |sib| drawSibling(buf, x, y, sib),
        LexTree.children => |child| drawTrees(buf, x, y, child),
    };
}

fn drawTrees(buf: *DrawBuf, x: usize, y: usize, tree: []LexTree) Err!void {
    for (tree) |t| {
        try drawTree(buf, x, y, t);
    }
}

fn countLines(buf: []const u8) u16 {
    return @truncate(std.mem.count(u8, buf, "\n"));
}

pub fn drawBefore(d: *Drawable, t: LexTree) !void {
    try drawTree(&d.before, 0, 0, t);
    try d.before.appendSlice("\x1B[K");
}

pub fn drawAfter(d: *Drawable, t: LexTree) !void {
    try d.after.append('\n');
    try drawTree(&d.after, 0, 0, t);
}

pub fn drawRight(d: *Drawable, tree: LexTree) !void {
    try drawTree(&d.right, 0, 0, tree);
}

pub fn draw(d: *Drawable, tree: LexTree) !void {
    try drawTree(&d.b, 0, 0, tree);
}

/// Renders the "prompt" line
/// hsh is based around the idea of user keyboard-driven input, so plugin should
/// provide the context, expecting not to know about, or touch the final user
/// input line
pub fn render(d: *Drawable) Err!void {
    _ = try d.write("\r");
    _ = try d.write(d.move(.Up, d.lines));
    d.lines = 0;
    var cntx: usize = 0;
    // TODO vert position

    if (d.before.items.len > 0) {
        cntx += try d.write(d.before.items);
        _ = try d.write("\n");
        d.lines += 1 + countLines(d.before.items);
    }

    if (d.after.items.len > 0) {
        cntx += try d.write(d.after.items);
        const after_lines = countLines(d.after.items);
        _ = try d.write("\x1B[K");
        _ = try d.write(d.move(.Up, after_lines));
    }

    if (d.right.items.len > 0) {
        cntx += try d.write("\r\x1B[K");
        // Assumes that movement becomes a nop once at term width
        cntx += try d.write(d.move(.Absolute, @intCast(d.term_size.x)));
        // printable [...] to give a blank buffer (I hate line wrapping)
        const printable = countPrintable(d.right.items);
        cntx += try d.write(d.move(.Left, @intCast(printable)));
        cntx += try d.write(d.right.items);
    }

    if (cntx == 0) _ = try d.write("\r\x1B[K");
    _ = try d.write("\r");
    _ = try d.write(d.b.items);
    _ = try d.write(d.move(.Left, @truncate(d.cursor)));
    // TODO save backtrack line count?
    d.lines += countLines(d.b.items);
}

pub fn clearCtx(d: *Drawable) void {
    _ = d.write(d.move(.Up, d.lines)) catch {};
    _ = d.write("\r\x1B[J") catch {};
    _ = d.write(d.b.items) catch {};
    d.lines = countLines(d.b.items);
}

/// Any context before the prompt line should be cleared and replaced with the
/// prompt before exec.
pub fn clear_before_exec(_: *Drawable) void {}

pub fn newLine(d: *Drawable) Err!void {
    _ = try d.write("\n");
}

// TODO rm -rf
/// feeling lazy, might delete later
pub fn printAfter(d: *const Drawable, comptime c: []const u8, a: anytype) !void {
    const w = d.tty.out;
    _ = try w.write("\r\n");
    _ = try w.print(c, a);
    _ = try w.write("\x1B[K");
    _ = try w.write("\x1B[A");
    _ = try w.write("\r");
}
