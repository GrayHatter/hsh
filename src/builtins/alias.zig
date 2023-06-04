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
        switch (t.type) {
            .Operator => {},
            else => {
                if (name) |_| {
                    value = h.alloc.dupe(u8, t.cannon()) catch return Err.Memory;
                } else {
                    if (std.mem.indexOf(u8, t.cannon(), "=")) |i| {
                        name = h.alloc.dupe(u8, t.cannon()[0..i]) catch return Err.Memory;
                    } else {
                        name = h.alloc.dupe(u8, t.cannon()) catch return Err.Memory;
                    }
                }
            },
        }
    }

    if (mode) |_| unreachable; // not implemented;

    if (name) |n| {
        if (value) |v| {
            if (find(n)) |*found| {
                h.alloc.free(found.*.value);
                found.*.value = v;
                h.alloc.free(n);
                return 0;
            }
            if (add(n, v)) return 0 else |err| return err;
        }
        if (find(n)) |nn| {
            print("{}\n", .{nn}) catch return Err.Unknown;
        } else {
            print("no known alias for {s}\n", .{n}) catch return Err.Unknown;
        }
        h.alloc.free(n);
        return 0;
    }

    for (aliases.items) |a| {
        print("{}\n", .{a}) catch return Err.Unknown;
    }
    return 0;
}

pub fn find(src: []const u8) ?*Alias {
    for (aliases.items) |*a| {
        if (std.mem.eql(u8, src, a.name)) {
            return a;
        }
    }
    return null;
}

fn add(src: []const u8, dst: []const u8) Err!void {
    aliases.append(Alias{
        .name = src,
        .value = dst,
    }) catch return Err.Memory;
}

fn del() void {}

pub fn testing_setup(a: std.mem.Allocator) *std.ArrayList(Alias) {
    aliases = std.ArrayList(Alias).init(a);
    return &aliases;
}
