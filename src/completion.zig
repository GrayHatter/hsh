const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const HSH = @import("hsh.zig").HSH;
const fs = @import("fs.zig");
const IterableDir = std.fs.IterableDir;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const Draw = @import("draw.zig");
const Cord = Draw.Cord;
const log = @import("log");
const S = @import("strings.zig");
const ERRSTR_TOOBIG = S.COMPLETE_TOOBIG;
const ERRSTR_NOOPTS = S.COMPLETE_NOOPTS;

const Self = @This();

pub const CompList = ArrayList(CompOption);

const Error = error{
    search_empty,
};

pub const FSKind = enum {
    File,
    Dir,
    Link,
    Pipe,
    Device,
    Socket,
    whiteout,
    door,
    event_port,
    unknown,

    pub fn color(k: FSKind) ?Draw.Color {
        return switch (k) {
            .Dir => .blue,
            .unknown => .red,
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
            .whiteout => .whiteout,
            .door => .door,
            .event_port => .event_port,
            .unknown => .unknown,
        };
    }
};

pub const Flavors = enum(u3) {
    any,
    path_exe,
    file_system,
};

const flavors_len = @typeInfo(Flavors).Enum.fields.len;

pub const Kind = union(Flavors) {
    any: void,
    path_exe: void,
    file_system: FSKind,
};

pub const CompOption = struct {
    str: []const u8,
    /// the original user text has kind == null
    kind: ?Kind = Kind{ .any = {} },
    pub fn format(self: CompOption, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "CompOption{{{s}, {s}}}", .{ self.str, @tagName(self.kind) });
    }

    pub fn style(self: CompOption, active: bool) Draw.Style {
        const default = Draw.Style{
            .attr = if (active) .reverse else .reset,
        };
        if (self.kind == null) return default;
        switch (self.kind.?) {
            .file_system => |f_s| {
                switch (f_s) {
                    .Dir => return .{
                        .attr = if (active) .reverse_bold else .bold,
                        .fg = f_s.color(),
                    },
                    else => return .{
                        .attr = .reset,
                        .fg = f_s.color(),
                    },
                }
            },
            else => return default,
        }
    }

    pub fn lexeme(self: CompOption, active: bool) Draw.Lexeme {
        return Draw.Lexeme{
            .char = self.str,
            .style = self.style(active),
        };
    }
};

fn searchMatch(items: []const u8, search: []const u8) bool {
    if (search.len > items.len) return false;

    var offset: usize = 0;
    for (search) |s| {
        if (offset >= items.len) break;
        if (std.mem.indexOfScalar(u8, items[offset..], s)) |i| {
            offset += i;
            continue;
        } else if (std.mem.indexOfScalar(u8, items[offset..], std.ascii.toUpper(s))) |i| {
            offset += i;
            continue;
        } else {
            return false;
        }
    }
    return offset < items.len;
}

fn styleToggle(lex: *Draw.Lexeme) void {
    lex.style.attr = switch (lex.style.attr.?) {
        .reset => .reverse,
        .reverse => .reset,
        .reverse_bold => .bold,
        .bold => .reverse_bold,
        .dim => .reverse_dim,
        .reverse_dim => .dim,
        else => .reset,
    };
}

fn styleActive(lex: *Draw.Lexeme) void {
    if (lex.style.attr) |*attr| {
        attr.* = switch (attr.*) {
            .reset => .reverse,
            .bold => .reverse_bold,
            .dim => .reverse,
            else => .reset,
        };
    }
}

fn styleInactive(lex: *Draw.Lexeme) void {
    if (lex.style.attr) |*attr| {
        attr.* = switch (attr.*) {
            .reverse => .reset,
            .reverse_bold => .bold,
            .reverse_dim => .dim,
            .dim => if (lex.style.fg != null) .bold else .reset, // TODO fixme
            else => attr.*,
        };
    }
}

