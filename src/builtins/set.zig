const std = @import("std");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const tokenizer = @import("../tokenizer.zig");
const Token = tokenizer.Token;
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const State = bi.State;

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

pub const OOptions = enum {
    // posix magic
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
    // hsh magic
};

const OptState = union(OOptions) {
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

pub const KnOptions = struct {
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

    pub fn init() KnOptions {
        return KnOptions {
            .allexport = false,
            .errexit = false,
            .ignoreeof = false,
            .monitor = false,
            .noclobber = false,
            .noglob = false,
            .noexec = false,
            .nolog = false,
            .notify = false,
            .nounset = false,
            .verbose = false,
            .vi = false,
            .xtrace = false,
        };
    }
};

var known_options: KnOptions = undefined;

pub fn init() void {
    known_options = KnOptions.init();
    hsh.addState(State{
        .name = "set",
        .ctx = &known_options,
        .api = &.{ .save = save },
    }) catch unreachable;
}

pub fn raze() void {
    return nop();
}

fn save(_: *HSH, _: *anyopaque) ?[][]const u8 {
    return null;
}

fn nop() void {}

fn enable(h: *HSH, o: Opts) !void {
    _ = h;
    switch (o) {
        .Export => return nop(),
        .BgJob => return nop(),
        .NoClobber => known_options.noclobber = true,
        .ErrExit => return nop(),
        .PathExpan => return nop(),
        .HashAll => return nop(),
        .NOPMode => return nop(),
        .FailUnset => return nop(),
        .Verbose => return nop(),
        .Trace => return nop(),
    }
}

fn disable(h: *HSH, o: Opts) !void {
    _ = h;
    switch (o) {
        .Export => return nop(),
        .BgJob => return nop(),
        .NoClobber => known_options.noclobber = false,
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

fn option(h: *HSH, titr: *ParsedIterator) Err!u8 {
    _ = h;
    _ = titr;
    return 0;
}

fn dump(h: *HSH) Err!u8 {
    _ = h;
    return 0;
}

pub fn get_noclobber() bool {
    return known_options.noclobber;
}

pub fn set(h: *HSH, titr: *ParsedIterator) Err!u8 {
    if (!std.mem.eql(u8, titr.first().cannon(), "set")) return Err.InvalidCommand;

    if (titr.next()) |arg| {
        const opt = arg.cannon();
        if (opt.len > 1) {
            if (std.mem.eql(u8, opt, "--")) return special(h, titr);
            if (opt.len == 2 and opt[1] == 'o') return option(h, titr);

            const mode = if (opt[0] == '-') true else if (opt[0] == '+') false else return Err.InvalidCommand;
            for (opt[1..]) |opt_c| {
                const o = try Opts.find(opt_c);

                if (mode) try enable(h, o) else try disable(h, o);
            }
        }
    } else {
        return dump(h);
    }
    return 0;
}