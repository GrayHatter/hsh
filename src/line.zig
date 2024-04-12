const std = @import("std");
const log = @import("log");

const fs = @import("fs.zig");
const HSH = @import("hsh.zig").HSH;
const Complete = @import("completion.zig");
const History = @import("history.zig");
const Input = @import("input.zig");
const Keys = @import("keys.zig");
const Prompt = @import("prompt.zig");

const printAfter = Draw.printAfter;
const Draw = @import("draw.zig");

const Line = @This();

// delete plx
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

const Mode = enum {
    TYPING,
    COMPLETING,
    COMPENDING, // Just completed a token, may or may not need more
    EXEDIT,
};

hsh: *HSH,
input: Input,
options: Options,
mode: union(enum) {
    interactive: void,
    scripted: void,
    external_editor: bool,
},
history: History = undefined,
completion: *Complete.CompSet,

usr_line: [1024]u8 = undefined,

pub const Options = struct {
    interactive: bool = true,
};

pub fn init(hsh: *HSH, comp: *Complete.CompSet, options: Options) Line {
    return .{
        .hsh = hsh,
        .completion = comp,
        .options = options,
        .history = History.init(hsh.hfs.history, hsh.alloc),
        .input = .{ .stdin = hsh.input, .spin = spin, .hsh = hsh },
        .mode = if (options.interactive) .{ .interactive = {} } else .{ .scripted = {} },
    };
}

fn spin(hsh: ?*HSH) bool {
    if (hsh) |h| return h.spin();
    return false;
}

pub fn do(line: *Line) !bool {
    while (true) {
        const input = switch (line.mode) {
            .interactive => line.input.interactive(),
            .scripted => line.input.nonInteractive(),
            .external_editor => return false,
        } catch |err| {
            switch (err) {
                error.io => return err,
                error.signaled => {
                    Draw.clearCtx(&line.hsh.draw);
                    try Draw.render(&line.hsh.draw);
                    return false;
                },
                error.end_of_text => return true,
            }
            comptime unreachable;
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
            .char => |c| {
                try line.hsh.tkn.consumec(c);
                try line.hsh.draw.key(c);
            },
            .control => |ctrl| {
                switch (ctrl) {
                    .esc => continue,
                    .up => line.findHistory(.up),
                    .down => line.findHistory(.down),
                    .backspace => line.hsh.tkn.pop(),
                    .newline => return true,
                    .end_of_text => return true,
                    .delete_word => _ = try line.hsh.tkn.dropWord(),
                    else => log.warn("unknown {}\n", .{ctrl}),
                }
                line.hsh.draw.clear();
                try Prompt.draw(line.hsh);
                try line.hsh.draw.render();
            },

            else => |el| {
                log.err("uncaptured {}\n", .{el});
                return true;
            },
        }
    }
}

pub fn externEditor(line: *Line) void {
    const filename = fs.mktemp(line.alloc, line.raw.items) catch {
        log.err("Unable to write prompt to tmp file\n", .{});
        return;
    };
    line.saveLine();
    line.consumes("$EDITOR ") catch unreachable;
    line.consumes(filename) catch unreachable;
    line.editor_mktmp = filename;
}

pub fn externEditorRead(line: *Tokenizer) void {
    if (line.editor_mktmp) |mkt| {
        var file = fs.openFile(mkt, false) orelse return;
        defer file.close();
        file.reader().readAllArrayList(&line.raw, 4096) catch unreachable;
        std.posix.unlink(mkt) catch unreachable;
        line.alloc.free(mkt);
    }
    line.editor_mktmp = null;
}

fn saveLine(_: *Line, _: []const u8) void {
    //const amount = @min(1024, save.len);
    //for (line.usr_line[0..amount], line[0..amount]) |*l, r| {
    //    l.* = r;
    //}
}

