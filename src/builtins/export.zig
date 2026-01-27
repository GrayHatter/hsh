var export_list: ArrayList(Export) = .{};

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

    pub fn format(expt: Export, w: *Writer) !void {
        try w.print("{s}='{s}'", .{ expt.name, expt.value });
    }
};

pub fn init() void {}

pub fn raze(a: Allocator) void {
    for (export_list.items) |ex| {
        a.free(ex.name);
    }
    export_list.clearAndFree(a);
}

pub fn save(_: *Hsh, w: *Writer) !void {
    for (export_list.items) |ex| {
        try w.print("export {f}\n", .{ex});
    }
}

/// print the list of known exports to whatever builtin suggests
fn printAll() Err!u8 {
    for (export_list.items) |ex| {
        try print("{}\n", .{ex});
    }
    return 0;
}

pub fn call(_: *Hsh, pitr: *ParsedIterator, a: Allocator, _: Io) Err!u8 {
    const expt = pitr.first();
    std.debug.assert(eql(u8, expt.resolved.str, "export"));

    const name = pitr.next() orelse return printAll();
    if (eql(u8, name.resolved.str, "-p")) return printAll();

    if (findScalar(u8, name.resolved.str, '=')) |idx| {
        const key = name.resolved.str[0..idx];
        const value = name.resolved.str[idx + 1 ..];
        Variables.put(key, value, a) catch {
            log.err("Unable to save variable", .{});
            return 1;
        };
        add(key, value, a) catch {
            log.err("unable to save export", .{});
            return 1;
        };
        return 0;
    } else {
        // no = in the string, so it needs to already exist within variables.
        const key = try a.dupe(u8, name.resolved.str);
        const value = Variables.get(key) orelse {
            log.err("Attempted to export an non-existant name\n", .{});
            return 1;
        };
        add(key, value, a) catch {
            log.err("", .{});
            return 1;
        };
        return 0;
    }
    comptime unreachable;
}

/// TODO method to remove an export
pub fn unexport(_: *Hsh, _: *ParsedIterator) Err!u8 {
    unreachable;
}

fn add(k: []const u8, v: []const u8, a: Allocator) !void {
    return try export_list.append(a, try .new(a, k, v));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Writer = std.Io.Writer;
const eql = std.mem.eql;
const findScalar = std.mem.findScalar;

const Hsh = @import("../hsh.zig");
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").Iterator;
const print = bi.print;
const log = @import("../log.zig");
const Variables = @import("../variables.zig");
