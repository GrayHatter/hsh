fn core(hsh: *Hsh, a: Allocator, io: Io) ![]u8 {
    var array_alloc = std.heap.ArenaAllocator.init(a);
    defer array_alloc.deinit();
    const alloc = array_alloc.allocator();
    var line = try Line.init(hsh, alloc, io, .{ .interactive = hsh.tty.dev != null });

    defer hsh.draw.reset();
    //try Context.update(hsh, &[_]Context.Contexts{.git});

    var redraw = true;
    // TODO drop hsh

    while (true) {
        hsh.draw.clear();
        redraw = hsh.spin(a, io) or redraw;

        if (redraw) {
            try hsh.prompt.render(&hsh.draw, line.peek());
            try hsh.draw.render();
            redraw = false;
        }

        // TOOD fixme this is the wrong place for the arena
        return try a.dupe(u8, try line.do(a, io));
    }
}

fn usage() void {
    std.debug.print("hsh usage:\n", .{});
}

/// No, I don't really like this hack either, but autoformatting :/
/// return 255 == unknown
/// return   1 == exec error
fn execTacC(mini: std.process.Init.Minimal, io: Io) u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    var hsh = Hsh.init(mini.environ, a, io) catch return 255;
    defer hsh.razeStateless(a, io);
    hsh.tty = Tty.init(a, io) catch return 255;
    defer hsh.tty.raze(a);
    var args = mini.args.iterate();

    var tkzr: Tokenizer = .{};
    while (args.next()) |arg| {
        tkzr.consumeChar(' ') catch unreachable;
        tkzr.consumeSlice(arg);
    }
    const str = tkzr.getSlice();
    Exec.exec(str, &hsh, a, io) catch |err| {
        log.err("-c error [{}]\n", .{err});
        return 1;
    };

    for (hsh.jobs.jobs.items) |job| {
        if (job.exit_code != null and job.exit_code.? > 0) {
            return job.exit_code.?;
        }
    }
    return 0;
}

fn readArgs(mini: std.process.Init.Minimal, io: Io) ?u8 {
    var args = mini.args.iterate();
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
        } else if (std.mem.eql(u8, "-c", arg)) {
            return execTacC(mini, io);
        } else {
            log.warn("unknown arg: {s}\n", .{arg});
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    if (readArgs(init.minimal, io)) |err| {
        std.process.exit(err);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.detectLeaks() > 0) {
        std.debug.print("Leaked\n", .{});
        Io.sleep(io, .fromSeconds(6), .real) catch unreachable;
    };
    const a = gpa.allocator();

    var hsh = try Hsh.init(init.minimal.environ, a, io);
    defer hsh.raze(a, io);

    hsh.prompt.cwd = &hsh.fs.cwd.name;
    Fs.g_fs = &hsh.fs;

    try Signals.init(a);
    defer Signals.raze();

    hsh.tty = try Tty.init(a, io);
    defer hsh.tty.raze(a);

    try hsh.tty.setRaw();
    // Look at me, I'm the captain now!
    try hsh.tty.pwnTTY();

    hsh.draw = Draw.init(a, &hsh) catch unreachable;
    defer hsh.draw.raze(a);
    hsh.draw.term_size = hsh.tty.geom() catch unreachable;

    var inerr = false;
    while (true) {
        if (core(&hsh, a, io)) |str| {
            inerr = false;
            if (str.len == 0) {
                std.debug.print("\n goodbye :) \n", .{});
                break;
            }
            defer a.free(str);
            std.debug.assert(str.len != 0);

            //var itr = hsh.tkn.iterator();
            try hsh.draw.writer.writeByte('\n');
            Exec.exec(str, &hsh, a, io) catch |err| switch (err) {
                error.ExeNotFound => {
                    const first = Exec.execFromInput(str, a, io) catch @panic("memory");
                    defer a.free(first);
                    hsh.draw.drawAfter(&[3]Draw.Lexeme{
                        .styled("[ Unable to find ", .red_bold),
                        .styled(first, .red_bold),
                        .styled(" ]", .red_bold),
                    });
                    try hsh.draw.render();
                },
                else => {
                    log.err("Exec error {}\n", .{err});
                    unreachable;
                },
            };
            continue;
        } else |err| {
            switch (err) {
                error.Io => {
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

// TODO determine if hsh still needs a custom panic the answer is probably yes,
// to capture/save state, but that's a much later TODO
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    @branchHint(.cold);
    log.err(
        \\Panic reached... your TTY is likely broken now.
        \\
        \\     ...sorry about that!
        \\
        \\
    , .{});
    std.debug.print("\n\r\x1B[J", .{});
    std.debug.defaultPanic(msg, addr);
    Tty.current().panic();
    @trap();
}

test "main" {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const hsh_build = @import("hsh_build");
const Io = std.Io;

const log = @import("log.zig");
const Tty = @import("tty.zig");
const Draw = @import("draw.zig");
const Prompt = @import("Prompt.zig");
const Context = @import("context.zig");
const Hsh = @import("hsh.zig");
const Exec = @import("exec.zig");
const Signals = @import("signals.zig");
const Jobs = @import("jobs.zig");
const Line = @import("line.zig");
const Fs = @import("fs.zig");
const Tokenizer = @import("tokenizer.zig");
