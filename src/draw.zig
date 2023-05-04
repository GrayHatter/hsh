const std = @import("std");
const Allocator = std.mem.Allocator;
const TTY = @import("tty.zig").TTY;
const ArrayList = std.ArrayList;

const DrawBuf = ArrayList(u8);

pub const Cord = struct {
    x: isize = 0,
    y: isize = 0,
};

pub const DrawErr = error{
    Unknown,
    Memory,
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

pub const Drawable = struct {
    alloc: Allocator,
    tty: TTY,
    cursor: u32 = 0,
    cursor_reposition: bool = true,
    before: DrawBuf = undefined,
    b: DrawBuf = undefined,
    right: DrawBuf = undefined,
    after: DrawBuf = undefined,
    term_size: Cord = .{},

    pub fn init(a: Allocator, tty: TTY) DrawErr!Drawable {
        return .{
            .alloc = a,
            .tty = tty,
            .before = DrawBuf.init(a),
            .b = DrawBuf.init(a),
            .right = DrawBuf.init(a),
            .after = DrawBuf.init(a),
        };
    }

    pub fn raze(_: *Drawable) void {}
};

fn setAttr(buf: *DrawBuf, attr: Attr) DrawErr!void {
    switch (attr) {
        .Bold => buf.appendSlice("\x1B[1m") catch return DrawErr.Memory,
        else => buf.appendSlice("\x1B[0m") catch return DrawErr.Memory,
    }
}

fn bgColor(buf: *DrawBuf, c: ?Color) DrawErr!void {
    if (c) |bg| {
        switch (bg) {
            .Red => buf.appendSlice("\x1B[41m") catch return DrawErr.Memory,
            .Blue => buf.appendSlice("\x1B[34m") catch return DrawErr.Memory,
            else => buf.appendSlice("\x1B[39m") catch return DrawErr.Memory,
        }
    }
}

fn fgColor(buf: *DrawBuf, c: ?Color) DrawErr!void {
    if (c) |fg| {
        switch (fg) {
            .Blue => buf.appendSlice("\x1B[34m") catch return DrawErr.Memory,
            else => buf.appendSlice("\x1B[39m") catch return DrawErr.Memory,
        }
    }
}

fn drawLexeme(buf: *DrawBuf, x: usize, y: usize, l: Lexeme) DrawErr!void {
    _ = x;
    _ = y;
    try setAttr(buf, l.attr);
    try fgColor(buf, l.fg);
    try bgColor(buf, l.bg);
    buf.appendSlice(l.char) catch return DrawErr.Memory;
    try bgColor(buf, .None);
    try fgColor(buf, .None);
    try setAttr(buf, .Reset);
}

fn drawSibling(buf: *DrawBuf, x: usize, y: usize, s: []Lexeme) DrawErr!void {
    for (s) |sib| {
        drawLexeme(buf, x, y, sib) catch return DrawErr.Memory;
    }
}

fn drawTree(buf: *DrawBuf, x: usize, y: usize, t: LexTree) DrawErr!void {
    return switch (t) {
        LexTree.lex => |lex| drawLexeme(buf, x, y, lex),
        LexTree.sibling => |sib| drawSibling(buf, x, y, sib),
        LexTree.children => |child| drawTrees(buf, x, y, child),
    };
}

fn drawTrees(buf: *DrawBuf, x: usize, y: usize, tree: []LexTree) DrawErr!void {
    for (tree) |t| {
        drawTree(buf, x, y, t) catch return DrawErr.Memory;
    }
}

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
    try d.b.append('\r');
    try drawTree(&d.b, 0, 0, tree);
}

/// Renders the "prompt" line
/// hsh is based around the idea of user keyboard-driven input, so plugin should
/// provide the context, expecting not to know about, or touch the final user
/// input line
pub fn render(d: *Drawable) !void {
    const w = d.tty.out;
    if (d.cursor_reposition) {
        var move = d.cursor;
        while (move > 0) : (move -= 1) {
            try d.b.appendSlice("\x1B[D");
        }
    }

    if (d.before.items.len > 0) _ = try w.write(d.before.items);
    if (d.after.items.len > 0) _ = try w.write(d.after.items);
    // TODO seek back up
    if (d.right.items.len > 0) {
        _ = try w.write("\r\x1B[K");
        var moving = [_:0]u8{0} ** 16;
        const right = try std.fmt.bufPrint(&moving, "\x1B[{}G", .{d.term_size.x});
        _ = try w.write(right);
        const left = try std.fmt.bufPrint(&moving, "\x1B[{}D", .{countPrintable(d.right.items)});
        _ = try w.write(left);
        _ = try w.write(d.right.items);
    }

    // finally
    _ = try w.write(d.b.items);
    // TODO save backtrack line count?
    d.before.clearAndFree();
    d.after.clearAndFree();
    d.right.clearAndFree();
    d.b.clearAndFree();
}

/// Any context before the prompt line should be cleared and replaced with the
/// prompt before exec.
pub fn clear_before_context(_: *Drawable) void {}

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
