const std = @import("std");
const hsh = @import("hsh.zig");
const HSH = hsh.HSH;
const jobs = @import("jobs.zig");
const tokenizer = @import("tokenizer.zig");
const Allocator = mem.Allocator;
const Tokenizer = tokenizer.Tokenizer;
const ArrayList = std.ArrayList;
const TokenKind = tokenizer.TokenKind;
const TokenIterator = tokenizer.TokenIterator;
const parse = @import("parse.zig");
const Parser = parse.Parser;
const ParsedIterator = parse.ParsedIterator;
const log = @import("log");
const mem = std.mem;
const fd_t = std.os.fd_t;
const bi = @import("builtins.zig");

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

const Binary = struct {
    arg: ARG,
    argv: ARGV,
};

const Builtin = struct {
    builtin: []const u8,
    argv: ParsedIterator,
};

const Callable = union(enum) {
    builtin: Builtin,
    exec: Binary,
};

const CallableStack = struct {
    callable: Callable,
    stdio: ?StdIo,
};

pub fn executable(h: *HSH, str: []const u8) bool {
    if (bi.exists(str)) return true;
    var plsfree = makeAbsExecutable(h.alloc, h.fs.paths.items, str) catch return false;
    plsfree.clearAndFree();
    return true;
}

fn executablePath(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    const md = file.metadata() catch return false;
    if (md.kind() != .File) return false;
    const perm = md.permissions().inner;
    if (perm.unixHas(
        std.fs.File.PermissionsUnix.Class.other,
        std.fs.File.PermissionsUnix.Permission.execute,
    )) return true;
    return false;
}

