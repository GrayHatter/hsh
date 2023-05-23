const std = @import("std");
const Hsh = @import("../hsh.zig");
const HSH = Hsh.HSH;
const tokenizer = @import("../tokenizer.zig");
const Token = tokenizer.Token;
const Err = @import("../builtins.zig").Err;

/// name and value are assumed to be owned by alias, and are expected to be
/// valid between calls to alias.
const Alias = struct {
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
}

pub fn alias(h: *HSH, tks: []const Token) Err!void {
    if (!std.mem.eql(u8, "alias", tks[0].cannon())) return Err.InvalidCommand;

    var name: ?[]const u8 = null;
    var value: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    for (tks[1..]) |t| {
        switch (t.type) {
            .WhiteSpace => continue,
            .Operator => {},
            else => {
                if (name) |_| {
                    value = h.alloc.dupe(u8, t.cannon()) catch return Err.Memory;
                } else {
                    if (t.raw[0] == '-') mode = t.raw[1..2];
                    name = h.alloc.dupe(u8, t.cannon()) catch return Err.Memory;
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
                return;
            }
            return add(n, v);
        }
        if (find(n)) |nn| {
            h.tty.print("{}\n", .{nn}) catch return Err.Unknown;
        } else {
            h.tty.print("no known alias for {s}\n", .{n}) catch return Err.Unknown;
        }
        h.alloc.free(n);
        return;
    }

    for (aliases.items) |a| {
        h.tty.print("{}\n", .{a}) catch return Err.Unknown;
    }
}

fn find(src: []const u8) ?*Alias {
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
