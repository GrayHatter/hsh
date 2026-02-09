alloc: Allocator,
mode: union(enum) {
    interactive: void,
    scripted: void,
    external_editor: []u8,
},
bytes: []u8,
input: Input,
tkn: Tokenizer,
options: Options,
hsh: *Hsh,
draw: *Draw,
prompt: *Prompt,
history: History,
hist_index: usize = 0,
hist_search: ?[]u8 = null,
completion: Completion,

const Line = @This();

pub const Options = struct {
    interactive: bool = true,
};

const Action = enum {
    exec,
    external,
};

pub fn init(hsh: *Hsh, a: Allocator, io: Io, options: Options) !Line {
    return .{
        .alloc = a,
        .mode = if (options.interactive) .{ .interactive = {} } else .{ .scripted = {} },
        .bytes = &.{},
        .hsh = hsh,
        .draw = &hsh.draw,
        .prompt = &hsh.prompt,
        .input = .{ .stdin = &hsh.tty.in.r.interface, .spin = spin },
        .tkn = .{},
        .completion = .init(),
        .options = options,
        .history = try .init(hsh.fs.history, a, io),
    };
}

pub fn raze(line: Line) void {
    _ = line;
}

fn spin(input: *const Input, a: Allocator, io: Io) bool {
    const line: *const Line = @fieldParentPtr("input", input);
    return line.hsh.spin(a, io);
}

fn char(l: *Line, c: u8) !void {
    if (l.hist_index > 0) {
        l.hist_index = 0;
        l.alloc.free(l.bytes);
        l.bytes = &.{};
    }
    try l.tkn.consumeChar(c);
    if (l.tkn.len != l.tkn.idx) {
        l.draw.clear();
        l.draw.cursor = @truncate(l.tkn.len - l.tkn.idx);
        try l.hsh.prompt.render(l.draw, l.peek());
    } else {
        l.draw.key(c);
    }

    // TODO FIXME
    //line.bytes = line.tkn.getSlice();
}

fn cursorMove(l: *Line, motion: Tokenizer.Cursor.Motion) void {
    l.tkn.move(motion);
}

pub fn peek(line: Line) []const u8 {
    return line.tkn.getSlice();
}

fn core(l: *Line, a: Allocator, io: Io) !Action {
    while (true) {
        const input = switch (l.mode) {
            .interactive => l.input.interactive(a, io),
            .scripted => l.input.nonInteractive(),
            .external_editor => return .external,
        } catch |err| switch (err) {
            error.Io => return err,
            error.Signaled => if (l.signal()) continue else |_| return err,
        };

        switch (input.evt) {
            .ascii => |c| try l.char(c),
            .key => |ctrl| {
                log.debug("control char = '{}'\n", .{ctrl});
                switch (ctrl) {
                    .esc => continue,
                    .up => try l.findHistory(.up),
                    .down => try l.findHistory(.down),
                    .left => l.cursorMove(.dec),
                    .right => l.cursorMove(.inc),
                    .home => l.cursorMove(.home),
                    .end => l.cursorMove(.end),
                    .backspace => l.tkn.remove(),
                    .newline => return .exec,
                    .end_of_text => return .exec,
                    .delete_word => _ = l.tkn.removeWord(),
                    .tab => l.complete(a, io) catch |e| switch (e) {
                        error.Signaled => if (l.signal()) continue else |_| return e,
                        else => return e,
                    },
                    else => |els| log.warn("unknown {}\n", .{els}),
                }
                l.draw.clear();
                l.draw.cursor = @truncate(l.tkn.len - l.tkn.idx);
                try l.prompt.render(l.draw, l.peek());
                try l.draw.render();
            },
            .mouse => |el| {
                log.err("uncaptured {}\n", .{el});
                unreachable;
            },
        }
    }
}

fn signal(l: *Line) !void {
    log.debug("signaled \n", .{});
    l.draw.key('\n');
    l.tkn.reset();
    l.draw.clear();
    l.draw.clearCtx();
    try l.prompt.render(l.draw, &.{});
}

pub fn do(line: *Line, a: Allocator, io: Io) ![]u8 {
    while (true) {
        return switch (try line.core(a, io)) {
            .external => try line.externEditorRead(io),
            .exec => {
                try line.draw.unbuffered.writeByte('\n');
                if (line.peek().len > 0) return try line.dupe();
                line.draw.clear();
                try line.prompt.render(line.draw, line.peek());
                try line.draw.render();
                continue;
            },
        };
    }
}

fn dupe(line: Line) ![]u8 {
    return try line.alloc.dupe(u8, line.tkn.getSlice());
}

