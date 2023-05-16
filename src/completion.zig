const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const HSH = @import("hsh.zig").HSH;
const IterableDir = std.fs.IterableDir;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const TokenType = tokenizer.TokenType;

const Self = @This();

pub const CompList = ArrayList(CompOption);

var compset: CompSet = undefined;

pub const CompKind = enum {
    Unknown,
    Original,
    FileSystem,
};

pub const CompOption = struct {
    str: []u8,
    kind: CompKind,
    pub fn format(self: CompOption, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "CompOption{{{s}, {s}}}", .{ self.str, @tagName(self.kind) });
    }
};

pub const CompSet = struct {
    alloc: Allocator,
    list: CompList,
    index: usize = 0,
    // actually using most of orig_token is much danger, such UB
    // the pointers contained within are likely already invalid!
    orig_token: ?*const Token = null,

    /// true when there's a known completion [or the original]
    pub fn known(self: *CompSet) bool {
        return self.list.items.len == 2;
    }

    /// Will attempt to provide the first completion option if
    /// available, otherwise returns the original.
    /// If token provided to complete() was null, this function is undefined
    pub fn first(self: *CompSet) *const CompOption {
        if (self.list.items.len > 1) return &self.list.items[1];
        return &self.list.items[0];
    }

    pub fn skip(self: *CompSet) void {
        self.index = (self.index + 1) % self.list.items.len;
    }

    pub fn reset(self: *CompSet) void {
        self.index = 0;
    }

    pub fn next(self: *CompSet) *const CompOption {
        defer self.skip();
        return &self.list.items[self.index];
    }

    // caller owns ArrayList
    pub fn optList(self: *const CompSet) ArrayList([]const u8) {
        var list = ArrayList([]const u8).init(self.alloc);
        for (self.list.items) |i| {
            list.append(i.str) catch break;
        }
        return list;
    }

    pub fn raze(self: *CompSet) void {
        for (self.list.items) |opt| {
            self.alloc.free(opt.str);
        }
        self.list.clearAndFree();
    }
};

fn completeDir(cwdi: *IterableDir) !void {
    var itr = cwdi.iterate();
    while (try itr.next()) |each| {
        switch (each.kind) {
            .File, .Directory, .SymLink => {
                try compset.list.append(CompOption{
                    .str = try compset.alloc.dupe(u8, each.name),
                    .kind = .FileSystem,
                });
            },
            else => unreachable,
        }
    }
}

fn completeDirBase(cwdi: *IterableDir, base: []const u8) !void {
    var itr = cwdi.iterate();
    while (try itr.next()) |each| {
        switch (each.kind) {
            .File, .Directory => {
                if (!std.mem.startsWith(u8, each.name, base)) continue;
                try compset.list.append(CompOption{
                    .str = try compset.alloc.dupe(u8, each.name),
                    .kind = .FileSystem,
                });
            },
            else => |typ| {
                std.debug.print("completion error! {}\n", .{typ});
                unreachable;
            },
        }
    }
}

/// Caller promises t: Token contains at least 1 /
fn completePath(h: *HSH, target: []const u8) !void {
    if (target.len < 1) return;

    if (target[0] == '/') {}

    var whole = std.mem.splitBackwards(u8, target, "/");
    var base = whole.first();
    var path = whole.rest();
    var dir = h.fs.cwdi.dir.openIterableDir(path, .{}) catch return;

    if (base.len > 0) return completeDirBase(&dir, base);

    return completeDir(&dir);
}

/// Caller owns nothing, memory is only guaranteed until `complete` is
/// called again.
pub fn complete(hsh: *HSH, t: *const Token) !*CompSet {
    compset.raze();
    compset.orig_token = t;
    compset.index = 0;

    try compset.list.append(CompOption{
        .str = try compset.alloc.dupe(u8, t.cannon()),
        .kind = .Original,
    });
    switch (t.type) {
        .WhiteSpace => try completeDir(&hsh.fs.cwdi),
        .String => try completeDirBase(&hsh.fs.cwdi, t.cannon()),
        .Path => try completePath(hsh, t.cannon()),
        else => {},
    }
    return &compset;
}

pub fn init(hsh: *HSH) !*CompSet {
    compset = CompSet{
        .alloc = hsh.alloc,
        .list = CompList.init(hsh.alloc),
    };
    return &compset;
}
