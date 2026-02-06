const Options = ArrayList(Completion.Option);

pub fn suggest(cs: *Completion, tokens: []Token, t_idx: ?usize, fs: Fs, a: Allocator, io: Io) error{OutOfMemory}!void {
    _ = cs;
    _ = tokens;
    _ = t_idx;
    _ = fs;
    _ = a;
    _ = io;
    unreachable;
}

pub fn filter(cs: *Completion, tokens: []Token, t_idx: ?usize, fs: Fs, a: Allocator, io: Io) void {
    _ = cs;
    _ = tokens;
    _ = t_idx;
    _ = fs;
    _ = a;
    _ = io;
    unreachable;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Completion = @import("../Completion.zig");
const Fs = @import("../fs.zig");
const Token = @import("../token.zig");
const log = @import("../log.zig");
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const findScalarLast = std.mem.findScalarLast;
const trim = std.mem.trim;
const assert = std.debug.assert;
