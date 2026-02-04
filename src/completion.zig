options: ArrayList(Option) = .{},
cursor_index: usize = 0,
search_str: [2048]u8 = undefined,
search_str_len: usize = 0,
kind: Token.Kind = .nos,
err: bool = false,
cache: Cache = .empty,

const Completion = @This();

const Cache = struct {
    original: LexemeGrid,
    any: LexemeGrid,
    executable: LexemeGrid,
    file: LexemeGrid,

    const LexemeRow = []Lexeme;
    const LexemeGrid = []LexemeRow;

    pub const empty: Cache = .{
        .original = &.{},
        .any = &.{},
        .executable = &.{},
        .file = &.{},
    };

    pub fn regenGroup(
        c: *Cache,
        comptime name: Flavor,
        group: []Option,
        cursor: usize,
        search_str: []const u8,
        wh: Cord,
        a: Allocator,
    ) !void {
        if (group.len == 0) return;

        const target: *LexemeGrid = &@field(c, @tagName(name));
        if (target.len == 0) {
            target.* = try genGroupLexeme(group, wh, a);
        }

        const mod: usize = @max(target.*[0].len, 1);
        const this_row = (cursor) / mod;
        const this_col = (cursor) % mod;
        log.debug("group {s} cursor {} % {} row {} col {}\n", .{ @tagName(name), cursor, mod, this_row, this_col });

        for (target.*, 0..) |row, r| {
            for (row) |*column| {
                if (searchMatch(column.bytes, search_str) == null) {
                    column.style.?.attr = .dim;
                } else {
                    styleInactive(column);
                }
            }
            if (r == this_row and row.len > 0) {
                styleActive(&row[this_col]);
            }
        }
    }

    fn genGroupLexeme(group: []Option, wh: Cord, a: Allocator) ![][]Draw.Lexeme {
        const list = try a.alloc(Draw.Lexeme, group.len);
        for (group, list) |itm, *dst|
            dst.* = itm.lexeme(false);
        return try Draw.Layout.tableLexeme(a, list, wh);
    }

    pub fn regenAll(c: *Cache, options: []Option, cursor: usize, str: []const u8, wh: Cord, a: Allocator) !void {
        var ori_len: usize = 0;
        var any_len: usize = 0;
        var exe_len: usize = 0;
        for (options) |opt| {
            switch (opt) {
                .original => ori_len += 1,
                .any => any_len += 1,
                .executable => exe_len += 1,
                .file => {
                    break;
                },
            }
        }
        try c.regenGroup(.original, options[0..ori_len], cursor, str, wh, a);
        try c.regenGroup(.any, options[ori_len..][0..any_len], cursor, str, wh, a);
        try c.regenGroup(.executable, options[ori_len + any_len ..][0..exe_len], cursor, str, wh, a);
        try c.regenGroup(.file, options[ori_len + any_len + exe_len ..], cursor, str, wh, a);

        //const target: *[]LexemeRow = @field(c, f.name);
    }

    fn styleActive(lex: *Draw.Lexeme) void {
        if (lex.style.?.attr) |*attr| {
            attr.* = switch (attr.*) {
                .reset => .reverse,
                .bold => .reverse_bold,
                .dim => .reverse,
                else => .reset,
            };
        } else lex.style.?.attr = .reverse;
    }

    fn styleInactive(lex: *Draw.Lexeme) void {
        if (lex.style.?.attr) |*attr| {
            attr.* = switch (attr.*) {
                .reverse => .reset,
                .reverse_bold => .bold,
                .reverse_dim => .dim,
                .dim => if (lex.style.?.fg != null) .bold else .reset, // TODO fixme
                else => attr.*,
            };
        } else lex.style.?.attr = .reset;
    }
};

pub const Flavor = enum(u8) {
    original,
    any,
    executable,
    file,

    pub const len = @typeInfo(Flavor).@"enum".fields.len;
};

