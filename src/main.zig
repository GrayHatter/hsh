const std = @import("std");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const TTY = TTY_.TTY;
const TTY_ = @import("tty.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TokenErr = @import("tokenizer.zig").Error;
const TokenKind = @import("tokenizer.zig").TokenKind;
const parser = @import("parse.zig");
const Parser = parser.Parser;
const mem = std.mem;
const os = std.os;
const tty_codes = TTY_.OpCodes;
const Draw = @import("draw.zig");
const Drawable = Draw.Drawable;
const printAfter = Draw.printAfter;
const prompt = @import("prompt.zig").prompt;
const jobsContext = @import("prompt.zig").jobsContext;
const Context = @import("context.zig");
const HSH = @import("hsh.zig").HSH;
const complete = @import("completion.zig");
const Builtins = @import("builtins.zig");
const Keys = @import("keys.zig");
const Exec = @import("exec.zig");
const exec = Exec.exec;
const Signals = @import("signals.zig");
const History = @import("history.zig");
const layoutTable = @import("draw/layout.zig").layoutTable;
const jobs = @import("jobs.zig");

test "main" {
    std.testing.refAllDecls(@This());
}

const Event = enum(u8) {
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

fn input(hsh: *HSH, tkn: *Tokenizer, buffer: u8, prev: u8, comp_: *complete.CompSet) !Event {
    var comp = comp_;
    // I no longer like this way of tokenization. I'd like to generate
    // Tokens as an n=2 state machine at time of keypress. It might actually
    // be required to unbreak a bug in history.
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
                            if (hist.cnt == 0) tkn.push_line();
                            tkn.clear();
                            hist.cnt += 1;
                            _ = hist.readAt(&tkn.raw) catch unreachable;
                            tkn.push_hist();
                        },
                        .Down => {
                            var hist = &(hsh.hist orelse return .None);
                            if (hist.cnt > 1) {
                                hist.cnt -= 1;
                                tkn.clear();
                                _ = hist.readAt(&tkn.raw) catch unreachable;
                                tkn.push_hist();
                            } else if (hist.cnt == 1) {
                                hist.cnt -= 1;
                                tkn.pop_line();
                            } else {}
                        },
                        .Left => tkn.cinc(-1),
                        .Right => tkn.cinc(1),
                        .Home => tkn.cinc(-@intCast(isize, tkn.raw.items.len)),
                        .End => tkn.cinc(@intCast(isize, tkn.raw.items.len)),
                        else => {}, // unable to use range on Key :<
                    }
                },
                .ModKey => |mk| {
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
        '\x09' => |b| { // \t
            // Tab is best effort, it shouldn't be able to crash hsh
            var tkns = tkn.tokenize() catch return .Prompt;
            _ = Parser.parse(&tkn.alloc, tkns, false) catch return .Prompt;

            if (!tkn.tab()) {
                try tkn.consumec(b);
                return .Prompt;
            }
            const ctkn = tkn.cursor_token() catch unreachable;
            // Should be unreachable given tokenize() above
            var target: *const complete.CompOption = undefined;
            if (b != prev) {
                comp = try complete.complete(hsh, ctkn);
                if (comp.known()) {
                    // original and single, complete now
                    target = comp.first();
                    try tkn.replaceToken(ctkn, target);
                    return .Prompt;
                }
                //for (comp.list.items) |c| std.debug.print("comp {}\n", .{c});
            } else {
                var l = comp.optList();
                defer l.clearAndFree();
                var table = try layoutTable(hsh.alloc, l.items, @intCast(u32, hsh.draw.term_size.x));
                // TODO draw warning after if unable to tab complete
                defer hsh.alloc.free(table);
                defer hsh.alloc.free(@ptrCast([]Draw.Lexeme, table[0].sibling));
                for (table, 0..) |r, ri| {
                    for (r.sibling, 0..) |*lex, li| {
                        const i = ri * table[0].sibling.len + li;
                        switch (comp.list.items[i].kind) {
                            .FileSystem => |fs| {
                                if (fs == .Dir) {
                                    lex.*.fg = .Blue;
                                    lex.*.attr = if (i == comp.index) .ReverseBold else .Bold;
                                } else {
                                    lex.*.attr = if (i == comp.index) .Reverse else .Reset;
                                }
                            },
                            else => lex.*.attr = if (i == comp.index) .Reverse else .Reset,
                        }
                    }
                    Draw.drawAfter(&hsh.draw, r) catch unreachable;
                    for (r.sibling) |s| {
                        hsh.alloc.free(s.char);
                    }
                }
            }

            target = comp.next();
            try tkn.replaceToken(ctkn, target);
            return .Redraw;
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
            const tkns = tkn.tokenize() catch |e| {
                switch (e) {
                    TokenErr.Empty => {
                        try hsh.tty.print("\n", .{});
                        return .None;
                    },
                    TokenErr.OpenGroup => try tkn.consumec(b),
                    TokenErr.TokenizeFailed => {
                        std.debug.print("tokenize Error {}\n", .{e});
                        try tkn.dump_tokens(true);
                        try tkn.consumec(b);
                    },
                    else => return .ExpectedError,
                }
                return .Prompt;
            };
            var run = Parser.parse(&tkn.alloc, tkns, false);
            //Draw.clearCtx(&hsh.draw);
            if (run) |titr| {
                if (titr.tokens.len > 0) return .Exec;
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

fn core(hsh: *HSH, tkn: *Tokenizer, comp: *complete.CompSet) !bool {
    defer hsh.tty.print("\n", .{}) catch {};
    defer hsh.draw.reset();
    var buffer: [1]u8 = undefined;
    var prev: [1]u8 = undefined;

    while (true) {
        hsh.draw.cursor = @truncate(u32, tkn.cadj());
        hsh.spin();

        //Draw.clearCtx(&hsh.draw);

        hsh.draw.clear();
        var bgjobs = jobs.getBg(hsh.alloc) catch unreachable;
        try jobsContext(hsh, bgjobs.items);
        bgjobs.clearAndFree();
        try prompt(hsh, tkn);
        try Draw.render(&hsh.draw);

        // REALLY WISH I COULD BUILD ZIG, ARCH LINUX!!!
        @memcpy(&prev, &buffer);
        const nbyte = try os.read(hsh.tty.tty, &buffer);
        if (nbyte == 0) {
            continue;
        }
        const event = try input(hsh, tkn, buffer[0], prev[0], comp);
        switch (event) {
            .None => continue,
            .ExitHSH => return false,
            .Exec => return true,
            .Redraw, .Prompt, .Update => {
                Draw.clearCtx(&hsh.draw);
                try Draw.render(&hsh.draw);

                //try prompt(hsh, tkn);
                continue;
            },
            .Advice => {},
            .HSHIntern => return true,
            .ExpectedError => return true,
            .EnvState => {},
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var hsh = try HSH.init(a);
    defer hsh.raze();

    var args = std.process.args();
    while (args.next()) |arg| {
        std.debug.print("arg: {s}\n", .{arg});
    }

    hsh.tkn = Tokenizer.init(a);
    defer hsh.tkn.raze();

    var comp: *complete.CompSet = try complete.init(&hsh);

    try Signals.init(hsh.alloc, &hsh.sig_queue);

    hsh.tty = try TTY.init(a);
    defer hsh.tty.raze();

    const pwn_tty = true;
    if (pwn_tty) {
        // Look at me, I'm the captain now!
        hsh.tty.pwnTTY();
    }

    hsh.draw = Drawable.init(&hsh) catch unreachable;
    defer hsh.draw.raze();
    hsh.draw.term_size = hsh.tty.geom() catch unreachable;
    hsh.input = hsh.tty.tty;

    while (true) {
        if (core(&hsh, &hsh.tkn, comp)) |l| {
            if (l) {
                var tokens = hsh.tkn.tokenize() catch continue;
                if (tokens.len == 0) continue;
                var titr = Parser.parse(&hsh.tkn.alloc, tokens, false) catch continue;
                if (false)
                    while (titr.next()) |t| std.debug.print("{}\n", .{t});

                titr.restart();
                if (hsh.hist) |*hist| try hist.push(hsh.tkn.raw.items);
                if (titr.peek()) |peek| {
                    switch (peek.type) {
                        .String => {
                            if (!Exec.executable(&hsh, peek.cannon())) {
                                std.debug.print("Unable to find {s}\n", .{peek.cannon()});
                                continue;
                            }

                            try hsh.tty.pushOrig();
                            var exec_jobs = exec(&hsh, &titr) catch |err| {
                                if (err == Exec.Error.ExeNotFound) {
                                    std.debug.print("exe pipe error {}\n", .{err});
                                }
                                std.debug.print("Exec error {}\n", .{err});
                                unreachable;
                            };
                            defer exec_jobs.clearAndFree();
                            hsh.tkn.reset();
                            _ = try jobs.add(exec_jobs.pop());
                            while (exec_jobs.popOrNull()) |j| {
                                _ = try jobs.add(j);
                            }
                        },
                        .Builtin => {
                            hsh.draw.reset();
                            const bi_func = Builtins.strExec(peek.cannon());
                            bi_func(&hsh, &titr) catch |err| {
                                std.debug.print("builtin error {}\n", .{err});
                            };
                            hsh.tkn.reset();
                            continue;
                        },
                        else => continue,
                    }
                }
            } else {
                break;
            }
        } else |err| {
            std.debug.print("unexpected error {}\n", .{err});
            unreachable;
        }
    }
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, retaddr: ?usize) noreturn {
    @setCold(true);
    std.debug.print("Panic reached... your TTY is likely broken now.\n\n...sorry about that!\n", .{});
    if (TTY_.current_tty) |*t| {
        t.raze();
    }
    std.builtin.default_panic(msg, trace, retaddr);
}
