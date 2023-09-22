const std = @import("std");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const bi = @import("../builtins.zig");
const print = bi.print;
const Err = bi.Err;
const Token = bi.Token;
const ParsedIterator = bi.ParsedIterator;
const State = bi.State;
const Vars = bi.Variables;

pub const Set = @This();

pub const Opts = enum(u8) {
    Export = 'a',
    BgJob = 'b',
    NoClobber = 'C',
    ErrExit = 'e',
    PathExpan = 'f',
    HashAll = 'h',
    NOPMode = 'n',
    FailUnset = 'u',
    Verbose = 'v', // "echo" stdin to stderr
    Trace = 'x',

    pub fn find(c: u8) Err!Opts {
        inline for (@typeInfo(Opts).Enum.fields) |field| {
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

pub fn init() void {
    hsh.addState(State{
        .name = "set",
        .ctx = &.{},
        .api = &.{ .save = save },
    }) catch unreachable;

    enable(.NoClobber) catch unreachable;
}

pub fn raze() void {
    return nop();
}

fn save(_: *HSH, _: *anyopaque) ?[][]const u8 {
    return null;
}

fn nop() void {}

fn enable(o: Opts) !void {
    switch (o) {
        .Export => return nop(),
        .BgJob => return nop(),
        .NoClobber => try Vars.putKind("noclobber", "true", .internal),
        .ErrExit => return nop(),
        .PathExpan => return nop(),
        .HashAll => return nop(),
        .NOPMode => return nop(),
        .FailUnset => return nop(),
        .Verbose => return nop(),
        .Trace => return nop(),
    }
}

fn disable(o: Opts) !void {
    switch (o) {
        .Export => return nop(),
        .BgJob => return nop(),
        .NoClobber => try Vars.putKind("noclobber", "false", .internal),
        .ErrExit => return nop(),
        .PathExpan => return nop(),
        .HashAll => return nop(),
        .NOPMode => return nop(),
        .FailUnset => return nop(),
        .Verbose => return nop(),
        .Trace => return nop(),
    }
}

fn special(_: std.mem.Allocator, _: *ParsedIterator) Err!u8 {
    return 0;
}

fn posix(opt: []const u8, titr: *ParsedIterator) Err!u8 {
    _ = titr;
    const mode = opt[0] == '-';
    if (!mode and opt[0] != '+') return Err.InvalidCommand;

    for (opt[1..]) |opt_c| {
        const o = try Opts.find(opt_c);
        if (mode) try enable(o) else try disable(o);
    }
    return 0;
}

fn option(_: std.mem.Allocator, opt: []const u8, titr: *ParsedIterator) Err!u8 {
    _ = opt;
    _ = titr;
    return 0;
}

fn dump() Err!u8 {
    inline for (@typeInfo(PosixOpts).Enum.fields) |o| {
        const name = o.name;
        var truthy = if (Vars.getKind(name, .internal)) |str|
            std.mem.eql(u8, "true", str.str)
        else
            false;

        try print("set {s}o {s}\n", .{ if (truthy) "-" else "+", name });
    }
    return 0;
}

fn setCore(a: std.mem.Allocator, pi: *ParsedIterator) Err!u8 {
    if (!std.mem.eql(u8, pi.first().cannon(), "set")) return Err.InvalidCommand;

    if (pi.next()) |arg| {
        const opt = arg.cannon();

        if (opt.len > 1) {
            if (std.mem.eql(u8, opt, "vi")) {
                try print("sorry robinli, not yet\n", .{});
                return 1;
            }

            if (std.mem.eql(u8, opt, "emacs") or std.mem.eql(u8, opt, "vscode")) {
                @panic("u wot m8?!");
            }

            if (opt[0] == '-' or opt[0] == '+') {
                if (opt[1] == '-') {
                    return special(a, pi);
                }
                return posix(opt, pi);
            } else {
                return option(a, arg.cannon(), pi);
            }
        }
    } else {
        return dump();
    }
    return 0;
}
pub fn set(h: *HSH, titr: *ParsedIterator) Err!u8 {
    return setCore(h.alloc, titr);
}

test "set" {
    var a = std.testing.allocator;
    Vars.init(a);
    defer Vars.raze();

    var ts = [_]Token{
        Token{ .kind = .word, .str = "set" },
        Token{ .kind = .ws, .str = " " },
        Token{ .kind = .word, .str = "-C" },
    };

    const Parse = @import("../parse.zig");
    var p = try Parse.Parser.parse(a, &ts);
    defer p.raze();

    _ = try setCore(a, &p);

    const nc = Vars.getKind("noclobber", .internal);
    try std.testing.expectEqualStrings("true", nc.?.str);
}