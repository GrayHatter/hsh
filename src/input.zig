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

const Input = @This();

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

const Mode = enum {
    TYPING,
    COMPLETING,
    COMPENDING, // Just completed a token, may or may not need more
};

var mode: Mode = .TYPING;
var next: ?Event = null;

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

fn doComplete(hsh: *HSH, tkn: *Tokenizer, comp: *complete.CompSet) !Mode {
    if (comp.known()) |only| {
        // original and single, complete now
        try tkn.maybeReplace(only);
        try tkn.maybeCommit(only);

        if (only.kind != null and only.kind.? == .file_system and only.kind.?.file_system == .Dir) {
            var iter = tkn.iterator();
            const ts = iter.toSliceAny(hsh.alloc) catch unreachable;
            defer hsh.alloc.free(ts);
            try complete.complete(comp, hsh, ts);
            if (tkn.raw_maybe == null and comp.original != null) {
                tkn.raw_maybe = comp.original.?.str;
            }
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
        return .TYPING;
    } else {
        var target = comp.next();
        try tkn.maybeReplace(target);
        comp.drawAll(&hsh.draw, hsh.draw.term_size) catch |err| {
            if (err == Draw.Layout.Error.ItemCount) return .COMPLETING else return err;
        };
    }

    return .COMPLETING;
}

fn completing(hsh: *HSH, tkn: *Tokenizer, buffer: u8, comp: *complete.CompSet) !Event {
    if (mode != .COMPLETING) {
        var iter = tkn.iterator();
        const ts = iter.toSliceAny(hsh.alloc) catch unreachable;
        defer hsh.alloc.free(ts);
        try complete.complete(comp, hsh, ts);
        if (tkn.raw_maybe == null and comp.original != null) {
            tkn.raw_maybe = comp.original.?.str;
        }
        mode = .COMPLETING;
        return completing(hsh, tkn, buffer, comp);
    }

    switch (buffer) {
        '\x1B' => {
            const key = try Keys.esc(hsh);
            switch (key) {
                .ModKey => {
                    if (@intFromEnum(key.ModKey.key) == 'Z' and
                        key.ModKey.mods == .shift)
                    {
                        comp.revr();
                        comp.revr();
                        mode = try doComplete(hsh, tkn, comp);
                    }
                },
                else => {
                    // There's a bug with mouse in/out triggering this code
                    mode = .TYPING;
                    try tkn.maybeDrop();
                    if (comp.original) |o| {
                        try tkn.maybeAdd(o.str);
                        try tkn.maybeCommit(null);
                    }
                },
            }
        },
        '\x7f' => {
            if (mode == .COMPENDING) {
                mode = .TYPING;
                return .Redraw;
            }
            // backspace
            comp.searchPop() catch {
                mode = .TYPING;
                tkn.raw_maybe = null;
                return .Redraw;
            };
            mode = try doComplete(hsh, tkn, comp);
            try tkn.maybeDrop();
            try tkn.maybeAdd(comp.search.items);
            return .Redraw;
        },
        ' ' => {
            if (mode == .COMPENDING) {
                mode = .TYPING;
                return .Redraw;
            }
        },
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        ','...'.',
        '_',
        => |c| {
            if (mode == .COMPENDING) mode = .COMPLETING;
            try comp.searchChar(c);
            mode = try doComplete(hsh, tkn, comp);
            if (mode == .COMPLETING) {
                try tkn.maybeDrop();
                try tkn.maybeAdd(comp.search.items);
            }
            return .Redraw;
        },
        '\x09' => {
            // tab \t
            mode = try doComplete(hsh, tkn, comp);
            return .Redraw;
        },
        '\n' => {
            if (comp.count() > 0) {
                try tkn.maybeReplace(comp.current());
                try tkn.maybeCommit(comp.current());
            }
            mode = .TYPING;
            return .Redraw;
        },
        else => {
            mode = .TYPING;
            try tkn.maybeCommit(null);
        },
    }

    _ = simple(hsh, tkn, buffer, comp) catch unreachable;
    return .Redraw;
}

pub fn do(hsh: *HSH, comp: *complete.CompSet) !Event {
    // I no longer like this way of tokenization. I'd like to generate
    // Tokens as an n=2 state machine at time of keypress. It might actually
    // be required to unbreak a bug in history.
    const tkn = &hsh.tkn;

    var buffer: [1]u8 = undefined;

    var nbyte: usize = 0;
    while (nbyte == 0) {
        if (hsh.spin()) {
            mode = .TYPING;
            return .Update;
        }
        nbyte = try read(hsh.input, &buffer);
    }

    const prevm = mode;
    var result = switch (mode) {
        .COMPLETING => completing(hsh, tkn, buffer[0], comp),
        .COMPENDING => completing(hsh, tkn, buffer[0], comp),
        .TYPING => simple(hsh, tkn, buffer[0], comp),
    };
    defer next = if (prevm == mode) null else .Redraw;
    return next orelse result;
}

pub fn simple(hsh: *HSH, tkn: *Tokenizer, buffer: u8, comp: *complete.CompSet) !Event {
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
                                _ = hist.readAtFiltered(&tkn.raw, hz.items);
                            } else {
                                _ = hist.readAt(&tkn.raw);
                            }
                            tkn.c_idx = tkn.raw.items.len;
                        },
                        .Down => {
                            var hist = &(hsh.hist orelse return .None);
                            if (hist.cnt > 1) {
                                hist.cnt -= 1;
                                tkn.resetRaw();
                                if (tkn.hist_z) |hz| {
                                    _ = hist.readAtFiltered(&tkn.raw, hz.items);
                                } else {
                                    _ = hist.readAt(&tkn.raw);
                                }
                                tkn.c_idx = tkn.raw.items.len;
                            } else {
                                hist.cnt -|= 1;
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
                    // TODO find a better scope for this call
                    hsh.draw.cursor = @truncate(tkn.cadj());
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
        '\x09' => |c| { // \t
            // Tab is best effort, it shouldn't be able to crash hsh
            //var titr = tkn.iterator();
            //var tkns = titr.toSlice(hsh.alloc) catch return .Prompt;
            //defer hsh.alloc.free(tkns);

            //if (tkns.len == 0) {
            //    try tkn.consumec(b);
            //    return .Prompt;
            //}
            return completing(hsh, tkn, c, comp) catch unreachable;
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
                try hsh.tty.print("^D\r\nExit caught... Good bye :)\n", .{});
                return .ExitHSH;
            }

            try hsh.tty.print("^D\r\n", .{});
            return .Redraw;
        },
        '\n', '\r' => |b| {
            hsh.draw.cursor = 0;
            if (tkn.raw.items.len == 0) {
                try hsh.tty.print("\n", .{});
                return .Prompt;
            }

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
