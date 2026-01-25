pub const git = @import("contexts/git.zig");

pub const Flavor = enum {
    git, // I know, I'm sorry, but... *runs*
    state, // some internal state of hsh
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

const Init = *const fn () error{InitFailed}!void;
const Raze = *const fn (Allocator) void;
const Update = *const fn (*Hsh, Allocator) error{ OutOfMemory, UpdateFailed }!void;
const Fetch = *const fn (*const Hsh) Lexeme;

pub const Ctx = struct {
    priority: Priority = .Noise,
    name: []const u8 = undefined,
    // unstable
    kind: Flavor = .state,
    init: Init,
    raze: Raze,
    fetch: Fetch,
    update: Update,
};

var a_contexts: ArrayList(Ctx) = .{};

pub fn init(a: Allocator) !void {
    try a_contexts.append(a, git.ctx);

    for (a_contexts.items) |c| {
        try c.init();
    }
}

pub fn raze(a: Allocator) void {
    for (a_contexts.items) |c| {
        c.raze(a);
    }
    a_contexts.clearAndFree(a);
}

pub fn available(hsh: *const Hsh) ![]Flavor {
    return if (hsh.pid > 0)
        [_]Flavor{.git}
    else
        &.{};
}

pub fn update(h: *Hsh, requested: []const Flavor) !void {
    for (requested) |r| {
        try a_contexts.items[@intFromEnum(r)].update(h);
    }
}

pub fn fetch(h: *const Hsh, c: Flavor) Lexeme {
    return try a_contexts.items[@intFromEnum(c)].fetch(h);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Hsh = @import("hsh.zig");
const Draw = @import("draw.zig");
const Lexeme = Draw.Lexeme;
