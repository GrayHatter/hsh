options: ArrayList(Option) = .{},
cursor_index: usize = 0,
search_str: [2048]u8 = undefined,
search_str_len: usize = 0,
err: bool = false,
cache: Cache = .empty,

const Completion = @This();

pub const Flavor = enum(u8) {
    original,
    any,
    args,
    executable,
    file,
    git,

    pub const len = @typeInfo(Flavor).@"enum".fields.len;
};

const Cache = struct {
    original: LexemeGrid,
    any: LexemeGrid,
    args: LexemeGrid,
    executable: LexemeGrid,
    file: LexemeGrid,
    git: LexemeGrid,

    const LexemeRow = []Lexeme;
    const LexemeGrid = []LexemeRow;

    pub const empty: Cache = .{
        .original = &.{},
        .any = &.{},
        .args = &.{},
        .executable = &.{},
        .file = &.{},
        .git = &.{},
    };

    pub fn raze(c: *Cache, a: Allocator) void {
        a.free(c.original);
        a.free(c.any);
        a.free(c.args);
        a.free(c.executable);
        a.free(c.file);
        a.free(c.git);
        c.* = .empty;

        comptime assert(@typeInfo(Cache).@"struct".fields.len == 6);
    }

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
        if (target.len == 0) target.* = try genGroupLexeme(group, wh, a);

        const mod: usize = @max(target.*[0].len, 1);
        const this_row = (cursor) / mod;
        const this_col = (cursor) % mod;
        log.debug("group {s} cursor {} % {} row {} col {}\n", .{
            @tagName(name), cursor, mod, this_row, this_col,
        });

        for (target.*, 0..) |row, r| {
            for (row) |*column| {
                if (searchMatch(column.bytes, search_str) == null) {
                    column.style.?.attr = .dim;
                } else {
                    styleInactive(column);
                }
            }
            if (r == this_row and this_col < row.len) {
                styleActive(&row[this_col]);
            }
        }
    }

    fn genGroupLexeme(group: []Option, wh: Cord, a: Allocator) error{ OutOfMemory, ItemCount }![][]Draw.Lexeme {
        const list = try a.alloc(Draw.Lexeme, group.len);
        for (group, list) |itm, *dst|
            dst.* = itm.lexeme(false);
        return Draw.Layout.tableLexeme(a, list, wh) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ItemCount,
            error.ViewportFit,
            error.LayoutUnable,
            => return error.ItemCount,
        };
    }

    pub fn regenAll(
        c: *Cache,
        options: []Option,
        cursor: usize,
        str: []const u8,
        wh: Cord,
        a: Allocator,
    ) error{ OutOfMemory, ItemCount }!void {
        var start: usize = 0;
        inline for (@typeInfo(Cache).@"struct".fields, 0..) |field, flavor_i| {
            const flavor: Flavor = @enumFromInt(flavor_i);
            comptime assert(eql(u8, @tagName(flavor), field.name));
            var end: usize = start;
            while (start < options.len and end < options.len) : (end += 1) {
                if (options[end].kind != flavor) break;
            }
            if (end > start) {
                try c.regenGroup(flavor, options[start..end], cursor, str, wh, a);
            }
            start = end;
        }
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

pub const Option = struct {
    str: []const u8,
    prefix: []const u8,
    kind: Extra,

    pub const Extra = union(Flavor) {
        original: void,
        any: void,
        args: void,
        executable: u16,
        file: File,
        git: File,
    };

    pub const File = enum {
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

        pub fn color(k: File) ?Draw.Color {
            return switch (k) {
                .dir => .blue,
                .unknown => .red,
                else => null,
            };
        }

        pub fn fromFs(k: Io.File.Kind) File {
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

    pub fn style(opt: Option, active: bool) Draw.Style {
        var sty: Draw.Style = switch (opt.kind) {
            .file, .git => |file| switch (file) {
                .dir => .{ .attr = .bold, .fg = file.color() },
                .file => .fromName(opt.str),
                else => .{ .fg = file.color() },
            },
            else => .none,
        };
        if (active) sty.reverse();
        return sty;
    }

    pub fn lexeme(opt: Option, active: bool) Draw.Lexeme {
        return .styled(opt.str, opt.style(active));
    }
};

pub fn init() Completion {
    return .{};
}

pub fn suggest(cs: *Completion, tokens: []Token, t_idx: ?usize, fs: Fs, a: Allocator, io: Io) error{OutOfMemory}!void {
    cs.cursor_index = 0;

    const command: ?Command = Command.init(tokens) catch null;

    const current_token: ?*const Token = if (t_idx) |idx| &tokens[idx] else null;

    if (command) |cmd| switch (cmd) {
        .git => try git.suggest(cs, current_token, tokens, fs, a, io),
        else => try filesystem.suggest(cs, current_token, tokens, fs, a, io),
    } else try filesystem.suggest(cs, current_token, tokens, fs, a, io);

    // TODO orderedRemoveMany allows an optimization to iterate only a single range if presorted
    if (command) |cmd| switch (cmd) {
        .git => git.filter(cs, current_token, tokens),
        else => filesystem.filter(cs, current_token, tokens),
    } else filesystem.filter(cs, current_token, tokens);

    cs.sort();
    log.info("Completing found '{}'\n", .{cs.count()});
    return;
}

pub fn suggestHistory(cs: *Completion, cmds: *const History.CmdMap, a: Allocator) error{OutOfMemory}!void {
    var itr = cmds.iterator();
    while (itr.next()) |entry| {
        try cs.options.append(a, .{
            // TODO don't alloc
            .str = try a.dupe(u8, entry.key_ptr.*),
            .prefix = &.{},
            .kind = .{ .executable = entry.value_ptr.* },
        });
    }
    cs.sort();
}

pub fn raze(comp: *Completion, a: Allocator) void {
    for (comp.options.items) |opt| a.free(opt.str);
    comp.options.clearAndFree(a);
    comp.cache.raze(a);
    comp.search_str_len = 0;
}

pub fn recolorAll(comp: *Completion, wh: Cord, a: Allocator) !void {
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

fn optAsFile(o: *const Option) Option.File {
    switch (o.kind) {
        .git => return o.kind.git,
        .file => return o.kind.file,
        .original, .any, .args, .executable => unreachable,
    }
}

fn sortAscOption(ctx: void, l: Option, r: Option) bool {
    if (@intFromEnum(l.kind) < @intFromEnum(r.kind)) return true;
    if (@intFromEnum(l.kind) > @intFromEnum(r.kind)) return false;

    switch (l.kind) {
        inline .git, .file => |*p| switch (@TypeOf(p.*)) {
            Option.File => {
                const l_file: *const Option.File = p;
                const r_file = optAsFile(&r);
                if (l_file.* == .dir and r_file != .dir) return true;
                if (r_file == .dir) return false;
            },
            else => {},
        },

        .original => {},
        .any => {},
        .args => {},
        .executable => return if (l.kind.executable == r.kind.executable)
            sortAscStr(ctx, l.str, r.str)
        else
            l.kind.executable > r.kind.executable,
    }
    return sortAscStr(ctx, l.str, r.str);
}

pub fn count(comp: *const Completion) usize {
    return comp.options.items.len;
}

pub fn countFiltered(comp: *const Completion) usize {
    var c: usize = 0;
    const str = comp.search();
    for (comp.options.items) |item| {
        if (searchMatch(item.str, str)) |_| {
            c += 1;
        }
    }
    return c;
}

/// Returns the "only" completion if there's a single option known completion,
/// ignoring the original. If there's multiple or only the original, null.
pub fn known(cs: *Completion) ?Option {
    if (cs.count() == 1) {
        cs.cursor_index = 0;
        _ = cs.next();
        return cs.next();
    }

    if (cs.search().len > 0 and cs.countFiltered() == 1) {
        cs.cursor_index = 0;
        return cs.next();
    }

    return null;
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
    return searchMatch(curr.str, comp.search()) != null;
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
        if (searchMatch(each.str, str)) |cost| {
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

pub const Command = enum {
    ls,
    git,

    pub fn init(tokens: []Token) !Command {
        if (tokens.len == 0) return error.NotFound;
        inline for (@typeInfo(Command).@"enum".fields) |field| {
            if (eqlIgnoreCase(tokens[0].str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.NotFound;
    }
};

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
const filesystem = @import("Completion/filesystem.zig");
const git = @import("Completion/git.zig");
const log = @import("log.zig");
const Fs = @import("Fs.zig");
const Token = @import("token.zig");
const Draw = @import("draw.zig");
const History = @import("History.zig");
const Lexeme = Draw.Lexeme;
const Cord = Draw.Cord;
const assert = std.debug.assert;
const findScalar = std.mem.findScalar;
const toUpper = std.ascii.toUpper;
const trim = std.mem.trim;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const eql = std.mem.eql;
const activeTag = std.meta.activeTag;