pub const CompSet = struct {
    alloc: Allocator,
    original: ?CompOption,
    /// Eventually groups should be dynamically allocated if it gets bigger
    groups: [flavors_len]CompList,
    group: *CompList,
    group_index: usize = 0,
    index: usize = 0,
    search: ArrayList(u8),
    // actually using most of orig_token is much danger, such UB
    // the pointers contained within are likely already invalid!
    //orig_token: ?*const Token = null,
    kind: tokenizer.Kind = .nos,
    err: bool = false,
    draw_cache: [flavors_len]?[]Draw.LexTree = .{null} ** 3,

    /// Intentionally excludes original from the count
    pub fn count(self: *const CompSet) usize {
        var c: usize = 0;
        for (self.groups) |grp| {
            c += grp.items.len;
        }
        return c;
    }

    pub fn countFiltered(self: *const CompSet) usize {
        var c: usize = 0;
        for (self.groups) |grp| {
            for (grp.items) |item| {
                if (searchMatch(item.str, self.search.items)) {
                    c += 1;
                }
            }
        }
        return c;
    }

    /// Returns the "only" completion if there's a single option known completion,
    /// ignoring the original. If there's multiple or only the original, null.
    pub fn known(self: *CompSet) ?*const CompOption {
        if (self.count() == 1) {
            self.reset();
            _ = self.next();
            return self.next();
        }

        if (self.search.items.len > 0 and self.countFiltered() == 1) {
            self.reset();
            return self.next();
        }

        return null;
    }

    pub fn reset(self: *CompSet) void {
        self.index = 0;
        self.groupSet(.any);
    }

    pub fn first(self: *CompSet) *const CompOption {
        self.reset();
        return self.next();
    }

    // behavior is undefined when count <= 0
    pub fn next(self: *CompSet) *const CompOption {
        std.debug.assert(self.count() > 0);

        self.skip();
        var maybe = &self.group.items[self.index];
        if (self.search.items.len > 0 and self.countFiltered() > 0) {
            while (!searchMatch(maybe.str, self.search.items)) {
                self.skip();
                maybe = &self.group.items[self.index];
            }
        }
        return maybe;
    }

    pub fn current(self: *const CompSet) *const CompOption {
        if (self.group.items.len == 0) return &self.original.?;
        return &self.group.items[self.index];
    }

    pub fn skip(self: *CompSet) void {
        std.debug.assert(self.count() > 0);
        self.index += 1;
        while (self.index >= self.group.items.len) {
            self.index = 0;
            self.groupSet(null);
        }
    }

    pub fn revr(self: *CompSet) void {
        if (self.count() < 3) return;
        if (self.index == 0) {
            while (true) {
                if (self.group_index == 0) {
                    self.group_index = self.groups.len - 1;
                } else {
                    self.group_index -= 1;
                }
                self.group = &self.groups[self.group_index];
                if (self.group.items.len > 0) {
                    self.index = self.group.items.len - 1;
                    break;
                }
            }
        }
        self.index -= 1;
    }

    pub fn groupSet(self: *CompSet, grp: ?Flavors) void {
        if (grp) |g| {
            self.group_index = @intFromEnum(g);
        } else {
            self.group_index = (self.group_index + 1) % self.groups.len;
        }
        self.group = &self.groups[self.group_index];
    }

    pub fn push(self: *CompSet, o: CompOption) !void {
        self.groupSet(o.kind.?);
        try self.group.append(o);
    }

    pub fn drawGroup(self: *CompSet, f: Flavors, d: *Draw.Drawable, wh: Cord) !void {
        //defer list.clearAndFree();
        const g_int = @intFromEnum(f);
        var group = &self.groups[g_int];
        var current_group = g_int == self.group_index;

        if (group.items.len == 0) return;

        if (self.draw_cache[g_int]) |*dc| {
            const mod: usize = dc.*[0].siblings.len;
            // self.index points to the next item, current item is index - 1

            const this_row = (self.index) / mod;
            const this_col = (self.index) % mod;

            for (dc.*, 0..) |tree, row| {
                var plz_draw = false;
                for (tree.siblings) |*sib| {
                    if (!searchMatch(sib.char, self.search.items)) {
                        sib.style.attr = .dim;
                    } else {
                        styleInactive(sib);
                        plz_draw = true;
                    }
                }

                if (current_group and row == this_row) {
                    styleActive(&tree.siblings[this_col]);
                }

                if (plz_draw) try Draw.drawAfter(d, tree);
            }
            return;
        }
        try self.drawGroupBuild(f, d, wh);
        return self.drawGroup(f, d, wh);
    }

    pub fn drawGroupBuild(self: *CompSet, f: Flavors, d: *Draw.Drawable, wh: Cord) !void {
        const g_int = @intFromEnum(f);
        var group = &self.groups[g_int];

        var list = ArrayList(Draw.Lexeme).init(self.alloc);
        for (group.items) |itm| {
            const lex = itm.lexeme(false);
            list.append(lex) catch break;
        }
        var items = try list.toOwnedSlice();
        if (Draw.Layout.table(self.alloc, items, wh)) |trees| {
            self.draw_cache[g_int] = trees;
        } else |err| {
            if (err == Draw.Layout.Error.ItemCount) {
                var fbuf: [128]u8 = undefined;
                const str = try std.fmt.bufPrint(&fbuf, ERRSTR_TOOBIG, .{self.count()});
                try Draw.drawAfter(d, Draw.LexTree{
                    .lex = Draw.Lexeme{ .char = str, .style = .{ .attr = .bold, .fg = .red } },
                });
                self.err = true;
                return err;
            }
        }
    }

    pub fn drawAll(self: *CompSet, d: *Draw.Drawable, wh: Cord) !void {
        if (self.err) {
            var fbuf: [128]u8 = undefined;
            const str = try std.fmt.bufPrint(&fbuf, ERRSTR_TOOBIG, .{self.count()});
            try Draw.drawAfter(d, Draw.LexTree{
                .lex = Draw.Lexeme{ .char = str, .style = .{ .attr = .bold, .fg = .red } },
            });
            return;
        }
        if (self.count() == 0) {
            try Draw.drawAfter(d, Draw.LexTree{
                .lex = Draw.Lexeme{ .char = ERRSTR_NOOPTS, .style = .{ .attr = .bold, .fg = .red } },
            });
            return;
        }

        // Yeah... I know
        for (0..flavors_len) |flavor| {
            // TODO Draw name
            try self.drawGroup(@enumFromInt(flavor), d, wh);
        }
    }

    pub fn searchChar(self: *CompSet, char: u8) !void {
        try self.search.append(char);
        //if (self.countFiltered() == 0) {}
    }

    pub fn searchPop(self: *CompSet) !void {
        if (self.search.items.len == 0) {
            return Error.search_empty;
        }
        _ = self.search.pop();
    }

    pub fn raze(self: *CompSet) void {
        for (&self.groups) |*group| {
            for (group.items) |opt| {
                self.alloc.free(opt.str);
            }
            group.clearAndFree();
        }
        if (self.original) |o| {
            self.alloc.free(o.str);
        }
        for (&self.draw_cache) |*cache_group| {
            if (cache_group.*) |*trees| {
                var real_size: usize = 0;
                for (trees.*) |row| {
                    for (row.siblings) |lex| {
                        self.alloc.free(lex.char);
                        real_size += 1;
                    }
                }
                trees.*[0].siblings.len = real_size;
                self.alloc.free(trees.*[0].siblings);
                self.alloc.free(trees.*);
                cache_group.* = null;
            }
        }
        self.err = false;
        self.search.clearAndFree();
    }
};

