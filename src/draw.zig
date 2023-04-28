const std = @import("std");
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
    fg: Color = .None,
    bg: Color = .None,
};

const LexSibling = []Lexeme;

pub const LexTree = union(enum) {
    lex: Lexeme,
    sibling: LexSibling,
    children: []LexTree,
};

pub const Drawable = struct {
    w: Writer,
    cursor: u32 = 0,
    cursor_reposition: bool = true,
};

fn set_attr(buf: *ArrayList(u8), attr: Attr) DrawErr!void {
    switch (attr) {
        .Bold => buf.appendSlice("\x1B[1m") catch return DrawErr.Memory,
        else => buf.appendSlice("\x1B[0m") catch return DrawErr.Memory,
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
    buf.appendSlice(l.char) catch return DrawErr.Memory;
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

pub fn render(d: *const Drawable, tree: LexTree) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer = ArrayList(u8).init(a);
    try buffer.append('\r');
    try buffer.appendSlice("\x1B[K");
    try render_tree(&buffer, 0, 0, tree);
    if (d.cursor_reposition) {
        var move = d.cursor;
        while (move > 0) : (move -= 1) {
            try buffer.appendSlice("\x1B[D");
        }
    }

    // finally
    _ = try d.w.write(buffer.items);
}
