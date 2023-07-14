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
    var target: *const complete.CompOption = undefined;
    if (mode.* == .typing) {
        try complete.complete(comp, hsh, &ctkn, flavor);

        if (comp.known()) |only| {
            // original and single, complete now
            try tkn.replaceToken(only);
            const newctkn = tkn.cursor_token() catch unreachable;
            try complete.complete(comp, hsh, &newctkn, flavor);
            return .Prompt;
        }
        mode.* = .completing;
    }

    comp.drawAll(&hsh.draw, hsh.draw.term_size) catch |err| {
        if (err == Draw.Layout.Error.ItemCount) return .Prompt else return err;
    };

    //for (comp.list.items) |c| std.debug.print("comp {}\n", .{c});
    target = comp.next();
    try tkn.replaceToken(target);
    return .Redraw;
}

pub fn input(hsh: *HSH, tkn: *Tokenizer, buffer: u8, mode: *Mode, comp: *complete.CompSet) !Event {
    // I no longer like this way of tokenization. I'd like to generate
    // Tokens as an n=2 state machine at time of keypress. It might actually
    // be required to unbreak a bug in history.

    if (mode.* == .completing) {
        switch (buffer) {
            '\x1B' => {
                mode.* = .typing;
            },
            '\x7f' => {
                comp.searchPop() catch {
                    mode.* = .typing;
                    return .Redraw;
                };
                return doComplete(hsh, tkn, comp, mode);
            },
            '\x30'...'\x7E' => |c| {
                try comp.searchChar(c);
                return doComplete(hsh, tkn, comp, mode);
            },
            '\x09' => return doComplete(hsh, tkn, comp, mode),
            else => {},
        }
    }

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
                            if (hist.cnt == 0) tkn.pushLine();
                            tkn.resetRaw();
                            hist.cnt += 1;
                            if (tkn.hist_z) |hz| {
                                _ = hist.readAtFiltered(&tkn.raw, hz.items) catch unreachable;
                            } else {
                                _ = hist.readAtFiltered(&tkn.raw, tkn.raw.items) catch unreachable;
                            }
                            tkn.pushHist();
                        },
                        .Down => {
                            var hist = &(hsh.hist orelse return .None);
                            if (hist.cnt > 1) {
                                hist.cnt -= 1;
                                tkn.resetRaw();
                                if (tkn.hist_z) |hz| {
                                    _ = hist.readAtFiltered(&tkn.raw, hz.items) catch unreachable;
                                } else {
                                    _ = hist.readAtFiltered(&tkn.raw, tkn.raw.items) catch unreachable;
                                }
                                tkn.pushHist();
                            } else if (hist.cnt == 1) {
                                hist.cnt -= 1;
                                tkn.popLine();
                            } else {}
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
            try tkn.popUntil();
            return .Redraw;
        },
        '\x20'...'\x7E' => |b| { // Normal printable ascii
            try tkn.consumec(b);
            try hsh.tty.print("{c}", .{b});
            return .None;
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
            var run = Parser.parse(&tkn.alloc, tkns);
            //Draw.clearCtx(&hsh.draw);
            if (run) |pitr| {
                if (pitr.tokens.len > 0) return .Exec;
                return .Redraw;
            } else |_| {}
            return .Redraw;
        },
        else => |b| {
            try hsh.tty.print("\n\n\runknown char    {} {}\n", .{ b, buffer });
            return .None;
        },
    }
    return .None;
}
