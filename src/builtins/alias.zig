/// name and value are assumed to be owned by alias, and are expected to be
// TODO this needs to become a map :/
var aliases: StringHashMap([]const u8) = .{};

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
    var itr = aliases.iterator();
    while (itr.next()) |entry| {
        a.free(entry.key_ptr.*);
        a.free(entry.value_ptr.*);
    }
    aliases.deinit(a);
    // Required for tests :/
    aliases = .{};
}

pub fn save(_: *Hsh, w: *Writer) !void {
    var itr = aliases.iterator();
    while (itr.next()) |entry| {
        try w.print("alias {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

fn validateName(str: []const u8) ![]const u8 {
    // TODO validate input str
    return str;
}

pub fn call(_: *Hsh, titr: *ParsedIterator, a: Allocator, _: Io) Err!u8 {
    log.debug("alias call {any}\n", .{titr});
    assert(eql(u8, "alias", titr.first().resolved.str));
    const arg = titr.next() orelse return printAll();
    log.info("alias call {}\n", .{arg});
    if (findScalar(u8, arg.resolved.str, '=')) |idx| {
        const name = validateName(arg.resolved.str[0..idx]) catch unreachable;
        const value = arg.resolved.str[idx + 1 ..];
        if (add(name, value, a)) return 0 else |err| return err;
    } else {
        const name = validateName(arg.resolved.str) catch unreachable;
        if (find(name)) |n| {
            try print("{}\n", .{n});
        } else {
            try print("no known alias for {s}\n", .{name});
        }
        return 0;
    }
}

fn printAll() Err!u8 {
    var itr = aliases.iterator();
    while (itr.next()) |entry| {
        try print("{s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return 0;
}

/// alias retains ownership of all memory, and memory lifetime is undefined
pub fn find(name: []const u8) ?Alias {
    if (aliases.getEntry(name)) |entry| {
        return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
    }
    return null;
}

// TODO might leak
fn add(name: []const u8, val: []const u8, a: Allocator) Err!void {
    log.debug("alias adding {s} = '{s}'\n", .{ name, val });
    if (val.len == 0) return del(name, a);
    const gop = aliases.getOrPut(a, name) catch unreachable;
    if (gop.found_existing) {
        a.free(gop.value_ptr.*);
        gop.value_ptr.* = try a.dupe(u8, val);
    } else {
        gop.key_ptr.* = try a.dupe(u8, name);
        gop.value_ptr.* = try a.dupe(u8, val);
    }
}

pub fn testingAdd(name: []const u8, value: []const u8, a: Allocator) void {
    add(name, value, a) catch unreachable;
}

fn del(name: []const u8, a: Allocator) Err!void {
    if (aliases.getEntry(name)) |entry| {
        a.free(entry.key_ptr.*);
        a.free(entry.value_ptr.*);
        std.debug.assert(aliases.remove(name));
    }
}

test "alias" {
    const a = std.testing.allocator;
    init();
    defer raze(a);

    try std.testing.expectEqual(aliases.count(), 0);
}

test save {
    if (true) return error.SkipZigTest;
    var a = std.testing.allocator;
    const io = std.testing.io;
    init();
    defer raze(a);
    const str = "alias haxzor='ssh 127.0.0.1 \"echo hsh was here | sudo tee /root/.lmao.txt\"'";

    var itr = Token.Iterator{ .raw = str };
    const slice = try itr.toSliceExec(a);
    defer a.free(slice);
    var pitr = try Parse.Parser.iterate(a, slice);
    try pitr.resolveAll(a, io);
    defer pitr.raze(a);

    const res = call(undefined, &pitr, a, io);
    try std.testing.expectEqual(res, 0);

    try std.testing.expectEqual(1, aliases.count());
    const tst = try std.fmt.allocPrint(a, "alias {f}\n", .{find("haxzor").?});
    defer a.free(tst);
    try std.testing.expectEqualStrings(str, tst[0 .. tst.len - 1]); // strip newline
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.hash_map.StringHashMapUnmanaged;
const Io = std.Io;
const Writer = Io.Writer;
const eql = std.mem.eql;
const findScalar = std.mem.findScalar;

const Hsh = @import("../hsh.zig");
const Token = @import("../token.zig");
const bi = @import("../builtins.zig");
const Err = bi.Err;
const Parse = @import("../parse.zig");
const ParsedIterator = Parse.Iterator;
const print = bi.print;
const log = @import("../log.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
