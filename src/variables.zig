const std = @import("std");

const Variables = @This();

const Kind = enum {
    internal,
    sysenv,
};

const Var = struct {
    value: []const u8,
    kind: Kind,
    exported: bool = false,
};

var variables: std.StringHashMap(Var) = undefined;

pub fn init(a: std.mem.Allocator) void {
    variables = std.StringHashMap(Var).init(a);
}

pub fn load(sys: std.process.EnvMap) !void {
    var i = sys.iterator();
    while (i.next()) |each| {
        try put(each.key_ptr.*, each.value_ptr.*);
    }
}

pub fn get(k: []const u8) ?Var {
    return variables.get(k);
}

pub fn getStr(k: []const u8) ?[]const u8 {
    if (variables.get(k)) |v| return v.value else return null;
}

pub fn put(k: []const u8, v: []const u8) !void {
    return variables.put(k, Var{
        .kind = .internal,
        .value = v,
    });
}

pub fn exports(k: []const u8) !void {
    if (variables.getPtr(k)) |v| {
        v.exported = true;
    }
}

pub fn unexport(k: []const u8) !void {
    if (variables.getPtr(k)) |v| {
        v.exported = false;
    }
}

pub fn raze() void {
    //var itr = variables.iterator();
    //while (itr.next()) |*ent| {
    //    a.free(ent.key_ptr.*);
    //    a.free(ent.value_ptr.value);
    //}
    variables.clearAndFree();
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
