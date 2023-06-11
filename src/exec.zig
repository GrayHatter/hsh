const std = @import("std");
const hsh = @import("hsh.zig");
const HSH = hsh.HSH;
const jobs = @import("jobs.zig");
const tokenizer = @import("tokenizer.zig");
const Allocator = mem.Allocator;
const Tokenizer = tokenizer.Tokenizer;
const ArrayList = std.ArrayList;
const Kind = tokenizer.Kind;
const KindExt = tokenizer.KindExt;
const TokenIterator = tokenizer.TokenIterator;
const parse = @import("parse.zig");
const Parser = parse.Parser;
const ParsedIterator = parse.ParsedIterator;
const log = @import("log");
const mem = std.mem;
const fd_t = std.os.fd_t;
const fs = @import("fs.zig");
const bi = @import("builtins.zig");

pub const Error = error{
    InvalidSrc,
    Unknown,
    OSErr,
    Memory,
    NotFound,
    ExecFailed,
    ExeNotFound,
    PipelineError,
};

const ARG = [*:0]u8;
const ARGV = [:null]?ARG;

const StdIo = struct {
    in: fd_t = std.os.STDIN_FILENO,
    out: fd_t = std.os.STDOUT_FILENO,
    err: fd_t = std.os.STDERR_FILENO,
    pipe: bool = false,
};

const Binary = struct {
    arg: ARG,
    argv: ARGV,
};

const Builtin = struct {
    builtin: []const u8,
    argv: ParsedIterator,
};

const Conditional = enum {
    Success,
    Failure,
    After,
};

const CallableStack = struct {
    callable: union(enum) {
        builtin: Builtin,
        exec: Binary,
    },
    stdio: StdIo,
    conditional: ?Conditional = null,
};

var paths: []const []const u8 = undefined;

