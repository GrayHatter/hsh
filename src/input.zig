const std = @import("std");
const log = @import("log");
const HSH = @import("hsh.zig").HSH;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const complete = @import("completion.zig");
const Keys = @import("keys.zig");
const printAfter = Draw.printAfter;
const Draw = @import("draw.zig");
const TokenErr = tokenizer.Error;
const parser = @import("parse.zig");
const Parser = parser.Parser;

pub const Event = enum(u8) {
    None,
    HSHIntern,
    Update,
    EnvState,
    Prompt,
    Advice,
    Redraw,
    Exec,
    // ...
    ExitHSH,
    ExpectedError,
};

pub const Mode = enum {
    typing,
    completing,
};

pub fn read(fd: std.os.fd_t, buf: []u8) !usize {
    const rc = std.os.linux.read(fd, buf.ptr, buf.len);
    switch (std.os.linux.getErrno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return error.Interupted,
        .AGAIN => return error.WouldBlock,
        .BADF => return error.NotOpenForReading, // Can be a race condition.
        .IO => return error.InputOutput,
        .ISDIR => return error.IsDir,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .CONNRESET => return error.ConnectionResetByPeer,
        .TIMEDOUT => return error.ConnectionTimedOut,
        else => |err| {
            std.debug.print("unexpected read err {}\n", .{err});
            @panic("unknown read error\n");
        },
    }
}

fn doComplete(hsh: *HSH, tkn: *Tokenizer, comp: *complete.CompSet, mode: *Mode) !Event {
    const ctkn = tkn.cursor_token() catch unreachable;
    var flavor: complete.Kind = .any;
    if (tkn.c_tkn == 0) {
        flavor = .path_exe;
    }
    if (mode.* == .typing) {
        try complete.complete(comp, hsh, &ctkn, flavor);
        if (tkn.raw_maybe == null and comp.original != null) {
            tkn.raw_maybe = comp.original.?.str;
        }
    }

    if (comp.known()) |only| {
        // original and single, complete now
        try tkn.replaceToken(only);
        try tkn.replaceCommit(only);
        //const newctkn = tkn.cursor_token() catch unreachable;
        //try complete.complete(comp, hsh, &newctkn, flavor);
        mode.* = .typing;
        return .Prompt;
    } else if (mode.* == .typing) {
        comp.drawAll(&hsh.draw, hsh.draw.term_size) catch |err| {
            if (err == Draw.Layout.Error.ItemCount) return .Prompt else return err;
        };
        mode.* = .completing;
        return .Redraw;
    }

    if (comp.countFiltered() == 0) {
        // TODO print error
        return .None;
    }
    var target = comp.next();
    comp.drawAll(&hsh.draw, hsh.draw.term_size) catch |err| {
        if (err == Draw.Layout.Error.ItemCount) return .Prompt else return err;
    };

    try tkn.replaceToken(target);
    return .Redraw;
}

fn completing(hsh: *HSH, tkn: *Tokenizer, buffer: u8, mode: *Mode, comp: *complete.CompSet) !Event {
    if (mode.* == .completing) {
        switch (buffer) {
            '\x1B' => {
                // There's a bug with mouse in/out triggering this code
                mode.* = .typing;
                try tkn.dropMaybe();
                if (comp.original) |o| {
                    try tkn.addMaybe(o.str);
                    try tkn.replaceCommit(null);
                }
            },
            '\x7f' => {
                // backspace
                comp.searchPop() catch {
                    mode.* = .typing;
                    tkn.raw_maybe = null;
                    return .Redraw;
                };
                const exit = doComplete(hsh, tkn, comp, mode);
                try tkn.dropMaybe();
                try tkn.addMaybe(comp.search.items);
                return exit;
            },
            '0'...'9',
            'A'...'Z',
            'a'...'z',
            ','...'.',
            '_',
            => |c| {
                try comp.searchChar(c);
                const exit = doComplete(hsh, tkn, comp, mode);
                if (mode.* == .completing) {
                    try tkn.dropMaybe();
                    try tkn.addMaybe(comp.search.items);
                }
                return exit;
            },
            '\x09' => {
                // tab \t
                return doComplete(hsh, tkn, comp, mode);
            },
            '\n' => {
                if (comp.count() > 0) {
                    try tkn.replaceToken(comp.current());
                    try tkn.replaceCommit(comp.current());
                }
                mode.* = .typing;
                return .Redraw;
            },
            else => {
                mode.* = .typing;
                try tkn.replaceCommit(null);
                _ = try simple(hsh, tkn, buffer, mode, comp);
                return .Redraw;
            },
        }
    }
    return simple(hsh, tkn, buffer, mode, comp);
}