/// Caller must cleanAndFree() memory
/// TODO BUG arg should be absolute but argv[0] should only be absolute IFF
/// there was a / is the original token.
pub fn makeAbsExecutable(a: Allocator, paths: [][]const u8, str: []const u8) Error!ArrayList(u8) {
    var exe = ArrayList(u8).init(a);
    if (str[0] == '/') {
        if (!executablePath(str)) return Error.ExeNotFound;
        exe.appendSlice(str) catch return Error.Memory;
        return exe;
    }
    for (paths) |path| {
        exe.clearAndFree();
        exe.appendSlice(path) catch return Error.Memory;
        exe.append('/') catch return Error.Memory;
        exe.appendSlice(str) catch return Error.Memory;
        if (executablePath(exe.items)) break else continue;
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

fn mkBuiltin(_: *const HSH, titr: ParsedIterator) Error!Builtin {
    var itr = titr;
    return Builtin{
        .builtin = itr.first().cannon(),
        .argv = itr,
    };
}

/// Caller owns memory of argv, and the open fds
fn mkExec(h: *const HSH, titr: ParsedIterator) Error!Binary {
    var exeZ: ?ARG = null;
    var argv = ArrayList(?ARG).init(h.alloc);
    var itr = titr;

    exeZ = makeExeZ(h.alloc, h.fs.paths.items, itr.first().cannon()) catch |e| {
        log.err("path missing {s}\n", .{itr.first().cannon()});
        return e;
    };
    argv.append(exeZ) catch return Error.Memory;

    while (itr.next()) |t| {
        argv.append(
            h.alloc.dupeZ(u8, t.cannon()) catch return Error.Memory,
        ) catch return Error.Memory;
    }
    return Binary{
        .arg = exeZ.?,
        .argv = argv.toOwnedSliceSentinel(null) catch return Error.Memory,
    };
}

fn mkCallableStack(h: *HSH, itr: *TokenIterator) Error![]CallableStack {
    var stack = ArrayList(CallableStack).init(h.alloc);

    itr.restart();

    while (itr.peek()) |peek| {
        var eslice = itr.toSliceExec(h.alloc) catch unreachable;
        //defer h.alloc.free(eslice);

        var io: ?StdIo = null;
        switch (peek.type) {
            .IoRedir => {
                if (!std.mem.eql(u8, "|", peek.cannon())) unreachable;
                const pipe = std.os.pipe2(0) catch return Error.OSErr;
                io = StdIo{
                    .left = pipe[1],
                    .right = pipe[0],
                    .stderr = std.os.STDERR_FILENO,
                };
            },
            else => {},
        }

        var parsed = Parser.parse(&h.alloc, eslice, false) catch unreachable;
        stack.append(CallableStack{
            .callable = switch (parsed.peek().?.type) {
                .Builtin => Callable{ .builtin = try mkBuiltin(h, parsed) },
                else => Callable{ .exec = try mkExec(h, parsed) },
            },
            .stdio = io,
        }) catch return Error.Memory;
    }
    return stack.toOwnedSlice() catch return Error.Memory;
}

fn execBuiltin(h: *HSH, b: *Builtin) Error!u8 {
    const bi_func = bi.strExec(b.builtin);
    log.dump(bi_func);
    log.dump(b.argv);
    log.dump(b.argv.first());
    return bi_func(h, &b.argv) catch |err| {
        log.err("builtin error {}\n", .{err});
        return 255;
    };
}

fn execBin(e: Binary) Error!void {
    // TODO manage env
    const res = std.os.execveZ(
        e.arg,
        e.argv,
        @ptrCast([*:null]?[*:0]u8, std.os.environ),
    );
    switch (res) {
        error.FileNotFound => {
            // we validate exes internally now this should be impossible
            unreachable;
        },
        else => log.err("exec error {}\n", .{res}),
    }
}

pub fn exec(h: *HSH, titr: *TokenIterator) Error!ArrayList(jobs.Job) {
    titr.restart();
    const stack = mkCallableStack(h, titr) catch |e| {
        log.err("unable to make stack {}\n", .{e});
        return e;
    };

    var previo: ?StdIo = null;
    var rootout = std.os.dup(std.os.STDOUT_FILENO) catch return Error.OSErr;

    var cjobs = ArrayList(jobs.Job).init(h.alloc);

    if (stack.len == 1 and stack[0].callable == .builtin) {
        _ = try execBuiltin(h, &stack[0].callable.builtin);
        return cjobs;
    }

    h.tty.pushOrig() catch |e| {
        log.err("TTY didn't respond {}\n", .{e});
        return Error.Unknown;
    };

    for (stack) |*s| {
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

            switch (s.callable) {
                .builtin => |*b| {
                    std.os.exit(try execBuiltin(h, b));
                },
                .exec => |e| {
                    try execBin(e);
                    unreachable;
                },
            }
            unreachable;
        }

        // Child must noreturn
        // Parent
        //log.err("chld pid {}\n", .{fpid});
        const name = switch (s.callable) {
            .builtin => |b| b.builtin,
            .exec => |e| std.mem.sliceTo(e.arg, 0),
        };
        cjobs.append(jobs.Job{
            .status = if (s.stdio) |_| .Piped else .Running,
            .pid = fpid,
            .name = h.alloc.dupe(u8, name) catch return Error.Memory,
        }) catch return Error.Memory;
        if (previo) |pio| {
            std.os.close(pio.left);
            std.os.close(pio.right);
        }
        previo = s.stdio;
    }
    return cjobs;
}

/// I hate all of this but stdlib likes to panic instead of manage errors
/// so we're doing the whole ChildProcess thing now
pub const ERes = struct {
    stdout: [][]u8,
};

//const exec = std.ChildProcess.exec;
pub fn child(h: *HSH, argv: [:null]const ?[*:0]const u8) !ERes {
    var pipe = std.os.pipe2(0) catch unreachable;
    const pid = std.os.fork() catch unreachable;
    if (pid == 0) {
        // we kid nao
        //std.os.dup2(pipe[1], std.os.STDERR_FILENO) catch unreachable;
        std.os.dup2(pipe[1], std.os.STDOUT_FILENO) catch unreachable;
        std.os.close(pipe[0]);
        std.os.close(pipe[1]);
        std.os.execvpeZ(
            argv[0].?,
            argv.ptr,
            @ptrCast([*:null]?[*:0]u8, std.os.environ),
        ) catch {
            unreachable;
        };
        unreachable;
    }
    //try jobs.add(jobs.Job{
    //    .name = "child",
    //    .pid = pid,
    //    .status = .Child,
    //});
    std.os.close(pipe[1]);
    defer std.os.close(pipe[0]);

    var f = std.fs.File{ .handle = pipe[0] };
    var r = f.reader();
    var list = std.ArrayList([]u8).init(h.alloc);

    while (try r.readUntilDelimiterOrEofAlloc(h.alloc, '\n', 2048)) |line| {
        try list.append(line);
    }
    return ERes{
        .stdout = try list.toOwnedSlice(),
    };
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
