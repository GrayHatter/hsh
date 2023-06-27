const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const HSH = @import("hsh.zig").HSH;
const IterableDir = std.fs.IterableDir;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const Draw = @import("draw.zig");
const log = @import("log");

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

    pub fn color(k: FSKind) ?Draw.Color {
        return switch (k) {
            .Dir => .Blue,
            else => null,
        };
    }

    pub fn fromFsKind(k: std.fs.IterableDir.Entry.Kind) FSKind {
        return switch (k) {
            .file => .File,
            .directory => .Dir,
            .sym_link => .Link,
            .named_pipe => .Pipe,
            .unix_domain_socket => .Socket,
            .block_device, .character_device => .Device,
            else => unreachable,
        };
    }
};

pub const Flavors = enum(u3) {
    Unknown,
    Original,
    FileSystem,
};

const flavors_len = @typeInfo(Flavors).Enum.fields.len;

pub const Kind = union(Flavors) {
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

    pub fn lexeme(self: CompOption, active: bool) Draw.Lexeme {
        var lex = Draw.Lexeme{
            .char = self.name,
            .attr = if (active) .Reverse else .Reset,
        };

        switch (self.kind) {
            .FileSystem => |fs| {
                lex.fg = fs.color();
                if (fs == .Dir) {
                    lex.attr = if (active) .ReverseBold else .Bold;
                }
            },
            else => {},
        }

        return lex;
    }
};

/// For when groups gets dynamic alloc
//pub const Group = struct {
//    flavor: Flavors,
//    list: CompList,
//};

pub const CompSet = struct {
    alloc: Allocator,
    /// Eventually groups should be dynamically allocated if it gets bigger
    groups: [flavors_len]CompList,
    group: *CompList,
    group_index: usize = 0,
    index: usize = 0,
    // actually using most of orig_token is much danger, such UB
    // the pointers contained within are likely already invalid!
    //orig_token: ?*const Token = null,
    kind: tokenizer.Kind = undefined,

    fn count(self: *const CompSet) usize {
        var c: usize = 0;
        for (self.groups) |grp| {
            c += grp.items.len;
        }
        return c;
    }

    /// Returns the "only" completion if there's a single option known completion,
    /// ignoring the original. If there's multiple or only the original, null.
    pub fn known(self: *CompSet) ?*const CompOption {
        if (self.count() == 2) {
            self.reset();
            _ = self.next();
            return self.next();
        }
        return null;
    }

    pub fn reset(self: *CompSet) void {
        self.index = 0;
        self.group_index = @enumToInt(Flavors.Original);
        self.group = &self.groups[self.group_index];
    }

    pub fn first(self: *CompSet) *const CompOption {
        self.reset();
        return self.next();
    }

    pub fn next(self: *CompSet) *const CompOption {
        std.debug.assert(self.count() > 0);
        defer self.skip();
        return &self.group.items[self.index];
    }

    pub fn skip(self: *CompSet) void {
        std.debug.assert(self.count() > 0);
        self.index += 1;
        if (self.group.items.len > self.index) {
            return;
        }

        while (self.index >= self.group.items.len) {
            self.index = 0;
            self.group_index = (self.group_index + 1) % self.groups.len;
            self.group = &self.groups[self.group_index];
        }
    }

    pub fn push(self: *CompSet, o: CompOption) !void {
        var group = &self.groups[@enumToInt(o.kind)];
        try group.append(o);
    }

    pub fn drawGroup(self: *const CompSet, f: Flavors, d: *Draw.Drawable, w: u32) !void {
        var list = ArrayList(Draw.Lexeme).init(self.alloc);
        var group = &self.groups[@enumToInt(f)];
        var current_group = if (@enumToInt(f) == self.group_index) true else false;

        if (group.items.len == 0) return;
        for (group.items, 0..) |itm, i| {
            const active = current_group and i == self.index;
            const lex = itm.lexeme(active);
            list.append(lex) catch break;
        }
        var trees = try Draw.Layout.tableLexeme(self.alloc, list.items, w);
        for (trees) |tree| try Draw.drawAfter(d, tree);

        for (list.items) |item| {
            self.alloc.free(item.char);
        }
        list.clearAndFree();
    }

    pub fn drawAll(self: *CompSet, d: *Draw.Drawable, w: u32) !void {
        // Yeah... I know
        for (0..flavors_len) |flavor| {
            // TOD Draw name
            try self.drawGroup(@intToEnum(Flavors, flavor), d, w);
        }
    }

    pub fn raze(self: *CompSet) void {
        for (&self.groups) |*group| {
            for (group.items) |opt| {
                self.alloc.free(opt.full);
            }
            group.clearAndFree();
        }
    }
};

fn completeDir(cwdi: *IterableDir) !void {
    var itr = cwdi.iterate();
    while (try itr.next()) |each| {
        const full = try compset.alloc.dupe(u8, each.name);
        try compset.push(CompOption{
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
        try compset.push(CompOption{
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
        try compset.push(CompOption{
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
    try compset.push(CompOption{
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
    compset.reset();
    return &compset;
}

pub fn init(hsh: *HSH) !*CompSet {
    compset = CompSet{
        .alloc = hsh.alloc,
        .group = undefined,
        .groups = .{
            CompList.init(hsh.alloc),
            CompList.init(hsh.alloc),
            CompList.init(hsh.alloc),
        },
    };
    compset.group = &compset.groups[0];
    return &compset;
}
