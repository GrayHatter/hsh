const std = @import("std");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const tokenizer = @import("../tokenizer.zig");
const Token = tokenizer.Token;
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const State = bi.State;
const print = bi.print;
const log = @import("log");

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
var aliases: std.ArrayList(Alias) = undefined;

pub fn init(a: std.mem.Allocator) void {
    aliases = std.ArrayList(Alias).init(a);
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
    if (!std.mem.eql(u8, "alias", titr.first().cannon())) return Err.InvalidCommand;

    var name: ?[]const u8 = null;
    var value: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    while (titr.next()) |t| {
        if (name) |_| {
            value = t.cannon();
        } else {
            if (std.mem.indexOf(u8, t.cannon(), "=")) |i| {
                name = t.cannon()[0..i];
                if (t.cannon().len > i + 1) {
                    const val_tkn = tokenizer.Tokenizer.any(t.cannon()[i + 1 ..]) catch unreachable;
                    value = val_tkn.cannon();
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
            if (try replace(h.alloc, n, v)) return 0;
            if (add(h.alloc, n, v)) return 0 else |err| return err;
        }
        if (find(n)) |nn| {
            print("{}\n", .{nn}) catch return Err.Unknown;
        } else {
            print("no known alias for {s}\n", .{n}) catch return Err.Unknown;
        }
        return 0;
    }

    for (aliases.items) |a| {
        print("{}\n", .{a}) catch return Err.Unknown;
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
    aliases.append(Alias{
        .name = a.dupe(u8, src) catch return Err.Memory,
        .value = a.dupe(u8, dst) catch return Err.Memory,
    }) catch return Err.Memory;
}

/// Returns true IFF existing value is replaced
fn replace(a: std.mem.Allocator, key: []const u8, val: []const u8) !bool {
    if (find(key)) |*found| {
        a.free(found.*.value);
        found.*.value = a.dupe(u8, val) catch return Err.Memory;
        return true;
    }
    return false;
}

fn del(src: []const u8) Err!void {
    for (aliases.items, 0..) |a, i| {
        if (std.mem.eql(u8, src, a.name)) {
            var d = aliases.swapRemove(i);
            aliases.allocator.free(d.name);
            aliases.allocator.free(d.value);
            return;
        }
    }
}

pub fn testing_setup(a: std.mem.Allocator) *std.ArrayList(Alias) {
    aliases = std.ArrayList(Alias).init(a);
    return &aliases;
}
