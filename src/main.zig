const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const TTY = TTY_.TTY;
const TTY_ = @import("tty.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TokenErr = @import("tokenizer.zig").Error;
const TokenType = @import("tokenizer.zig").TokenType;
const mem = std.mem;
const os = std.os;
const std = @import("std");
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

test "main" {
    std.testing.refAllDecls(@This());
}

const Event = enum(u8) {
    None = 0,
    Update = 1,
    EnvState = 2,
    Prompt = 4,
    Advice = 8,
    Redraw = 14,
    Exec = 16,
    // ...
    ExitHSH = 254,
    ExpectedError = 255,
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
                            if (tkn.hist_pos == 0) tkn.push_line();
                            tkn.clear();
                            const top = History.readAt(
                                tkn.hist_pos + 1,
                                hsh.history.?,
                                &tkn.raw,
                            ) catch unreachable;
                            if (!top) tkn.hist_pos += 1;
                            tkn.push_hist();
                        },
                        .Down => {
                            if (tkn.hist_pos > 1) {
                                tkn.hist_pos -= 1;
                                tkn.clear();
                                _ = History.readAt(
                                    tkn.hist_pos,
                                    hsh.history.?,
                                    &tkn.raw,
                                ) catch unreachable;
                                tkn.push_hist();
                            } else if (tkn.hist_pos == 1) {
                                tkn.hist_pos -= 1;
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
                .Mouse => {},
            }
            return .Redraw;
        },
        '\x07' => try hsh.tty.print("^bel\r\n", .{}),
        '\x08' => try hsh.tty.print("\r\ninput: backspace\r\n", .{}),
        '\x09' => |b| { // \t
            // Tab is best effort, it shouldn't be able to crash hsh
            _ = tkn.parse() catch {};
            if (!tkn.tab()) {
                try tkn.consumec(b);
                return .Prompt;
            }
            const ctkn = tkn.cursor_token() catch unreachable;
            // Should be unreachable given parse() above
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
            return .Prompt;
        },
        '\x0C' => try hsh.tty.print("^L (reset term)\x1B[J\n", .{}),
        '\x0E' => try hsh.tty.print("shift in\r\n", .{}),
        '\x0F' => try hsh.tty.print("^shift out\r\n", .{}),
        '\x12' => try hsh.tty.print("^R\r\n", .{}), // DC2
        '\x13' => try hsh.tty.print("^S\r\n", .{}), // DC3
        '\x14' => try hsh.tty.print("^T\r\n", .{}), // DC4
        '\x1A' => try hsh.tty.print("^Z\r\n", .{}),
        '\x17' => try tkn.popUntil(), // ^w
        '\x20'...'\x7E' => |b| { // Normal printable ascii
            try tkn.consumec(b);
            return .Prompt;
        },
        '\x7F' => { // backspace
            tkn.pop() catch |err| {
                if (err == TokenErr.Empty) return .None;
                return err;
            };
            return .Prompt;
        },
        '\x03' => {
            try hsh.tty.print("^C\r\n", .{});
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
            const run = tkn.parse() catch |e| {
                switch (e) {
                    TokenErr.OpenGroup => try tkn.consumec(b),
                    TokenErr.ParseErr => {
                        std.debug.print("Parse Error {}\n", .{e});
                        try tkn.dump_parsed(true);
                        try tkn.consumec(b);
                    },
                    else => return .ExpectedError,
                }
                return .Prompt;
            };
            try hsh.tty.print("\r\n", .{});
            Draw.blank(&hsh.draw);
            if (run) {
                //try tkn.dump_parsed(false);
                if (tkn.tokens.items.len > 0) {
                    return .Exec;
                }
                return .Redraw;
            }
        },
        else => |b| {
            try hsh.tty.print("\n\n\runknown char    {} {}\n", .{ b, buffer });
            return .None;
        },
    }
    return .None;
}

fn core(hsh: *HSH, tkn: *Tokenizer, comp: *complete.CompSet) !bool {
    var buffer: [1]u8 = undefined;
    var prev: [1]u8 = undefined;
    defer hsh.draw.rel_offset = 0;
    defer hsh.draw.reset();
    defer Draw.blank(&hsh.draw);
    while (true) {
        hsh.draw.cursor = @truncate(u32, tkn.cadj());
        hsh.spin();
        var jobs = hsh.getBgJobs() catch unreachable;
        defer jobs.clearAndFree();
        try jobsContext(hsh, jobs.items);
        try prompt(hsh, tkn);
        try Draw.render(&hsh.draw);
        hsh.draw.reset();

        // REALLY WISH I COULD BUILD ZIG, ARCH LINUX!!!
        @memcpy(&prev, &buffer);
        const nbyte = try os.read(hsh.tty.tty, &buffer);
        if (nbyte == 0) {
            continue;
        }
        const event = try input(hsh, tkn, buffer[0], prev[0], comp);
        switch (event) {
            .ExitHSH => return false,
            .Exec => return true,
            else => continue,
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var hsh = try HSH.init(a);
    defer hsh.raze();

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
                _ = try hsh.history.?.seekFromEnd(0);
                _ = try hsh.history.?.write(hsh.tkn.raw.items);
                _ = try hsh.history.?.write("\n");
                try hsh.history.?.sync();
                if (!(hsh.tkn.parse() catch continue)) continue;

                switch (hsh.tkn.tokens.items[0].type) {
                    .String => {
                        if (!Exec.executable(&hsh, hsh.tkn.tokens.items[0].cannon())) {
                            std.debug.print("Unable to find {s}\n", .{hsh.tkn.tokens.items[0].cannon()});
                            continue;
                        }

                        // while (forks.popOrNull()) |_| {
                        //     const res = std.os.waitpid(-1, 0);
                        //     const status = res.status >> 8 & 0xff;
                        //     std.debug.print("fork res ({}){}\n", .{ res.pid, status });
                        // }
                        try hsh.tty.pushOrig();
                        var jobs = exec(&hsh, &hsh.tkn) catch |err| {
                            if (err == Exec.Error.ExeNotFound) {
                                std.debug.print("exe pipe error {}\n", .{err});
                            }
                            std.debug.print("Exec error {}\n", .{err});
                            unreachable;
                        };
                        hsh.tkn.reset();
                        _ = try hsh.newJob(jobs.pop());
                        while (jobs.popOrNull()) |j| {
                            _ = try hsh.newJob(j);
                        }
                        jobs.clearAndFree();
                    },
                    .Builtin => {
                        const bi_func = Builtins.strExec(hsh.tkn.tokens.items[0].cannon());
                        bi_func(&hsh, hsh.tkn.tokens.items) catch |err| {
                            std.debug.print("builtin error {}\n", .{err});
                        };
                        hsh.tkn.reset();
                        continue;
                    },
                    else => continue,
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
