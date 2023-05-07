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
    OSErr,
    Memory,
    NotFound,
    ExecFailed,
    ExeNotFound,
};

const ARG = [*:0]u8;
const ARGV = [:null]?ARG;

const StdIo = struct {
    stdin: [2]fd_t,
    stdout: [2]fd_t,
    stderr: fd_t,
};

const ExecStack = struct {
    arg: ARG,
    argv: ARGV,
    stdio: ?StdIo,
};

fn setup() void {}

pub fn executable(hsh: *HSH, str: []const u8) bool {
    var plsfree = makeAbsExecutable(hsh.alloc, hsh.fs.paths.items, str) catch return false;
    plsfree.clearAndFree();
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

/// Caller will own memory
fn makeExeZ(a: Allocator, paths: [][]const u8, str: []const u8) Error!ARG {
    var exe = makeAbsExecutable(a, paths, str) catch |e| return e;
    return exe.toOwnedSliceSentinel(0) catch return Error.Memory;
}

/// Caller owns memory of argv, and the open fds
fn makeExecStack(hsh: *const HSH, tkns: []const Tokens.Token) Error![]ExecStack {
    if (tkns.len == 0) return Error.InvalidSrc;

    var stack = ArrayList(ExecStack).init(hsh.alloc);
    var exeZ: ?ARG = null;
    var argv = ArrayList(?ARG).init(hsh.alloc);
    var stdio: ?StdIo = null;

    for (tkns) |t| {
        switch (t.type) {
            .WhiteSpace => continue,
            .IoRedir => {
                if (!std.mem.eql(u8, "|", t.cannon())) unreachable;
                const io = StdIo{
                    .stdin = std.os.pipe2(0) catch return Error.Unknown,
                    .stdout = std.os.pipe2(0) catch return Error.Unknown,
                    .stderr = std.os.STDERR_FILENO,
                };
                stack.append(ExecStack{
                    .arg = exeZ.?,
                    .argv = argv.toOwnedSliceSentinel(null) catch return Error.Memory,
                    .stdio = io,
                }) catch return Error.Memory;
                exeZ = null;
                argv = ArrayList(?ARG).init(hsh.alloc);
                continue;
            },
            else => {
                if (exeZ) |_| {} else {
                    exeZ = makeExeZ(hsh.alloc, hsh.fs.paths.items, t.cannon()) catch |e| return e;
                    argv.append(exeZ.?) catch return Error.Memory;
                    continue;
                }
                argv.append(hsh.alloc.dupeZ(u8, t.cannon()) catch return Error.Memory) catch return Error.Memory;
            },
        }
    }

    stack.append(ExecStack{
        .arg = exeZ.?,
        .argv = argv.toOwnedSliceSentinel(null) catch return Error.Memory,
        .stdio = stdio,
    }) catch return Error.Memory;
    return stack.toOwnedSlice() catch return Error.Memory;
}

pub fn exec(hsh: *const HSH, tkn: *const Tokenizer) Error!void {
    const stack = makeExecStack(hsh, tkn.tokens.items) catch |e| return e;

    var fpid: std.os.pid_t = 0;
    var previo: ?StdIo = null;
    var rootin = std.os.dup(std.os.STDIN_FILENO) catch return Error.OSErr;
    var rootout = std.os.dup(std.os.STDOUT_FILENO) catch return Error.OSErr;

    std.debug.print("stack looks like {any}\n", .{stack});
    for (stack) |s| {
        fpid = std.os.fork() catch return Error.OSErr;
        std.debug.print("forked {any}\n", .{fpid});
        if (fpid == 0) {
            std.debug.print("forked for {s}\n", .{s.arg});
            if (previo) |pio| {
                std.debug.print("rewriting in\n", .{});
                std.os.dup2(pio.stdout[0], std.os.STDIN_FILENO) catch return Error.OSErr;
            } else {
                std.debug.print("setting in\n", .{});
                std.os.dup2(hsh.tty.tty, std.os.STDIN_FILENO) catch return Error.OSErr;
            }
            if (s.stdio) |io| {
                std.debug.print("rewriting out\n", .{});
                std.os.dup2(io.stdout[1], std.os.STDOUT_FILENO) catch return Error.OSErr;
                //std.os.dup2(io.stderr, std.os.STDERR_FILENO) catch return Error.OSErr;
                std.os.close(io.stdin[0]);
                std.os.close(io.stdin[1]);
                std.os.close(io.stdout[0]);
                std.os.close(io.stdout[1]);
            } else if (previo) |io| {
                std.debug.print("restoring out\n", .{});
                std.os.dup2(rootout, std.os.STDOUT_FILENO) catch return Error.OSErr;
                std.os.close(io.stdin[0]);
                std.os.close(io.stdin[1]);
                std.os.close(io.stdout[0]);
                std.os.close(io.stdout[1]);
            }

            // TODO manage env
            const res = std.os.execveZ(s.arg, s.argv, @ptrCast([*:null]?[*:0]u8, std.os.environ));
            switch (res) {
                error.FileNotFound => {
                    // we validate exes internall now this should be impossible
                    unreachable;
                },
                else => std.debug.print("exec error {}", .{res}),
            }
            unreachable;
        } else {
            if (s.stdio) |io| previo = io;
        }
    }

    if (fpid != 0) {
        const res = std.os.waitpid(fpid, 0);
        const status = res.status >> 8 & 0xff;
        std.debug.print("fork res {}\n", .{status});
    }
    if (true) {
        std.debug.print("restoring in\n", .{});
        //try std.os.dup(rootout)
        std.os.dup2(rootin, std.os.STDIN_FILENO) catch return Error.OSErr;
        std.os.close(rootin); // catch return Error.OSErr;
        std.os.close(rootout); // catch return Error.OSEr;
    }
    if (stack.len > 1) _ = std.os.waitpid(-1, 0);
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
