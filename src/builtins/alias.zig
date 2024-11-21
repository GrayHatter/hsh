const std = @import("std");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const Token = @import("../token.zig");
const bi = @import("../builtins.zig");
const Err = bi.Err;
const Parse = @import("../parse.zig");
const ParsedIterator = Parse.ParsedIterator;
const State = bi.State;
const print = bi.print;
const log = @import("log");
const builtin = @import("builtin");

/// name and value are assumed to be owned by alias, and are expected to be
/// valid between calls to alias.
pub const Alias = struct {
    name: []const u8,
    value: []const u8,

    pub fn format(self: Alias, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len == 4) {
            try std.fmt.format(out, "alias {s}='{s}'", .{ self.name, self.value });
        } else {
            try std.fmt.format(out, "{s}='{s}'", .{ self.name, self.value });
        }
    }
};

// TODO this needs to become a map :/
pub var aliases: std.ArrayList(Alias) = undefined;

pub fn init(a: std.mem.Allocator) void {
    aliases = std.ArrayList(Alias).init(a);
    if (builtin.is_test) return;
    hsh.addState(State{
        .name = "aliases",
        .ctx = &aliases,
        .api = &.{ .save = save },
    }) catch unreachable;
}

pub fn raze(a: std.mem.Allocator) void {
    for (aliases.items) |ar| {
        a.free(ar.name);
        a.free(ar.value);
    }
    aliases.clearAndFree();
}

fn save(h: *HSH, _: *anyopaque) ?[][]const u8 {
    var list = h.alloc.alloc([]u8, aliases.items.len) catch return null;
    for (aliases.items, 0..) |a, i| {
        list[i] = std.fmt.allocPrint(h.alloc, "{save}\n", .{a}) catch continue;
    }
    return list;
}

pub fn alias(h: *HSH, titr: *ParsedIterator) Err!u8 {
    return alias_core(h.alloc, titr);
}

pub fn alias_core(a: std.mem.Allocator, titr: *ParsedIterator) Err!u8 {
    if (!std.mem.eql(u8, "alias", titr.first().cannon())) return Err.InvalidCommand;

    var name: ?[]const u8 = null;
    var value: ?[]const u8 = null;
    const mode: ?[]const u8 = null;
    while (titr.next()) |t| {
        if (name) |_| {
            value = t.cannon();
        } else {
            if (std.mem.indexOf(u8, t.cannon(), "=")) |i| {
                name = t.cannon()[0..i];
                if (t.cannon().len > i + 1) {
                    value = t.cannon()[i + 1 ..];
                    break;
                }
            } else {
                name = t.cannon();
            }
        }
    }

    if (mode) |_| unreachable; // not implemented;

    if (name) |n| {
        if (value) |v| {
            if (try replace(a, n, v)) return 0;
            if (add(a, n, v)) return 0 else |err| return err;
        }
        if (find(n)) |nn| {
            try print("{}\n", .{nn});
        } else {
            try print("no known alias for {s}\n", .{n});
        }
        return 0;
    }

    for (aliases.items) |al| {
        try print("{}\n", .{al});
    }
    return 0;
}

/// alias retains ownership of all memory, and memory lifetime is undefined
pub fn find(src: []const u8) ?*Alias {
    for (aliases.items) |*a| {
        if (std.mem.eql(u8, src, a.name)) {
            return a;
        }
    }
    return null;
}

// TODO might leak
fn add(a: std.mem.Allocator, src: []const u8, dst: []const u8) Err!void {
    log.debug("ALIAS adding {s} = '{s}'\n", .{ src, dst });
    if (dst.len == 0) return del(src);
    try aliases.append(Alias{
        .name = try a.dupe(u8, src),
        .value = try a.dupe(u8, dst),
    });
}

/// Returns true IFF existing value is replaced
fn replace(a: std.mem.Allocator, key: []const u8, val: []const u8) !bool {
    if (find(key)) |*found| {
        a.free(found.*.value);
        found.*.value = try a.dupe(u8, val);
        return true;
    }
    return false;
}

fn del(src: []const u8) Err!void {
    for (aliases.items, 0..) |a, i| {
        if (std.mem.eql(u8, src, a.name)) {
            const d = aliases.swapRemove(i);
            aliases.allocator.free(d.name);
            aliases.allocator.free(d.value);
            return;
        }
    }
}

test "alias" {
    const a = std.testing.allocator;
    init(a);
    defer raze(a);

    try std.testing.expectEqual(aliases.items.len, 0);
}

test "save" {
    var a = std.testing.allocator;
    init(a);
    defer raze(a);
    const str = "alias haxzor='ssh 127.0.0.1 \"echo hsh was here | sudo tee /root/.lmao.txt\"'";

    var itr = Token.Iterator{ .raw = str };
    const slice = try itr.toSliceExec(a);
    defer a.free(slice);
    var pitr = try Parse.Parser.parse(a, slice);

    defer pitr.raze();
    const res = alias_core(a, &pitr);
    try std.testing.expectEqual(res, 0);

    try std.testing.expectEqual(aliases.items.len, 1);
    const tst = try std.fmt.allocPrint(a, "{save}\n", .{aliases.items[0]});
    defer a.free(tst);
    try std.testing.expectEqualStrings(str, tst[0 .. tst.len - 1]); // strip newline
}
