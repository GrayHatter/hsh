git: Git,
state: State,

const Context = @This();

var self: Context = undefined;

pub const Git = @import("contexts/git.zig");

const State = struct {
    pub fn init(_: *State) error{InitFailed}!void {}

    pub fn fetch(_: *const State) Lexeme {
        unreachable;
    }

    pub fn update(_: *State, _: *Hsh, _: Allocator, _: Io) error{ OutOfMemory, UpdateFailed }!void {
        unreachable;
    }

    pub fn raze(_: *Git, _: Allocator) void {}
};

pub const Flavor = enum {
    git, // I know, I'm sorry, but... *runs*
    state, // some internal state of hsh
};

pub fn init() !void {
    try self.git.init();
    try self.state.init();
}

pub fn raze(a: Allocator) void {
    self.git.raze(a);
}

pub fn update(h: *Hsh, a: Allocator, io: Io) !void {
    try self.git.update(h, a, io);
}

pub fn fetch(c: Flavor) Lexeme {
    switch (c) {
        inline else => |f| {
            return @field(self, @tagName(f)).fetch();
        },
    }
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Hsh = @import("hsh.zig");
const Draw = @import("draw.zig");
const Lexeme = Draw.Lexeme;
