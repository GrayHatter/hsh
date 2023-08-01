const std = @import("std");
const log = @import("log");
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
const input = @import("input.zig");

test "main" {
    std.testing.refAllDecls(@This());
}

fn core(hsh: *HSH) !bool {
    var tkn = &hsh.tkn;
    defer hsh.tty.print("\n", .{}) catch {};
    defer hsh.draw.reset();
    var buffer: [1]u8 = undefined;
    var mode: input.Mode = .typing;
    //try Context.update(hsh, &[_]Context.Contexts{.git});
    var comp = try complete.init(hsh);
    defer comp.raze();

    while (true) {
        hsh.draw.cursor = @truncate(tkn.cadj());
        hsh.spin();

        //Draw.clearCtx(&hsh.draw);

        hsh.draw.clear();
        var bgjobs = jobs.getBg(hsh.alloc) catch unreachable;
        try jobsContext(hsh, bgjobs.items);
        //try ctxContext(hsh, try Context.fetch(hsh, .git));
        bgjobs.clearAndFree();
        try prompt(hsh, tkn);
        try Draw.render(&hsh.draw);

        const nbyte = try input.read(hsh.input, &buffer);
        if (nbyte == 0) {
            continue;
        }
        const event = try input.input(hsh, tkn, buffer[0], &mode, &comp);
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
        if (gpa.detectLeaks()) {
            std.debug.print("Leaked\n", .{});
            std.time.sleep(6 * 1000 * 1000 * 1000);
        }
    }
    var a = gpa.allocator();

    var hsh = try HSH.init(a);
    defer hsh.raze();
    hsh.tkn = Tokenizer.init(a);
    defer hsh.tkn.raze();

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
        if (core(&hsh)) |l| {
            inerr = false;
            if (l) {
                if (hsh.tkn.raw.items.len == 0) continue;
                // debugging data

                var titr = hsh.tkn.iterator();
                var tokens = try titr.toSlice(hsh.alloc);
                defer hsh.alloc.free(tokens);
                var pitr = Parser.parse(&hsh.tkn.alloc, tokens) catch continue;
                while (pitr.next()) |t| log.debug("{}\n", .{t});
                pitr.close();

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
                hsh.tkn.exec();
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
