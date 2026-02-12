fn core(hsh: *Hsh, a: Allocator, io: Io) CoreError![]u8 {
    var array_alloc = std.heap.ArenaAllocator.init(a);
    defer array_alloc.deinit();
    const alloc = array_alloc.allocator();
    var line = Line.init(hsh, alloc, io, .{ .interactive = hsh.tty.dev != null });

    defer hsh.draw.reset();
    hsh.prompt.render(&hsh.draw, line.peek());
    while (true) {
        hsh.draw.clear();
        //hsh.spin(a, io);
        return try a.dupe(u8, try line.do(a, io));
    }
}

const CoreError = error{
    Done,
    Io,
    OutOfMemory,
    Signaled,
    Unexpected,
    WriteFailed,
};

fn usage() void {
    std.debug.print("hsh usage:\n", .{});
}

/// No, I don't really like this hack either, but autoformatting :/
/// return 255 == unknown
/// return   1 == exec error
fn execTacC(mini: std.process.Init.Minimal, io: Io) u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    var hsh = Hsh.initStateless(mini.environ, a, io) catch return 255;
    defer hsh.razeStateless(a, io);
    var args = mini.args.iterate();

    var tkzr: Tokenizer = .{};
    while (args.next()) |arg| {
        tkzr.consumeChar(' ') catch unreachable;
        tkzr.consumeSlice(arg);
    }
    const str = tkzr.getSlice();
    Exec.exec(str, &hsh, a, io, .default) catch |err| {
        log.err("-c error [{}]\n", .{err});
        return 1;
    };

    for (hsh.jobs.jobs.items) |job| switch (job.status) {
        .exited => |ec| return ec,
        else => unreachable,
    };
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

    if (readArgs(init.minimal, io)) |err| std.process.exit(err);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.detectLeaks() > 0) {
        std.debug.print("Leaked\n", .{});
        io.sleep(.fromSeconds(6), .real) catch unreachable;
    };
    const a = gpa.allocator();

    var hsh = try Hsh.init(init.minimal.environ, a, io);
    defer hsh.raze(a, io);
    hsh.prompt.cwd = &hsh.fs.cwd.name;
    Fs.g_fs = &hsh.fs;
    try hsh.tty.set(.raw);
    // Look at me, I'm the captain now!
    try hsh.tty.pwn();
    hsh.draw = try .init(
        &hsh.tty.out.w.interface,
        &hsh.tty.out.unbuffered.interface,
        a,
        .{ .colorize = hsh.enabled(.colorize) },
    );
    hsh.draw.term_size = try hsh.tty.geom();

    try Signals.init();
    defer Signals.raze();

    var errcnt: u8 = 0;
    while (true) {
        if (core(&hsh, a, io)) |str| {
            errcnt = 0;
            if (str.len == 0) {}
            defer a.free(str);
            std.debug.assert(str.len != 0);

            Exec.exec(str, &hsh, a, io, .default) catch |err| switch (err) {
                error.ExeNotFound => {
                    const first = Exec.execFromInput(str, a, io) catch @panic("memory");
                    defer a.free(first);
                    hsh.draw.drawAfter(&[3]Draw.Lexeme{
                        .styled("[ Unable to find ", .red_bold), .styled(first, .red_bold), .styled(" ]", .red_bold),
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
                error.Done => return std.debug.print("\n goodbye :) \n", .{}),
                error.Io => {
                    hsh.tty.waitForFg();
                    log.err("{} crash in main\n", .{err});
                    if (errcnt < 4) {
                        errcnt += 1;
                        continue;
                    }
                    @panic("too many errors");
                },
                error.OutOfMemory,
                error.Signaled,
                error.Unexpected,
                error.WriteFailed,
                => @panic("unhandled error in main.zig"),
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
const Hsh = @import("hsh.zig");
const Exec = @import("exec.zig");
const Signals = @import("signals.zig");
const Jobs = @import("jobs.zig");
const Line = @import("line.zig");
const Fs = @import("Fs.zig");
const Tokenizer = @import("tokenizer.zig");
