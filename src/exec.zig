const std = @import("std");
const HSH = @import("hsh.zig").HSH;
const Tokens = @import("tokenizer.zig");
const Allocator = mem.Allocator;
const Tokenizer = Tokens.Tokenizer;
const ArrayList = std.ArrayList;
const TokenType = @import("tokenizer.zig").TokenType;
const mem = std.mem;
const fd_t = std.os.fd_t;

pub const Error = error{
    InvalidSrc,
    Unknown,
    Memory,
    NotFound,
    ExeNotFound,
};

const ARG = [*:0]u8;
const ARGV = [:null]?ARG;

const StdIo = struct {
    stdin: fd_t,
    stdout: fd_t,
    stderr: fd_t,
};

const ExecStack = struct {
    arg: ARG,
    argv: ARGV,
    stdio: StdIo,
};

fn setup() void {}

pub fn executable(hsh: *HSH, str: []const u8) bool {
    _ = makeAbsExecutable(hsh.alloc, hsh.fs.paths.items, str) catch return false;
    return true;
}

/// Caller must cleanAndFree() memory
pub fn makeAbsExecutable(a: Allocator, paths: [][]const u8, str: []const u8) Error!ArrayList(u8) {
    var exe = ArrayList(u8).init(a);
    if (str[0] == '/') {
        const file = std.fs.openFileAbsolute(str, .{}) catch return Error.ExeNotFound;
        const perm = (file.metadata() catch return Error.ExeNotFound).permissions().inner;
        if (!perm.unixHas(
            std.fs.File.PermissionsUnix.Class.other,
            std.fs.File.PermissionsUnix.Permission.execute,
        )) return Error.ExeNotFound;
        exe.appendSlice(str) catch return Error.Memory;
        return exe;
    }
    for (paths) |path| {
        exe.clearAndFree();
        exe.appendSlice(path) catch return Error.Memory;
        exe.append('/') catch return Error.Memory;
        exe.appendSlice(str) catch return Error.Memory;
        const file = std.fs.openFileAbsolute(exe.items, .{}) catch continue;
        defer file.close();
        const perm = (file.metadata() catch continue).permissions().inner;
        if (perm.unixHas(
            std.fs.File.PermissionsUnix.Class.other,
            std.fs.File.PermissionsUnix.Permission.execute,
        )) break;
    } else {
        exe.clearAndFree();
        return Error.ExeNotFound;
    }
    return exe;
}

/// Caller owns memory of argv, and the open fd_s
fn makeExecStack(hsh: *const HSH, tkns: []const Tokens.Token) Error!ExecStack {
    if (tkns.len == 0) return Error.InvalidSrc;

    var argv = ArrayList(?ARG).init(hsh.alloc);
    var exe = makeAbsExecutable(hsh.alloc, hsh.fs.paths.items, tkns[0].cannon()) catch |e| return e;
    const exeZ = exe.toOwnedSliceSentinel(0) catch return Error.Memory;
    argv.append(exeZ) catch return Error.Memory;

    for (tkns[1..]) |t| {
        if (t.type == TokenType.WhiteSpace) continue;
        argv.append(hsh.alloc.dupeZ(u8, t.cannon()) catch return Error.Memory) catch return Error.Memory;
    }
    return ExecStack{
        .arg = exeZ,
        .argv = argv.toOwnedSliceSentinel(null) catch return Error.Memory,
        .stdio = StdIo{
            .stdin = 0,
            .stdout = 0,
            .stderr = 0,
        },
    };
}

pub fn exec(hsh: *const HSH, tkn: *const Tokenizer) Error!void {
    const stack = try makeExecStack(hsh, tkn.tokens.items);

    const fork_pid = std.os.fork() catch return Error.Unknown;
    if (fork_pid == 0) {
        // TODO manage env
        // TODO restore cooked!!
        const res = std.os.execveZ(stack.arg, stack.argv, @ptrCast([*:null]?[*:0]u8, std.os.environ));
        switch (res) {
            error.FileNotFound => return Error.NotFound,
            else => {
                std.debug.print("exec error {}", .{res});
                unreachable;
            },
        }
    } else {
        //tkn.reset();
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
