const std = @import("std");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const State = bi.State;
const print = bi.print;
const log = @import("log");
const Variables = @import("../variables.zig");
const Allocator = std.mem.Allocator;

pub const Export = struct {
    // name is owned internally
    name: []u8,
    // value is both tied and owned by Variables
    value: []const u8,

    pub fn new(a: Allocator, name: []const u8, val: []const u8) !Export {
        return .{
            .name = try a.dupe(u8, name),
            .value = val,
        };
    }

    pub fn format(self: Export, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len == 4) {
            try std.fmt.format(out, "export {s}='{s}'", .{ self.name, self.value });
        } else {
            try std.fmt.format(out, "{s}='{s}'", .{ self.name, self.value });
        }
    }
};

var alloc: std.mem.Allocator = undefined;
var export_list: std.ArrayList(Export) = undefined;

pub fn init(a: std.mem.Allocator) void {
    // Set up the local list of exports
    alloc = a;
    export_list = std.ArrayList(Export).init(a);
    hsh.addState(State{
        .name = "exports",
        .ctx = &export_list,
        .api = &.{ .save = save },
    }) catch unreachable;
}

pub fn raze() void {
    for (export_list.items) |ex| {
        alloc.free(ex.name);
    }
    export_list.clearAndFree();
}

fn save(h: *HSH, _: *anyopaque) ?[][]const u8 {
    var list = h.alloc.alloc([]u8, export_list.items.len) catch return null;
    for (export_list.items, 0..) |ex, i| {
        list[i] = std.fmt.allocPrint(h.alloc, "{save}\n", .{ex}) catch continue;
    }
    return list;
}

/// print the list of known exports to whatever builtin suggests
fn printAll() Err!u8 {
    for (export_list.items) |ex| {
        try print("{}\n", .{ex});
    }
    return 0;
}

/// Named exports because I didn't want to fight the compiler for the word
/// export
pub fn exports(h: *HSH, pitr: *ParsedIterator) Err!u8 {
    const expt = pitr.first();
    std.debug.assert(std.mem.eql(u8, expt.cannon(), "export"));

    const name = pitr.next();
    if (name == null or std.mem.eql(u8, name.?.cannon(), "-p")) {
        return printAll();
    }

    if (std.mem.indexOf(u8, name.?.cannon(), "=")) |_| {
        var keyitr = std.mem.split(u8, name.?.cannon(), "=");
        var key = keyitr.first();
        var value = keyitr.rest();
        // TODO push into variables
        add(key, value) catch {
            log.err("", .{});
            return 1;
        };
        return 0;
    } else {
        // no = in the string, so it needs to already exist within variables.
        var key = h.alloc.dupe(u8, name.?.cannon()) catch return Err.Memory;
        var value = Variables.getStr(key) orelse {
            log.err("Attempted to export an non-existant name\n", .{});
            return 1;
        };
        add(key, value) catch {
            log.err("", .{});
            return 1;
        };
        return 0;
    }
    unreachable; // there's a logic error here so crash if we hit it.
}

/// TODO method to remove an export
pub fn unexport(_: *HSH, _: *ParsedIterator) Err!u8 {}

fn add(k: []const u8, v: []const u8) !void {
    return try export_list.append(try Export.new(alloc, k, v));
}
