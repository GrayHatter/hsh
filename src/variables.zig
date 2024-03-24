const std = @import("std");
const span = std.mem.span;

const Variables = @This();

var variables: std.StringHashMap([]const u8) = undefined;

var environ: [:null]?[*:0]u8 = undefined;
var environ_alloc: std.mem.Allocator = undefined;
var environ_dirty = true;

const Specials = enum(u8) {
    exit_status = '?',
};

fn initHsh() void {
    put("SHELL", "/usr/bin/hsh") catch unreachable; // TODO this isn't right
}

fn initSpecials() void {}

pub fn init(a: std.mem.Allocator) void {
    environ_alloc = a;
    var env = a.alloc(?[*:0]u8, 1) catch unreachable;
    env[env.len - 1] = null;
    environ = env[0 .. env.len - 1 :null];
    variables = std.StringHashMap([]const u8).init(a);
    initSpecials();
    initHsh();
}

pub fn load(sys: std.process.EnvMap) !void {
    var i = sys.iterator();
    while (i.next()) |each| {
        try put(each.key_ptr.*, each.value_ptr.*);
    }
    // TODO super hacky :/
    initHsh();
}

fn environRaze() void {
    for (environ) |env| {
        environ_alloc.free(span(env));
    }
    environ_alloc.free(environ);
}

fn environBuild() ![:null]?[*:0]u8 {
    const count = variables.count() + 1;
    if (!environ_alloc.resize(environ, count)) {
        var env = try environ_alloc.realloc(environ, count);
        env[env.len - 1] = null;
        environ = env[0 .. env.len - 1 :null];
    }
    var index: usize = 0;
    var itr = variables.iterator();
    while (itr.next()) |ent| {
        const k = ent.key_ptr.*;
        const v = ent.value_ptr.*;
        var str = try environ_alloc.alloc(u8, k.len + v.len + 2);
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

pub fn henviron() [:null]?[*:0]u8 {
    if (!environ_dirty) return environ;
    return environBuild() catch @panic("unable to build environ");
}

pub fn get(k: []const u8) ?[]const u8 {
    return variables.get(k);
}

pub fn put(k: []const u8, v: []const u8) !void {
    environ_dirty = true;
    const key = try environ_alloc.dupe(u8, k);
    const value = try environ_alloc.dupe(u8, v);
    const kv = try variables.getOrPut(key);
    if (kv.found_existing) {
        environ_alloc.free(key);
        environ_alloc.free(kv.value_ptr.*);
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

pub fn raze() void {
    var itr = variables.iterator();
    while (itr.next()) |*ent| {
        environ_alloc.free(ent.key_ptr.*);
        environ_alloc.free(ent.value_ptr.*);
    }
    variables.clearAndFree();
    environ_alloc.free(environ);
}

test "variables standard usage" {
    const a = std.testing.allocator;

    init(a);
    defer raze();

    try put("key", "value");

    const str = get("key").?;
    try std.testing.expectEqualStrings("value", str);
}

test "variables ephemeral" {
    const a = std.testing.allocator;

    init(a);
    defer raze();

    try put("key", "value");

    const str = get("key").?;
    try std.testing.expectEqualStrings("value", str);
    //razeEphemeral();

    //const n = get("key");
    //try std.testing.expect(n == null);
}
