const std = @import("std");

const Variables = @This();

const Kind = enum {
    internal,
    sysenv,
};

const Var = struct {
    kind: Kind,
    value: []const u8,
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

pub fn put(k: []const u8, v: []const u8) !void {
    return variables.put(k, Var{
        .kind = .internal,
        .value = v,
    });
}

pub fn get(k: []const u8) ?[]const u8 {
    if (variables.get(k)) |v| return v.value else return null;
}

pub fn raze() void {
    //var itr = variables.iterator();
    //while (itr.next()) |*ent| {
    //    a.free(ent.key_ptr.*);
    //    a.free(ent.value_ptr.value);
    //}
    variables.clearAndFree();
}
