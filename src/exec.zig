const std = @import("std");
const HSH = @import("hsh.zig").HSH;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const ArrayList = std.ArrayList;
const TokenType = @import("tokenizer.zig").TokenType;
const mem = std.mem;

pub const Error = error{
    None,
    Unknown,
    MemError,
    NotFound,
};

pub fn exec(_: *HSH, tkn: *Tokenizer) Error!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: [:null]?[*:0]u8 = undefined;
    var list = ArrayList(?[*:0]u8).init(a);
    for (tkn.tokens.items) |*token| {
        if (token.*.type == TokenType.Exe) {
            token.*.backing.?.insertSlice(0, "/usr/bin/") catch return Error.Unknown;
        } else if (token.*.type == TokenType.WhiteSpace) continue;
        var arg = a.alloc(u8, token.*.cannon().len + 1) catch return Error.MemError;
        mem.copy(u8, arg, token.*.cannon());
        arg[token.*.cannon().len] = 0;
        list.append(@ptrCast(?[*:0]u8, arg.ptr)) catch return Error.MemError;
    }
    argv = list.toOwnedSliceSentinel(null) catch return Error.MemError;

    const fork_pid = std.os.fork() catch return Error.Unknown;
    if (fork_pid == 0) {
        // TODO manage env
        // TODO restore cooked!!
        const res = std.os.execveZ(argv[0].?, argv, @ptrCast([*:null]?[*:0]u8, std.os.environ));
        switch (res) {
            error.FileNotFound => return Error.NotFound,
            else => {
                std.debug.print("exec error {}", .{res});
                unreachable;
            },
        }
    } else {
        tkn.reset();
        const res = std.os.waitpid(fork_pid, 0);
        const status = res.status >> 8 & 0xff;
        std.debug.print("fork res {}\n", .{status});
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
    _ = try tkn.parse();

    var argv: [:null]?[*:0]u8 = undefined;
    var list = ArrayList(?[*:0]u8).init(a);
    try std.testing.expect(tkn.tokens.items.len == 3);
    try std.testing.expect(mem.eql(u8, tkn.tokens.items[0].raw, "ls"));
    try std.testing.expect(mem.eql(u8, tkn.tokens.items[0].cannon(), "ls"));
    for (tkn.tokens.items) |token| {
        if (token.type == .WhiteSpace) continue;
        var arg = a.alloc(u8, token.cannon().len + 1) catch unreachable;
        mem.copy(u8, arg, token.cannon());
        arg[token.cannon().len] = 0;
        try list.append(@ptrCast(?[*:0]u8, arg.ptr));
    }
    try std.testing.expect(list.items.len == 2);
    argv = list.toOwnedSliceSentinel(null) catch unreachable;

    try std.testing.expect(mem.eql(u8, argv[0].?[0..2 :0], "ls"));
    try std.testing.expect(mem.eql(u8, argv[1].?[0..3 :0], "-la"));
    try std.testing.expect(argv[2] == null);
}
