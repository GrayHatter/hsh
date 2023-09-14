const std = @import("std");
const span = std.mem.span;

const Variables = @This();

const Kind = enum(u4) {
    nos,
    internal,
    sysenv,
    special,
};

const Var = struct {
    value: []const u8,
    kind: Kind,
    exported: bool = false,
};

var variables: [4]std.StringHashMap(Var) = undefined;

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
    for (&variables) |*vari| {
        vari.* = std.StringHashMap(Var).init(a);
    }
    initSpecials();
    initHsh();
}

pub fn load(sys: std.process.EnvMap) !void {
    var i = sys.iterator();
    while (i.next()) |each| {
        try putKind(each.key_ptr.*, each.value_ptr.*, .sysenv);
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
    const count = variables[@intFromEnum(Kind.sysenv)].count() + 1;
    if (!environ_alloc.resize(environ, count)) {
        var env = try environ_alloc.realloc(environ, count);
        env[env.len - 1] = null;
        environ = env[0 .. env.len - 1 :null];
    }
    var index: usize = 0;
    var itr = variables[@intFromEnum(Kind.sysenv)].iterator();
    while (itr.next()) |ent| {
        const k = ent.key_ptr.*;
        const v = ent.value_ptr.*.value;
        var str = try environ_alloc.alloc(u8, k.len + v.len + 2);
        @memcpy(str[0..k.len], k);
        str[k.len] = '=';
        @memcpy(str[k.len + 1 ..][0..v.len], v);
        str[str.len - 1] = 0;
        environ[index] = str[0 .. str.len - 1 :0];
        index += 1;
    }
    var last = @as(*?[*:0]u8, &environ[index]);
    last.* = null;
    environ_dirty = false;
    return environ;
}

pub fn henviron() [:null]?[*:0]u8 {
    if (!environ_dirty) return environ;
    return environBuild() catch @panic("unable to build environ");
}

pub fn getKind(k: []const u8, comptime g: Kind) ?Var {
    return variables[@intFromEnum(g)].get(k);
}

pub fn get(k: []const u8) ?Var {
    return getKind(k, .sysenv);
}

pub fn getStr(k: []const u8) ?[]const u8 {
    if (get(k)) |v| return v.value else return null;
}

pub fn putKind(k: []const u8, v: []const u8, comptime g: Kind) !void {
    return variables[@intFromEnum(g)].put(k, Var{
        .kind = g,
        .value = v,
    });
}

pub fn put(k: []const u8, v: []const u8) !void {
    return putKind(k, v, .sysenv);
}

pub fn delKind(k: []const u8, comptime g: Kind) !void {
    variables[@intFromEnum(g)].remove(k);
}

// del(k, v) where v can be an optional, delete only of v matches current value
pub fn del(k: []const u8) !void {
    delKind(k, .nos);
}

/// named exports because I don't want to fight the compiler over the keyword
pub fn exports(k: []const u8) !void {
    if (variables[@intFromEnum(Kind.sysenv)].getPtr(k)) |v| {
        v.exported = true;
    }
}

pub fn unexport(k: []const u8) !void {
    if (variables[@intFromEnum(Kind.sysenv)].getPtr(k)) |v| {
        v.exported = false;
    }
}

pub fn raze() void {
    //var itr = variables.iterator();
    //while (itr.next()) |*ent| {
    //    a.free(ent.key_ptr.*);
    //    a.free(ent.value_ptr.value);
    //}
    for (&variables) |*vari| {
        vari.clearAndFree();
    }
    environ_alloc.free(environ);
}

test "standard usage" {
    var a = std.testing.allocator;

    init(a);
    defer raze();

    try put("key", "value");

    var str = getStr("key").?;
    try std.testing.expectEqualStrings("value", str);

    var x = get("key").?;
    try std.testing.expectEqual(x.exported, false);
    try exports("key");
    x = get("key").?;
    try std.testing.expectEqual(x.exported, true);
    try unexport("key");
    x = get("key").?;
    try std.testing.expectEqual(x.exported, false);
}