fn completeDir(cs: *CompSet, cwdi: IterableDir) !void {
    var itr = cwdi.iterate();
    cs.original = CompOption{ .str = try cs.alloc.dupe(u8, ""), .kind = null };
    while (try itr.next()) |each| {
        try cs.push(CompOption{
            .str = try cs.alloc.dupe(u8, each.name),
            .kind = Kind{
                .file_system = FSKind.fromFsKind(each.kind),
            },
        });
    }
}

fn completeDirBase(cs: *CompSet, cwdi: IterableDir, base: []const u8) !void {
    var itr = cwdi.iterate();
    cs.original = CompOption{ .str = try cs.alloc.dupe(u8, base), .kind = null };
    while (try itr.next()) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        try cs.push(CompOption{
            .str = try cs.alloc.dupe(u8, each.name),
            .kind = Kind{
                .file_system = FSKind.fromFsKind(each.kind),
            },
        });
    }
}

fn completePath(cs: *CompSet, _: *HSH, target: []const u8) !void {
    if (target.len < 1) return;

    var whole = std.mem.splitBackwards(u8, target, "/");
    var base = whole.first();
    var path = whole.rest();

    var dir: std.fs.IterableDir = undefined;
    if (target[0] == '/') {
        if (path.len == 0) {
            dir = std.fs.openIterableDirAbsolute("/", .{}) catch return;
        } else {
            dir = std.fs.openIterableDirAbsolute(path, .{}) catch return;
        }
    } else {
        dir = std.fs.cwd().openIterableDir(path, .{}) catch return;
    }
    defer dir.close();

    cs.original = CompOption{ .str = try cs.alloc.dupe(u8, base), .kind = null };
    var itr = dir.iterate();
    while (try itr.next()) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        if (each.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;

        try cs.push(CompOption{
            .str = try cs.alloc.dupe(u8, each.name),
            .kind = Kind{
                .file_system = FSKind.fromFsKind(each.kind),
            },
        });
    }
}