pub fn executable(h: *HSH, str: []const u8) bool {
    paths = h.hfs.names.paths.items;
    if (bi.exists(str)) return true;
    var plsfree = makeAbsExecutable(h.alloc, str) catch return false;
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
pub fn makeAbsExecutable(a: Allocator, str: []const u8) Error!ArrayList(u8) {
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
fn makeExeZ(a: Allocator, str: []const u8) Error!ARG {
    var exe = makeAbsExecutable(a, str) catch |e| return e;
    return exe.toOwnedSliceSentinel(0) catch return Error.Memory;
}

fn builtin(a: Allocator, parsed: ParsedIterator) Error!Builtin {
    var itr = parsed;
    itr.tokens = a.dupe(tokenizer.Token, itr.tokens) catch return Error.Memory;
    return Builtin{
        .builtin = itr.first().cannon(),
        .argv = itr,
    };
}

/// Caller owns memory of argv, and the open fds
fn binary(a: Allocator, titr: ParsedIterator) Error!Binary {
    var exeZ: ?ARG = null;
    var argv = ArrayList(?ARG).init(a);
    var itr = titr;

    exeZ = makeExeZ(a, itr.first().cannon()) catch |e| {
        log.err("path missing {s}\n", .{itr.first().cannon()});
        return e;
    };
    argv.append(exeZ) catch return Error.Memory;

    while (itr.next()) |t| {
        argv.append(
            a.dupeZ(u8, t.cannon()) catch return Error.Memory,
        ) catch return Error.Memory;
    }
    return Binary{
        .arg = exeZ.?,
        .argv = argv.toOwnedSliceSentinel(null) catch return Error.Memory,
    };
}

fn mkCallableStack(a: *Allocator, itr: *TokenIterator) Error![]CallableStack {
    var stack = ArrayList(CallableStack).init(a.*);
    var prev_stdout: ?fd_t = null;
    var conditional_rule: ?Conditional = null;

    while (itr.peek()) |peek| {
        //var before: tokenizer.Token = peek.*;
        var eslice = itr.toSliceExec(a.*) catch unreachable;
        var parsed = Parser.parse(a, eslice) catch unreachable;
        var io: StdIo = StdIo{ .in = prev_stdout orelse std.os.STDIN_FILENO };
        var condition: ?Conditional = conditional_rule;

        // peek is now the exec operator because of how the iterator works :<
        if (peek.kindext == .oper) {
            switch (peek.kindext.oper) {
                .Pipe => {
                    const pipe = std.os.pipe2(0) catch return Error.OSErr;
                    io.pipe = true;
                    io.out = pipe[1];
                    prev_stdout = pipe[0];
                },
                .Fail => {
                    conditional_rule = .Failure;
                },
                .Success => {
                    conditional_rule = .Success;
                },
                .Next => {
                    conditional_rule = .After;
                },
                .Background => {},
            }
        }

        for (eslice) |maybeio| {
            if (maybeio.kindext == .io) {
                switch (maybeio.kindext.io) {
                    .Out, .Append => {
                        if (fs.openFile(maybeio.cannon(), true)) |file| {
                            io.out = file.handle;
                        }
                    },
                    .In, .HDoc => {
                        if (prev_stdout) |out| {
                            std.os.close(out);
                            prev_stdout = null;
                        }
                        if (fs.openFile(maybeio.cannon(), true)) |file| {
                            io.in = file.handle;
                        }
                    },
                    .Err => unreachable,
                }
            }
        }

        var stk = CallableStack{
            .callable = switch (parsed.first().kind) {
                .Builtin => .{ .builtin = try builtin(a.*, parsed) },
                else => .{ .exec = try binary(a.*, parsed) },
            },
            .stdio = io,
            .conditional = condition,
        };
        stack.append(stk) catch return Error.Memory;
        a.free(eslice);
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
    const res = std.os.execveZ(e.arg, e.argv, @ptrCast([*:null]?[*:0]u8, std.os.environ));
    switch (res) {
        error.FileNotFound => {
            // we validate exes internally now this should be impossible
            unreachable;
        },
        else => log.err("exec error {}\n", .{res}),
    }
}

pub fn exec(h: *HSH, titr: *TokenIterator) Error!void {
    // HACK I don't like it either, but LOOK OVER THERE!!!
    paths = h.hfs.names.paths.items;

    titr.restart();
    const stack = mkCallableStack(&h.alloc, titr) catch |e| {
        log.err("unable to make stack {}\n", .{e});
        return e;
    };

    if (stack.len == 1 and stack[0].callable == .builtin) {
        _ = try execBuiltin(h, &stack[0].callable.builtin);
        return;
    }

    h.tty.pushOrig() catch |e| {
        log.err("TTY didn't respond {}\n", .{e});
        return Error.Unknown;
    };

    var fpid: std.os.pid_t = 0;
    for (stack) |*s| {
        if (s.conditional) |cond| {
            if (fpid == 0) unreachable;
            switch (cond) {
                .After => _ = jobs.waitFor(h, fpid) catch {},
                .Failure => {
                    if (jobs.waitFor(h, fpid) catch continue) {
                        continue;
                    }
                },
                .Success => {
                    if (!(jobs.waitFor(h, fpid) catch return Error.PipelineError)) {
                        continue;
                    }
                },
            }
            // repush original because spinning will revert
            h.tty.pushOrig() catch |e| {
                log.err("TTY didn't respond {}\n", .{e});
                return Error.Unknown;
            };
        }

        fpid = std.os.fork() catch return Error.OSErr;
        if (fpid == 0) {
            if (s.stdio.in != std.os.STDIN_FILENO) {
                std.os.dup2(s.stdio.in, std.os.STDIN_FILENO) catch return Error.OSErr;
                std.os.close(s.stdio.in);
            }
            if (s.stdio.out != std.os.STDOUT_FILENO) {
                std.os.dup2(s.stdio.out, std.os.STDOUT_FILENO) catch return Error.OSErr;
                std.os.close(s.stdio.out);
            }
            if (s.stdio.err != std.os.STDERR_FILENO) {
                std.os.dup2(s.stdio.err, std.os.STDERR_FILENO) catch return Error.OSErr;
                std.os.close(s.stdio.err);
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
            // Child must noreturn
        }
        // Parent

        //log.err("chld pid {}\n", .{fpid});
        const name = switch (s.callable) {
            .builtin => |b| b.builtin,
            .exec => |e| std.mem.sliceTo(e.arg, 0),
        };
        jobs.add(jobs.Job{
            .status = if (s.stdio.pipe) .Piped else .Running,
            .pid = fpid,
            .name = h.alloc.dupe(u8, name) catch return Error.Memory,
        }) catch return Error.Memory;
        if (s.stdio.in != std.os.STDIN_FILENO) std.os.close(s.stdio.in);
        if (s.stdio.out != std.os.STDOUT_FILENO) std.os.close(s.stdio.out);
        if (s.stdio.err != std.os.STDERR_FILENO) std.os.close(s.stdio.err);
    }
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
        if (token.kind == .WhiteSpace) continue;
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

test "mkstack" {
    var ti = TokenIterator{
        .raw = "ls | sort",
    };

    var len: usize = 0;
    while (ti.next()) |_| {
        len += 1;
    }

    try std.testing.expectEqualStrings("ls", ti.first().cannon());
    try std.testing.expectEqualStrings("|", ti.next().?.cannon());
    try std.testing.expectEqualStrings("sort", ti.next().?.cannon());

    paths = &[_][]const u8{"/usr/bin"};

    var a = std.testing.allocator;
    ti.restart();
    var stk = try mkCallableStack(&a, &ti);
    try std.testing.expect(stk.len == 2);
    for (stk) |*s| {
        var argl = std.mem.len(s.callable.exec.arg) + 1;
        var arg = s.callable.exec.arg[0..argl];
        a.free(@as([]u8, arg));
        var argv = s.callable.exec.argv;
        a.free(@as([]?[*]u8, argv[0..2]));
    }
    a.free(stk);
}
