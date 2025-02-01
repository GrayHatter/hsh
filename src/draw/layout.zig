const std = @import("std");
const Allocator = std.mem.Allocator;
const Draw = @import("../draw.zig");
const Cord = Draw.Cord;
const Lexeme = Draw.Lexeme;
const dupePadded = @import("../mem.zig").dupePadded;

pub const Error = Draw.Error || error{
    ViewportFit,
    ItemCount,
    LayoutUnable,
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

/// items aren't duplicated and must outlive Lexeme based grid
pub fn grid(a: Allocator, items: []const []const u8, wh: Cord) Error![][]Lexeme {
    // errdefer
    const largest = maxWidth(items);
    if (largest > wh.x) return Error.ViewportFit;

    const stride: usize = @max(@divFloor(wh.x, largest), 1);
    const full_count: usize = items.len / stride;
    const remainder: usize = items.len % stride;
    const row_count: usize = full_count + @as(usize, if (remainder != 0) 1 else 0);

    const rows = try a.alloc([]Lexeme, row_count);

    // errdefer

    var i: usize = 0;
    root: for (rows) |*row| {
        row.* = if (i < stride * full_count)
            try a.alloc(Lexeme, stride)
        else
            try a.alloc(Lexeme, remainder);

        for (row.*) |*col| {
            const char = items[i];
            col.* = Lexeme{
                .char = char,
                .padding = .{ .right = @intCast(largest - countPrintable(char)) },
            };
            i += 1;
            if (i >= items.len) break :root;
        }
    }

    return rows;
}

fn sum(cs: []u16) u32 {
    var total: u32 = 0;
    for (cs) |c| total += c;
    return total;
}

pub fn tableSize(a: Allocator, items: []const Lexeme, wh: Cord) Error![]u16 {
    var colsize: []u16 = try a.alloc(u16, 0);
    errdefer a.free(colsize);

    var cols = items.len;
    var rows: u32 = 0;

    first: while (true) : (cols -= 1) {
        if (cols == 0) return Error.LayoutUnable;
        if (countLexems(items[0..cols]) > wh.x) continue;

        colsize = try a.realloc(colsize, cols);
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

pub fn tableLexeme(a: Allocator, items: []const Lexeme, wh: Cord) Error![][]Lexeme {
    const largest = maxWidthLexem(items);
    if (largest > wh.x) return Error.ViewportFit;

    const colsz = try tableSize(a, items, wh);
    const stride = colsz.len;
    defer a.free(colsz);
    const row_count = std.math.divCeil(usize, items.len, stride) catch unreachable;
    const remainder = (items.len % stride) -| 1;

    const rows = try a.alloc([]Lexeme, row_count);
    for (rows, 0..) |*row, i| {
        const row_num = if (i == row_count - 1 and i != 0) remainder else stride;

        row.* = try a.alloc(Lexeme, row_num);
        for (row.*, 0..) |*col, j| {
            const offset = i * stride + j;
            col.char = try dupePadded(a, items[offset].char, colsz[j]);
            col.style = items[offset].style;
        }
    }
    return rows;
}

/// Caller owns memory, strings **are** duplicated
pub fn tableChar(a: Allocator, items: []const []const u8, wh: Cord) Error![][]Lexeme {
    const lexes = try a.alloc(Lexeme, items.len);
    defer a.free(lexes);

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
    const err = tableChar(a, strs12[0..], Cord{ .x = 50, .y = 1 });
    try std.testing.expectError(Error.ItemCount, err);

    const rows = try tableChar(a, strs12[0..], Cord{ .x = 50, .y = 5 });
    //std.debug.print("rows {any}\n", .{rows});
    for (rows) |row| {
        //std.debug.print("  row {any}\n", .{row});
        for (row) |col| {
            //std.debug.print("    sib {s}\n", .{sib.char});
            a.free(col.char);
        }
    }

    try std.testing.expect(rows.len == 3);
    try std.testing.expect(rows[0].len == 4);

    for (rows) |row| a.free(row);
    a.free(rows);
}

test "grid 3*4" {
    var a = std.testing.allocator;

    const rows = try grid(a, strs12[0..], Cord{ .x = 50, .y = 1 });
    //std.debug.print("rows {any}\n", .{rows});

    try std.testing.expect(rows.len == 4);
    try std.testing.expect(rows[0].len == 3);
    try std.testing.expect(rows[3].len == 3);

    for (rows) |row| a.free(row);
    a.free(rows);
}

test "grid 3*4 + 1" {
    var a = std.testing.allocator;
    const rows = try grid(a, &strs13, Cord{ .x = 50, .y = 1 });

    try std.testing.expectEqual(rows.len, 5);
    try std.testing.expect(rows[0].len == 3);
    try std.testing.expect(rows[4].len == 1);

    for (rows) |row| a.free(row);
    a.free(rows);
}
