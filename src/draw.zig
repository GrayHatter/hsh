const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.fs.File.Writer;
const ArrayList = std.ArrayList;

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
    w: Writer,
    cursor: u32 = 0,
    cursor_reposition: bool = true,
    b: ArrayList(u8) = undefined,

    pub fn init() Drawable {}

    pub fn raze() void {}
};

fn set_attr(buf: *ArrayList(u8), attr: Attr) DrawErr!void {
    switch (attr) {
        .Bold => buf.appendSlice("\x1B[1m") catch return DrawErr.Memory,
        else => buf.appendSlice("\x1B[0m") catch return DrawErr.Memory,
    }
}

fn bg_color(buf: *ArrayList(u8), c: ?Color) DrawErr!void {
    if (c) |bg| {
        switch (bg) {
            .Red => buf.appendSlice("\x1B[41m") catch return DrawErr.Memory,
            .Blue => buf.appendSlice("\x1B[34m") catch return DrawErr.Memory,
            else => buf.appendSlice("\x1B[39m") catch return DrawErr.Memory,
        }
    }
}

fn fg_color(buf: *ArrayList(u8), c: ?Color) DrawErr!void {
    if (c) |fg| {
        switch (fg) {
            .Blue => buf.appendSlice("\x1B[34m") catch return DrawErr.Memory,
            else => buf.appendSlice("\x1B[39m") catch return DrawErr.Memory,
        }
    }
}

fn render_lexeme(buf: *ArrayList(u8), x: usize, y: usize, l: Lexeme) DrawErr!void {
    _ = x;
    _ = y;
    try set_attr(buf, l.attr);
    try fg_color(buf, l.fg);
    try bg_color(buf, l.bg);
    buf.appendSlice(l.char) catch return DrawErr.Memory;
    try bg_color(buf, .None);
    try fg_color(buf, .None);
    try set_attr(buf, .Reset);
}

fn render_sibling(buf: *ArrayList(u8), x: usize, y: usize, s: []Lexeme) DrawErr!void {
    for (s) |sib| {
        render_lexeme(buf, x, y, sib) catch return DrawErr.Memory;
    }
}

fn render_tree(buf: *ArrayList(u8), x: usize, y: usize, t: LexTree) DrawErr!void {
    return switch (t) {
        LexTree.lex => |lex| render_lexeme(buf, x, y, lex),
        LexTree.sibling => |sib| render_sibling(buf, x, y, sib),
        LexTree.children => |child| render_trees(buf, x, y, child),
    };
}

fn render_trees(buf: *ArrayList(u8), x: usize, y: usize, tree: []LexTree) DrawErr!void {
    for (tree) |t| {
        render_tree(buf, x, y, t) catch return DrawErr.Memory;
    }
}

fn draw_before(_: *Drawable, _: LexTree) !void {}

pub fn draw(d: *Drawable, tree: LexTree) !void {
    try d.b.append('\r');
    try d.b.appendSlice("\x1B[K");
    try render_tree(&d.b, 0, 0, tree);
}

fn draw_after(_: *Drawable, _: LexTree) !void {}

/// Renders the "prompt" line
/// hsh is based around the idea of user keyboard-driven input, so plugin should
/// provide the context, expecting not to know about, or touch the final user
/// input line
pub fn render(d: *Drawable) !void {
    if (d.cursor_reposition) {
        var move = d.cursor;
        while (move > 0) : (move -= 1) {
            try d.b.appendSlice("\x1B[D");
        }
    }

    // finally
    _ = try d.w.write(d.b.items);
    d.b.clearAndFree();
}

// TODO rm -rf
/// feeling lazy, might delete later
pub fn printAfter(d: *const Drawable, comptime c: []const u8, a: anytype) !void {
    _ = try d.w.write("\r\n");
    _ = try d.w.print(c, a);
    _ = try d.w.write("\x1B[K");
    _ = try d.w.write("\x1B[A");
    _ = try d.w.write("\r");
}
