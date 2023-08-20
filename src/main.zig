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
    defer hsh.draw.reset();
    //try Context.update(hsh, &[_]Context.Contexts{.git});
    var comp = try complete.init(hsh);
    defer comp.raze();

    var redraw = true;

    while (true) {
        hsh.draw.clear();
        var bgjobs = jobs.getBg(hsh.alloc) catch unreachable;
        try jobsContext(hsh, bgjobs.items);
        //try ctxContext(hsh, try Context.fetch(hsh, .git));
        bgjobs.clearAndFree();

        redraw = hsh.spin() or redraw;
        if (redraw) {
            try prompt(hsh, tkn);
            try Draw.render(&hsh.draw);
            redraw = false;
        }
        const event = if (hsh.tty.is_tty) try input.do(hsh, &comp) else try input.nonInteractive(hsh, &comp);
        switch (event) {
            .None => continue,
            .Redraw, .Prompt, .Update => {
                Draw.clearCtx(&hsh.draw);
                try Draw.render(&hsh.draw);

                redraw = true;
                continue;
            },
            .Exec => return true,
            .ExitHSH => return false,
            .ExpectedError => return true,
            .HSHIntern => return true,
            .Advice => {},
            .EnvState => {},
            .Signaled => redraw = true,
        }
    }
}

fn usage() void {
    std.debug.print("hsh usage:\n", .{});
}

fn readArgs() ?u8 {
    var args = std.process.args();
    _ = args.next(); // argv[0] bin name
    while (args.next()) |arg| {
        log.info("arg: {s}\n", .{arg});
        if (std.mem.eql(u8, "debug", arg)) {
            log.verbosity = .debug;
        } else if (std.mem.eql(u8, "debug-trace", arg)) {
            log.verbosity = .trace;
        } else if (std.mem.eql(u8, "--version", arg) or std.mem.eql(u8, "version", arg)) {
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
        } else {
            log.warn("unknown arg: {s}\n", .{arg});
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
    try hsh.tty.setRaw();
    // Look at me, I'm the captain now!
    hsh.tty.pwnTTY();

    hsh.draw = Drawable.init(&hsh) catch unreachable;
    defer hsh.draw.raze();
    hsh.draw.term_size = hsh.tty.geom() catch unreachable;

    var inerr = false;
    root: while (true) {
        if (core(&hsh)) |actionable| {
            inerr = false;
            if (actionable) {
                if (hsh.tkn.raw.items.len == 0) continue;
                // debugging data

                var titr = hsh.tkn.iterator();
                var tokens = try titr.toSlice(hsh.alloc);
                defer hsh.alloc.free(tokens);

                // var pitr = Parser.parse(&hsh.tkn.alloc, tokens) catch continue;
                // while (pitr.next()) |t| log.debug("{}\n", .{t});
                // pitr.close();

                if (hsh.hist) |*hist| try hist.push(hsh.tkn.raw.items);
                var itr = hsh.tkn.iterator();
                while (itr.next()) |exe_t| {
                    // TODO add a "list" version of Exec.executable() for this code
                    var ts = [_]tokenizer.Token{exe_t.*};
                    var ps = try Parser.parse(&hsh.tkn.alloc, &ts);
                    const first = ps.first().cannon();
                    defer ps.close();
                    if (!Exec.executable(&hsh, first)) {
                        const estr = "[ Unable to find {s} ]";
                        const size = first.len + estr.len;
                        var fbuf: []u8 = hsh.alloc.alloc(u8, size) catch @panic("memory");
                        defer hsh.alloc.free(fbuf);
                        const str = try std.fmt.bufPrint(fbuf, estr, .{first});
                        try Draw.drawAfter(&hsh.draw, Draw.LexTree{
                            .lex = Draw.Lexeme{ .char = str, .style = .{ .attr = .bold, .fg = .red } },
                        });
                        try Draw.render(&hsh.draw);

                        continue :root;
                    }
                    while (itr.nextExec()) |_| {}
                    _ = itr.next();
                }
                try Draw.newLine(&hsh.draw);
                exec(&hsh, &itr) catch |err| {
                    log.err("Exec error {}\n", .{err});
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

    log.err("Panic reached... your TTY is likely broken now.\n\n      ...sorry about that!\n\n", .{});
    std.debug.print("\n\r\x1B[J", .{});
    std.builtin.default_panic(msg, trace, retaddr);
    if (TTY_.current_tty) |*t| {
        TTY_.current_tty = null;
        t.raze();
    }
    std.time.sleep(1000 * 1000 * 1000 * 30);
}
