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
completion: Complete.CompSet,

const Line = @This();

pub const Options = struct {
    interactive: bool = true,
};

const Action = enum {
    exec,
    empty,
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
        .tkn = Tokenizer.init(a),
        .completion = Complete.init(a),
        .options = options,
        .history = try .init(hsh.fs.history, a, io),
    };
}

pub fn raze(line: Line) void {
    if (line.completion) |comp| comp.raze();
}

fn spin(input: *const Input, a: Allocator, io: Io) bool {
    const line: *const Line = @fieldParentPtr("input", input);
    return line.hsh.spin(a, io);
}

fn char(line: *Line, c: u8) !void {
    if (line.hist_index > 0) {
        line.hist_index = 0;
        line.alloc.free(line.bytes);
        line.bytes = &.{};
    }
    try line.tkn.consumec(c);
    try line.draw.key(c);

    // TODO FIXME
    line.bytes = line.tkn.raw.items;
}

pub const CursorDirection = enum {
    left,
    right,
    start,
    end,
    word_left,
    word_right,
};

fn cursor(line: *Line, cd: CursorDirection) void {
    _ = line;
    switch (cd) {
        else => {},
    }
}

pub fn peek(line: Line) []const u8 {
    return line.tkn.raw.items;
}

fn core(line: *Line, a: Allocator, io: Io) !Action {
    while (true) {
        const input = switch (line.mode) {
            .interactive => line.input.interactive(a, io),
            .scripted => line.input.nonInteractive(),
            .external_editor => return .external,
        } catch |err| switch (err) {
            error.Io => return err,
            error.Signaled => {
                line.draw.clearCtx();
                try line.draw.render();
                return .empty;
            },
            //error.end_of_text => return error.FIXME,
        };
        ////line.draw.cursor = 0;
        //if (tkn.raw.items.len == 0) {
        //    try hsh.tty.out.print("\n", .{});
        //    return .prompt;
        //}

        //const nl_exec = tkn.consumec(nl);
        //if (nl_exec == error.exec) {
        //    if (tkn.validate()) {} else |e| {
        //        log.err("validate", .{});
        //        switch (e) {
        //            TokenErr.OpenGroup, TokenErr.OpenLogic => {},
        //            TokenErr.TokenizeFailed => log.err("tokenize Error {}\n", .{e}),
        //            else => return .ExpectedError,
        //        }
        //        return .prompt;
        //    }
        //    tkn.bsc();
        //    return .exec;
        //}
        //var run = Parser.parse(tkn.alloc, tkns) catch return .redraw;
        //defer run.raze();
        //if (run.tokens.len > 0) return .exec;
        //return .redraw;
        //return input;
        switch (input) {
            .char => |c| try line.char(c),
            .control => |ctrl| {
                log.debug("control char = '{}'\n", .{ctrl});
                switch (ctrl.c) {
                    .esc => {
                        // TODO reset many
                        continue;
                    },
                    .up => try line.findHistory(.up),
                    .down => try line.findHistory(.down),
                    .left => line.tkn.move(.dec),
                    .right => line.tkn.move(.inc),
                    .backspace => line.tkn.pop(),
                    .newline => return .exec,
                    .end_of_text => return .exec,
                    .delete_word => _ = try line.tkn.dropWord(),
                    .tab => try line.complete(a, io),
                    else => |els| log.warn("unknown {}\n", .{els}),
                }
                line.draw.clear();
                try line.prompt.render(line.draw, line.peek());
                try line.draw.render();
            },

            else => |el| {
                log.err("uncaptured {}\n", .{el});
                unreachable;
            },
        }
    }
}

