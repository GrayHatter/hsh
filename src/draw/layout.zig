const std = @import("std");
const Allocator = std.mem.Allocator;
const draw = @import("../draw.zig");
const LexTree = draw.LexTree;
const Lexeme = draw.Lexeme;

/// TODO unicode support when?
pub fn countPrintable(buf: []const u8) usize {
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

/// Returns the longest width + 1 to account for whitespace during layout
fn maxWidth(items: []const []const u8) u32 {
    var max: u32 = 0;
    for (items) |item| {
        var len = @truncate(u32, countPrintable(item));
        max = @max(max, len);
    }
    return max + 1;
}

/// Caller owns memory, strings **are** duplicated
/// LexTree,
/// LexTree.children.LexTree,
/// LexTree.children.LexTree.sibling.Lexem,
/// LexTree.children.LexTree.sibling.Lexem[..].char must all be free'd
pub fn layoutGrid(a: Allocator, items: []const []const u8, w: u32) ![]LexTree {
    var root = try a.alloc(LexTree, 1);
    // errdefer
    const largest = maxWidth(items);
    const cols: u32 = @max(w / largest, 1);
    const rows: u32 = @truncate(u32, items.len) / cols + @as(u32, if (items.len % cols > 0) 1 else 0);

    var trees = try a.alloc(LexTree, rows);
    var lexes = try a.alloc(Lexeme, items.len);
    // errdefer

    root[0] = LexTree{ .children = trees };

    for (0..rows) |row| {
        root[0].children[row] = LexTree{
            .sibling = lexes[row * cols .. @min((row + 1) * cols, items.len)],
        };
        for (0..cols) |col| {
            root[0].children[row].sibling[col] = Lexeme{
                .char = try a.dupe(u8, items[row * cols + col]),
            };
        }
    }

    return root;
}

/// caller owns the memory
pub fn layoutTable(a: Allocator) !*LexTree {
    return layoutGrid(a);
}

test "count printable" {
    try std.testing.expect(countPrintable(
        "\x1B[1m\x1B[0m\x1B[1m BLERG \x1B[0m\x1B[1m\x1B[0m\n",
    ) == 7);
}

test "grid" {
    var a = std.testing.allocator;
    const strs = [_][]const u8{
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

    const rows = try layoutGrid(a, &strs, 60);
    //std.debug.print("rows {any}\n", .{rows});
    for (rows[0].children) |child| {
        //std.debug.print("  row {any}\n", .{child});
        for (child.sibling) |sib| {
            //std.debug.print("    sib {s}\n", .{sib.char});
            a.free(sib.char);
        }
    }

    try std.testing.expect(rows[0].children.len == 3);
    try std.testing.expect(rows[0].children[0].sibling.len == 4);

    // I have my good ol' C pointers back... this is so nice :)
    a.free(@ptrCast(*[strs.len]Lexeme, rows[0].children[0].sibling));
    a.free(rows[0].children);
    a.free(rows);
}
