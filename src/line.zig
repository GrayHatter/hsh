hsh: *HSH,
alloc: Allocator,
input: Input,
tkn: Tokenizer,
options: Options,
mode: union(enum) {
    interactive: void,
    scripted: void,
    external_editor: []u8,
},
history: History = undefined,
history_position: ?usize = null,
history_search: ?[]const u8 = null,
completion: Complete.CompSet,
text: []u8,

const Line = @This();

pub const Options = struct {
    interactive: bool = true,
};

const Action = enum {
    exec,
    empty,
    external,
};

pub fn init(hsh: *HSH, a: Allocator, options: Options) !Line {
    return .{
        .hsh = hsh,
        .alloc = a,
        .input = .{ .stdin = hsh.input, .spin = spin, .hsh = hsh },
        .tkn = Tokenizer.init(a),
        .completion = Complete.init(a),
        .options = options,
        .history = History.init(hsh.hfs.history, hsh.alloc),
        .mode = if (options.interactive) .{ .interactive = {} } else .{ .scripted = {} },
        .text = try hsh.alloc.alloc(u8, 0),
    };
}

pub fn raze(line: Line) void {
    if (line.completion) |comp| comp.raze();
}

fn spin(hsh: ?*HSH) bool {
    if (hsh) |h| return h.spin();
    return false;
}

fn char(line: *Line, c: u8) !void {
    try line.tkn.consumec(c);
    try line.hsh.draw.key(c);

    // TODO FIXME
    line.text = line.tkn.raw.items;
}

pub fn peek(line: Line) []const u8 {
    return line.tkn.raw.items;
}

fn core(line: *Line) !Action {
    while (true) {
        const input = switch (line.mode) {
            .interactive => line.input.interactive(),
            .scripted => line.input.nonInteractive(),
            .external_editor => return .external,
        } catch |err| switch (err) {
            error.io => return err,
            error.signaled => {
                Draw.clearCtx(&line.hsh.draw);
                try Draw.render(&line.hsh.draw);
                return .empty;
            },
            error.end_of_text => return error.FIXME,
        };
        ////hsh.draw.cursor = 0;
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
                switch (ctrl.c) {
                    .esc => {
                        // TODO reset many
                        continue;
                    },
                    .up => line.findHistory(.up),
                    .down => line.findHistory(.down),
                    .left => line.tkn.move(.dec),
                    .right => line.tkn.move(.inc),
                    .backspace => line.tkn.pop(),
                    .newline => return .exec,
                    .end_of_text => return .exec,
                    .delete_word => _ = try line.tkn.dropWord(),
                    .tab => try line.complete(),
                    else => |els| log.warn("unknown {}\n", .{els}),
                }
                line.hsh.draw.clear();
                try Prompt.draw(line.hsh, line.peek());
                try line.hsh.draw.render();
            },

            else => |el| {
                log.err("uncaptured {}\n", .{el});
                unreachable;
            },
        }
    }
}

pub fn do(line: *Line) ![]u8 {
    while (true) {
        return switch (try line.core()) {
            .external => try line.externEditorRead(),
            .empty => continue,
            .exec => {
                if (line.peek().len > 0) {
                    return try line.dupeText();
                }

                line.hsh.draw.newline();
                line.hsh.draw.clear();
                try Prompt.draw(line.hsh, line.peek());
                try line.hsh.draw.render();
                continue;
            },
        };
    }
}

fn dupeText(line: Line) ![]u8 {
    return try line.alloc.dupe(u8, line.text);
}

pub fn externEditor(line: *Line) ![]u8 {
    line.mode = .{ .external_editor = fs.mktemp(line.alloc, line.text) catch |err| {
        log.err("Unable to write prompt to tmp file {}\n", .{err});
        return err;
    } };
    return try std.fmt.allocPrint("$EDITOR {}", .{line.mode.external_editor});
}

pub fn externEditorRead(line: *Line) ![]u8 {
    const tmp = line.mode.external_editor;
    defer line.mode = .{ .interactive = {} };
    defer line.alloc.free(tmp);
    defer std.posix.unlink(tmp) catch unreachable;

    var file = fs.openFile(tmp, false) orelse return error.io;
    defer file.close();
    line.text = file.reader().readAllAlloc(line.alloc, 4096) catch unreachable;
    return line.text;
}

