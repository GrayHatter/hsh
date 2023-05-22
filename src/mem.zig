const std = @import("std");
pub const Allocator = std.mem.Allocator;

pub fn dupePadded(a: Allocator, str: []const u8, w: usize) ![]u8 {
    const width = @max(str.len, w);
    var dupe = try a.alloc(u8, width);
    @memcpy(dupe[0..str.len], str);
    @memset(dupe[str.len..width], ' ');
    return dupe;
}

/// orig must have originated from the provided allocator
/// validity of base is undefined once this function returns
/// orig will be expanded with end
pub fn concat(a: Allocator, base: []u8, ends: []const []const u8) ![]u8 {
    var es: usize = 0;
    for (ends) |e| {
        es += e.len;
    }
    var i = base.len;
    var out = try a.realloc(base, base.len + es);
    for (ends) |e| {
        @memcpy(out[i..][0..e.len], e);
        i += e.len;
    }
    return out;
}

pub fn concatPath(a: Allocator, base: []u8, end: []const u8) ![]u8 {
    var sep = if (base[base.len - 1] == '/') "" else "/";
    var end_clean = if (end[0] == '/') end[1..] else end;
    return concat(a, base, &[2][]const u8{ sep, end_clean });
}

test "concat" {
    var a = std.testing.allocator;
    var thing = try a.dupe(u8, "thing");
    var out = try concat(a, thing, &[_][]const u8{ " blerg", " null" });
    try std.testing.expect(std.mem.eql(u8, out, "thing blerg null"));
    defer a.free(out);
}

test "concatPath" {
    var a = std.testing.allocator;
    var thing = try a.dupe(u8, "thing");
    var out = try concatPath(a, thing, "null");
    try std.testing.expect(std.mem.eql(u8, out, "thing/null"));
    defer a.free(out);
}

test "concatPath 2" {
    var a = std.testing.allocator;
    var thing = try a.dupe(u8, "thing/");
    var out = try concatPath(a, thing, "null");
    try std.testing.expect(std.mem.eql(u8, out, "thing/null"));
    defer a.free(out);
}
