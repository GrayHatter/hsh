const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const HSH = @import("hsh.zig").HSH;
const IterableDir = std.fs.IterableDir;
const _tkn = @import("tokenizer.zig");
const Token = _tkn.Token;
const TokenType = _tkn.TokenType;

pub const CompList = ArrayList(CompOption);

// pub? compset
pub var compset: CompSet = undefined;

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

    pub fn next(self: *CompSet) ?*const CompOption {
        if (self.list.items.len > self.index) {
            self.index += 1;
            return &self.list.items[self.index - 1];
        }
        return null;
    }

    pub fn raze(self: *CompSet) void {
        for (self.list.items) |opt| {
            self.alloc.free(opt.str);
        }
        self.list.clearAndFree();
    }
};

fn complete_cwd(cwdi: *IterableDir, _: *const Token) !void {
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

fn complete_cwd_token(cwdi: IterableDir, t: *const Token) !void {
    var itr = cwdi.iterate();
    while (try itr.next()) |each| {
        switch (each.kind) {
            .File, .Directory => {
                if (!std.mem.startsWith(u8, each.name, t.cannon())) continue;
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

/// Caller owns both the array of options, and the option text memory for each as well
pub fn complete(hsh: *HSH, t: *const Token) !*CompSet {
    compset.raze();
    compset.orig_token = t;
    try compset.list.append(CompOption{
        .str = try compset.alloc.dupe(u8, t.cannon()),
        .kind = .Original,
    });
    switch (t.type) {
        .WhiteSpace => try complete_cwd(&hsh.fs.cwdi, t),
        .String, .Char => try complete_cwd_token(hsh.fs.cwdi, t),
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
