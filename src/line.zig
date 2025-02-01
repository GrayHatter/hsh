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
completion: ?Complete.CompSet = null,
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
        .completion = try Complete.init(hsh),
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
    line.core() catch |err| switch (err) {
        error.PassToExternEditor => return try line.externEditorRead(),
        error.SendEmpty => return try line.alloc.dupe(u8, ""),
        error.FIXME => return try line.alloc.dupe(u8, line.tkn.raw.items),
        else => return err,
    };
    return line.dupeText();
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

fn doComplete(hsh: *HSH, tkn: *Tokenizer, comp: *Complete.CompSet) !Mode {
    if (comp.known()) |only| {
        // original and single, complete now
        try tkn.maybeReplace(only);
        try tkn.maybeCommit(only);

        if (only.kind != null and only.kind.? == .file_system and only.kind.?.file_system == .dir) {
            try Complete.complete(comp, hsh, tkn);
            return .COMPENDING;
        } else {
            comp.raze();
            try Draw.drawAfter(&hsh.draw, &[_]Draw.Lexeme{.{
                .char = "[ found ]",
                .style = .{ .attr = .bold, .fg = .green },
            }});
            return .TYPING;
        }
    }

    if (comp.countFiltered() == 0) {
        try Draw.drawAfter(&hsh.draw, &[_]Draw.Lexeme{
            Draw.Lexeme{ .char = "[ nothing found ]", .style = .{ .attr = .bold, .fg = .red } },
        });
        if (comp.count() == 0) {
            comp.raze();
        }
        return .TYPING;
    }

    if (comp.countFiltered() > 1) {
        const target = comp.next();
        try tkn.maybeReplace(target);
        comp.drawAll(&hsh.draw, hsh.draw.term_size) catch |err| {
            if (err == Draw.Layout.Error.ItemCount) return .COMPLETING else return err;
        };
    }

    return .COMPLETING;
}

const CompState = union(enum) {
    typing: Input.Event,
    pending: void,
    read: void,
    redraw: void,
    done: void,
};

fn complete(line: *Line) !void {
    sw: switch (CompState{ .typing = Input.Event{ .char = 0x09 } }) {
        .pending => {},
        .typing => |ks| {
            switch (ks) {
                .char => |c| {
                    switch (c) {
                        0x09 => {}, // unreachable?
                        0x0A => {
                            // TODO don't return if navigating around
                            continue :sw .{ .done = {} };
                            //if (line.completion.count() > 0) {
                            //    try line.tkn.maybeReplace(line.completion.current());
                            //    try line.tkn.maybeCommit(line.completion.current());
                            //    continue :sw .{ .pending = {} };
                            //}
                            //continue :sw .{ .redraw = {} };
                        },
                        0x7f => { // backspace
                            line.completion.?.searchPop() catch {
                                line.completion.?.raze();
                                line.tkn.raw_maybe = null;
                                continue :sw .{ .done = {} };
                            };
                            //line.mode = try doComplete(line.hsh, line.tkn, line.completion);
                            try line.tkn.maybeDrop();
                            try line.tkn.maybeAdd(line.completion.?.search.items);
                            continue :sw .{ .redraw = {} };
                        },
                        ' ' => continue :sw .{ .redraw = {} },
                        '/' => |chr| {
                            // IFF this is an existing directory,
                            // completion should continue
                            if (line.completion.?.count() > 1) {
                                if (line.completion.?.current().kind) |kind| {
                                    if (kind == .file_system and kind.file_system == .dir) {
                                        try line.tkn.consumec(chr);
                                    }
                                }
                            }
                            continue :sw .{ .redraw = {} };
                        },
                        else => {
                            //if (line.mode == .COMPENDING) line.mode = .COMPLETING;
                            //try line.completion.?.searchChar(c);
                            //line.mode = try doComplete(line.hsh, line.tkn, line.completion);
                            //if (line.mode == .COMPLETING) {
                            //    try line.tkn.maybeDrop();
                            //    try line.tkn.maybeAdd(line.completion.search.items);
                            //}
                            continue :sw .{ .redraw = {} };
                        },
                    }
                },
                .control => |k| {
                    switch (k.c) {
                        .tab => {
                            if (k.mod.shift) {
                                line.completion.?.revr();
                                line.completion.?.revr();
                            }
                            _ = try doComplete(line.hsh, &line.tkn, &line.completion.?);
                            continue :sw .{ .redraw = {} };
                        },
                        .esc => {
                            try line.tkn.maybeDrop();
                            if (line.completion.?.original) |o| {
                                try line.tkn.maybeAdd(o.str);
                                try line.tkn.maybeCommit(null);
                            }
                            line.completion.?.raze();
                            continue :sw .{ .redraw = {} };
                        },
                        .up, .down, .left, .right => {
                            // TODO implement arrows
                            continue :sw .{ .redraw = {} };
                        },
                        .home, .end => |h_e| {
                            try line.tkn.maybeCommit(null);
                            line.tkn.idx = if (h_e == .home) 0 else line.tkn.raw.items.len;
                            continue :sw .{ .redraw = {} };
                        },
                        else => {
                            log.err("unexpected key  [{}]\n", .{ks});
                            try line.tkn.maybeCommit(null);
                        },
                    }
                },
                .mouse => {},
                .action => {},
            }
        },
        .redraw => {
            line.hsh.draw.clear();
            try Prompt.draw(line.hsh, line.peek());
            try line.hsh.draw.render();
            continue :sw .{ .read = {} };
        },
        .read => {
            continue :sw .{ .typing = try line.input.interactive() };
        },
        .done => {
            return;
        },
    }
    unreachable;
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
