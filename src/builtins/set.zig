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

fn special(h: *HSH, titr: *ParsedIterator) Err!u8 {
    _ = h;
    _ = titr;
    return 0;
}

fn posix(opt: []const u8, titr: *ParsedIterator) Err!u8 {
    _ = titr;
    const mode = if (opt[0] == '-')
        true
    else if (opt[0] == '+')
        false
    else
        return Err.InvalidCommand;
    for (opt[1..]) |opt_c| {
        const o = try Opts.find(opt_c);
        if (mode) try enable(o) else try disable(o);
    }
    return 0;
}

fn option(h: *HSH, opt: []const u8, titr: *ParsedIterator) Err!u8 {
    _ = h;
    _ = opt;
    _ = titr;
    return 0;
}

fn dump(h: *HSH) Err!u8 {
    _ = h;
    return 0;
}

pub fn set(h: *HSH, titr: *ParsedIterator) Err!u8 {
    if (!std.mem.eql(u8, titr.first().cannon(), "set")) return Err.InvalidCommand;

    if (titr.next()) |arg| {
        const opt = arg.cannon();

        if (opt.len > 1) {
            if (std.mem.eql(u8, opt, "vi")) {
                try print("sorry robinli, not yet\n", .{});
                return 0;
            }

            if (std.mem.eql(u8, opt, "emacs") or std.mem.eql(u8, opt, "vscode")) {
                @panic("u wot m8?!");
            }

            if (opt[0] == '-' or opt[0] == '+') {
                switch (opt[1]) {
                    'o' => {
                        return posix(arg.cannon(), titr);
                    },
                    '-' => {
                        if (opt.len == 2) return special(h, titr);
                    },
                    else => unreachable,
                }
            } else {
                return option(h, arg.cannon(), titr);
            }
        }
    } else {
        return dump(h);
    }
    return 0;
}