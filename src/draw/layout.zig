const std = @import("std");
const Allocator = std.mem.Allocator;
const draw = @import("../draw.zig");
const Cord = draw.Cord;
const LexTree = draw.LexTree;
const Lexeme = draw.Lexeme;
const dupePadded = @import("../mem.zig").dupePadded;

pub const Error = error{
    ViewportFit,
    ItemCount,
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
        const len: u32 = countPrintable(item);
        max = @max(max, len);
    }
    return max + 1;
}

fn maxWidthLexem(lexs: []const Lexeme) u32 {
    var max: u32 = 0;
    for (lexs) |lex| {
        const len: u32 = countPrintable(lex.char);
        max = @max(max, len);
    }
    return max + 1;
}

/// Caller owns memory, strings **are** duplicated
/// *LexTree
/// LexTree.siblings.Lexem,
/// LexTree.siblings.Lexem[..].char must all be free'd
pub fn grid(a: Allocator, items: []const []const u8, wh: Cord) Error![]LexTree {
    // errdefer
    const largest = maxWidth(items);
    if (largest > wh.x) return Error.ViewportFit;

    const cols: u32 = @max(@as(u32, @intCast(wh.x)) / largest, 1);
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

pub fn tableSize(a: Allocator, items: []Lexeme, wh: Cord) Error![]u16 {
    var colsize: []u16 = a.alloc(u16, 0) catch return Error.Memory;
    errdefer a.free(colsize);

    var cols = items.len;
    var rows: u32 = 0;

    first: while (true) : (cols -= 1) {
        if (cols == 0) return Error.LayoutUnable;
        if (countLexems(items[0..cols]) > wh.x) continue;

        colsize = a.realloc(colsize, cols) catch return Error.Memory;
        @memset(colsize, 0);
        rows = @as(u32, @truncate(items.len / cols));
        if (items.len % cols > 0) rows += 1;
        if (rows >= wh.y) return Error.ItemCount;

        for (0..rows) |row| {
            const current = items[row * cols .. @min((row + 1) * cols, items.len)];
            for (0..cols) |c| {
                if (row * cols + c >= items.len) break;
                colsize[c] = @max(colsize[c], countPrintable(current[c].char) + 2);
                // padding of 2 feels more comfortable
            }
            if (sum(colsize) > wh.x) continue :first;
        }
        break;
    }
    return colsize;
}

pub fn table(a: Allocator, items: anytype, wh: Cord) Error![]LexTree {
    const T = @TypeOf(items);
    const func = comptime switch (T) {
        []Lexeme => tableLexeme,
        *[][]const u8 => tableChar,
        *const [12][]const u8 => tableChar,
        else => unreachable,
    };
    return func(a, items, wh);
}

fn tableLexeme(a: Allocator, items: []Lexeme, wh: Cord) Error![]LexTree {
    const largest = maxWidthLexem(items);
    if (largest > wh.x) return Error.ViewportFit;

    const colsz = try tableSize(a, items, wh);
    defer a.free(colsz);
    var rows = (items.len / colsz.len);
    if (items.len % colsz.len > 0) rows += 1;

    var trees = a.alloc(LexTree, rows) catch return Error.Memory;

    for (0..rows) |row| {
        trees[row] = LexTree{
            .siblings = items[row * colsz.len .. @min((row + 1) * colsz.len, items.len)],
        };
        for (0..colsz.len) |c| {
            const rowcol = row * colsz.len + c;
            if (rowcol >= items.len) break;
            const old = items[rowcol].char;
            trees[row].siblings[c].char = dupePadded(a, old, colsz[c]) catch return Error.Memory;
        }
    }
    return trees;
}

/// Caller owns memory, strings **are** duplicated
/// *LexTree
/// LexTree.siblings.Lexem,
/// LexTree.siblings.Lexem[..].char must all be free'd
/// items are not reordered
fn tableChar(a: Allocator, items: []const []const u8, wh: Cord) Error![]LexTree {
    const lexes = a.alloc(Lexeme, items.len) catch return Error.Memory;
    errdefer a.free(lexes);

    for (items, lexes) |i, *l| {
        l.*.char = i;
    }

    return tableLexeme(a, lexes, wh);
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
    const err = table(a, &strs12, Cord{ .x = 50, .y = 1 });
    try std.testing.expectError(Error.ItemCount, err);

    const rows = try table(a, &strs12, Cord{ .x = 50, .y = 5 });
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

    const rows = try grid(a, &strs12, Cord{ .x = 50, .y = 1 });
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
    const rows = try grid(a, &strs13, Cord{ .x = 50, .y = 1 });
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