pub fn externEditor(line: *Line, a: Allocator, io: Io) ![]u8 {
    line.mode = .{ .external_editor = Fs.mktemp(line.bytes, line.alloc, io) catch |err| {
        log.err("Unable to write prompt to tmp file {}\n", .{err});
        return err;
    } };
    return try allocPrint(a, "$EDITOR {s}", .{line.mode.external_editor});
}

pub fn externEditorRead(line: *Line, io: Io) ![]u8 {
    const tmp = line.mode.external_editor;
    defer line.mode = .{ .interactive = {} };
    defer line.alloc.free(tmp);
    defer unreachable;

    var file = Fs.writable(tmp, io, .create) orelse return error.io;
    defer file.close(io);
    var reader = file.reader(io, &.{});

    line.bytes = reader.interface.allocRemaining(line.alloc, .limited(4096)) catch unreachable;
    return line.bytes;
}

fn findHistory(l: *Line, dr: enum { up, down }) !void {
    var history = l.history;

    if (l.hist_index == 0) {
        if (dr == .down) return;
        l.hist_index = 1;
        if (l.bytes.len > 0) {
            l.hist_search = l.bytes;
        }
    } else if (l.hist_index == 1) {
        if (dr == .down) {
            l.hist_index = 0;
            if (l.hist_search) |hs| {
                l.bytes = hs;
                l.hist_search = null;
            } else l.bytes = &.{};
            l.tkn.reset();
            l.tkn.consumeSlice(l.bytes);
            l.cursorMove(.end);
            return;
        } else l.hist_index += 1;
    } else {
        if (dr == .up) l.hist_index += 1 else l.hist_index -= 1;
    }

    const history_l: ?[]const u8 = if (l.hist_search) |search|
        history.readLineFiltered(l.hist_index, search)
    else
        history.readLine(l.hist_index);

    assert(l.hist_index > 0);
    if (history_l) |hist_line| {
        // TODO optimize
        l.alloc.free(l.bytes);
        l.bytes = try l.alloc.dupe(u8, hist_line);
        l.tkn.reset();
        l.tkn.consumeSlice(l.bytes);
        l.tkn.move(.end);
    } else {
        if (dr == .up) l.hist_index -= 1 else l.hist_index += 1;
        l.draw.drawAfter(&[1]Lexeme{.styled("[ End of History ]", .red_bold)});
        try l.draw.render();
    }
}

const CompState = union(enum) {
    restart: void,
    start: void,
    input: void,
    key: Input.Event,
    redraw: void,
    empty: void,
    commit: void,
    finish: ?u8,
    exit: void,
};

