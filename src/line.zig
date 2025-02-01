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
completion: Complete.CompSet,
text: []u8,

usr_line: [1024]u8 = undefined,

const Line = @This();

const Mode = enum {
    TYPING,
    COMPLETING,
    COMPENDING, // Just completed a token, may or may not need more
    EXEDIT,
};

pub const Options = struct {
    interactive: bool = true,
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

fn core(line: *Line) !void {
    while (true) {
        const input = switch (line.mode) {
            .interactive => line.input.interactive(),
            .scripted => line.input.nonInteractive(),
            .external_editor => return error.PassToExternEditor,
        } catch |err| switch (err) {
            error.io => return err,
            error.signaled => {
                Draw.clearCtx(&line.hsh.draw);
                try Draw.render(&line.hsh.draw);
                return error.SendEmpty;
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
                    .esc => continue,
                    .up => line.findHistory(.up),
                    .down => line.findHistory(.down),
                    .left => line.tkn.move(.dec),
                    .right => line.tkn.move(.inc),
                    .backspace => line.tkn.pop(),
                    .newline => return,
                    .end_of_text => return,
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
                return;
            },
        }
    }
}

pub fn do(line: *Line) ![]u8 {
    while (true) {
        line.core() catch |err| switch (err) {
            error.PassToExternEditor => return try line.externEditorRead(),
            error.SendEmpty => return try line.alloc.dupe(u8, ""),
            error.FIXME => return try line.alloc.dupe(u8, line.tkn.raw.items),
            else => return err,
        };
        if (line.peek().len > 0) {
            return line.dupeText();
        } else {
            line.hsh.draw.newline();
            line.hsh.draw.clear();
            try Prompt.draw(line.hsh, line.peek());
            try line.hsh.draw.render();
        }
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
            defer history.cnt += 1;
            if (history.cnt == 0) {
                if (tkn.user_data == true) {
                    // TODO let token manage it's own brain :<
                    tkn.prev_exec = null;
                } else if (tkn.prev_exec) |pe| {
                    tkn.raw = pe;
                    // lol, super leaks
                    tkn.prev_exec = null;
                    tkn.idx = tkn.raw.items.len;
                    return;
                }
            }
            _ = history.readAtFiltered(tkn.lineReplaceHistory(), &line.usr_line);
            line.tkn.move(.end);
            return;
        },
        .down => {
            if (history.cnt > 1) {
                history.cnt -= 1;
                tkn.reset();
            } else {
                history.cnt -|= 1;
                tkn.reset();
                tkn.consumes(&line.usr_line) catch unreachable;
                //in.hist_orig = in.hist_data[0..0];

                return;
            }
            _ = history.readAtFiltered(tkn.lineReplaceHistory(), &line.usr_line);
            tkn.move(.end);
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
                        0x09 => unreachable,
                        0x0A => unreachable,
                        0x7f => unreachable,
                        ' ' => {
                            try line.tkn.maybeCommit(null);
                            cmplt.raze();
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
