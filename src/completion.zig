const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const HSH = @import("hsh.zig").HSH;
const IterableDir = std.fs.IterableDir;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;

const Self = @This();

pub const CompList = ArrayList(CompOption);

var compset: CompSet = undefined;

pub const FSKind = enum {
    File,
    Dir,
    Link,
    Pipe,
    Device,
    Socket,
    Other,

    pub fn fromFsKind(k: std.fs.IterableDir.Entry.Kind) FSKind {
        return switch (k) {
            .File => .File,
            .Directory => .Dir,
            .SymLink => .Link,
            .NamedPipe => .Pipe,
            .UnixDomainSocket => .Socket,
            .BlockDevice, .CharacterDevice => .Device,
            else => unreachable,
        };
    }
};

pub const Kind = union(enum) {
    Unknown: void,
    Original: bool,
    FileSystem: FSKind,
};

pub const CompOption = struct {
    full: []const u8,
    /// name is normally a simple subslice of full.
    name: []const u8,
    kind: Kind = Kind{ .Unknown = {} },
    pub fn format(self: CompOption, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "CompOption{{{s}, {s}}}", .{ self.full, @tagName(self.kind) });
    }
};

pub const CompSet = struct {
    alloc: Allocator,
    list: CompList,
    index: usize = 0,
    // actually using most of orig_token is much danger, such UB
    // the pointers contained within are likely already invalid!
    //orig_token: ?*const Token = null,
    kind: tokenizer.Kind = undefined,

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
            if (i.kind == .Original) {
                if (i.kind.Original) continue;
            }
            list.append(i.name) catch break;
        }
        return list;
    }

    pub fn raze(self: *CompSet) void {
        for (self.list.items) |opt| {
            self.alloc.free(opt.full);
        }
        self.list.clearAndFree();
    }
};

fn completeDir(cwdi: *IterableDir) !void {
    var itr = cwdi.iterate();
    while (try itr.next()) |each| {
        const full = try compset.alloc.dupe(u8, each.name);
        try compset.list.append(CompOption{
            .full = full,
            .name = full,
            .kind = Kind{
                .FileSystem = FSKind.fromFsKind(each.kind),
            },
        });
    }
}

fn completeDirBase(cwdi: *IterableDir, base: []const u8) !void {
    var itr = cwdi.iterate();
    while (try itr.next()) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        var full = try compset.alloc.dupe(u8, each.name);
        try compset.list.append(CompOption{
            .full = full,
            .name = full,
            .kind = Kind{
                .FileSystem = FSKind.fromFsKind(each.kind),
            },
        });
    }
}

fn completePath(h: *HSH, target: []const u8) !void {
    if (target.len < 1) return;

    if (target[0] == '/') {}

    var whole = std.mem.splitBackwards(u8, target, "/");
    var base = whole.first();
    var path = whole.rest();
    var dir = h.hfs.dirs.cwd.dir.openIterableDir(path, .{}) catch return;

    var itr = dir.iterate();
    while (try itr.next()) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        if (each.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;

        var full = try compset.alloc.alloc(u8, path.len + each.name.len + 1);
        var name = full[path.len + 1 ..];
        @memcpy(full[0..path.len], path);
        full[path.len] = '/';
        @memcpy(name, each.name);
        try compset.list.append(CompOption{
            .full = full,
            .name = name,
            .kind = Kind{
                .FileSystem = FSKind.fromFsKind(each.kind),
            },
        });
    }
}

/// Caller owns nothing, memory is only guaranteed until `complete` is
/// called again.
pub fn complete(hsh: *HSH, t: *const Token) !*CompSet {
    compset.raze();
    compset.kind = t.kind;
    compset.index = 0;

    const full = try compset.alloc.dupe(u8, t.cannon());
    try compset.list.append(CompOption{
        .full = full,
        .name = full,
        .kind = Kind{ .Original = t.kind == .WhiteSpace },
    });
    switch (t.kind) {
        .WhiteSpace => try completeDir(&hsh.hfs.dirs.cwd),
        .String => try completeDirBase(&hsh.hfs.dirs.cwd, t.cannon()),
        .Path => try completePath(hsh, t.cannon()),
        .IoRedir => {},
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