fn complete(line: *Line, a: Allocator, io: Io) error{ Signaled, Io, OutOfMemory, WriteFailed }!void {
    const cmplt: *Completion = &line.completion;

    var iter = line.tkn.iterator();
    var tokens = iter.toSlice(a) catch unreachable;
    defer a.free(tokens);
    log.debug("completion enter\n", .{});
    sw: switch (CompState{ .start = {} }) {
        .restart => {
            cmplt.raze(a);
            a.free(tokens);
            iter = line.tkn.iterator();
            tokens = iter.toSlice(a) catch unreachable;
            continue :sw .start;
        },
        .start => {
            try cmplt.suggest(tokens, line.tkn.cursorTokenIdx(), line.hsh.fs, a, io);
            if (line.tkn.cursorToken()) |token| {
                log.debug("completion start '{s}'\n", .{token.str});
                line.tkn.maybe.copyCurrent();
                if (token.str.len > 0 and token.str[token.str.len - 1] == '/') {
                    line.tkn.maybe.commit(null);
                }
            } else |_| {}

            line.tkn.maybe.replace(cmplt.current().str) catch unreachable;
            if (line.tkn.maybe.len > 1 and cmplt.count() == 1) {
                log.debug("start commit '{s}' \n", .{line.tkn.maybe.slice()});

                continue :sw .commit;
            }
            continue :sw .redraw;
        },
        .input => if (line.input.interactive(a, io)) |key| continue :sw .{ .key = key } else |err| switch (err) {
            error.Signaled => {
                line.tkn.maybe.remove();
                return err;
            },
            else => return err,
        },
        .key => |ks| switch (ks.evt) {
            .ascii => |c| switch (c) {
                0x00...0x1f => unreachable,
                0x7f...0xff => unreachable,
                ' ' => continue :sw .{ .finish = ' ' },
                // IFF this is an existing directory,
                // completion should continue
                '/' => if (cmplt.count() > 1) {
                    continue :sw .commit;
                } else continue :sw .redraw,
                0x21...0x2e, 0x30...0x7e => if (cmplt.count() == 0) {
                    line.tkn.consumeChar(c) catch {};
                    continue :sw .exit;
                } else {
                    try cmplt.searchChar(c);
                    continue :sw .redraw;
                },
            },
            .key => |k| switch (k) {
                .tab => {
                    if (cmplt.count() == 0) continue :sw .empty;
                    if (cmplt.count() == 1) continue :sw .commit;
                    if (ks.mods._shift) {
                        cmplt.revr();
                        cmplt.revr();
                    }
                    line.tkn.maybe.replace(cmplt.next().str) catch unreachable;

                    continue :sw .redraw;
                },
                .left => {
                    cmplt.revr();
                    cmplt.revr();
                    line.tkn.maybe.replace(cmplt.next().str) catch unreachable;
                    continue :sw .redraw;
                },
                .right => {
                    line.tkn.maybe.replace(cmplt.next().str) catch unreachable;
                    continue :sw .redraw;
                },
                .up, .down => {
                    log.err("Completion arrows not yet implemented\n", .{});
                    continue :sw .redraw;
                },
                .backspace => {
                    cmplt.searchPop() catch {
                        line.tkn.maybe.remove();
                        continue :sw .restart;
                    };
                    line.tkn.maybe.replace(cmplt.search()) catch unreachable;
                    continue :sw .redraw;
                },
                .delete_word => {
                    _ = line.tkn.removeWord();
                    continue :sw .redraw;
                },
                .home, .end => |h_e| {
                    line.tkn.idx = if (h_e == .home) 0 else line.tkn.len;
                    continue :sw .{ .finish = null };
                },
                .newline => continue :sw .{ .finish = ' ' },
                .esc => {
                    //if (cmplt.originalStr()) |o| {
                    //    line.tkn.maybe.replace(o) catch unreachable;
                    //    line.tkn.maybe.commit(null);
                    //} else line.tkn.maybe.remove();
                    line.tkn.maybe.remove();
                    continue :sw .exit;
                },
                else => {
                    log.err("\n\nunexpected key  [{}]\n\n\n", .{ks});
                    continue :sw .{ .finish = null };
                },
            },
            .mouse => unreachable,
        },
        .redraw => {
            line.draw.clear();
            cmplt.recolorAll(line.draw.term_size, a) catch |err| switch (err) {
                error.ItemCount => {
                    var b: [128]u8 = undefined;
                    const text = bufPrint(&b, "[ Unable to print all {} options ]", .{
                        cmplt.count(),
                    }) catch unreachable;
                    line.draw.drawAfter(&[1]Draw.Lexeme{.styled(text, .red_bold)});
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            try cmplt.drawAll(line.draw);
            try line.hsh.prompt.render(line.draw, line.peek());
            try line.draw.render();
            continue :sw .input;
        },
        .empty => {
            line.tkn.maybe.commit(null);
            cmplt.raze(a);
            line.draw.clearCtx();
            try line.draw.render();
            line.draw.drawAfter(&[1]Draw.Lexeme{.styled("[ No completions found ]", .red_bold)});
            try line.hsh.prompt.render(line.draw, line.peek());
            try line.draw.render();
            return;
        },
        .commit => {
            log.debug("completion commit {}\n", .{cmplt.current().*});
            const chr: u8 = switch (cmplt.current().kind) {
                .file, .git => |file| switch (file) {
                    .dir => '/',
                    else => ' ',
                },
                else => ' ',
            };
            line.tkn.maybe.commit(chr);
            line.draw.clearCtx();
            continue :sw .restart;
        },
        .finish => |extra| {
            log.debug("completion finish\n", .{});
            line.tkn.maybe.commit(extra);
            continue :sw .exit;
        },
        .exit => {
            cmplt.raze(a);
            line.draw.clearCtx();
            log.debug("completion exit\n", .{});
            return;
        },
    }
    comptime unreachable;
}

test {
    _ = std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = @import("log.zig");
const Tokenizer = @import("tokenizer.zig");
const Fs = @import("fs.zig");
const Hsh = @import("hsh.zig");
const Completion = @import("Completion.zig");
const History = @import("History.zig");
const Input = @import("input.zig");
const Keys = @import("keys.zig");
const Prompt = @import("Prompt.zig");

const Draw = @import("draw.zig");
const Lexeme = Draw.Lexeme;
const assert = std.debug.assert;
const bufPrint = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const trim = std.mem.trim;
const whitespace = std.ascii.whitespace[0..];