fn saveLine(_: *Line, _: []const u8) void {
    //const amount = @min(1024, save.len);
    //for (line.usr_line[0..amount], line[0..amount]) |*l, r| {
    //    l.* = r;
    //}
}

fn findHistory(line: *Line, dr: enum { up, down }) void {
    var history = line.history;
    var tkn = &line.tkn;
    if (tkn.user_data) {
        line.saveLine(tkn.raw.items);
    }

    switch (dr) {
        .up => {
            if (line.history_position) |pos| {
                _ = history.readAtFiltered(pos, line.history_search.?, tkn.lineReplaceHistory());
                line.history_position.? = pos + 1;
            } else {
                line.history_position = 0;
                if (tkn.raw.items.len == 0) {
                    if (tkn.prev_exec) |prvexe| {
                        tkn.raw = prvexe;
                        tkn.idx = tkn.raw.items.len;
                        tkn.prev_exec = null;
                        return;
                    }
                    line.history_search = line.alloc.dupe(u8, "") catch @panic("OOM");
                } else if (line.history_search == null) {
                    if (tkn.user_data == true) {
                        log.warn("clobbered userdata\n", .{});
                    }
                    line.history_search = line.alloc.dupe(u8, line.tkn.raw.items) catch @panic("OOM");
                }
                _ = history.readAtFiltered(0, line.history_search.?, tkn.lineReplaceHistory());
            }
            line.tkn.move(.end);
            return;
        },
        .down => {
            if (line.history_position) |pos| {
                if (pos == 0) {
                    tkn.reset();
                    log.warn("todo restore userdata\n", .{});
                    tkn.reset();
                    line.history_position = null;
                    tkn.move(.end);
                } else {
                    line.history_position.? -|= 1;
                    _ = history.readAtFiltered(pos, line.history_search.?, tkn.lineReplaceHistory());
                    //tkn.reset();
                    //tkn.consumes(&line.usr_line) catch unreachable;
                    tkn.move(.end);
                }
            }

            return;
        },
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

fn complete(line: *Line) !void {
    const cmplt: *Complete.CompSet = &line.completion;
    sw: switch (CompState{ .start = {} }) {
        .pending => unreachable,
        .start => {
            try Complete.complete(cmplt, line.hsh, &line.tkn);
            continue :sw .{ .redraw = {} };
        },
        .typing => |ks| {
            switch (ks) {
                .char => |c| {
                    line.hsh.draw.clear();
                    try Prompt.draw(line.hsh, line.peek());
                    try line.hsh.draw.render();

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
                            try Complete.complete(cmplt, line.hsh, &line.tkn);

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
            line.hsh.draw.clear();
            cmplt.drawAll(line.hsh.draw.term_size) catch |err| switch (err) {
                error.ItemCount => {},
                else => return err,
            };
            for (cmplt.draw_cache) |grp| {
                for (grp orelse continue) |row| {
                    try line.hsh.draw.drawAfter(row);
                }
            }
            try Prompt.draw(line.hsh, line.peek());
            try line.hsh.draw.render();
            continue :sw .{ .read = {} };
        },
        .read => {
            const chr = line.input.interactive() catch |err| switch (err) {
                error.signaled => continue :sw .{ .typing = .{ .control = .{ .c = .esc } } },
                else => return err,
            };
            continue :sw .{ .typing = chr };
        },
        .done => {
            line.hsh.draw.clearCtx();
            return;
        },
    }
    comptime unreachable;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = @import("log");

const Tokenizer = @import("tokenizer.zig");
const fs = @import("fs.zig");
const HSH = @import("hsh.zig").HSH;
const Complete = @import("completion.zig");
const History = @import("history.zig");
const Input = @import("input.zig");
const Keys = @import("keys.zig");
const Prompt = @import("prompt.zig");

const Draw = @import("draw.zig");
const printAfter = Draw.printAfter;
