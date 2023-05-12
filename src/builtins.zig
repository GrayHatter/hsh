const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const HSH = @import("hsh.zig").HSH;

var Self = @This();

pub const Err = error{
    Unknown,
    InvalidToken,
    InvalidCommand,
    FileSysErr,
};

const BuiltinFn = *const fn (a: *HSH, b: []const Token) Err!void;

pub const Builtins = enum {
    alias,
    bg,
    cd,
    die,
    echo,
    exit,
    fg,
    jobs,
    which,
    // DEBUGGING BUILTINS
    tty,
};

pub fn builtinToName(comptime bi: Builtins) []const u8 {
    return @tagName(bi);
}

pub fn exec(self: Builtins) BuiltinFn {
    return switch (self) {
        .alias => alias,
        .bg => bg,
        .cd => cd,
        .die => die,
        .echo => echo,
        .exit => die, // TODO exit should be kinder than die
        .fg => fg,
        .jobs => jobs,
        .which => which,
        // DEBUGGING BUILTIN
        .tty => tty,
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

fn alias(_: *HSH, _: []const Token) Err!void {}

fn bg(_: *HSH, _: []const Token) Err!void {}

/// Someone should add some sane input sanitzation to this
fn cd(hsh: *HSH, tkns: []const Token) Err!void {
    // TODO pushd and popd
    var path: [1 << 10]u8 = undefined;
    var path_len: usize = 0;
    for (tkns[1..]) |t| {
        switch (t.type) {
            .String, .Quote, .Var => {
                std.mem.copy(u8, &path, t.cannon());
                path_len = t.cannon().len;
                break;
            },
            .WhiteSpace => continue,
            else => return Err.InvalidToken,
        }
    } else {
        if (tkns.len < 2 and hsh.fs.home_name != null) {
            std.mem.copy(u8, &path, hsh.fs.home_name.?);
            path_len = hsh.fs.home_name.?.len;
        } else return Err.InvalidCommand;
    }

    // std.debug.print("cd path {s} default {s}\n", .{ &path, hsh.fs.home_name });
    const dir = hsh.fs.cwd.openDir(path[0..path_len], .{}) catch return Err.FileSysErr;
    dir.setAsCwd() catch |e| {
        std.debug.print("cwd failed! {}", .{e});
        return Err.FileSysErr;
    };
    hsh.updateFs();
}

pub fn die(_: *HSH, _: []const Token) Err!void {
    unreachable;
}

test "fs" {
    const c = std.fs.cwd();
    //std.debug.print("cwd failed! {}", .{e});
    const ndir = try c.openDir("/home/grayhatter", .{});
    //std.debug.print("test {}\n", .{ndir});
    try ndir.setAsCwd();
}

fn echo(hsh: *HSH, _: []const Token) Err!void {
    hsh.tty.print("echo not yet implemented\n", .{}) catch return Err.Unknown;
}

/// TODO implement real version of exit
fn exit(_: *HSH, _: []const Token) Err!void {}

/// TODO implement job selection support
fn fg(hsh: *HSH, _: []const Token) Err!void {
    var paused: usize = 0;
    for (hsh.jobs.items) |j| {
        paused += if (j.status == .Paused or j.status == .Waiting) 1 else 0;
    }
    if (paused == 0) {
        hsh.tty.print("No resumeable jobs\n", .{}) catch {};
        return;
    }
    if (paused == 1) {
        hsh.tty.print("Restarting job\n", .{}) catch {};
        hsh.contNextJob(true) catch unreachable;
        return;
    }

    hsh.tty.print("More than one job paused, fg not yet implemented\n", .{}) catch return Err.Unknown;
}

fn jobs(hsh: *HSH, _: []const Token) Err!void {
    for (hsh.jobs.items) |j| {
        hsh.tty.print("{}", .{j}) catch return Err.Unknown;
    }
}

fn which(_: *HSH, _: []const Token) Err!void {}

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

//DEBUGGING BUILTINS
fn tty(hsh: *HSH, _: []const Token) Err!void {
    for (hsh.tty.attrs.items) |i| {
        std.debug.print("attr {any}\n", .{i});
    }
}
