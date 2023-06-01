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

pub const Contexts = enum {
    state, // some internal state of hsh
    git,
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

const Ctx = struct {
    priority: Priority = .Noise,
    name: []u8 = undefined,
    // unstable
    type: Contexts = .state,
};

var a_contexts: std.ArrayList(Ctx) = undefined;

pub fn init(a: std.mem.Allocator) void {
    a_contexts = std.ArrayList(Ctx).init(a);
}

pub fn ctxAvailable(hsh: *const HSH) ![]Contexts {
    if (hsh.pid > 0) return [_]Contexts{.git} else return [0]Contexts{};
}

/// Caller owns all memory within context
pub fn ctxGet(h: *HSH) Error!Lexeme {
    return git.get(h);
}
