const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const TTY = TTY_.TTY;
const TTY_ = @import("tty.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const mem = std.mem;
const os = std.os;
const std = @import("std");
const tty_codes = TTY_.OpCodes;

fn prompt(tty: *TTY, tkn: *Tokenizer) !void {
    try tty.prompt("\r{s}@{s}({})({}) # {s}", .{
        "username",
        "host",
        tkn.raw.items.len,
        tkn.tokens.items.len,
        tkn.raw.items,
    });
}

pub fn csi(tty: *TTY) !void {
    var buffer: [1]u8 = undefined;
    _ = try os.read(tty.tty, &buffer);
    if (buffer[0] == 'D') {
        tty.chadj += 1;
    } else if (buffer[0] == 'C') {
        tty.chadj -= 1;
    } else {
        try tty.print("\r\nCSI next: \r\n", .{});
        try tty.printAfter("    {x} {s}", .{ buffer[0], buffer });
    }
}

pub fn loop(tty: *TTY, tkn: *Tokenizer) !bool {
    while (true) {
        try prompt(tty, tkn);
        var buffer: [1]u8 = undefined;
        _ = try os.read(tty.tty, &buffer);
        switch (buffer[0]) {
            '\x1B' => {
                _ = try os.read(tty.tty, &buffer);
                if (buffer[0] == '[') {
                    try csi(tty);
                } else {
                    try tty.print("\r\ninput: escape {s} {}\n", .{ buffer, buffer[0] });
                }
            },
            '\x08' => try tty.print("\r\ninput: backspace\r\n", .{}),
            '\x09' => |b| {
                if (tkn.tab()) {} else {
                    try tkn.consumec(b);
                    try tty.printAfter("    {} {s}", .{ b, buffer });
                }
            },
            '\x7F' => try tkn.pop(),
            '\x17' => try tty.print("\r\ninput: ^w\r\n", .{}),
            '\x03' => {
                if (tkn.raw.items.len >= 0) {
                    try tty.print("^C\r\n", .{});
                    tkn.clear();
                } else {
                    try tty.print("\r\nExit caught... Bye ()\r\n", .{});
                    return false;
                }
            },
            '\x04' => |b| {
                try tty.print("\r\nExit caught... Bye ({})\r\n", .{b});
                return false;
            },
            '\n', '\r' => {
                try tty.print("\r\n", .{});
                try tkn.parse();
                try tkn.dump_parsed();
                if (tkn.tokens.items.len > 0) {
                    return true;
                }
            },
            else => |b| {
                try tkn.consumec(b);
                try tty.printAfter("    {} {s}", .{ b, buffer });
            },
        }
    }
}

test "c memory" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tkn = Tokenizer.init(a);
    for ("ls -la") |c| {
        try tkn.consumec(c);
    }
    try tkn.parse();

    var argv: [:null]?[*:0]u8 = undefined;
    var list = ArrayList(?[*:0]u8).init(a);
    try std.testing.expect(tkn.tokens.items.len == 2);
    try std.testing.expect(mem.eql(u8, tkn.tokens.items[0].raw, "ls"));
    try std.testing.expect(mem.eql(u8, tkn.tokens.items[0].real, "ls"));
    for (tkn.tokens.items) |token| {
        var arg = a.alloc(u8, token.real.len + 1) catch unreachable;
        mem.copy(u8, arg, token.real);
        arg[token.real.len] = 0;
        try list.append(@ptrCast(?[*:0]u8, arg.ptr));
    }
    try std.testing.expect(list.items.len == 2);
    argv = list.toOwnedSliceSentinel(null) catch unreachable;

    try std.testing.expect(mem.eql(u8, argv[0].?[0..2 :0], "ls"));
    try std.testing.expect(mem.eql(u8, argv[1].?[0..3 :0], "-la"));
    try std.testing.expect(argv[2] == null);
}

const hshExecErr = error{
    None,
    Unknown,
    MemError,
    NotFound,
};

pub fn exec(tty: *TTY, tkn: *Tokenizer) hshExecErr!void {
    _ = tty;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: [:null]?[*:0]u8 = undefined;
    var list = ArrayList(?[*:0]u8).init(a);
    for (tkn.tokens.items) |token| {
        var arg = a.alloc(u8, token.real.len + 1) catch return hshExecErr.MemError;
        mem.copy(u8, arg, token.real);
        arg[token.real.len] = 0;
        list.append(@ptrCast(?[*:0]u8, arg.ptr)) catch return hshExecErr.MemError;
    }
    argv = list.toOwnedSliceSentinel(null) catch return hshExecErr.MemError;

    const fork_pid = std.os.fork() catch return hshExecErr.Unknown;
    if (fork_pid == 0) {
        // TODO manage env
        const res = std.os.execvpeZ(argv[0].?, argv, @ptrCast([*:null]?[*:0]u8, std.os.environ));
        switch (res) {
            error.FileNotFound => return hshExecErr.NotFound,
            else => {
                std.debug.print("exec error {}", .{res});
                unreachable;
            },
        }
    } else {
        const res = std.os.waitpid(fork_pid, 0);
        std.debug.print("fork res {}", .{res.status});
    }
}

pub fn sig_cb(sig: c_int, info: *const os.siginfo_t, uctx: ?*const anyopaque) callconv(.C) void {
    if (sig != os.SIG.WINCH) unreachable;
    _ = info;
    _ = uctx; // TODO maybe install uctx and drop TTY.current_tty?
    var curr = TTY_.current_tty.?;
    curr.size = TTY.geom(curr.tty) catch unreachable;
}

pub fn signals() !void {
    try os.sigaction(os.SIG.WINCH, &os.Sigaction{
        .handler = .{ .sigaction = sig_cb },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);
}

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n\n", .{"codebase"});
    var tty = TTY.init() catch unreachable;
    defer tty.raze();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var t = Tokenizer.init(arena.allocator());

    try signals();

    while (true) {
        if (loop(&tty, &t)) |l| {
            if (l) {
                try exec(&tty, &t);
                t.clear();
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
    TTY_.current_tty.?.raze();
    std.builtin.default_panic(msg, trace, retaddr);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "alloc" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Tokenizer.init(a);
    try expect(std.mem.eql(u8, t.raw.items, ""));
}

test "tokens" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = Tokenizer.init(a);
    for ("token") |c| {
        try parsed.consumec(c);
    }
    try parsed.parse();
    try expect(std.mem.eql(u8, parsed.raw.items, "token"));
}

test "parse string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = Tokenizer.init(a);
    var tkn = t.parse_string("string is true");
    if (tkn) |tk| {
        try expect(std.mem.eql(u8, tk.raw, "string"));
        try expect(tk.raw.len == 6);
    } else |_| {}
}
