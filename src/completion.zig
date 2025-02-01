const Completion = @This();

pub const CompList = ArrayList(CompOption);

const Error = error{
    search_empty,
};

pub const FSKind = enum {
    file,
    dir,
    link,
    pipe,
    device,
    socket,
    whiteout,
    door,
    event_port,
    unknown,

    pub fn color(k: FSKind) ?Draw.Color {
        return switch (k) {
            .dir => .blue,
            .unknown => .red,
            else => null,
        };
    }

    pub fn fromFsKind(k: std.fs.Dir.Entry.Kind) FSKind {
        return switch (k) {
            .file => .file,
            .directory => .dir,
            .sym_link => .link,
            .named_pipe => .pipe,
            .unix_domain_socket => .socket,
            .block_device, .character_device => .device,
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

    pub const len = @typeInfo(Flavors).@"enum".fields.len;
};

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
                    .dir => return .{
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

fn searchMatch(items: []const u8, search: []const u8) ?usize {
    if (search.len == 0) return 0;
    if (search.len > items.len) return null;

    var offset: usize = 0;
    for (search) |s| {
        if (offset >= items.len) return null;
        if (indexOfScalar(u8, items[offset..], s)) |i| {
            offset += i + 1;
            continue;
        }
        if (indexOfScalar(u8, items[offset..], toUpper(s))) |i| {
            offset += i + 1;
            continue;
        }
        return null;
    }
    return offset - search.len;
}

test "search match" {
    const n: ?usize = null;
    try std.testing.expectEqual(0, comptime searchMatch("string", "s").?);
    try std.testing.expectEqual(1, comptime searchMatch("string", "t").?);
    try std.testing.expectEqual(0, comptime searchMatch("string", "str").?);
    try std.testing.expectEqual(1, comptime searchMatch("string", "tri").?);
    try std.testing.expectEqual(n, comptime searchMatch("string", "strI"));
    try std.testing.expectEqual(0, comptime searchMatch("STRINg", "strI").?);
    try std.testing.expectEqual(n, comptime searchMatch("string", "q"));
    try std.testing.expectEqual(0, comptime searchMatch("string", "").?);
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
    if (lex.style) |*style| if (style.attr) |*attr| {
        attr.* = switch (attr.*) {
            .reset => .reverse,
            .bold => .reverse_bold,
            .dim => .reverse,
            else => .reset,
        };
    };
}

fn styleInactive(lex: *Draw.Lexeme) void {
    if (lex.style) |*style| if (style.attr) |*attr| {
        attr.* = switch (attr.*) {
            .reverse => .reset,
            .reverse_bold => .bold,
            .reverse_dim => .dim,
            .dim => if (style.fg != null) .bold else .reset, // TODO fixme
            else => attr.*,
        };
    };
}

fn sortAscStr(_: void, a: []const u8, b: []const u8) bool {
    const end = @min(a.len, b.len);

    for (a[0..end], b[0..end]) |l, r| {
        if (l != r) return l < r;
    }
    return false;
}

fn sortAscCompOption(ctx: void, a: CompOption, b: CompOption) bool {
    return sortAscStr(ctx, a.str, b.str);
}

pub const CompSet = struct {
    alloc: Allocator,
    original: ?CompOption,
    /// Eventually groups should be dynamically allocated if it gets bigger
    groups: [Flavors.len]CompList,
    group: *CompList,
    group_index: usize = 0,
    index: usize = 0,
    search: ArrayList(u8),
    // actually using most of orig_token is much danger, such UB
    // the pointers contained within are likely already invalid!
    //orig_token: ?*const Token = null,
    kind: Token.Kind = .nos,
    err: bool = false,
    draw_cache: [Flavors.len]?[][]Draw.Lexeme = .{null} ** 3,

    /// Intentionally excludes original from the count
    pub fn count(self: *const CompSet) usize {
        var c: usize = 0;
        for (self.groups) |grp| {
            c += grp.items.len;
        }
        return c;
    }

    // TODO cache
    pub fn countFiltered(self: *const CompSet) usize {
        var c: usize = 0;
        for (self.groups) |grp| {
            for (grp.items) |item| {
                if (searchMatch(item.str, self.search.items)) |_| {
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

    pub fn sort(self: *CompSet) void {
        for (self.groups) |group| {
            std.sort.heap(CompOption, group.items, {}, sortAscCompOption);
        }
    }

    pub fn first(self: *CompSet) *const CompOption {
        self.reset();
        return self.next();
    }

    // behavior is undefined when count <= 0
    pub fn next(self: *CompSet) *const CompOption {
        std.debug.assert(self.count() > 0);

        self.skip();
        if (self.search.items.len > 0 and self.countFiltered() > 0) {
            while (!self.curSearchMatch()) {
                self.skip();
            }
        }
        return &self.group.items[self.index];
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

    fn curSearchMatch(self: *CompSet) bool {
        const curr = &self.group.items[self.index];
        return searchMatch(curr.str, self.search.items) != null;
    }

    pub fn revr(self: *CompSet) void {
        if (self.countFiltered() < 3) return;
        while (true) {
            if (self.index == 0) {
                while (true) {
                    if (self.group_index == 0) {
                        self.group_index = self.groups.len - 1;
                    } else {
                        self.group_index -= 1;
                    }
                    self.group = &self.groups[self.group_index];
                    if (self.group.items.len == 0) continue;

                    self.index = self.group.items.len - 1;
                    if (self.curSearchMatch()) return;
                    break;
                }
            }
            self.index -|= 1;
            if (self.curSearchMatch()) break;
        }
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
        const group = &self.groups[g_int];
        const current_group = g_int == self.group_index;

        if (group.items.len == 0) return;

        if (self.draw_cache[g_int]) |dcache| {
            const mod: usize = if (dcache[0].len > 0) dcache[0].len else 1;
            // self.index points to the next item, current item is index - 1

            const this_row = (self.index) / mod;
            const this_col = (self.index) % mod;

            for (dcache, 0..) |row, r| {
                var plz_draw = false;
                for (row) |*column| {
                    if (searchMatch(column.char, self.search.items) == null) {
                        column.style.?.attr = .dim;
                    } else {
                        styleInactive(column);
                        plz_draw = true;
                    }
                }

                if (current_group and r == this_row and row.len > 0) {
                    styleActive(&row[this_col]);
                }

                if (plz_draw) try Draw.drawAfter(d, row);
            }
            return;
        }
        try self.drawGroupBuild(f, d, wh);
        return self.drawGroup(f, d, wh);
    }

    pub fn drawGroupBuild(self: *CompSet, f: Flavors, d: *Draw.Drawable, wh: Cord) !void {
        const g_int = @intFromEnum(f);
        const group = &self.groups[g_int];

        var list = ArrayList(Draw.Lexeme).init(self.alloc);
        for (group.items) |itm| {
            const lex = itm.lexeme(false);
            list.append(lex) catch break;
        }
        const items = try list.toOwnedSlice();
        if (Draw.Layout.tableLexeme(self.alloc, items, wh)) |lexes| {
            self.draw_cache[g_int] = lexes;
        } else |err| switch (err) {
            error.ItemCount => {
                var fbuf: [128]u8 = undefined;
                const str = try std.fmt.bufPrint(&fbuf, ERRSTR_TOOBIG, .{self.count()});
                try Draw.drawAfter(d, &[_]Draw.Lexeme{.{
                    .char = str,
                    .style = .{ .attr = .bold, .fg = .red },
                }});
                self.err = true;
                return err;
            },
            else => unreachable,
        }
    }

    pub fn drawAll(self: *CompSet, d: *Draw.Drawable, wh: Cord) !void {
        if (self.err) {
            var fbuf: [128]u8 = undefined;
            const str = try std.fmt.bufPrint(&fbuf, ERRSTR_TOOBIG, .{self.count()});
            try Draw.drawAfter(
                d,
                &[_]Draw.Lexeme{.{ .char = str, .style = .{ .attr = .bold, .fg = .red } }},
            );
            return;
        }
        if (self.count() == 0) {
            try Draw.drawAfter(
                d,
                &[_]Draw.Lexeme{.{ .char = ERRSTR_NOOPTS, .style = .{ .attr = .bold, .fg = .red } }},
            );
            return;
        }

        // Yeah... I know
        for (0..Flavors.len) |flavor| {
            // TODO Draw name
            try self.drawGroup(@enumFromInt(flavor), d, wh);
        }
    }

    pub fn searchChar(self: *CompSet, char: u8) !void {
        try self.search.append(char);
        // TODO when searching, set to the lowest sum of search offsets

        self.searchMove();
    }

    fn searchMove(self: *CompSet) void {
        var mcount: usize = 0;
        var best_cost: usize = ~@as(usize, 0);
        for (self.groups, 0..) |grp, gi| {
            for (grp.items, 0..) |each, ei| {
                if (searchMatch(each.str, self.search.items)) |cost| {
                    mcount += 1;
                    if (cost < best_cost) {
                        self.group_index = gi;
                        self.index = ei;
                        self.index -|= 1;
                        best_cost = cost;
                    }
                }
            }
        }
        self.group = &self.groups[self.group_index];
    }

    pub fn searchStr(self: *CompSet, str: []const u8) !void {
        for (str) |c| try self.searchChar(c);
    }

    pub fn searchPop(self: *CompSet) !void {
        if (self.search.items.len == 0) {
            return Error.search_empty;
        }
        _ = self.search.pop();
        self.searchMove();
    }

    fn razeDrawing(self: *CompSet) void {
        for (&self.draw_cache) |*dcache| {
            if (dcache.*) |*row| {
                var real_size: usize = 0;
                for (row.*) |col| {
                    for (col) |lex| {
                        self.alloc.free(lex.char);
                        real_size += 1;
                    }
                }
                row.*[0].len = real_size;
                self.alloc.free(row.*);
                dcache.* = null;
            }
        }
        self.err = false;
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
            self.original = null;
        }
        self.razeDrawing();
        self.search.clearAndFree();
    }
};

fn completeDir(cs: *CompSet, cwdi: Dir) !void {
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

fn completeDirBase(cs: *CompSet, cwdi: Dir, base: []const u8) !void {
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

    var whole = std.mem.splitBackwardsAny(u8, target, "/");
    const base = whole.first();
    const path = whole.rest();

    var dir: std.fs.Dir = undefined;
    if (target[0] == '/') {
        if (path.len == 0) {
            dir = std.fs.openDirAbsolute("/", .{ .iterate = true }) catch return;
        } else {
            dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
        }
    } else {
        dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
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
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
        defer dir.close();
        var itr = dir.iterate();
        while (try itr.next()) |each| {
            if (!std.mem.startsWith(u8, each.name, target)) continue;
            if (each.name[0] == '.' and (target.len == 0 or target[0] != '.')) continue;
            if (each.kind != .file) continue; // TODO probably a bug
            const file = fs.openFileAt(dir, each.name, false) orelse continue;
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

const TknPair = struct {
    t: Token = .{ .str = "" },
    offset: usize = 0,
    count: usize = 0,
};

fn findToken(tkns: *Tokenizer) TknPair {
    var itr = tkns.iterator();
    var pair: TknPair = .{};
    var idx: usize = tkns.idx;
    while (itr.next()) |t| {
        pair.count += 1;
        if (idx <= t.str.len) {
            pair.t = t.*;
            pair.offset = idx;
            break;
        }
        idx -|= t.str.len;
    }
    pair.t.str = pair.t.str[0..pair.offset];
    return pair;
}

/// Caller owns nothing, memory is only guaranteed until `complete` is
/// called again.
pub fn complete(cs: *CompSet, hsh: *HSH, tks: *Tokenizer) !void {
    cs.raze();

    var iter = tks.iterator();
    const ts = iter.toSlice(hsh.alloc) catch unreachable;
    defer hsh.alloc.free(ts);

    cs.kind = if (ts.len > 0) ts[0].kind else .nos;
    cs.index = 0;

    // TODO need the real bug here
    var pair = findToken(tks);
    const hint: Kind = if (ts.len <= 1) .path_exe else .any;

    try Draw.drawAfter(&hsh.draw, &[_]Draw.Lexeme{.{
        .char = "[ complete ]",
        .style = .{ .attr = .bold, .fg = .green },
    }});
    try hsh.draw.render();

    switch (hint) {
        .path_exe => {
            try completeSysPath(cs, hsh, pair.t.cannon());
        },
        else => {
            switch (pair.t.kind) {
                .ws => {
                    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
                    defer dir.close();
                    try completeDir(cs, dir);
                },
                .word, .path => {
                    var t = try Parser.single(hsh.alloc, pair.t);
                    if (std.mem.indexOfScalar(u8, t.cannon(), '/')) |_| {
                        try completePath(cs, hsh, t.cannon());
                    } else {
                        var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
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

    if (cs.original) |orig| {
        try tks.maybeDupe(orig.str);
        try cs.searchStr(orig.str);
    }
    if (cs.original) |orig| {
        log.debug("Completion original is {s}\n\n", .{orig.str});
    } else {
        log.debug("Completion original is null\n\n", .{});
    }

    cs.sort();
    cs.reset();
    return;
}

pub fn init(a: Allocator) CompSet {
    var compset = CompSet{
        .alloc = a,
        .original = null,
        .group = undefined,
        .groups = .{
            CompList.init(a),
            CompList.init(a),
            CompList.init(a),
        },
        .search = ArrayList(u8).init(a),
    };
    compset.group = &compset.groups[0];
    return compset;
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const indexOfScalar = std.mem.indexOfScalar;
const toUpper = std.ascii.toUpper;
const log = @import("log");

const HSH = @import("hsh.zig").HSH;
const fs = @import("fs.zig");
const Tokenizer = @import("tokenizer.zig");
const Token = @import("token.zig");
const Parser = @import("parse.zig").Parser;
const Draw = @import("draw.zig");
const Cord = Draw.Cord;
const S = @import("strings.zig");
const ERRSTR_TOOBIG = S.COMPLETE_TOOBIG;
const ERRSTR_NOOPTS = S.COMPLETE_NOOPTS;
