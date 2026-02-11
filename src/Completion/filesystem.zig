const Options = ArrayList(Option);

pub fn suggest(cs: *Completion, cur_token: ?*const Token, all_tokens: []Token, fs: Fs, a: Allocator, io: Io) error{OutOfMemory}!void {
    cs.cursor_index = 0;

    if (cur_token) |token| {
        const str = trim(u8, token.str, std.ascii.whitespace[0..]);
        assert(all_tokens.len > 0 or str.len > 0);
        log.debug("Completion.filesystem Token '{s}'\n", .{token.str});
        if (findScalar(u8, str, '/')) |_| {
            try genOptionsResolveDir(cs, str, fs, a, io);
        } else if (token == &all_tokens[0]) {
            try genOptionsFromPATH(cs, str, fs, a, io);
        } else {
            log.debug("Completion.filesystem Token '{s}'\n", .{token.str});
            try genOptionsDir(cs, &.{}, str, fs.cwd.dir, a, io);
        }
    } else {
        log.debug("Completion.filesystem PATH\n", .{});
        // TODO from history
        //try genOptionsFromPATH(cs, "", fs, a, io);
    }

    log.debug("Completion.filesystem found '{}'\n", .{cs.count()});
    return;
}

fn argExists(opt: Option, current: ?*const Token, tokens: []const Token) bool {
    for (tokens) |*token| {
        if (current) |cur| if (cur == token) continue;
        switch (opt.kind) {
            .file => {
                if (opt.prefix.len > 0) {
                    if (findScalarLast(u8, token.str, '/')) |idx| {
                        const path = token.str[0..idx];
                        const str = token.str[idx + 1 ..];
                        if (eql(u8, path, opt.prefix) and eql(u8, str, opt.str)) return true;
                    } else continue; //if (eql(u8, token.str, opt.prefix)) return true;
                } else if (eql(u8, token.str, opt.str)) return true;
            },
            else => continue,
        }
    }
    return false;
}

pub fn filter(cs: *Completion, current: ?*const Token, tokens: []Token) void {
    var buf: [50]usize = undefined;
    var list: ArrayList(usize) = .initBuffer(&buf);
    for (cs.options.items, 0..) |opt, i| {
        if (argExists(opt, current, tokens)) {
            list.appendBounded(i) catch break;
        }
    }
    cs.options.orderedRemoveMany(list.items);

    return;
}

fn genOptionsDir(cs: *Completion, prefix: []const u8, str: []const u8, search_dir: Io.Dir, a: Allocator, io: Io) !void {
    log.debug("genOptionDir\n", .{});
    var itr = search_dir.iterate();
    const skip_dot = str.len == 0 or str[0] != '.';
    while (itr.next(io)) |eachZ| {
        const each = eachZ orelse break;
        log.debug("genOptionDir {s}\n", .{each.name});
        if (each.name[0] == '.' and skip_dot) continue;
        if (!startsWith(u8, each.name, str)) continue;
        log.debug("genOptionDir {s} saved \n", .{each.name});
        try cs.options.append(a, .{
            .str = try a.dupe(u8, each.name),
            .prefix = prefix,
            .kind = .{ .file = .fromFs(each.kind) },
        });
    } else |err| log.err("Completion directory read error {}\n", .{err});
}

fn genOptionsResolveDir(cs: *Completion, target: []const u8, fs: Fs, a: Allocator, io: Io) !void {
    log.debug("genOptionResolvedDir\n", .{});
    if (target.len < 1) return;

    if (findScalarLast(u8, target, '/')) |idx| {
        const path = target[0..idx];
        const str = target[idx + 1 ..];
        log.debug("genOptionResolvedDir path '{s}' str '{s}' \n", .{ path, str });

        var search_dir: Io.Dir = if (path.len == 0 or path[0] == '/')
            Fs.openDirAbsolute(io, "/", .{ .iterate = true }) catch return
        else
            fs.cwd.dir.openDir(io, path, .{ .iterate = true }) catch return;
        defer search_dir.close(io);

        try genOptionsDir(cs, path, str, search_dir, a, io);
    } else {
        try genOptionsDir(cs, &.{}, target, fs.cwd.dir, a, io);
    }
}

fn genOptionsFromPATH(cs: *Completion, target: []const u8, fs: Fs, a: Allocator, io: Io) !void {
    log.debug("genOptionPATH\n", .{});
    if (findScalar(u8, target, '/')) |_| {
        return genOptionsResolveDir(cs, target, fs, a, io);
    }

    for (fs.paths.items) |path| {
        if (path != .dir) continue;
        //try cs.genOptionsDir(target, path.dir, a, io);

        var itr = path.dir.dir.iterate();
        const skip_dot = target.len == 0 or target[0] != '.';
        while (itr.next(io)) |eachZ| {
            const each = eachZ orelse break;
            if (each.kind != .file) continue; // TODO probably a bug
            if (each.name[0] == '.' and skip_dot) continue;
            if (!startsWith(u8, each.name, target)) continue;

            const file = Fs.openFrom(path.dir.dir, each.name, io, .open) orelse continue;
            defer file.close(io);
            if (file.stat(io)) |_| {
                // TODO check executable bit
            } else |err| {
                log.debug("{} unable to get metadata for file at path {s} name {s}\n", .{
                    err, path.dir.name, target,
                });
                return;
            }

            try cs.options.append(a, .{
                .str = try a.dupe(u8, each.name),
                .prefix = &.{},
                .kind = .executable,
            });
        } else |err| log.err("Completion PATH read error {}\n", .{err});
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Completion = @import("../Completion.zig");
const Option = Completion.Option;
const Fs = @import("../Fs.zig");
const Token = @import("../token.zig");
const log = @import("../log.zig");
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const findScalarLast = std.mem.findScalarLast;
const trim = std.mem.trim;
const assert = std.debug.assert;
const eql = std.mem.eql;