fn completeSysPath(cs: *CompSet, h: *HSH, target: []const u8) !void {
    if (std.mem.indexOf(u8, target, "/")) |_| {
        return completePath(cs, h, target);
    }

    cs.original = CompOption{ .str = try cs.alloc.dupe(u8, target), .kind = null };

    for (h.hfs.names.paths.items) |path| {
        var dir = std.fs.openIterableDirAbsolute(path, .{}) catch return;
        defer dir.close();
        var itr = dir.iterate();
        while (try itr.next()) |each| {
            if (!std.mem.startsWith(u8, each.name, target)) continue;
            if (each.name[0] == '.' and (target.len == 0 or target[0] != '.')) continue;
            if (each.kind != .file) continue; // TODO probably a bug
            const file = fs.openFileAt(dir.dir, each.name, false) orelse continue;
            defer file.close();
            if (file.metadata()) |md| {
                if (!md.permissions().inner.unixHas(
                    std.fs.File.PermissionsUnix.Class.other,
                    std.fs.File.PermissionsUnix.Permission.execute,
                )) continue;
            } else |err| {
                log.err("{} unable to get metadata for file at path {s} name {s}\n", .{
                    err,
                    path,
                    target,
                });
                return;
            }

            try cs.push(CompOption{
                .str = try cs.alloc.dupe(u8, each.name),
                .kind = Kind{ .path_exe = {} },
            });
        }
    }
}
/// Caller owns nothing, memory is only guaranteed until `complete` is
/// called again.
pub fn complete(cs: *CompSet, hsh: *HSH, ts: []const Token) !void {
    cs.raze();
    cs.kind = if (ts.len > 0) ts[0].kind else .nos;
    cs.index = 0;

    // TODO need the real bug here
    const t = if (ts.len > 0) ts[ts.len - 1] else Token{ .str = "", .kind = .nos };
    const hint: Kind = if (ts.len <= 1) .path_exe else .any;
    switch (hint) {
        .path_exe => {
            try completeSysPath(cs, hsh, t.cannon());
        },
        else => {
            switch (t.kind) {
                .ws => {
                    var dir = try std.fs.cwd().openIterableDir(".", .{});
                    defer dir.close();
                    try completeDir(cs, dir);
                },
                .word, .path => {
                    if (std.mem.indexOfScalar(u8, t.cannon(), '/')) |_| {
                        try completePath(cs, hsh, t.cannon());
                    } else {
                        var dir = try std.fs.cwd().openIterableDir(".", .{});
                        defer dir.close();
                        try completeDirBase(cs, dir, t.cannon());
                    }
                },
                .io => {
                    // TODO pipeline integration
                },
                else => {},
            }
        },
    }
    cs.reset();
    return;
}

pub fn init(hsh: *HSH) !CompSet {
    var compset = CompSet{
        .alloc = hsh.alloc,
        .original = null,
        .group = undefined,
        .groups = .{
            CompList.init(hsh.alloc),
            CompList.init(hsh.alloc),
            CompList.init(hsh.alloc),
        },
        .search = ArrayList(u8).init(hsh.alloc),
    };
    compset.group = &compset.groups[0];
    return compset;
}