pub const Option = union(Flavor) {
    original: Base,
    any: Base,
    executable: Base,
    file: File,

    pub fn str(opt: Option) []const u8 {
        return switch (opt) {
            inline else => |el| el.str,
        };
    }

    pub const Base = struct {
        str: []const u8,
    };

    pub const File = struct {
        str: []const u8,
        kind: File.Kind,

        pub const Kind = enum {
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

            pub fn color(k: File.Kind) ?Draw.Color {
                return switch (k) {
                    .dir => .blue,
                    .unknown => .red,
                    else => null,
                };
            }

            pub fn fromFs(k: Io.File.Kind) File.Kind {
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
    };

    pub fn style(opt: Option, active: bool) Draw.Style {
        var sty: Draw.Style = switch (opt) {
            .file => |file| switch (file.kind) {
                .dir => .{ .attr = .bold, .fg = file.kind.color() },
                .file => .fromName(opt.str()),
                else => .{ .fg = file.kind.color() },
            },
            else => .none,
        };
        if (active) sty.reverse();
        return sty;
    }

    pub fn lexeme(opt: Option, active: bool) Draw.Lexeme {
        return .styled(opt.str(), opt.style(active));
    }
};

pub fn init() Completion {
    return .{};
}

/// Caller owns nothing, memory is only guaranteed until `complete` is
/// called again.
pub fn start(cs: *Completion, tks: *Tokenizer, fs: Fs, a: Allocator, io: Io) !void {
    cs.raze(a);

    var iter = tks.iterator();
    const ts = iter.toSlice(a) catch unreachable;
    defer a.free(ts);

    cs.kind = if (ts.len > 0) ts[0].kind else .nos;
    cs.cursor_index = 0;

    // TODO need the real bug here
    var pair = findToken(tks);
    const hint: Flavor = if (ts.len <= 1) .executable else .any;

    switch (hint) {
        .executable => try genPathBinary(cs, pair.t.str, fs.paths, a, io),
        else => {
            switch (pair.t.kind) {
                .ws => {
                    var dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
                    defer dir.close(io);
                    try completeDir(cs, dir, a, io);
                },
                .word, .path => {
                    switch ((try Resolver.word(pair.t)).parsed) {
                        .word => |w| try completeDirBase(cs, w.str, fs.cwd.dir, a, io),
                        .path => |p| try genCompletionDir(cs, p.str, a, io),
                        else => unreachable,
                    }
                },
                .io => {
                    // TODO pipeline integration
                },
                else => {},
            }
        },
    }

    if (cs.originalStr()) |str| {
        try tks.maybeReplace(str, a);
        try cs.searchStr(str);
        log.debug("Completion original is {s}\n\n", .{str});
    } else log.debug("Completion original is null\n\n", .{});

    cs.sort();
    cs.reset();
    return;
}

pub fn raze(comp: *Completion, a: Allocator) void {
    for (comp.options.items) |opt| {
        switch (opt) {
            inline else => |el| a.free(el.str),
        }
    }
    comp.options.clearAndFree(a);
    comp.search_str_len = 0;
}

pub fn originalStr(comp: Completion) ?[]const u8 {
    if (comp.options.items.len > 0) switch (comp.options.items[0]) {
        .original => |orig| return orig.str,
        else => return &.{},
    };
    return null;
}

pub fn regenAll(comp: *Completion, wh: Cord, a: Allocator) !void {
    try comp.cache.regenAll(comp.options.items, comp.cursor_index, comp.search(), wh, a);
}

fn searchMatch(items: []const u8, search_str: []const u8) ?usize {
    if (search_str.len == 0) return 0;
    if (search_str.len > items.len) return null;

    var offset: usize = 0;
    for (search_str) |s| {
        if (offset >= items.len) return null;
        if (findScalar(u8, items[offset..], s)) |i| {
            offset += i + 1;
            continue;
        }
        if (findScalar(u8, items[offset..], toUpper(s))) |i| {
            offset += i + 1;
            continue;
        }
        return null;
    }
    return offset - search_str.len;
}

fn sortAscStr(_: void, a: []const u8, b: []const u8) bool {
    const end = @min(a.len, b.len);

    for (a[0..end], b[0..end]) |l, r| {
        if (l != r) return l < r;
    }
    return false;
}

fn sortAscOption(ctx: void, a: Option, b: Option) bool {
    const l = switch (a) {
        inline else => |_, t| @intFromEnum(t),
    };
    const r = switch (b) {
        inline else => |_, t| @intFromEnum(t),
    };
    if (l < r) return true;
    return sortAscStr(ctx, a.str(), b.str());
}

/// Intentionally excludes original from the count
pub fn count(comp: *const Completion) usize {
    return comp.options.items.len;
}

// TODO cache
pub fn countFiltered(comp: *const Completion) usize {
    var c: usize = 0;
    const str = comp.search();
    for (comp.options.items) |item| {
        if (searchMatch(item.str(), str)) |_| {
            c += 1;
        }
    }
    return c;
}

/// Returns the "only" completion if there's a single option known completion,
/// ignoring the original. If there's multiple or only the original, null.
pub fn known(cs_: *Completion) ?Option {
    if (cs_.count() == 1) {
        cs_.reset();
        _ = cs_.next();
        return cs_.next();
    }

    if (cs_.search().len > 0 and cs_.countFiltered() == 1) {
        cs_.reset();
        return cs_.next();
    }

    return null;
}

pub fn reset(cs_: *Completion) void {
    cs_.cursor_index = 0;
}

pub fn sort(comp: *Completion) void {
    std.sort.heap(Option, comp.options.items, {}, sortAscOption);
}

// behavior is undefined when count <= 0
pub fn next(comp: *Completion) Option {
    assert(comp.count() > 0);

    comp.skip();
    if (comp.search_str_len > 0 and comp.countFiltered() > 0) {
        while (!comp.curSearchMatch()) {
            comp.skip();
        }
    }
    return comp.options.items[comp.cursor_index];
}

pub fn current(comp: *const Completion) *const Option {
    return &comp.options.items[comp.cursor_index];
}

pub fn skip(comp: *Completion) void {
    std.debug.assert(comp.count() > 0);
    comp.cursor_index += 1;
    while (comp.cursor_index >= comp.options.items.len) {
        comp.cursor_index = 0;
    }
}

fn curSearchMatch(comp: *Completion) bool {
    const curr = &comp.options.items[comp.cursor_index];
    return searchMatch(curr.str(), comp.search()) != null;
}

pub fn revr(comp: *Completion) void {
    if (comp.countFiltered() < 3) return;
    while (true) {
        if (comp.cursor_index == 0) {
            while (true) {
                if (comp.options.items.len == 0) continue;
                comp.cursor_index = comp.options.items.len - 1;
                if (comp.curSearchMatch()) return;
                break;
            }
        }
        comp.cursor_index -|= 1;
        if (comp.curSearchMatch()) break;
    }
}

pub fn drawAll(cs: *Completion, draw: *Draw) !void {
    inline for (@typeInfo(Flavor).@"enum".fields) |f| {
        // TODO Draw name
        const cache = @field(cs.cache, f.name);
        if (cache.len > 0) {
            for (cache) |row| {
                draw.drawAfter(row);
            }
        }
    }
}

pub fn search(cs: *const Completion) []const u8 {
    return cs.search_str[0..cs.search_str_len];
}

pub fn searchChar(cs: *Completion, char: u8) !void {
    assert(cs.search_str_len < cs.search_str.len);
    cs.search_str[cs.search_str_len] = char;
    cs.search_str_len += 1;
    // TODO when searching, set to the lowest sum of search offsets

    cs.searchMove();
}

fn searchMove(comp: *Completion) void {
    var mcount: usize = 0;
    const str = comp.search();
    var best_cost: usize = ~@as(usize, 0);
    for (comp.options.items, 0..) |each, ei| {
        if (searchMatch(each.str(), str)) |cost| {
            mcount += 1;
            if (cost < best_cost) {
                comp.cursor_index = ei;
                comp.cursor_index -|= 1;
                best_cost = cost;
            }
        }
    }
}

pub fn searchStr(cs: *Completion, str: []const u8) !void {
    for (str) |c| try cs.searchChar(c);
}

pub fn searchPop(cs: *Completion) !void {
    if (cs.search_str_len == 0) {
        return error.SearchEmpty;
    }
    cs.search_str_len -= 1;
    cs.searchMove();
}

fn completeDir(cs: *Completion, cwdi: Io.Dir, a: Allocator, io: Io) !void {
    var itr = cwdi.iterate();

    //const original = &cs.groups[@intFromEnum(Flavor.original)];
    //original.appendBounded(Option{ .original = .{ .str = &.{} } }) catch unreachable;

    while (try itr.next(io)) |each| {
        try cs.options.append(a, .{ .file = .{
            .str = try a.dupe(u8, each.name),
            .kind = .fromFs(each.kind),
        } });
    }
}

fn completeDirBase(cs: *Completion, base: []const u8, cwdi: Io.Dir, a: Allocator, io: Io) !void {
    var itr = cwdi.iterate();

    //const original = &cs.groups[@intFromEnum(Flavor.original)];
    //original.appendBounded(Option{ .original = .{ .str = try a.dupe(u8, base) } }) catch unreachable;

    while (try itr.next(io)) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        try cs.options.append(a, .{ .file = .{
            .str = try a.dupe(u8, each.name),
            .kind = .fromFs(each.kind),
        } });
    }
}

fn genCompletionDir(cs: *Completion, target: []const u8, a: Allocator, io: Io) !void {
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

    //const original = &cs.groups[@intFromEnum(Flavor.original)];
    //original.appendBounded(Option{ .original = .{ .str = try a.dupe(u8, base) } }) catch unreachable;

    var itr = dir.iterate();
    while (try itr.next(io)) |each| {
        if (!std.mem.startsWith(u8, each.name, base)) continue;
        if (each.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;

        try cs.options.append(a, .{ .file = .{
            .str = try a.dupe(u8, each.name),
            .kind = .fromFs(each.kind),
        } });
    }
}

fn genPathBinary(cs: *Completion, target: []const u8, paths: ArrayList(Fs.Named), a: Allocator, io: Io) !void {
    if (findScalar(u8, target, '/')) |_| {
        return genCompletionDir(cs, target, a, io);
    }

    //const original = &cs.groups[@intFromEnum(Flavor.original)];
    //original.appendBounded(Option{ .original = .{ .str = try a.dupe(u8, target) } }) catch unreachable;

    for (paths.items) |path| {
        if (path != .dir) continue;
        var dir = std.Io.Dir.openDirAbsolute(io, path.dir.name, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var itr = dir.iterate();
        while (try itr.next(io)) |each| {
            if (!std.mem.startsWith(u8, each.name, target)) continue;
            if (each.name[0] == '.' and (target.len == 0 or target[0] != '.')) continue;
            if (each.kind != .file) continue; // TODO probably a bug
            const file = Fs.openFrom(dir, each.name, io, .open) orelse continue;
            defer file.close(io);
            if (file.stat(io)) |_| {
                // TODO check executable bit
            } else |err| {
                log.err("{} unable to get metadata for file at path {s} name {s}\n", .{
                    err, path.dir.name, target,
                });
                return;
            }

            try cs.options.append(a, .{ .executable = .{
                .str = try a.dupe(u8, each.name),
            } });
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

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = @import("log.zig");
const Fs = @import("fs.zig");
const Tokenizer = @import("tokenizer.zig");
const Token = @import("token.zig");
const Resolver = @import("parse.zig").Resolver;
const Draw = @import("draw.zig");
const Lexeme = Draw.Lexeme;
const Cord = Draw.Cord;
const assert = std.debug.assert;
const findScalar = std.mem.findScalar;
const toUpper = std.ascii.toUpper;
