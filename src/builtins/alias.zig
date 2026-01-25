/// name and value are assumed to be owned by alias, and are expected to be
// TODO this needs to become a map :/
pub var aliases: ArrayList(Alias) = .{};

/// valid between calls to alias.
pub const Alias = struct {
    name: []const u8,
    value: []const u8,

    pub fn format(alias: Alias, w: *Writer) !void {
        try w.print("{s}='{s}'", .{ alias.name, alias.value });
    }
};

pub fn init() void {}

pub fn raze(a: Allocator) void {
    for (aliases.items) |ar| {
        a.free(ar.name);
        a.free(ar.value);
    }
    aliases.deinit(a);
}

pub fn save(_: *Hsh, w: *Writer) !void {
    for (aliases.items) |al| {
        try w.print("alias {f}\n", .{al});
    }
}

pub fn call(_: *Hsh, titr: *ParsedIterator, a: Allocator, _: Io) Err!u8 {
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
fn add(a: Allocator, src: []const u8, dst: []const u8) Err!void {
    log.debug("ALIAS adding {s} = '{s}'\n", .{ src, dst });
    if (dst.len == 0) return del(src);
    try aliases.append(a, .{
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

test save {
    var a = std.testing.allocator;
    init(a);
    defer raze(a);
    const str = "alias haxzor='ssh 127.0.0.1 \"echo hsh was here | sudo tee /root/.lmao.txt\"'";

    var itr = Token.Iterator{ .raw = str };
    const slice = try itr.toSliceExec(a);
    defer a.free(slice);
    var pitr = try Parse.Parser.parse(a, slice);

    defer pitr.raze();
    const res = call(undefined, &pitr, a, undefined);
    try std.testing.expectEqual(res, 0);

    try std.testing.expectEqual(aliases.items.len, 1);
    const tst = try std.fmt.allocPrint(a, "alias \n", .{aliases.items[0]});
    defer a.free(tst);
    try std.testing.expectEqualStrings(str, tst[0 .. tst.len - 1]); // strip newline
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Writer = Io.Writer;

const Hsh = @import("../hsh.zig");
const Token = @import("../token.zig");
const bi = @import("../builtins.zig");
const Err = bi.Err;
const Parse = @import("../parse.zig");
const ParsedIterator = Parse.ParsedIterator;
const print = bi.print;
const log = @import("../log.zig");
const builtin = @import("builtin");
