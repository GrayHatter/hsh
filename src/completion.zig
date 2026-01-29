const Completion = @This();

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

    pub fn fromFsKind(k: Io.File.Kind) FSKind {
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

pub const Flavor = enum(u3) {
    any,
    path_exe,
    file_system,

    pub const len = @typeInfo(Flavor).@"enum".fields.len;
};

pub const Kind = union(Flavor) {
    any: void,
    path_exe: void,
    file_system: FSKind,
};

pub const Option = struct {
    str: []const u8,
    /// the original user text has kind == null
    kind: ?Kind = Kind{ .any = {} },

    pub fn style(cs_: Option, active: bool) Draw.Style {
        const default = Draw.Style{
            .attr = if (active) .reverse else .reset,
        };
        if (cs_.kind == null) return default;
        switch (cs_.kind.?) {
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

    pub fn lexeme(cs_: Option, active: bool) Draw.Lexeme {
        return .styled(cs_.str, cs_.style(active));
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

fn sortAscOption(ctx: void, a: Option, b: Option) bool {
    return sortAscStr(ctx, a.str, b.str);
}

pub const CompSet = struct {
    alloc: Allocator,
    original: ?Option,
    /// Eventually groups should be dynamically allocated if it gets bigger
    groups: [Flavor.len]ArrayList(Option) = @splat(.{}),
    group: *ArrayList(Option),
    group_index: usize = 0,
    index: usize = 0,
    search: ArrayList(u8),
    // actually using most of orig_token is much danger, such UB
    // the pointers contained within are likely already invalid!
    //orig_token: ?*const Token = null,
    kind: Token.Kind = .nos,
    err: bool = false,
    draw_cache: [Flavor.len]?[][]Draw.Lexeme = .{null} ** 3,

    /// Intentionally excludes original from the count
    pub fn count(cs_: *const CompSet) usize {
        var c: usize = 0;
        for (cs_.groups) |grp| {
            c += grp.items.len;
        }
        return c;
    }

    // TODO cache
    pub fn countFiltered(cs_: *const CompSet) usize {
        var c: usize = 0;
        for (cs_.groups) |grp| {
            for (grp.items) |item| {
                if (searchMatch(item.str, cs_.search.items)) |_| {
                    c += 1;
                }
            }
        }
        return c;
    }

    /// Returns the "only" completion if there's a single option known completion,
    /// ignoring the original. If there's multiple or only the original, null.
    pub fn known(cs_: *CompSet) ?*const Option {
        if (cs_.count() == 1) {
            cs_.reset();
            _ = cs_.next();
            return cs_.next();
        }

        if (cs_.search.items.len > 0 and cs_.countFiltered() == 1) {
            cs_.reset();
            return cs_.next();
        }

        return null;
    }

    pub fn reset(cs_: *CompSet) void {
        cs_.index = 0;
        cs_.groupSet(.any);
    }

    pub fn sort(cs_: *CompSet) void {
        for (cs_.groups) |group| {
            std.sort.heap(Option, group.items, {}, sortAscOption);
        }
    }

    pub fn first(cs_: *CompSet) *const Option {
        cs_.reset();
        return cs_.next();
    }

    // behavior is undefined when count <= 0
    pub fn next(cs_: *CompSet) *const Option {
        std.debug.assert(cs_.count() > 0);

        cs_.skip();
        if (cs_.search.items.len > 0 and cs_.countFiltered() > 0) {
            while (!cs_.curSearchMatch()) {
                cs_.skip();
            }
        }
        return &cs_.group.items[cs_.index];
    }

    pub fn current(cs_: *const CompSet) *const Option {
        if (cs_.group.items.len == 0) return &cs_.original.?;
        return &cs_.group.items[cs_.index];
    }

    pub fn skip(cs_: *CompSet) void {
        std.debug.assert(cs_.count() > 0);
        cs_.index += 1;
        while (cs_.index >= cs_.group.items.len) {
            cs_.index = 0;
            cs_.groupSet(null);
        }
    }

    fn curSearchMatch(cs_: *CompSet) bool {
        const curr = &cs_.group.items[cs_.index];
        return searchMatch(curr.str, cs_.search.items) != null;
    }

    pub fn revr(cs_: *CompSet) void {
        if (cs_.countFiltered() < 3) return;
        while (true) {
            if (cs_.index == 0) {
                while (true) {
                    if (cs_.group_index == 0) {
                        cs_.group_index = cs_.groups.len - 1;
                    } else {
                        cs_.group_index -= 1;
                    }
                    cs_.group = &cs_.groups[cs_.group_index];
                    if (cs_.group.items.len == 0) continue;

                    cs_.index = cs_.group.items.len - 1;
                    if (cs_.curSearchMatch()) return;
                    break;
                }
            }
            cs_.index -|= 1;
            if (cs_.curSearchMatch()) break;
        }
    }

    pub fn groupSet(cs_: *CompSet, grp: ?Flavor) void {
        if (grp) |g| {
            cs_.group_index = @intFromEnum(g);
        } else {
            cs_.group_index = (cs_.group_index + 1) % cs_.groups.len;
        }
        cs_.group = &cs_.groups[cs_.group_index];
    }

    pub fn push(cs: *CompSet, o: Option) !void {
        cs.groupSet(o.kind.?);
        try cs.group.append(cs.alloc, o);
    }

    pub fn drawGroup(cs_: *CompSet, f: Flavor, wh: Cord) ![][]Draw.Lexeme {
        const cache: *?[][]Draw.Lexeme = &cs_.draw_cache[@intFromEnum(f)];
        const group = &cs_.groups[@intFromEnum(f)];

        if (group.items.len == 0) return error.Empty;

        if (cache.*) |dcache| {
            const mod: usize = if (dcache[0].len > 0) dcache[0].len else 1;
            const this_row = (cs_.index) / mod;
            const this_col = (cs_.index) % mod;

            for (dcache, 0..) |row, r| {
                for (row) |*column| {
                    if (searchMatch(column.bytes, cs_.search.items) == null) {
                        column.style.?.attr = .dim;
                    } else {
                        styleInactive(column);
                    }
                }
                if (r == this_row and row.len > 0) {
                    styleActive(&row[this_col]);
                }
            }
            return dcache;
        }

        cache.* = try cs_.buildDrawGroup(f, wh);
        return cache.*.?;
    }

    fn buildDrawGroup(cs: CompSet, f: Flavor, wh: Cord) ![][]Draw.Lexeme {
        const group = &cs.groups[@intFromEnum(f)];

        const list = try cs.alloc.alloc(Draw.Lexeme, group.items.len);
        for (group.items, list) |itm, *dst| dst.* = itm.lexeme(false);
        return try Draw.Layout.tableLexeme(cs.alloc, list, wh);
    }

    pub fn drawAll(cs_: *CompSet, wh: Cord) !void {
        if (cs_.count() == 0) {
            return;
        }

        for (0..Flavor.len) |flavor| {
            // TODO Draw name
            _ = cs_.drawGroup(@enumFromInt(flavor), wh) catch |err| switch (err) {
                error.Empty => continue,
                else => return err,
            };
        }
    }

    pub fn searchChar(cs: *CompSet, char: u8) !void {
        try cs.search.append(cs.alloc, char);
        // TODO when searching, set to the lowest sum of search offsets

        cs.searchMove();
    }

    fn searchMove(cs_: *CompSet) void {
        var mcount: usize = 0;
        var best_cost: usize = ~@as(usize, 0);
        for (cs_.groups, 0..) |grp, gi| {
            for (grp.items, 0..) |each, ei| {
                if (searchMatch(each.str, cs_.search.items)) |cost| {
                    mcount += 1;
                    if (cost < best_cost) {
                        cs_.group_index = gi;
                        cs_.index = ei;
                        cs_.index -|= 1;
                        best_cost = cost;
                    }
                }
            }
        }
        cs_.group = &cs_.groups[cs_.group_index];
    }

    pub fn searchStr(cs_: *CompSet, str: []const u8) !void {
        for (str) |c| try cs_.searchChar(c);
    }

    pub fn searchPop(cs_: *CompSet) !void {
        if (cs_.search.items.len == 0) {
            return error.SearchEmpty;
        }
        _ = cs_.search.pop();
        cs_.searchMove();
    }

    pub fn raze(cs: *CompSet) void {
        for (&cs.groups) |*group| {
            for (group.items) |opt| {
                cs.alloc.free(opt.str);
            }
            group.clearAndFree(cs.alloc);
        }
        if (cs.original) |o| {
            cs.alloc.free(o.str);
            cs.original = null;
        }
        cs.search.clearAndFree(cs.alloc);
    }
};

fn completeDir(cs: *CompSet, cwdi: Io.Dir, io: Io) !void {
    var itr = cwdi.iterate();
    cs.original = Option{ .str = try cs.alloc.dupe(u8, ""), .kind = null };
    while (try itr.next(io)) |each| {
        try cs.push(Option{
            .str = try cs.alloc.dupe(u8, each.name),
            .kind = Kind{ .file_system = .fromFsKind(each.kind) },
        });
    }
}

fn completeDirBase(cs: *CompSet, base: []const u8, cwdi: Io.Dir, io: Io) !void {
    var itr = cwdi.iterate();
    cs.original = Option{ .str = try cs.alloc.dupe(u8, base), .kind = null };
    while (try itr.next(io)) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        try cs.push(Option{
            .str = try cs.alloc.dupe(u8, each.name),
            .kind = .{ .file_system = .fromFsKind(each.kind) },
        });
    }
}

fn completePath(cs: *CompSet, target: []const u8, io: Io) !void {
    if (target.len < 1) return;

    var whole = std.mem.splitBackwardsAny(u8, target, "/");
    const base = whole.first();
    const path = whole.rest();

    var dir: Io.Dir = undefined;
    if (target[0] == '/') {
        if (path.len == 0) {
            dir = Io.Dir.openDirAbsolute(io, "/", .{ .iterate = true }) catch return;
        } else {
            dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
        }
    } else {
        dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    }
    defer dir.close(io);

    cs.original = Option{ .str = try cs.alloc.dupe(u8, base), .kind = null };
    var itr = dir.iterate();
    while (try itr.next(io)) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        if (each.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;

        try cs.push(Option{
            .str = try cs.alloc.dupe(u8, each.name),
            .kind = Kind{
                .file_system = FSKind.fromFsKind(each.kind),
            },
        });
    }
}

fn completeFromPath(cs: *CompSet, target: []const u8, paths: ArrayList(Fs.Named), io: Io) !void {
    if (std.mem.indexOf(u8, target, "/")) |_| {
        return completePath(cs, target, io);
    }

    cs.original = .{ .str = try cs.alloc.dupe(u8, target), .kind = null };

    for (paths.items) |path| {
        var dir = std.Io.Dir.openDirAbsolute(io, path.dir.name, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var itr = dir.iterate();
        while (try itr.next(io)) |each| {
            if (!std.mem.startsWith(u8, each.name, target)) continue;
            if (each.name[0] == '.' and (target.len == 0 or target[0] != '.')) continue;
            if (each.kind != .file) continue; // TODO probably a bug
            const file = Fs.openFileAt(dir, each.name, io, .open) orelse continue;
            defer file.close(io);
            if (file.stat(io)) |_| {
                // TODO check executable bit
            } else |err| {
                log.err("{} unable to get metadata for file at path {s} name {s}\n", .{
                    err, path.dir.name, target,
                });
                return;
            }

            try cs.push(Option{
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
            pair.t = t;
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
pub fn complete(cs: *CompSet, hsh: *Hsh, tks: *Tokenizer, io: Io) !void {
    cs.raze();

    var iter = tks.iterator();
    const ts = iter.toSlice(cs.alloc) catch unreachable;
    defer cs.alloc.free(ts);

    cs.kind = if (ts.len > 0) ts[0].kind else .nos;
    cs.index = 0;

    // TODO need the real bug here
    var pair = findToken(tks);
    const hint: Kind = if (ts.len <= 1) .path_exe else .any;

    switch (hint) {
        .path_exe => {
            try completeFromPath(cs, pair.t.str, hsh.fs.paths, io);
        },
        else => {
            switch (pair.t.kind) {
                .ws => {
                    var dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
                    defer dir.close(io);
                    try completeDir(cs, dir, io);
                },
                .word, .path => {
                    var t = try Parser.single(pair.t);
                    if (std.mem.indexOfScalar(u8, t.resolved.str, '/')) |_| {
                        try completePath(cs, t.resolved.str, io);
                    } else {
                        var dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
                        defer dir.close(io);
                        try completeDirBase(cs, t.resolved.str, dir, io);
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
    var compset: CompSet = .{
        .alloc = a,
        .original = null,
        .group = undefined,
        .groups = @splat(.{}),
        .search = .{},
    };
    compset.group = &compset.groups[0];
    return compset;
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const indexOfScalar = std.mem.indexOfScalar;
const toUpper = std.ascii.toUpper;
const log = @import("log.zig");

const Hsh = @import("hsh.zig");
const Fs = @import("fs.zig");
const Tokenizer = @import("tokenizer.zig");
const Token = @import("token.zig");
const Parser = @import("parse.zig").Parser;
const Draw = @import("draw.zig");
const Cord = Draw.Cord;
const S = @import("strings.zig");
const ERRSTR_TOOBIG = S.COMPLETE_TOOBIG;
const ERRSTR_NOOPTS = S.COMPLETE_NOOPTS;
