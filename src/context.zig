const std = @import("std");
const hshz = @import("hsh.zig");
const HSH = hshz.HSH;
const Lexeme = Draw.Lexeme;

pub const Draw = @import("draw.zig");

pub const git = @import("contexts/git.zig");

pub const Error = error{
    Unknown,
    Memory,
    Other,
};

pub const Contexts = enum(u2) {
    state = 1, // some internal state of hsh
    git = 0, // I know, I'm sorry, but... *runs*
};

/// Context priority clones log priority for simplicity, but isn't required to
/// follow it's naming explicitly. E.g. Panic is the most extreme level, but
/// context that doesn't result in app an crash is still able to use it.
const Priority = enum {
    Panic,
    Error,
    Warning,
    Notice,
    Info,
    Debug,
    Trace,
    Noise,
    Off,
};

const Init = *const fn () Error!void;
const Update = *const fn (*HSH) Error!void;
const Fetch = *const fn (*const HSH) Error!Lexeme;

pub const Ctx = struct {
    priority: Priority = .Noise,
    name: []const u8 = undefined,
    // unstable
    kind: Contexts = .state,
    init: Init,
    fetch: Fetch,
    update: Update,
};

var a_contexts: std.ArrayList(Ctx) = undefined;

pub fn init(a: *std.mem.Allocator) Error!void {
    a_contexts = std.ArrayList(Ctx).init(a.*);
    a_contexts.append(git.ctx) catch return Error.Memory;

    for (a_contexts.items) |c| {
        try c.init();
    }
}

pub fn available(hsh: *const HSH) ![]Contexts {
    if (hsh.pid > 0) return [_]Contexts{.git} else return [0]Contexts{};
}

pub fn update(h: *HSH, requested: []const Contexts) !void {
    for (requested) |r| {
        try a_contexts.items[@enumToInt(r)].update(h);
    }
}

pub fn fetch(h: *const HSH, c: Contexts) Error!Lexeme {
    return try a_contexts.items[@enumToInt(c)].fetch(h);
}
