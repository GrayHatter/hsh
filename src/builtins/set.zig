pub const Set = @This();

pub const Context = struct {};

pub const Opts = enum(u8) {
    @"export" = 'a',
    bgjob = 'b',
    noclobber = 'C',
    errexit = 'e',
    pathexpan = 'f',
    hashall = 'h',
    nopmode = 'n',
    failunset = 'u',
    verbose = 'v', // "echo" stdin to stderr
    trace = 'x',

    pub fn find(c: u8) Err!Opts {
        inline for (@typeInfo(Opts).@"enum".fields) |field| {
            if (field.value == c) return @enumFromInt(field.value);
        }
        return Err.InvalidToken;
    }
};

pub const PosixOpts = enum {
    allexport,
    errexit,
    ignoreeof,
    monitor,
    noclobber,
    noglob,
    noexec,
    nolog,
    notify,
    nounset,
    verbose,
    vi,
    xtrace,
};

const PosixState = union(PosixOpts) {
    allexport: ?bool,
    errexit: ?bool,
    ignoreeof: ?bool,
    monitor: ?bool,
    noclobber: ?bool,
    noglob: ?bool,
    noexec: ?bool,
    nolog: ?bool,
    notify: ?bool,
    nounset: ?bool,
    verbose: ?bool,
    vi: ?bool,
    xtrace: ?bool,
};

var context = Context{};

pub fn init(a: Allocator) void {
    enable(.noclobber, a) catch unreachable;
}

pub fn raze(_: Allocator) void {
    return nop();
}

pub fn save(_: *Hsh, _: *std.Io.Writer) !void {
    return;
}

fn nop() void {}

fn enable(o: Opts, a: Allocator) !void {
    switch (o) {
        .@"export" => return nop(),
        .bgjob => return nop(),
        .noclobber => try Vars.put("noclobber", "true", a),
        .errexit => return nop(),
        .pathexpan => return nop(),
        .hashall => return nop(),
        .nopmode => return nop(),
        .failunset => return nop(),
        .verbose => return nop(),
        .trace => return nop(),
    }
}

fn disable(o: Opts, a: Allocator) !void {
    switch (o) {
        .@"export" => return nop(),
        .bgjob => return nop(),
        .noclobber => try Vars.put("noclobber", "false", a),
        .errexit => return nop(),
        .pathexpan => return nop(),
        .hashall => return nop(),
        .nopmode => return nop(),
        .failunset => return nop(),
        .verbose => return nop(),
        .trace => return nop(),
    }
}

fn special(_: *ParsedIterator, _: std.mem.Allocator) Err!u8 {
    return 0;
}

fn posix(opt: []const u8, titr: *ParsedIterator, a: Allocator) Err!u8 {
    _ = titr;
    const mode = opt[0] == '-';
    if (!mode and opt[0] != '+') return Err.InvalidCommand;

    for (opt[1..]) |opt_c| {
        const o = try Opts.find(opt_c);
        if (mode) try enable(o, a) else try disable(o, a);
    }
    return 0;
}

fn option(opt: []const u8, titr: *ParsedIterator, _: Allocator) Err!u8 {
    _ = opt;
    _ = titr;
    return 0;
}

fn dump() Err!u8 {
    inline for (@typeInfo(PosixOpts).@"enum".fields) |o| {
        const name = o.name;
        const truthy = if (Vars.get(name)) |str|
            eql(u8, "true", str)
        else
            false;

        try print("set {s}o {s}\n", .{ if (truthy) "-" else "+", name });
    }
    return 0;
}

pub fn set(pi: *ParsedIterator, a: Allocator) Err!u8 {
    if (!eql(u8, pi.first().resolved.str, "set")) return Err.InvalidCommand;

    if (pi.next()) |arg| {
        const opt = arg.resolved.str;

        if (opt.len > 1) {
            if (eql(u8, opt, "vi")) {
                try print("sorry robinli, not yet\n", .{});
                return 1;
            }

            if (eql(u8, opt, "emacs") or eql(u8, opt, "vscode")) {
                @panic("u wot m8?!");
            }

            if (opt[0] == '-' or opt[0] == '+') {
                if (opt[1] == '-') {
                    return special(pi, a);
                }
                return posix(opt, pi, a);
            } else {
                return option(arg.resolved.str, pi, a);
            }
        }
    } else {
        return dump();
    }
    return 0;
}

pub fn call(_: *Hsh, titr: *ParsedIterator, a: Allocator, _: Io) Err!u8 {
    return set(titr, a);
}

test "set" {
    const Parse = @import("../parse.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    Vars.init(a);
    defer Vars.raze(a);

    var ts = [_]Token{
        .make("set", .word),
        .make(" ", .ws),
        .make("-C", .word),
    };

    var p = try Parse.Resolver.iterate(a, &ts);
    try p.resolveAll(a, io);
    defer p.raze(a);

    _ = try set(&p, a);

    const nc = Vars.get("noclobber");
    try std.testing.expectEqualStrings("true", nc.?);

    ts = [_]Token{
        .make("set", .word),
        .make(" ", .ws),
        .make("+C", .word),
    };

    p.raze(a);
    p = try Parse.Resolver.iterate(a, &ts);
    try p.resolveAll(a, io);

    _ = try set(&p, a);

    const ync = Vars.get("noclobber");
    try std.testing.expectEqualStrings("false", ync.?);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const eql = std.mem.eql;
const Hsh = @import("../hsh.zig");
const bi = @import("../builtins.zig");
const print = bi.print;
const Err = bi.Err;
const Token = bi.Token;
const ParsedIterator = bi.ParsedIterator;
const Vars = bi.Variables;
