const Variables = @This();

var variables: std.StringHashMapUnmanaged([]const u8) = .{};

var environ: [:null]?[*:0]u8 = undefined;
var environ_dirty = true;

const Specials = enum(u8) {
    exit_status = '?',
};

pub fn init(a: Allocator) void {
    var env = a.alloc(?[*:0]u8, 1) catch unreachable;
    env[env.len - 1] = null;
    environ = env[0 .. env.len - 1 :null];
}

pub fn load(env: std.process.Environ, a: Allocator) !void {
    for (env.block) |opt_line| {
        const line = span(opt_line.?);

        if (findScalar(u8, line, '=')) |idx|
            try put(line[0..idx], line[idx + 1 ..], a);
    }
    // TODO super hacky :/
    put("SHELL", "/usr/bin/hsh", a) catch unreachable;
}

fn environBuild(a: Allocator) ![:null]?[*:0]u8 {
    const count = variables.count() + 1;
    if (!a.resize(environ, count)) {
        var env = try a.realloc(environ, count);
        env[env.len - 1] = null;
        environ = env[0 .. env.len - 1 :null];
    }
    var index: usize = 0;
    var itr = variables.iterator();
    while (itr.next()) |ent| {
        const k = ent.key_ptr.*;
        const v = ent.value_ptr.*;
        var str = try a.alloc(u8, k.len + v.len + 2);
        @memcpy(str[0..k.len], k);
        str[k.len] = '=';
        @memcpy(str[k.len + 1 ..][0..v.len], v);
        str[str.len - 1] = 0;
        environ[index] = str[0 .. str.len - 1 :0];
        index += 1;
    }
    const last = @as(*?[*:0]u8, &environ[index]);
    last.* = null;
    environ_dirty = false;
    return environ;
}

pub fn henviron(a: Allocator) [:null]?[*:0]u8 {
    if (!environ_dirty) return environ;
    return environBuild(a) catch @panic("unable to build environ");
}

pub fn get(k: []const u8) ?[]const u8 {
    return variables.get(k);
}

pub fn put(k: []const u8, v: []const u8, a: Allocator) !void {
    environ_dirty = true;
    const key = try a.dupe(u8, k);
    const value = try a.dupe(u8, v);
    const kv = try variables.getOrPut(a, key);
    if (kv.found_existing) {
        a.free(key);
        a.free(kv.value_ptr.*);
    }
    kv.value_ptr.* = value;
}

// del(k, v) where v can be an optional, delete only of v matches current value
pub fn del(k: []const u8) !void {
    variables.remove(k);
}

//pub fn razeEphemeral() void {
//    variables[@intFromEnum(Kind.ephemeral)].clearAndFree();
//}

pub fn raze(a: Allocator) void {
    var itr = variables.iterator();
    while (itr.next()) |*ent| {
        a.free(ent.key_ptr.*);
        a.free(ent.value_ptr.*);
    }
    variables.clearAndFree(a);
    a.free(environ);
}

test "variables standard usage" {
    const a = std.testing.allocator;

    init(a);
    defer raze(a);

    try put("key", "value", a);

    const str = get("key").?;
    try std.testing.expectEqualStrings("value", str);
}

test "variables ephemeral" {
    const a = std.testing.allocator;

    init(a);
    defer raze(a);

    try put("key", "value", a);

    const str = get("key").?;
    try std.testing.expectEqualStrings("value", str);
    //razeEphemeral();

    //const n = get("key");
    //try std.testing.expect(n == null);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const findScalar = std.mem.findScalar;
const span = std.mem.span;
