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
};

// TODO this needs to become a map :/
var aliases: std.ArrayList(Alias) = undefined;

pub fn init(a: std.mem.Allocator) void {
    aliases = std.ArrayList(Alias).init(a);
}

pub fn alias(h: *HSH, tks: []const Token) Err!void {
    if (!std.mem.eql(u8, "alias", tks[0].cannon())) return Err.InvalidCommand;
    if (tks.len > 2) {
        var name = h.alloc.dupe(u8, tks[2].cannon()) catch return Err.Memory;
        var value = h.alloc.dupe(u8, tks[3].cannon()) catch return Err.Memory;
        if (find(name)) |*found| {
            h.alloc.free(found.*.value);
            found.*.value = value;
            h.alloc.free(name);
            return;
        }
        return add(name, value);
    }

    for (aliases.items) |a| {
        h.tty.print("{}\n", .{a}) catch {};
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