fn findHistory(line: *Line, dr: enum { up, down }) void {
    var history = line.history;
    var tkn = &line.hsh.tkn;
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
                    tkn.c_idx = tkn.raw.items.len;
                    return;
                }
            }
            _ = history.readAtFiltered(tkn.lineReplaceHistory(), &line.usr_line);
            tkn.cPos(.end);
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
            tkn.cPos(.end);
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
            try Draw.drawAfter(&hsh.draw, Draw.LexTree{
                .lex = Draw.Lexeme{ .char = "[ found ]", .style = .{ .attr = .bold, .fg = .green } },
            });
            return .TYPING;
        }
    }

    if (comp.countFiltered() == 0) {
        try Draw.drawAfter(&hsh.draw, Draw.LexTree{
            .lex = Draw.Lexeme{ .char = "[ nothing found ]", .style = .{ .attr = .bold, .fg = .red } },
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

fn completing(in: *Input, hsh: *HSH, tkn: *Tokenizer, ks: Keys.KeyMod, comp: *Complete.CompSet) !Input.Event {
    if (in.mode == .TYPING) {
        try Complete.complete(comp, hsh, tkn);
        in.mode = .COMPLETING;
        return in.completing(hsh, tkn, ks, comp);
    }

    switch (ks.evt) {
        .ascii => |c| {
            switch (c) {
                0x09 => {
                    // tab \t
                    if (ks.mods.shift) {
                        comp.revr();
                        comp.revr();
                    }
                    in.mode = try doComplete(hsh, tkn, comp);
                    return .Redraw;
                },
                0x0A => {
                    // newline \n
                    if (in.mode == .COMPENDING) {
                        in.mode = .TYPING;
                        return .Exec;
                    }
                    if (comp.count() > 0) {
                        try tkn.maybeReplace(comp.current());
                        try tkn.maybeCommit(comp.current());
                        in.mode = .COMPENDING;
                    }
                    return .Redraw;
                },
                0x7f => { // backspace
                    if (in.mode == .COMPENDING) {
                        in.mode = .TYPING;
                        return .Redraw;
                    }
                    comp.searchPop() catch {
                        in.mode = .TYPING;
                        comp.raze();
                        tkn.raw_maybe = null;
                        return .Redraw;
                    };
                    in.mode = try doComplete(hsh, tkn, comp);
                    try tkn.maybeDrop();
                    try tkn.maybeAdd(comp.search.items);
                    return .Redraw;
                },
                ' ' => {
                    in.mode = .TYPING;
                    return .Redraw;
                },
                '/' => |chr| {
                    // IFF this is an existing directory,
                    // completion should continue
                    if (comp.count() > 1) {
                        if (comp.current().kind) |kind| {
                            if (kind == .file_system and kind.file_system == .dir) {
                                try tkn.consumec(chr);
                            }
                        }
                    }
                    in.mode = .TYPING;
                    return .Redraw;
                },
                else => {
                    if (in.mode == .COMPENDING) in.mode = .COMPLETING;
                    try comp.searchChar(c);
                    in.mode = try doComplete(hsh, tkn, comp);
                    if (in.mode == .COMPLETING) {
                        try tkn.maybeDrop();
                        try tkn.maybeAdd(comp.search.items);
                    }
                    return .Redraw;
                },
            }
        },
        .key => |k| {
            switch (k) {
                .Esc => {
                    in.mode = .TYPING;
                    try tkn.maybeDrop();
                    if (comp.original) |o| {
                        try tkn.maybeAdd(o.str);
                        try tkn.maybeCommit(null);
                    }
                    comp.raze();
                    return .Redraw;
                },
                .Up, .Down, .Left, .Right => {
                    // TODO implement arrows
                    return .Redraw;
                },
                .Home, .End => |h_e| {
                    in.mode = .TYPING;
                    try tkn.maybeCommit(null);
                    tkn.cPos(if (h_e == .Home) .home else .end);
                    return .Redraw;
                },
                else => {
                    log.err("unexpected key  [{}]\n", .{ks});
                    in.mode = .TYPING;
                    try tkn.maybeCommit(null);
                },
            }
        },
    }
    log.err("end of completing... oops\n  [{}]\n", .{ks});
    unreachable;
}
