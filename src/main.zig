const std = @import("std");
const hsh_build = @import("hsh_build");
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const TTY = TTY_.TTY;
const TTY_ = @import("tty.zig");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const TokenErr = tokenizer.Error;
const TokenKind = tokenizer.Kind;
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
const ctxContext = @import("prompt.zig").ctxContext;
const Context = @import("context.zig");
const HSH = @import("hsh.zig").HSH;
const complete = @import("completion.zig");
const Keys = @import("keys.zig");
const Exec = @import("exec.zig");
const exec = Exec.exec;
const Signals = @import("signals.zig");
const History = @import("history.zig");
const jobs = @import("jobs.zig");
const log = @import("log");

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
                            if (tkn.hist_z) |hz| {
                                _ = hist.readAtFiltered(&tkn.raw, hz.items) catch unreachable;
                            } else {
                                _ = hist.readAtFiltered(&tkn.raw, tkn.raw.items) catch unreachable;
                            }
                            tkn.push_hist();
                        },
                        .Down => {
                            var hist = &(hsh.hist orelse return .None);
                            if (hist.cnt > 1) {
                                hist.cnt -= 1;
                                tkn.clear();
                                if (tkn.hist_z) |hz| {
                                    _ = hist.readAtFiltered(&tkn.raw, hz.items) catch unreachable;
                                } else {
                                    _ = hist.readAtFiltered(&tkn.raw, tkn.raw.items) catch unreachable;
                                }
                                tkn.push_hist();
                            } else if (hist.cnt == 1) {
                                hist.cnt -= 1;
                                tkn.pop_line();
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
                                    const key: u8 = @enumToInt(k);
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
        '\x09' => |b| { // \t
            // Tab is best effort, it shouldn't be able to crash hsh
            var titr = tkn.iterator();
            var tkns = titr.toSlice(hsh.alloc) catch return .Prompt;
            defer hsh.alloc.free(tkns);
            _ = Parser.parse(&tkn.alloc, tkns) catch return .Prompt;

            if (tkn.raw.items.len == 0) {
                try tkn.consumec(b);
                return .Prompt;
            }
            const ctkn = tkn.cursor_token() catch unreachable;
            // Should be unreachable given tokenize() above
            var target: *const complete.CompOption = undefined;
            if (b != prev) {
                comp = try complete.complete(hsh, &ctkn);
                if (comp.known()) |only| {
                    // original and single, complete now
                    try tkn.replaceToken(only);
                    return .Prompt;
                }
                //for (comp.list.items) |c| std.debug.print("comp {}\n", .{c});
            } else {
                try comp.drawAll(&hsh.draw, @intCast(u32, hsh.draw.term_size.x));
            }

            target = comp.next();
            try tkn.replaceToken(target);
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

fn read(fd: std.os.fd_t, buf: []u8) !usize {
    const rc = std.os.linux.read(fd, buf.ptr, buf.len);
    switch (std.os.linux.getErrno(rc)) {
        .SUCCESS => return @intCast(usize, rc),
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

fn core(hsh: *HSH, tkn: *Tokenizer, comp: *complete.CompSet) !bool {
    defer hsh.tty.print("\n", .{}) catch {};
    defer hsh.draw.reset();
    var buffer: [1]u8 = undefined;
    var prev: [1]u8 = undefined;
    //try Context.update(hsh, &[_]Context.Contexts{.git});

    while (true) {
        hsh.draw.cursor = @truncate(u32, tkn.cadj());
        hsh.spin();

        //Draw.clearCtx(&hsh.draw);

        hsh.draw.clear();
        var bgjobs = jobs.getBg(hsh.alloc) catch unreachable;
        try jobsContext(hsh, bgjobs.items);
        //try ctxContext(hsh, try Context.fetch(hsh, .git));
        bgjobs.clearAndFree();
        try prompt(hsh, tkn);
        try Draw.render(&hsh.draw);

        // REALLY WISH I COULD BUILD ZIG, ARCH LINUX!!!
        @memcpy(&prev, &buffer);
        const nbyte = try read(hsh.input, &buffer);
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

fn usage() void {
    std.debug.print("hsh usage:\n", .{});
}

fn readArgs() ?u8 {
    var args = std.process.args();
    while (args.next()) |arg| {
        log.info("arg: {s}\n", .{arg});
        if (std.mem.eql(u8, "debug", arg)) {
            log.verbosity = .debug;
        } else if (std.mem.eql(u8, "debug-trace", arg)) {
            log.verbosity = .trace;
        } else if (std.mem.eql(u8, "--version", arg)) {
            std.debug.print("version: {}\n", .{hsh_build.version});
            return 0;
        } else if (std.mem.eql(u8, "--help", arg)) {
            usage();
            return 0;
        } else if (std.mem.eql(u8, "--config", arg)) {
            // IFF --config=file use `file` exclusively for instance
            // ELSE print config search locations
            // and print the config file[s] that would be sourced or updated
            @panic("Not Implemented");
        }
    }
    return null;
}

pub fn main() !void {
    if (readArgs()) |err| {
        std.process.exit(err);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.detectLeaks()) std.debug.print("Leaked\n", .{});
        std.time.sleep(1000 * 1000 * 1000);
    }
    var a = gpa.allocator();

    var hsh = try HSH.init(a);
    defer hsh.raze();
    hsh.tkn = Tokenizer.init(a);
    defer hsh.tkn.raze();

    var comp: *complete.CompSet = try complete.init(&hsh);
    defer comp.raze();

    try Signals.init(a);
    defer Signals.raze();

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
    hsh.input = hsh.tty.dev;

    var inerr = false;
    root: while (true) {
        if (core(&hsh, &hsh.tkn, comp)) |l| {
            inerr = false;
            if (l) {
                if (hsh.tkn.raw.items.len == 0) continue;
                // debugging data

                var titr = hsh.tkn.iterator();
                var tokens = try titr.toSlice(hsh.alloc);
                defer hsh.alloc.free(tokens);
                var pitr = Parser.parse(&hsh.tkn.alloc, tokens) catch continue;
                while (pitr.next()) |t| log.debug("{}\n", .{t});
                pitr.restart();

                if (hsh.hist) |*hist| try hist.push(hsh.tkn.raw.items);
                var itr = hsh.tkn.iterator();
                while (itr.next()) |exe_t| {
                    // TODO add a "list" version of Exec.executable() for this code
                    var ts = [_]tokenizer.Token{exe_t.*};
                    var ps = try Parser.parse(&hsh.tkn.alloc, &ts);
                    const first = ps.first().cannon();
                    defer ps.close();
                    if (!Exec.executable(&hsh, first)) {
                        std.debug.print("Unable to find {s}\n", .{first});
                        continue :root;
                    }
                    while (itr.nextExec()) |_| {}
                    _ = itr.next();
                }

                exec(&hsh, &itr) catch |err| {
                    if (err == Exec.Error.ExeNotFound) {
                        std.debug.print("exe pipe error {}\n", .{err});
                    }
                    std.debug.print("Exec error {}\n", .{err});
                    unreachable;
                };
                hsh.tkn.reset();
                continue;
            } else {
                break;
            }
        } else |err| {
            switch (err) {
                error.Interupted => log.err("intr\n", .{}),
                error.InputOutput => {
                    hsh.tty.waitForFg();
                    //@breakpoint();
                    log.err("{} crash in main\n", .{err});
                    if (!inerr) {
                        inerr = true;
                        continue;
                    }
                    @panic("too many errors");
                },
                else => {
                    std.debug.print("unexpected error {}\n", .{err});
                    unreachable;
                },
            }
        }
    }
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, retaddr: ?usize) noreturn {
    @setCold(true);

    std.debug.print("Panic reached... your TTY is likely broken now.\n\n...sorry about that!\n", .{});
    if (TTY_.current_tty) |*t| {
        TTY_.current_tty = null;
        t.raze();
    }
    std.builtin.default_panic(msg, trace, retaddr);
    std.time.sleep(1000 * 1000 * 1000 * 30);
}