pub fn do(line: *Line, a: Allocator, io: Io) ![]u8 {
    while (true) {
        return switch (try line.core(a, io)) {
            .external => try line.externEditorRead(io),
            .empty => continue,
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
    return try line.alloc.dupe(u8, line.bytes);
}

pub fn externEditor(line: *Line, io: Io) ![]u8 {
    line.mode = .{ .external_editor = Fs.mktemp(line.text, line.alloc, io) catch |err| {
        log.err("Unable to write prompt to tmp file {}\n", .{err});
        return err;
    } };
    return try std.fmt.allocPrint("$EDITOR {}", .{line.mode.external_editor});
}

pub fn externEditorRead(line: *Line, io: Io) ![]u8 {
    const tmp = line.mode.external_editor;
    defer line.mode = .{ .interactive = {} };
    defer line.alloc.free(tmp);
    defer unreachable;

    var file = Fs.openFile(tmp, io, .create) orelse return error.io;
    defer file.close(io);
    var reader = file.reader(io, &.{});

    line.bytes = reader.interface.allocRemaining(line.alloc, .limited(4096)) catch unreachable;
    return line.bytes;
}

fn findHistory(line: *Line, dr: enum { up, down }) !void {
    var history = line.history;
    var tkn = &line.tkn;

    if (line.hist_index == 0) {
        if (dr == .down) return;
        line.hist_index = 1;
        if (line.bytes.len > 0) {
            line.hist_search = line.bytes;
        }
    } else if (line.hist_index == 1) {
        if (dr == .down) {
            line.hist_index = 0;
            if (line.hist_search) |hs| {
                line.bytes = hs;
                line.hist_search = null;
            } else line.bytes = &.{};
            tkn.reset();
            try line.tkn.consumeSlice(line.bytes);
            tkn.move(.end);
            return;
        } else line.hist_index += 1;
    } else {
        if (dr == .up) line.hist_index += 1 else line.hist_index -= 1;
    }

    const history_line: ?[]const u8 = if (line.hist_search) |search|
        history.readLineFiltered(line.hist_index, search)
    else
        history.readLine(line.hist_index);

    assert(line.hist_index > 0);
    if (history_line) |hist_line| {
        // TODO optimize
        line.alloc.free(line.bytes);
        line.bytes = try line.alloc.dupe(u8, hist_line);
        tkn.reset();
        try line.tkn.consumeSlice(line.bytes);
        tkn.move(.end);
    } else {
        if (dr == .up) line.hist_index -= 1 else line.hist_index += 1;
        line.draw.drawAfter(&[1]Lexeme{.styled("[ End of History ]", .red_bold)});
        try line.draw.render();
    }
}

const CompState = union(enum) {
    start: void,
    typing: Input.Event,
    pending: void,
    read: void,
    redraw: void,
    done: void,
};

fn complete(line: *Line, a: Allocator, io: Io) !void {
    const cmplt: *Complete.CompSet = &line.completion;
    sw: switch (CompState{ .start = {} }) {
        .pending => unreachable,
        .start => {
            try Complete.complete(cmplt, line.hsh, &line.tkn, io);
            continue :sw .{ .redraw = {} };
        },
        .typing => |ks| {
            switch (ks) {
                .char => |c| {
                    line.draw.clear();
                    try line.prompt.render(line.draw, line.peek());
                    try line.draw.render();

                    switch (c) {
                        0x00...0x1f => unreachable,
                        ' ' => {
                            try line.tkn.maybeCommit(null);
                            cmplt.raze();
                            try line.tkn.consumec(' ');
                            continue :sw .{ .done = {} };
                        },
                        '/' => |chr| {
                            // IFF this is an existing directory,
                            // completion should continue
                            if (cmplt.count() > 1) {
                                if (cmplt.current().kind) |kind| {
                                    if (kind == .file_system and kind.file_system == .dir) {
                                        try line.tkn.consumec(chr);
                                    }
                                }
                            }
                            continue :sw .{ .redraw = {} };
                        },
                        else => {
                            try Complete.complete(cmplt, line.hsh, &line.tkn, io);

                            if (cmplt.count() == 0) {
                                try line.tkn.consumec(c);
                                continue :sw .{ .done = {} };
                            } else {
                                try cmplt.searchChar(c);
                            }

                            continue :sw .{ .redraw = {} };
                        },
                        0x7f...0xff => unreachable,
                    }
                },
                .control => |k| {
                    switch (k.c) {
                        .tab => {
                            if (k.mod.shift) {
                                cmplt.revr();
                                cmplt.revr();
                            }
                            //_ = try doComplete(line.hsh, &line.tkn, &cmplt);
                            try line.tkn.maybeReplace(cmplt.next());
                        },
                        .esc => {
                            try line.tkn.maybeDrop();
                            if (cmplt.original) |o| {
                                try line.tkn.maybeAdd(o.str);
                                try line.tkn.maybeCommit(null);
                            }
                            cmplt.raze();
                            continue :sw .{ .done = {} };
                        },
                        .up, .down, .left, .right => {
                            // TODO implement arrows
                        },
                        .home, .end => |h_e| {
                            try line.tkn.maybeCommit(null);
                            line.tkn.idx = if (h_e == .home) 0 else line.tkn.raw.items.len;
                        },
                        .newline => {
                            try line.tkn.maybeCommit(null);
                            cmplt.raze();
                            try line.tkn.consumec(' ');
                            continue :sw .{ .done = {} };
                        },
                        .backspace => {
                            cmplt.searchPop() catch {
                                cmplt.raze();
                                line.tkn.raw_maybe = null;
                                continue :sw .{ .redraw = {} };
                            };
                            //line.mode = try doComplete(line.hsh, line.tkn, line.completion);
                            try line.tkn.maybeDrop();
                            try line.tkn.maybeAdd(cmplt.search.items);
                            continue :sw .{ .redraw = {} };
                        },
                        .delete_word => {
                            _ = try line.tkn.dropWord();
                            continue :sw .{ .redraw = {} };
                        },
                        else => {
                            log.err("\n\nunexpected key  [{}]\n\n\n", .{ks});
                            try line.tkn.maybeCommit(null);
                        },
                    }
                    continue :sw .{ .redraw = {} };
                },
                .mouse, .action => unreachable,
            }
        },
        .redraw => {
            line.draw.clear();
            cmplt.drawAll(line.draw.term_size) catch |err| switch (err) {
                error.ItemCount => {},
                else => return err,
            };
            for (cmplt.draw_cache) |grp| {
                for (grp orelse continue) |row| {
                    line.draw.drawAfter(row);
                }
            }
            try line.hsh.prompt.render(line.draw, line.peek());
            try line.draw.render();
            continue :sw .{ .read = {} };
        },
        .read => {
            const chr = line.input.interactive(a, io) catch |err| switch (err) {
                error.Signaled => continue :sw .{ .typing = .{ .control = .{ .c = .esc } } },
                else => return err,
            };
            continue :sw .{ .typing = chr };
        },
        .done => {
            line.draw.clearCtx();
            return;
        },
    }
    comptime unreachable;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = @import("log.zig");
const Tokenizer = @import("tokenizer.zig");
const Fs = @import("fs.zig");
const Hsh = @import("hsh.zig");
const Complete = @import("completion.zig");
const History = @import("History.zig");
const Input = @import("input.zig");
const Keys = @import("keys.zig");
const Prompt = @import("Prompt.zig");

const Draw = @import("draw.zig");
const Lexeme = Draw.Lexeme;
const assert = std.debug.assert;
