const std = @import("std");
const log = @import("log");
const hsh_build = @import("hsh_build");
const Allocator = std.mem.Allocator;
const TTY = @import("tty.zig");
const Draw = @import("draw.zig");
const Drawable = Draw.Drawable;
const prompt = @import("prompt.zig");
const jobsContext = @import("prompt.zig").jobsContext;
const ctxContext = @import("prompt.zig").ctxContext;
const Context = @import("context.zig");
const HSH = @import("hsh.zig").HSH;
const Exec = @import("exec.zig");
const Signals = @import("signals.zig");
const History = @import("history.zig");
const jobs = @import("jobs.zig");
const Line = @import("line.zig");

test "main" {
    std.testing.refAllDecls(@This());
}

fn core(hsh: *HSH, a: Allocator) ![]u8 {
    var array_alloc = std.heap.ArenaAllocator.init(a);
    defer array_alloc.deinit();
    const alloc = array_alloc.allocator();
    var line = try Line.init(hsh, alloc, .{ .interactive = hsh.tty.is_tty });

    defer hsh.draw.reset();
    //try Context.update(hsh, &[_]Context.Contexts{.git});

    var redraw = true;
    // TODO drop hsh

    while (true) {
        hsh.draw.clear();
        redraw = hsh.spin() or redraw;

        if (redraw) {
            try prompt.draw(hsh, line.peek());
            try Draw.render(&hsh.draw);
            redraw = false;
        }

        return a.dupe(u8, try line.do());
    }
}

fn usage() void {
    std.debug.print("hsh usage:\n", .{});
}

/// No, I don't really like this hack either, but autoformatting :/
/// return 255 == unknown
/// return   1 == exec error
/// return   2 == alloc error
fn execTacC(args: *std.process.ArgIterator) u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    var hsh = HSH.init(a) catch return 255;
    defer hsh.raze();
    hsh.tty = TTY.init(a) catch return 255;
    defer hsh.tty.raze();

    while (args.next()) |_| {
        unreachable;
        //hsh.tkn.consumes(arg) catch return 2;
    }
    if (true) return 0;
    Exec.exec(&hsh, undefined) catch |err| {
        log.err("-c error [{}]\n", .{err});
        return 1;
    };
    for (jobs.jobs.items) |job| {
        if (job.exit_code != null and job.exit_code.? > 0) {
            return job.exit_code.?;
        }
    }
    return 0;
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
        } else if (std.mem.eql(u8, "-c", arg)) {
            return execTacC(&args);
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
    const a = gpa.allocator();

    var hsh = try HSH.init(a);
    defer hsh.raze();

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
    while (true) {
        if (core(&hsh, a)) |str| {
            inerr = false;
            if (str.len == 0) {
                std.debug.print("\n goodbye :) \n", .{});
                break;
            }
            defer hsh.alloc.free(str);
            std.debug.assert(str.len != 0);

            //var itr = hsh.tkn.iterator();
            try Draw.newLine(&hsh.draw);
            Exec.exec(&hsh, str) catch |err| switch (err) {
                error.ExeNotFound => {
                    const first = Exec.execFromInput(&hsh, str) catch @panic("memory");
                    defer hsh.alloc.free(first);
                    const tree = [_]Draw.Lexeme{
                        .{ .char = "[ Unable to find ", .style = .{ .attr = .bold, .fg = .red } },
                        .{ .char = first, .style = .{ .attr = .bold, .fg = .red } },
                        .{ .char = " ]", .style = .{ .attr = .bold, .fg = .red } },
                    };
                    try Draw.drawAfter(&hsh.draw, tree[0..]);
                    try Draw.render(&hsh.draw);
                },
                error.StdIOError => {
                    log.err("StdIoError\n", .{});
                },
                else => {
                    log.err("Exec error {}\n", .{err});
                    unreachable;
                },
            };
            continue;
        } else |err| {
            switch (err) {
                error.io => {
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

    log.err("Panic reached... your TTY is likely broken now.\n\n      ...sorry about that!\n\n", .{});
    std.debug.print("\n\r\x1B[J", .{});
    if (TTY.current_tty) |*t| {
        TTY.current_tty = null;
        t.raze();
    }
    std.debug.defaultPanic(msg, addr);
    @trap();
}
