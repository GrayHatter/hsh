const std = @import("std");
const Allocator = std.mem.Allocator;
const TTY = @import("tty.zig").TTY;
const ArrayList = std.ArrayList;
const hsh_ = @import("hsh.zig");
const HSH = hsh_.HSH;
const Features = hsh_.Features;

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

/// TODO unicode support when?
fn countPrintable(buf: []const u8) usize {
    var total: usize = 0;
    var csi = false;
    for (buf) |b| {
        if (csi) {
            switch (b) {
                0x41...0x5A,
                0x61...0x7A,
                => csi = false,
                else => continue,
            }
            continue;
        }
        switch (b) {
            0x1B => csi = true,
            0x20...0x7E => total += 1,
            else => {}, // not implemented
        }
    }
    return total;
}

fn countLines(buf: []const u8) usize {
    return std.mem.count(u8, buf, '\n');
}

fn drawBefore(d: *Drawable, t: LexTree) !void {
    try d.before.append('\n');
    try drawTree(&d.before, 0, 0, t);
}

fn drawAfter(d: *Drawable, t: LexTree) !void {
    try drawTree(&d.after, 0, 0, t);
    try d.after.append('\n');
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
    var cntx: usize = 0;
    // TODO vert position
    if (d.cursor_reposition) {
        var move = d.cursor;
        while (move > 0) : (move -= 1) {
            d.b.appendSlice("\x1B[D") catch return Err.Memory;
        }
    }

    if (d.before.items.len > 0) cntx += try d.write(d.before.items);
    if (d.after.items.len > 0) cntx += try d.write(d.after.items);
    // TODO seek back up
    if (d.right.items.len > 0) {
        cntx += try d.write("\r\x1B[K");
        var moving = [_:0]u8{0} ** 16;
        // Depending on movement being a nop once at term width
        const right = std.fmt.bufPrint(&moving, "\x1B[{}G", .{d.term_size.x}) catch return Err.Memory;
        cntx += try d.write(right);
        // printable [...] - 2 to give a blank buffer (I hate line wrapping)
        const printable = countPrintable(d.right.items);
        const left = std.fmt.bufPrint(&moving, "\x1B[{}D", .{printable}) catch return Err.Memory;
        cntx += try d.write(left);
        cntx += try d.write(d.right.items);
    }

    if (cntx == 0) _ = try d.write("\r\x1B[K");
    _ = try d.write(d.b.items);
    // TODO save backtrack line count?
    const prompt_lines = std.mem.count(u8, d.b.items, "\n");

    d.reset();
    if (prompt_lines > 0) {
        var moving = [_:0]u8{0} ** 16;
        const up = std.fmt.bufPrint(&moving, "\x1B[{}A", .{prompt_lines}) catch return Err.Memory;
        d.b.appendSlice(up) catch return Err.Memory;
    }
    d.b.append('\r') catch return Err.Memory;
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
