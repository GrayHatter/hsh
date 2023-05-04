const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const HSH = @import("hsh.zig").HSH;

var Self = @This();

pub const BuiltinErr = error{
    Unknown,
    InvalidToken,
    InvalidCommand,
    FileSysErr,
};

const BuiltinFn = *const fn (a: *HSH, b: []const Token) BuiltinErr!void;

pub const Builtins = enum {
    alias,
    cd,
    echo,
    which,
};

pub fn builtinToName(comptime bi: Builtins) []const u8 {
    return @tagName(bi);
}

pub fn exec(self: Builtins) BuiltinFn {
    return switch (self) {
        .alias => alias,
        .cd => cd,
        .echo => echo,
        .which => which,
    };
}

/// Caller must ensure this builtin exists.
pub fn strExec(str: []const u8) BuiltinFn {
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return exec(@intToEnum(Builtins, f.value));
    }
    std.debug.print("strExec panic on {s}\n", .{str});
    unreachable;
}

pub fn exists(str: []const u8) bool {
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return true;
    }
    return false;
}

fn alias(_: *HSH, _: []const Token) BuiltinErr!void {}

/// Someone should add some sane input sanitzation to this
fn cd(hsh: *HSH, tkns: []const Token) BuiltinErr!void {
    // TODO pushd and popd
    var path: [1 << 10]u8 = undefined;
    var path_len: usize = 0;
    for (tkns[1..]) |t| {
        switch (t.type) {
            .String, .Char, .Quote, .Var => {
                std.mem.copy(u8, &path, t.cannon());
                path_len = t.cannon().len;
                break;
            },
            .WhiteSpace => continue,
            else => return BuiltinErr.InvalidToken,
        }
    } else {
        if (tkns.len < 2) {
            std.mem.copy(u8, &path, hsh.fs.home_name);
            path_len = hsh.fs.home_name.len;
        } else return BuiltinErr.InvalidCommand;
    }

    // std.debug.print("cd path {s} default {s}\n", .{ &path, hsh.fs.home_name });
    const dir = hsh.fs.cwd.openDir(path[0..path_len], .{}) catch return BuiltinErr.FileSysErr;
    dir.setAsCwd() catch |e| {
        std.debug.print("cwd failed! {}", .{e});
        return BuiltinErr.FileSysErr;
    };
    hsh.updateFs();
}

test "fs" {
    const c = std.fs.cwd();
    //std.debug.print("cwd failed! {}", .{e});
    const ndir = try c.openDir("/home/grayhatter", .{});
    //std.debug.print("test {}\n", .{ndir});
    try ndir.setAsCwd();
}

fn echo(_: *HSH, _: []const Token) BuiltinErr!void {}

fn which(_: *HSH, _: []const Token) BuiltinErr!void {}

test "builtins" {
    const str = @tagName(Builtins.alias);
    var bi: bool = false;
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) bi = true;
    }
    try std.testing.expect(bi);
    var bi2 = false;
    const never = "pleasegodletthisneverbecomeabuiltin";
    inline for (@typeInfo(Builtins).Enum.fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, never)) bi2 = true;
    }
    try std.testing.expect(!bi2);
}

test "builtins alias" {
    try std.testing.expect(exists(@tagName(Builtins.alias)));
    try std.testing.expect(exists(@tagName(Builtins.cd)));
    try std.testing.expect(exists(@tagName(Builtins.echo)));
    try std.testing.expect(exists(@tagName(Builtins.which)));

    try std.testing.expect(!exists("BLERG"));
}
