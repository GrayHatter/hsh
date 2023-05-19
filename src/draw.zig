const std = @import("std");
const Allocator = std.mem.Allocator;
const TTY = @import("tty.zig").TTY;
const ArrayList = std.ArrayList;
const hsh_ = @import("hsh.zig");
const HSH = hsh_.HSH;
const Features = hsh_.Features;
const countPrintable = @import("draw/layout.zig").countPrintable;

const DrawBuf = ArrayList(u8);

pub const Cord = struct {
    x: isize = 0,
    y: isize = 0,
};

pub const Err = error{
    Unknown,
    Memory,
    WriterIO,
};

const Layer = enum {
    Norm,
    Top,
    Bottom,
    Temp,
    Null, // "Nop" layer
};

pub const Attr = enum {
    Reset,
    Bold,
    Dim,
    Italic,
    Underline,
    Reverse,
    ReverseBold, // Not in standard
    Strikeout,
};

pub const Color = enum {
    None,
    Black,
    White,
    Gray,
    Red,
    Blue,
    Green,
};

pub const Lexeme = struct {
    char: []const u8,
    attr: Attr = .Reset,
    fg: ?Color = null,
    bg: ?Color = null,
};

const LexSibling = []Lexeme;

pub const LexTree = union(enum) {
    lex: Lexeme,
    sibling: LexSibling,
    children: []LexTree,
};

var colorize: bool = true;

var movebuf = [_:0]u8{0} ** 32;
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
    rel_offset: u16 = 0,

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

    pub fn reset(d: *Drawable) void {
        d.before.clearAndFree();
        d.after.clearAndFree();
        d.right.clearAndFree();
        d.b.clearAndFree();
    }

    pub fn raze(_: *Drawable) void {}
};

fn setAttr(buf: *DrawBuf, attr: Attr) Err!void {
    switch (attr) {
        .Bold => buf.appendSlice("\x1B[1m") catch return Err.Memory,
        .Reverse => buf.appendSlice("\x1B[7m") catch return Err.Memory,
        .ReverseBold => buf.appendSlice("\x1B[1m\x1B[7m") catch return Err.Memory,
        else => buf.appendSlice("\x1B[0m") catch return Err.Memory,
    }
}

fn bgColor(buf: *DrawBuf, c: ?Color) Err!void {
    if (c) |bg| {
        switch (bg) {
            .Red => buf.appendSlice("\x1B[41m") catch return Err.Memory,
            .Blue => buf.appendSlice("\x1B[34m") catch return Err.Memory,
            else => buf.appendSlice("\x1B[39m") catch return Err.Memory,
        }
    }
}

fn fgColor(buf: *DrawBuf, c: ?Color) Err!void {
    if (c) |fg| {
        switch (fg) {
            .Blue => buf.appendSlice("\x1B[34m") catch return Err.Memory,
            else => buf.appendSlice("\x1B[39m") catch return Err.Memory,
        }
    }
}

fn drawLexeme(buf: *DrawBuf, x: usize, y: usize, l: Lexeme) Err!void {
    if (l.char.len == 0) return;
    _ = x;
    _ = y;
    if (colorize) {
        try setAttr(buf, l.attr);
        try fgColor(buf, l.fg);
        try bgColor(buf, l.bg);
    }
    buf.appendSlice(l.char) catch return Err.Memory;
    if (colorize) {
        try bgColor(buf, .None);
        try fgColor(buf, .None);
        try setAttr(buf, .Reset);
    }
}

fn drawSibling(buf: *DrawBuf, x: usize, y: usize, s: []Lexeme) Err!void {
    for (s) |sib| {
        drawLexeme(buf, x, y, sib) catch return Err.Memory;
    }
}

fn drawTree(buf: *DrawBuf, x: usize, y: usize, t: LexTree) Err!void {
    return switch (t) {
        LexTree.lex => |lex| drawLexeme(buf, x, y, lex),
        LexTree.sibling => |sib| drawSibling(buf, x, y, sib),
        LexTree.children => |child| drawTrees(buf, x, y, child),
    };
}

fn drawTrees(buf: *DrawBuf, x: usize, y: usize, tree: []LexTree) Err!void {
    for (tree) |t| {
        drawTree(buf, x, y, t) catch return Err.Memory;
    }
}

fn countLines(buf: []const u8) u16 {
    return @truncate(u16, std.mem.count(u8, buf, "\n"));
}

pub fn drawBefore(d: *Drawable, t: LexTree) !void {
    try d.before.append('\r');
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
    if (d.rel_offset > 0)
        _ = try d.write(d.move(.Up, @truncate(u16, d.rel_offset)));
    //d.b.appendSlice(d.move(.Up, d.rel_offset)) catch return Err.Memory;
    var cntx: usize = 0;
    // TODO vert position
    if (d.cursor_reposition) {
        var move = d.cursor;
        while (move > 0) : (move -= 1) {
            d.b.appendSlice("\x1B[D") catch return Err.Memory;
        }
    }

    var before_lines: u16 = 0;
    if (d.before.items.len > 0) {
        d.before.append('\n') catch return Err.Memory;
        cntx += try d.write(d.before.items);
        before_lines += countLines(d.before.items);
    }
    //defer d.before.appendSlice(d.move(.Up, before_lines)) catch {};

    if (d.after.items.len > 0) {
        cntx += try d.write(d.after.items);
        const after_lines = countLines(d.after.items);
        _ = try d.write("\x1B[K");
        _ = try d.write(d.move(.Up, after_lines));
    }

    if (d.right.items.len > 0) {
        cntx += try d.write("\r\x1B[K");
        // Assumes that movement becomes a nop once at term width
        cntx += try d.write(d.move(.Absolute, @intCast(u16, d.term_size.x)));
        // printable [...] to give a blank buffer (I hate line wrapping)
        const printable = countPrintable(d.right.items);
        cntx += try d.write(d.move(.Left, @intCast(u16, printable)));
        cntx += try d.write(d.right.items);
    }

    if (cntx == 0) _ = try d.write("\r\x1B[K");
    _ = try d.write("\r");
    _ = try d.write(d.b.items);
    // TODO save backtrack line count?
    const prompt_lines = countLines(d.b.items);

    d.rel_offset = before_lines + prompt_lines;
}

pub fn blank(d: *Drawable) void {
    if (d.rel_offset == 0) return;
    _ = d.write(d.move(.Up, d.rel_offset)) catch {};
    _ = d.write("\r\x1B[J") catch {};
    _ = d.write(d.move(.Up, d.rel_offset)) catch {};
    _ = d.write(d.b.items) catch {};
    _ = d.write("\n") catch {};
}

/// Any context before the prompt line should be cleared and replaced with the
/// prompt before exec.
pub fn clear_before_exec(_: *Drawable) void {}

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
