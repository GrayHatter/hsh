const Options = ArrayList(Option);

pub fn suggest(cs: *Completion, tokens: []Token, t_idx: ?usize, fs: Fs, a: Allocator, io: Io) error{OutOfMemory}!void {
    cs.cursor_index = 0;

    if (t_idx) |idx| {
        log.err("Completion.filesystem idx '{}'\n", .{idx});
        const token: Token = tokens[idx];
        const str = trim(u8, token.str, std.ascii.whitespace[0..]);
        assert(idx != 0 or str.len > 0);
        log.err("Completion.filesystem Token '{s}'\n", .{token.str});
        if (findScalar(u8, str, '/')) |_| {
            try genOptionsResolveDir(cs, str, fs, a, io);
        } else if (idx == 0) {
            try genOptionsFromPATH(cs, str, fs, a, io);
        } else {
            try genOptionsDir(cs, &.{}, str, fs.cwd.dir, a, io);
        }
    } else {
        log.debug("Completion.filesystem PATH\n", .{});
        // TODO from history
        //try genOptionsFromPATH(cs, "", fs, a, io);
    }

    log.err("Completion.filesystem found '{}'\n", .{cs.count()});
    return;
}

fn argExists(opt: Option, tokens: []Token) bool {
    for (tokens) |token| {
        switch (opt) {
            .file => |file| {
                if (file.prefix.len > 0) {
                    if (findScalarLast(u8, token.str, '/')) |idx| {
                        const path = token.str[0..idx];
                        const str = token.str[idx + 1 ..];
                        if (eql(u8, path, file.prefix) and eql(u8, str, file.str)) return true;
                    } else continue; //if (eql(u8, token.str, opt.prefix)) return true;
                } else if (eql(u8, token.str, file.str)) return true;
            },
            else => continue,
        }
    }
    return false;
}

pub fn filter(cs: *Completion, tokens: []Token, t_idx: ?usize) void {
    _ = t_idx;
    var buf: [50]usize = undefined;
    var list: ArrayList(usize) = .initBuffer(&buf);
    for (cs.options.items, 0..) |opt, i| {
        if (argExists(opt, tokens)) {
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
        try cs.options.append(a, .{ .file = .{
            .prefix = prefix,
            .str = try a.dupe(u8, each.name),
            .kind = .fromFs(each.kind),
        } });
    } else |err| log.err("Completion directory read error {}\n", .{err});
}

fn genOptionsResolveDir(cs: *Completion, target: []const u8, fs: Fs, a: Allocator, io: Io) !void {
    log.debug("genOptionResolvedDir\n", .{});
    if (target.len < 1) return;

    if (findScalarLast(u8, target, '/')) |idx| {
        const path = target[0..idx];
        const str = target[idx + 1 ..];
        log.err("genOptionResolvedDir path '{s}' str '{s}' \n", .{ path, str });

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

            try cs.options.append(a, .{ .executable = .{ .str = try a.dupe(u8, each.name) } });
        } else |err| log.err("Completion PATH read error {}\n", .{err});
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Completion = @import("../Completion.zig");
const Option = Completion.Option;
const Fs = @import("../fs.zig");
const Token = @import("../token.zig");
const log = @import("../log.zig");
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const findScalarLast = std.mem.findScalarLast;
const trim = std.mem.trim;
const assert = std.debug.assert;
const eql = std.mem.eql;
