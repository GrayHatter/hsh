const std = @import("std");
const hsh = @import("hsh.zig");
const HSH = hsh.HSH;
const Job = @import("jobs.zig").Job;
const Tokens = @import("tokenizer.zig");
const Allocator = mem.Allocator;
const Tokenizer = Tokens.Tokenizer;
const ArrayList = std.ArrayList;
const TokenKind = @import("tokenizer.zig").TokenKind;
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
    left: fd_t,
    right: fd_t,
    stderr: fd_t,
};

const ExecStack = struct {
    arg: ARG,
    argv: ARGV,
    stdio: ?StdIo,
};

fn setup() void {}

pub fn executable(h: *HSH, str: []const u8) bool {
    var plsfree = makeAbsExecutable(h.alloc, h.fs.paths.items, str) catch return false;
    plsfree.clearAndFree();
    return true;
}

/// Caller must cleanAndFree() memory
/// TODO BUG arg should be absolute but argv[0] should only be absolute IFF
/// there was a / is the original token.
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
fn makeExecStack(h: *const HSH, tkns: []const Tokens.Token) Error![]ExecStack {
    if (tkns.len == 0) return Error.InvalidSrc;

    var stack = ArrayList(ExecStack).init(h.alloc);
    var exeZ: ?ARG = null;
    var argv = ArrayList(?ARG).init(h.alloc);

    for (tkns) |t| {
        switch (t.type) {
            .WhiteSpace => continue,
            .IoRedir => {
                if (!std.mem.eql(u8, "|", t.cannon())) unreachable;
                const pipe = std.os.pipe2(0) catch return Error.OSErr;
                const io = StdIo{
                    .left = pipe[1],
                    .right = pipe[0],
                    .stderr = std.os.STDERR_FILENO,
                };
                stack.append(ExecStack{
                    .arg = exeZ.?,
                    .argv = argv.toOwnedSliceSentinel(null) catch return Error.Memory,
                    .stdio = io,
                }) catch return Error.Memory;
                exeZ = null;
                argv = ArrayList(?ARG).init(h.alloc);
                continue;
            },
            else => {
                if (exeZ) |_| {} else {
                    exeZ = makeExeZ(
                        h.alloc,
                        h.fs.paths.items,
                        t.cannon(),
                    ) catch |e| return e;
                    argv.append(exeZ.?) catch return Error.Memory;
                    continue;
                }
                argv.append(
                    h.alloc.dupeZ(u8, t.cannon()) catch return Error.Memory,
                ) catch return Error.Memory;
            },
        }
    }

    stack.append(ExecStack{
        .arg = exeZ.?,
        .argv = argv.toOwnedSliceSentinel(null) catch return Error.Memory,
        .stdio = null,
    }) catch return Error.Memory;
    return stack.toOwnedSlice() catch return Error.Memory;
}

pub fn exec(h: *const HSH, tkn: *const Tokenizer) Error!ArrayList(Job) {
    const stack = makeExecStack(h, tkn.tokens.items) catch |e| return e;

    var previo: ?StdIo = null;
    var rootout = std.os.dup(std.os.STDOUT_FILENO) catch return Error.OSErr;

    var jobs = ArrayList(Job).init(h.alloc);

    for (stack) |s| {
        const fpid: std.os.pid_t = std.os.fork() catch return Error.OSErr;
        if (fpid == 0) {
            if (previo) |pio| {
                std.os.dup2(pio.right, std.os.STDIN_FILENO) catch return Error.OSErr;
                std.os.close(pio.left);
                std.os.close(pio.right);
            }
            if (s.stdio) |io| {
                std.os.dup2(io.left, std.os.STDOUT_FILENO) catch return Error.OSErr;
                std.os.close(io.left);
                std.os.close(io.right);
            } else {
                std.os.dup2(rootout, std.os.STDOUT_FILENO) catch return Error.OSErr;
            }

            // TODO manage env
            const res = std.os.execveZ(
                s.arg,
                s.argv,
                @ptrCast([*:null]?[*:0]u8, std.os.environ),
            );
            switch (res) {
                error.FileNotFound => {
                    // we validate exes internall now this should be impossible
                    unreachable;
                },
                else => std.debug.print("exec error {}\n", .{res}),
            }
            unreachable;
        }

        // Child must noreturn
        // Parent
        //std.debug.print("chld pid {}\n", .{fpid});
        jobs.append(Job{
            .status = if (s.stdio) |_| .Piped else .Running,
            .pid = fpid,
            .name = h.alloc.dupe(u8, std.mem.sliceTo(s.arg, 0)) catch return Error.Memory,
        }) catch return Error.Memory;
        if (previo) |pio| {
            std.os.close(pio.left);
            std.os.close(pio.right);
        }
        previo = s.stdio;
    }
    return jobs;
}

test "c memory" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tkn = Tokenizer.init(a);
    for ("ls -la") |c| {
        try tkn.consumec(c);
    }
    _ = try tkn.tokenize();

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
