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

/// Returns the longest width + 1 to account for whitespace during layout
fn maxWidth(items: []const []const u8) u32 {
    var max: u32 = 0;
    for (items) |item| {
        var len: u32 = countPrintable(item);
        max = @max(max, len);
    }
    return max + 1;
}

/// Caller owns memory, strings **are** duplicated
/// *LexTree
/// LexTree.siblings.Lexem,
/// LexTree.siblings.Lexem[..].char must all be free'd
pub fn layoutGrid(a: Allocator, items: []const []const u8, w: u32) Error![]LexTree {
    // errdefer
    const largest = maxWidth(items);
    if (largest > w) return Error.SizeTooLarge;

    const cols: u32 = @max(w / largest, 1);
    const remainder: u32 = if (items.len % cols > 0) 1 else 0;
    const rows: u32 = @truncate(u32, items.len) / cols + remainder;

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

/// Caller owns memory, strings **are** duplicated
/// *LexTree
/// LexTree.siblings.Lexem,
/// LexTree.siblings.Lexem[..].char must all be free'd
/// items are not reordered
pub fn layoutTable(a: Allocator, items: []const []const u8, w: u32) Error![]LexTree {
    const largest = maxWidth(items);
    if (largest > w) return Error.SizeTooLarge;
    var cols_w: []u16 = a.alloc(u16, w / largest) catch return Error.Memory;
    // not ideal but it's a reasonable start
    defer a.free(cols_w);

    var cols = items.len;
    var rows: u32 = 0;

    first: while (true) : (cols -= 1) {
        if (countPrintableMany(items[0..cols]) > w) continue;
        if (cols == 0) return Error.LayoutUnable;

        cols_w = a.realloc(cols_w, cols) catch return Error.Memory;
        @memset(cols_w, 0);
        const remainder: u32 = if (items.len % cols > 0) 1 else 0;
        rows = @truncate(u32, items.len / cols) + remainder;
        for (0..rows) |row| {
            const curr_len = @min(items.len, (row + 1) * cols);
            const current = items[row * cols .. curr_len];
            if (countPrintableMany(current) > w) continue :first;
            for (0..cols) |c| {
                if (c + row * cols >= items.len) break;
                cols_w[c] = @max(cols_w[c], countPrintable(current[c]) + 1);
            }
            if (sum(cols_w) > w) continue :first;
        }
        break;
    }

    if (rows == 1) @memset(cols_w, @truncate(u16, largest));
    var trees = a.alloc(LexTree, rows) catch return Error.Memory;
    var lexes = a.alloc(Lexeme, items.len) catch return Error.Memory;
    // errdefer

    for (0..rows) |row| {
        trees[row] = LexTree{
            .siblings = lexes[row * cols .. @min((row + 1) * cols, items.len)],
        };
        for (0..cols) |col| {
            if (col + row * cols >= items.len) break;
            trees[row].siblings[col] = Lexeme{
                .char = dupePadded(a, items[row * cols + col], cols_w[col]) catch return Error.Memory,
            };
        }
    }

    return trees;
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
    const rows = try layoutTable(a, &strs12, 50);
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
    a.free(@ptrCast(*[strs12.len]Lexeme, rows[0].siblings));
    a.free(rows);
}

test "grid 3*4" {
    var a = std.testing.allocator;

    const rows = try layoutGrid(a, &strs12, 50);
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
    a.free(@ptrCast(*[strs12.len]Lexeme, rows[0].siblings));
    a.free(rows);
}

test "grid 3*4 + 1" {
    var a = std.testing.allocator;
    const rows = try layoutGrid(a, &strs13, 50);
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
    a.free(@ptrCast(*[strs13.len]Lexeme, rows[0].siblings));
    a.free(rows);
}
