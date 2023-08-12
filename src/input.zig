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
            if (comp.original != null) {
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
        if (comp.count() == 0) {
            comp.raze();
        }
        return .TYPING;
    }

    if (comp.countFiltered() > 1) {
        var target = comp.next();
        try tkn.maybeReplace(target);
        comp.drawAll(&hsh.draw, hsh.draw.term_size) catch |err| {
            if (err == Draw.Layout.Error.ItemCount) return .COMPLETING else return err;
        };
    }

    return .COMPLETING;
}

fn completing(hsh: *HSH, tkn: *Tokenizer, evt: Keys.Event, comp: *complete.CompSet) !Event {
    var buffer: u8 = switch (evt) {
        .ascii => |a| a,
        .keysm => return .Redraw,
        .mouse => return .Redraw,
    };

    if (mode != .COMPLETING) {
        var iter = tkn.iterator();
        const ts = iter.toSliceAny(hsh.alloc) catch unreachable;
        defer hsh.alloc.free(ts);
        try complete.complete(comp, hsh, ts);
        if (comp.original != null) {
            tkn.raw_maybe = comp.original.?.str;
        }
        mode = .COMPLETING;
        return completing(hsh, tkn, evt, comp);
    }

    switch (buffer) {
        '\x1B' => {
            //const key = try Keys.esc(hsh.input);
            //switch (key) {
            //    .ModKey => {
            //        if (@intFromEnum(key.ModKey.key) == 'Z' and
            //            key.ModKey.mods == .shift)
            //        {
            //            comp.revr();
            //            comp.revr();
            //            mode = try doComplete(hsh, tkn, comp);
            //        }
            //    },
            //    else => {
            //        // There's a bug with mouse in/out triggering this code
            //        mode = .TYPING;
            //        try tkn.maybeDrop();
            //        if (comp.original) |o| {
            //            try tkn.maybeAdd(o.str);
            //            try tkn.maybeCommit(null);
            //        }
            //    },
            //}
        },
        '\x7f' => { // backspace
            if (mode == .COMPENDING) {
                mode = .TYPING;
                return .Redraw;
            }
            comp.searchPop() catch {
                mode = .TYPING;
                comp.raze();
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

    unreachable;
    //_ = simple(hsh, tkn, buffer, comp) catch unreachable;
    //return .Redraw;
}

fn ctrlCode(hsh: *HSH, tkn: *Tokenizer, b: u8, comp: *complete.CompSet) !Event {
    switch (b) {
        0x03 => {
            try hsh.tty.print("^C\n\n", .{});
            tkn.reset();
            return .Prompt;
        },
        0x04 => {
            if (tkn.raw.items.len == 0) {
                try hsh.tty.print("^D\r\nExit caught... Good bye :)\n", .{});
                return .ExitHSH;
            }

            try hsh.tty.print("^D\r\n", .{});
            return .Redraw;
        },
        0x07 => try hsh.tty.print("^bel\r\n", .{}),
        0x08 => try hsh.tty.print("\r\ninput: backspace\r\n", .{}),
        0x09 => |c| { // \t
            // Tab is best effort, it shouldn't be able to crash hsh
            // var titr = tkn.iterator();
            // var tkns = titr.toSlice(hsh.alloc) catch return .Prompt;
            // defer hsh.alloc.free(tkns);

            // if (tkns.len == 0) {
            //     try tkn.consumec(b);
            //     return .Prompt;
            // }
            return completing(hsh, tkn, Keys.Event.ascii(c), comp) catch unreachable;
        },
        0x0A, 0x0D => |nl| {
            //hsh.draw.cursor = 0;
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
                    TokenErr.OpenGroup => try tkn.consumec(nl),
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
        // probably ctrl + bs
        '\x0C' => try hsh.tty.print("^L (reset term)\x1B[J\n", .{}),
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
        else => unreachable,
    }
    return .None;
}

fn event(hsh: *HSH, tkn: *Tokenizer, km: Keys.KeyMod) !Event {
    tkn.err_idx = 0;
    //const to_reset = tkn.err_idx != 0;
    switch (km.evt) {
        .ascii => |a| {
            switch (a) {
                '.' => if (km.mods.alt) log.err("<A-.> not yet implemented\n", .{}),
                else => {},
            }
        },
        .key => |k| {
            switch (k) {
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
                .Left => if (km.mods.ctrl) tkn.cPos(.back) else tkn.cPos(.dec),
                .Right => if (km.mods.ctrl) tkn.cPos(.word) else tkn.cPos(.inc),
                .Home => tkn.cPos(.home),
                .End => tkn.cPos(.end),
                .Delete => tkn.delc(),
                else => {}, // unable to use range on Key :<
            }
            // TODO find a better scope for this call
            hsh.draw.cursor = @truncate(tkn.cadj());
        },
    }
    return .Redraw;
}

fn ascii(hsh: *HSH, tkn: *Tokenizer, buf: u8, comp: *complete.CompSet) !Event {
    switch (buf) {
        0x00...0x1F => return ctrlCode(hsh, tkn, buf, comp),
        ' '...'~' => |b| { // Normal printable ascii
            try tkn.consumec(b);
            try hsh.tty.print("{c}", .{b});
            return if (tkn.cadj() == 0) .None else .Redraw;
        },
        0x7F => { // backspace
            tkn.pop() catch |err| {
                if (err == TokenErr.Empty) return .None;
                return err;
            };
            return .Prompt;
        },
        0x80...0xFF => unreachable,
    }
    return .None;
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

    // No... I don't like this, but I've spent too long staring at it
    // TODO optimize later
    const evt = Keys.translate(buffer[0], hsh.input) catch unreachable;

    const prevm = mode;
    var result: Event = .None;
    switch (mode) {
        .COMPLETING, .COMPENDING => {
            const e = if (evt == .ascii) Keys.Event.ascii(evt.ascii) else evt;
            result = try completing(hsh, tkn, e, comp);
        },
        .TYPING => {
            result = switch (evt) {
                .ascii => |a| try ascii(hsh, tkn, a, comp),
                .keysm => |e| try event(hsh, tkn, e),
                .mouse => |_| return .Redraw,
            };
        },
    }
    defer next = if (prevm == mode) null else .Redraw;
    return next orelse result;
}
