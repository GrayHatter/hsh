const std = @import("std");
const Allocator = std.mem.Allocator;
const draw = @import("../draw.zig");
const LexTree = draw.LexTree;
const Lexeme = draw.Lexeme;
const dupePadded = @import("../mem.zig").dupePadded;

const Error = error{
    SizeTooLarge,
    LayoutUnable,
    Memory,
};

/// TODO unicode support when?
pub fn countPrintable(buf: []const u8) u16 {
    var total: u16 = 0;
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

/// Adds a minimum of 1 whitespace
fn countPrintableMany(bufs: []const []const u8) u32 {
    var total: u32 = 0;
    for (bufs) |buf| {
        total += countPrintable(buf) + 1;
    }
    return total;
}

fn countLexems(lexs: []const Lexeme) u32 {
    var total: u32 = 0;
    for (lexs) |lex| {
        total += countPrintable(lex.char) + 1;
    }
    return total;
}

/// Returns the longest width + 1 to account for whitespace during layout
fn maxWidth(items: []const []const u8) u32 {
    var max: u32 = 0;
    for (items) |item| {
        var len: u32 = countPrintable(item);
        max = @max(max, len);
    }
    return max + 1;
}

fn maxWidthLexem(lexs: []const Lexeme) u32 {
    var max: u32 = 0;
    for (lexs) |lex| {
        var len: u32 = countPrintable(lex.char);
        max = @max(max, len);
    }
    return max + 1;
}

/// Caller owns memory, strings **are** duplicated
/// *LexTree
/// LexTree.siblings.Lexem,
/// LexTree.siblings.Lexem[..].char must all be free'd
pub fn grid(a: Allocator, items: []const []const u8, w: u32) Error![]LexTree {
    // errdefer
    const largest = maxWidth(items);
    if (largest > w) return Error.SizeTooLarge;

    const cols: u32 = @max(w / largest, 1);
    const remainder: u32 = if (items.len % cols > 0) 1 else 0;
    const rows: u32 = @as(u32, @truncate(items.len)) / cols + remainder;

    var trees = a.alloc(LexTree, rows) catch return Error.Memory;
    var lexes = a.alloc(Lexeme, items.len) catch return Error.Memory;
    // errdefer

    for (0..rows) |row| {
        trees[row] = LexTree{
            .siblings = lexes[row * cols .. @min((row + 1) * cols, items.len)],
        };
        for (0..cols) |col| {
            if (items.len <= cols * row + col) break;
            trees[row].siblings[col] = Lexeme{
                .char = dupePadded(a, items[row * cols + col], largest) catch return Error.Memory,
            };
        }
    }

    return trees;
}

fn sum(cs: []u16) u32 {
    var total: u32 = 0;
    for (cs) |c| total += c;
    return total;
}

pub fn tableLexeme(a: Allocator, items: []Lexeme, w: u32) Error![]LexTree {
    const largest = maxWidthLexem(items);
    if (largest > w) return Error.SizeTooLarge;
    var cols_w: []u16 = a.alloc(u16, 0) catch return Error.Memory;
    defer a.free(cols_w);

    var cols = items.len;
    var rows: u32 = 0;

    first: while (true) : (cols -= 1) {
        if (countLexems(items[0..cols]) > w) continue;
        if (cols == 0) return Error.LayoutUnable;

        cols_w = a.realloc(cols_w, cols) catch return Error.Memory;
        @memset(cols_w, 0);
        const remainder: u32 = if (items.len % cols > 0) 1 else 0;
        rows = @as(u32, @truncate(items.len / cols)) + remainder;
        for (0..rows) |row| {
            const current = items[row * cols .. @min((row + 1) * cols, items.len)];
            if (countLexems(current) > w) {
                //continue :first;
            }
            for (0..cols) |c| {
                if (row * cols + c >= items.len) break;
                cols_w[c] = @max(cols_w[c], countPrintable(current[c].char) + 2);
                // padding of 2 feels more comfortable
            }
            if (sum(cols_w) > w) continue :first;
        }
        break;
    }

    var trees = a.alloc(LexTree, rows) catch return Error.Memory;
    // errdefer

    for (0..rows) |row| {
        trees[row] = LexTree{
            .siblings = items[row * cols .. @min((row + 1) * cols, items.len)],
        };
        for (0..cols) |c| {
            const rowcol = row * cols + c;
            if (rowcol >= items.len) break;
            const old = items[rowcol].char;
            trees[row].siblings[c].char = dupePadded(a, old, cols_w[c]) catch return Error.Memory;
        }
    }

    return trees;
}

/// Caller owns memory, strings **are** duplicated
/// *LexTree
/// LexTree.siblings.Lexem,
/// LexTree.siblings.Lexem[..].char must all be free'd
/// items are not reordered
pub fn table(a: Allocator, items: []const []const u8, w: u32) Error![]LexTree {
    var lexes = a.alloc(Lexeme, items.len) catch return Error.Memory;
    errdefer a.free(lexes);

    for (items, lexes) |i, *l| {
        l.*.char = i;
    }

    return tableLexeme(a, lexes, w);
}

test "count printable" {
    try std.testing.expect(countPrintable(
        "\x1B[1m\x1B[0m\x1B[1m BLERG \x1B[0m\x1B[1m\x1B[0m\n",
    ) == 7);
}

const strs12 = [_][]const u8{
    "string",
    "otherstring",
    "blerg",
    "bah",
    "wut",
    "wat",
    "catastrophic ",
    "backtracking",
    "other",
    "some short",
    "some lng",
    "\x1B[1m\x1B[0m\x1B[1mBLERG\x1B[0m\x1B[1m\x1B[0m",
};

const strs13 = strs12 ++ [_][]const u8{"extra4luck"};

test "table" {
    var a = std.testing.allocator;
    const rows = try table(a, &strs12, 50);
    //std.debug.print("rows {any}\n", .{rows});
    for (rows) |row| {
        //std.debug.print("  row {any}\n", .{row});
        for (row.siblings) |sib| {
            //std.debug.print("    sib {s}\n", .{sib.char});
            a.free(sib.char);
        }
    }

    try std.testing.expect(rows.len == 3);
    try std.testing.expect(rows[0].siblings.len == 4);

    // I have my good ol' C pointers back... this is so nice :)
    a.free(@as(*[strs12.len]Lexeme, @ptrCast(rows[0].siblings)));
    a.free(rows);
}

test "grid 3*4" {
    var a = std.testing.allocator;

    const rows = try grid(a, &strs12, 50);
    //std.debug.print("rows {any}\n", .{rows});
    for (rows) |row| {
        //std.debug.print("  row {any}\n", .{row});
        for (row.siblings) |sib| {
            //std.debug.print("    sib {s}\n", .{sib.char});
            a.free(sib.char);
        }
    }

    try std.testing.expect(rows.len == 4);
    try std.testing.expect(rows[0].siblings.len == 3);
    try std.testing.expect(rows[3].siblings.len == 3);

    // I have my good ol' C pointers back... this is so nice :)
    a.free(@as(*[strs12.len]Lexeme, @ptrCast(rows[0].siblings)));
    a.free(rows);
}

test "grid 3*4 + 1" {
    var a = std.testing.allocator;
    const rows = try grid(a, &strs13, 50);
    //std.debug.print("rows {any}\n", .{rows});
    for (rows) |row| {
        //std.debug.print("  row {any}\n", .{row});
        for (row.siblings) |sib| {
            //std.debug.print("    sib {s}\n", .{sib.char});
            a.free(sib.char);
        }
    }

    try std.testing.expectEqual(rows.len, 5);
    try std.testing.expect(rows[0].siblings.len == 3);
    try std.testing.expect(rows[4].siblings.len == 1);

    // I have my good ol' C pointers back... this is so nice :)
    a.free(@as(*[strs13.len]Lexeme, @ptrCast(rows[0].siblings)));
    a.free(rows);
}
