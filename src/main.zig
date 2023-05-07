const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const TTY = TTY_.TTY;
const TTY_ = @import("tty.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TokenType = @import("tokenizer.zig").TokenType;
const mem = std.mem;
const os = std.os;
const std = @import("std");
const tty_codes = TTY_.OpCodes;
const Draw = @import("draw.zig");
const Drawable = Draw.Drawable;
const printAfter = Draw.printAfter;
const prompt = @import("prompt.zig").prompt;
const HSH = @import("hsh.zig").HSH;
const complete = @import("completion.zig");
const Builtins = @import("builtins.zig");
const Keys = @import("keys.zig");
const Exec = @import("exec.zig");
const exec = Exec.exec;

var term_resized: bool = false;

test {
    std.testing.refAllDecls(@This());
}

pub fn loop(hsh: *HSH, tkn: *Tokenizer) !bool {
    var buffer: [1]u8 = undefined;
    var prev: [1]u8 = undefined;
    while (true) {
        if (term_resized) {
            hsh.draw.term_size = hsh.tty.geom() catch unreachable;
            term_resized = false;
        }
        hsh.draw.cursor = @truncate(u32, tkn.cadj());
        try prompt(hsh, tkn);
        try Draw.render(&hsh.draw);

        // REALLY WISH I COULD BUILD ZIG, ARCH LINUX!!!
        //@memcpy(prev, buffer);
        prev[0] = buffer[0];
        const nbyte = try os.read(hsh.tty.tty, &buffer);
        if (nbyte == 0) {
            continue;
        }

        // I no longer like this way of tokenization. I'd like to generate
        // Tokens as an n=2 state machine at time of keypress. It might actually
        // be required to unbreak a bug in history.
        switch (buffer[0]) {
            '\x1B' => {
                const to_reset = tkn.err_idx != 0;
                tkn.err_idx = 0;
                switch (try Keys.esc(hsh)) {
                    .Unknown => if (!to_reset) try printAfter(&hsh.draw, "Unknown esc --", .{}),
                    .Key => |a| {
                        switch (a) {
                            .Up => {
                                if (tkn.hist_pos == 0) tkn.push_line();
                                tkn.clear();
                                const top = read_history(tkn.hist_pos + 1, hsh.history.?, &tkn.raw) catch unreachable;
                                if (!top) tkn.hist_pos += 1;
                                tkn.push_hist();
                                //while (!top and mem.eql(u8, tkn.raw.items, tkn.hist_z.?.items)) {
                                //    tkn.hist_pos += 1;
                                //    top = read_history(tkn.hist_pos + 1, history, &tkn.raw) catch unreachable;
                                //}
                            },
                            .Down => {
                                if (tkn.hist_pos > 1) {
                                    tkn.hist_pos -= 1;
                                    tkn.clear();
                                    _ = read_history(tkn.hist_pos, hsh.history.?, &tkn.raw) catch unreachable;
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
                }
            },
            '\x07' => try hsh.tty.print("^bel\r\n", .{}),
            '\x08' => try hsh.tty.print("\r\ninput: backspace\r\n", .{}),
            '\x09' => |b| {
                // Tab is best effort, it shouldn't be able to crash hsh
                _ = tkn.parse() catch continue;
                if (!tkn.tab()) {
                    try tkn.consumec(b);
                    continue;
                }
                const ctkn = tkn.cursor_token() catch continue;
                var comp = &complete.compset;
                if (b != prev[0]) {
                    _ = try complete.complete(hsh, ctkn);
                    if (comp.list.items.len == 2) {
                        // original and single, complete now
                        comp.index = 1;
                    } else {
                        // multiple options, complete original first
                        comp.index = 0;
                    }
                    // for (comp.list.items) |c| std.debug.print("comp {}\n", .{c});
                } else {
                    comp.index = (comp.index + 1) % comp.list.items.len;
                }
                if (comp.list.items.len > 0) {
                    const new = comp.list.items[comp.index].str;
                    try tkn.replaceToken(ctkn, new);
                }
                // TODO free memory
            },
            '\x0E' => try hsh.tty.print("shift in\r\n", .{}),
            '\x0F' => try hsh.tty.print("^shift out\r\n", .{}),
            '\x12' => try hsh.tty.print("^R\r\n", .{}), // DC2
            '\x13' => try hsh.tty.print("^R\r\n", .{}), // DC3
            '\x14' => try hsh.tty.print("^T\r\n", .{}), // DC4
            '\x1A' => try hsh.tty.print("^Z\r\n", .{}),
            '\x17' => try tkn.popUntil(),
            '\x20'...'\x7E' => |b| {
                // Normal printable ascii
                try tkn.consumec(b);
            },
            '\x7F' => try tkn.pop(), // backspace
            '\x03' => {
                try hsh.tty.print("^C\r\n", .{});
                tkn.reset();
                // if (tn.raw.items.len > 0) {
                // } else {
                //     return false;
                //     try tty.print("\r\nExit caught... Bye ()\r\n", .{});
                // }
            },
            '\x04' => |b| {
                try hsh.tty.print("^D\r\n", .{});
                try hsh.tty.print("\r\nExit caught... Bye ({})\r\n", .{b});
                return false;
            },
            '\n', '\r' => |b| {
                hsh.draw.cursor = 0;
                try hsh.tty.print("\r\n", .{});
                const run = tkn.parse() catch |e| {
                    std.debug.print("Parse Error {}\n", .{e});
                    try tkn.dump_parsed(true);
                    try tkn.consumec(b);
                    continue;
                };
                if (run) {
                    try tkn.dump_parsed(false);
                    if (tkn.tokens.items.len > 0) {
                        return true;
                    }
                    return false;
                }
            },
            else => |b| {
                try hsh.tty.print("\n\n\runknown char    {} {s}\n", .{ b, buffer });
            },
        }
    }
}

pub fn sig_cb(sig: c_int, _: *const os.siginfo_t, _: ?*const anyopaque) callconv(.C) void {
    if (sig != os.SIG.WINCH) unreachable;
    //std.debug.print("{}\n", .{info});
    term_resized = true;
}

pub fn signals() !void {
    // zsh blocks and unblocks winch signals during most processing, collecting
    // them only when needed. It's likely something we should do as well
    try os.sigaction(os.SIG.WINCH, &os.Sigaction{
        .handler = .{ .sigaction = sig_cb },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);
}

fn read_history(cnt: usize, hist: std.fs.File, buffer: *ArrayList(u8)) !bool {
    var row = cnt;
    var len: usize = try hist.getEndPos();
    try hist.seekFromEnd(-1);
    var pos = len;
    var buf: [1]u8 = undefined;
    while (row > 0 and pos > 0) {
        hist.seekBy(-2) catch {
            hist.seekBy(-1) catch break;
            break;
        };
        _ = try hist.read(&buf);
        if (buf[0] == '\n') row -= 1;
        pos = try hist.getPos();
    }
    pos = try hist.getPos();
    try hist.reader().readUntilDelimiterArrayList(buffer, '\n', 1 << 16);
    return pos == 0;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t = Tokenizer.init(a);

    var hsh = try HSH.init(a);
    defer hsh.raze();

    _ = try complete.init(&hsh);

    try signals();

    hsh.tty = TTY.init() catch unreachable;
    defer hsh.tty.raze();
    hsh.draw = Drawable.init(&hsh) catch unreachable;
    defer hsh.draw.raze();
    hsh.draw.term_size = hsh.tty.geom() catch unreachable;
    hsh.input = hsh.tty.tty;

    while (true) {
        if (loop(&hsh, &t)) |l| {
            if (l) {
                _ = try hsh.history.?.seekFromEnd(0);
                _ = try hsh.history.?.write(t.raw.items);
                _ = try hsh.history.?.write("\n");
                try hsh.history.?.sync();
                if (!(t.parse() catch continue)) continue;

                switch (t.tokens.items[0].type) {
                    .String => {
                        if (!Exec.executable(&hsh, t.tokens.items[0].cannon())) continue;
                        exec(&hsh, &t) catch |err| {
                            if (err == Exec.Error.NotFound) std.os.exit(99);
                            unreachable;
                        };
                        t.reset();
                    },
                    .Builtin => {
                        const bi_func = Builtins.strExec(t.tokens.items[0].cannon());
                        bi_func(&hsh, t.tokens.items) catch |err| {
                            std.debug.print("builtin error {}\n", .{err});
                        };
                        t.reset();
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
    TTY_.current_tty.?.raze();
    std.builtin.default_panic(msg, trace, retaddr);
}