pub fn input(hsh: *HSH, buffer: u8, mode: *Mode, comp: *complete.CompSet) !Event {
    // I no longer like this way of tokenization. I'd like to generate
    // Tokens as an n=2 state machine at time of keypress. It might actually
    // be required to unbreak a bug in history.
    const tkn = &hsh.tkn;

    return switch (mode.*) {
        .completing => completing(hsh, tkn, buffer, mode, comp),
        else => simple(hsh, tkn, buffer, mode, comp),
    };
}

pub fn simple(hsh: *HSH, tkn: *Tokenizer, buffer: u8, mode: *Mode, comp: *complete.CompSet) !Event {
    switch (buffer) {
        '\x1B' => {
            const to_reset = tkn.err_idx != 0;
            tkn.err_idx = 0;
            switch (try Keys.esc(hsh)) {
                .Unknown => if (!to_reset) try printAfter(&hsh.draw, "Unknown esc --\x1B[J", .{}),
                .Key => |a| {
                    switch (a) {
                        .Up => {
                            var hist = &(hsh.hist orelse return .None);
                            if (hist.cnt == 0) {
                                if (tkn.raw.items.len > 0) {
                                    tkn.saveLine();
                                } else if (tkn.prev_exec) |pe| {
                                    tkn.raw = pe;
                                    tkn.prev_exec = null;
                                    tkn.c_idx = tkn.raw.items.len;
                                    return .Redraw;
                                }
                            }
                            tkn.resetRaw();
                            hist.cnt += 1;
                            if (tkn.hist_z) |hz| {
                                _ = hist.readAtFiltered(&tkn.raw, hz.items) catch unreachable;
                            } else {
                                _ = hist.readAt(&tkn.raw) catch unreachable;
                            }
                            tkn.c_idx = tkn.raw.items.len;
                        },
                        .Down => {
                            var hist = &(hsh.hist orelse return .None);
                            if (hist.cnt > 1) {
                                hist.cnt -= 1;
                                tkn.resetRaw();
                                if (tkn.hist_z) |hz| {
                                    _ = hist.readAtFiltered(&tkn.raw, hz.items) catch unreachable;
                                } else {
                                    _ = hist.readAt(&tkn.raw) catch unreachable;
                                }
                                tkn.c_idx = tkn.raw.items.len;
                            } else if (hist.cnt == 1) {
                                hist.cnt -= 1;
                                tkn.restoreLine();
                            } else {
                                tkn.restoreLine();
                            }
                        },
                        .Left => tkn.cPos(.dec),
                        .Right => tkn.cPos(.inc),
                        .Home => tkn.cPos(.home),
                        .End => tkn.cPos(.end),
                        .Delete => tkn.delc(),
                        else => {}, // unable to use range on Key :<
                    }
                },
                .ModKey => |mk| {
                    switch (mk.mods) {
                        .none => {},
                        .shift => {},
                        .alt => {
                            switch (mk.key) {
                                else => |k| {
                                    const key: u8 = @intFromEnum(k);
                                    switch (key) {
                                        '.' => log.err("<A-.> not yet implemented\n", .{}),
                                        else => {},
                                    }
                                },
                            }
                        },
                        .ctrl => {
                            switch (mk.key) {
                                .Left => {
                                    tkn.cPos(.back);
                                },
                                .Right => {
                                    tkn.cPos(.word);
                                },
                                .Home => tkn.cPos(.home),
                                .End => tkn.cPos(.end),
                                else => {},
                            }
                        },
                        .meta => {},
                        _ => {},
                    }
                    switch (mk.key) {
                        .Left => {},
                        .Right => {},
                        else => {},
                    }
                },
                .Mouse => return .None,
            }
            return .Redraw;
        },
        '\x07' => try hsh.tty.print("^bel\r\n", .{}),
        '\x08' => try hsh.tty.print("\r\ninput: backspace\r\n", .{}),
        // probably ctrl + bs
        '\x09' => |b| { // \t
            // Tab is best effort, it shouldn't be able to crash hsh
            var titr = tkn.iterator();
            var tkns = titr.toSlice(hsh.alloc) catch return .Prompt;
            defer hsh.alloc.free(tkns);

            if (tkns.len == 0) {
                try tkn.consumec(b);
                return .Prompt;
            }
            return doComplete(hsh, tkn, comp, mode);
        },
        '\x0C' => {
            try hsh.tty.print("^L (reset term)\x1B[J\n", .{});
            return .Redraw;
        },
        '\x0E' => try hsh.tty.print("shift in\r\n", .{}),
        '\x0F' => try hsh.tty.print("^shift out\r\n", .{}),
        '\x12' => try hsh.tty.print("^R\r\n", .{}), // DC2
        '\x13' => try hsh.tty.print("^S\r\n", .{}), // DC3
        '\x14' => try hsh.tty.print("^T\r\n", .{}), // DC4
        '\x1A' => try hsh.tty.print("^Z\r\n", .{}),
        '\x17' => { // ^w
            _ = try tkn.dropWord();
            return .Redraw;
        },
        '\x20'...'\x7E' => |b| { // Normal printable ascii
            try tkn.consumec(b);
            try hsh.tty.print("{c}", .{b});
            return if (tkn.cadj() == 0) .None else .Redraw;
        },
        '\x7F' => { // backspace
            tkn.pop() catch |err| {
                if (err == TokenErr.Empty) return .None;
                return err;
            };
            return .Prompt;
        },
        '\x03' => {
            try hsh.tty.print("^C\n\n", .{});
            tkn.reset();
            return .Prompt;
            // if (tn.raw.items.len > 0) {
            // } else {
            //     return false;
            //     try tty.print("\r\nExit caught... Bye ()\r\n", .{});
            // }
        },
        '\x04' => {
            if (tkn.raw.items.len == 0) {
                try hsh.tty.print("^D\r\n", .{});
                try hsh.tty.print("\r\nExit caught... Bye\r\n", .{});
                return .ExitHSH;
            }

            try hsh.tty.print("^D\r\n", .{});
            return .None;
        },
        '\n', '\r' => |b| {
            hsh.draw.cursor = 0;
            var titr = tkn.iterator();

            const tkns = titr.toSliceError(hsh.alloc) catch |e| {
                switch (e) {
                    TokenErr.Empty => {
                        try hsh.tty.print("\n", .{});
                        return .None;
                    },
                    TokenErr.OpenGroup => try tkn.consumec(b),
                    TokenErr.TokenizeFailed => {
                        std.debug.print("tokenize Error {}\n", .{e});
                        try tkn.consumec(b);
                    },
                    else => return .ExpectedError,
                }
                return .Prompt;
            };
            defer hsh.alloc.free(tkns);
            var run = Parser.parse(&tkn.alloc, tkns) catch return .Redraw;
            defer run.close();
            if (run.tokens.len > 0) return .Exec;
            return .Redraw;
        },
        else => |b| {
            try hsh.tty.print("\n\n\runknown char    {} {}\n", .{ b, buffer });
            return .None;
        },
    }
    return .None;
}
