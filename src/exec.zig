const std = @import("std");
const hsh = @import("hsh.zig");
const HSH = hsh.HSH;
const jobs = @import("jobs.zig");
const tokenizer = @import("tokenizer.zig");
const Allocator = mem.Allocator;
const Tokenizer = tokenizer.Tokenizer;
const ArrayList = std.ArrayList;
const Kind = tokenizer.Kind;
const TokenIterator = tokenizer.TokenIterator;
const parse = @import("parse.zig");
const Parser = parse.Parser;
const ParsedIterator = parse.ParsedIterator;
const log = @import("log");
const mem = std.mem;
const fd_t = std.os.fd_t;
const fs = @import("fs.zig");
const bi = @import("builtins.zig");
const signal = @import("signals.zig");

const STDIN_FILENO = std.os.STDIN_FILENO;
const STDOUT_FILENO = std.os.STDOUT_FILENO;
const STDERR_FILENO = std.os.STDERR_FILENO;

pub const Error = error{
    InvalidSrc,
    Unknown,
    OSErr,
    Memory,
    NotFound,
    ExecFailed,
    ExeNotFound,
    PipelineError,
    StdIOError,
};

const ARG = [*:0]u8;
const ARGV = [:null]?ARG;

const StdIo = struct {
    in: fd_t = STDIN_FILENO,
    out: fd_t = STDOUT_FILENO,
    err: fd_t = STDERR_FILENO,
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

pub fn execFromInput(h: *HSH, str: []const u8) ![]u8 {
    var itr = TokenIterator{ .raw = str };
    var tokens = try itr.toSlice(h.alloc);
    defer h.alloc.free(tokens);
    var ps = try Parser.parse(&h.tkn.alloc, tokens);
    defer ps.close();
    return h.alloc.dupe(u8, ps.first().cannon());
}

pub fn executable(h: *HSH, str: []const u8) bool {
    if (bi.exists(str)) return true;
    paths = h.hfs.names.paths.items;
    var plsfree = makeAbsExecutable(h.alloc, str) catch return bi.existsOptional(str);
    h.alloc.free(plsfree);
    return true;
}

fn validPath(path: []const u8) bool {
    const file = fs.openFile(path, false) orelse return false;
    defer file.close();
    const md = file.metadata() catch return false;
    if (md.kind() != .file) return false;
    const perm = md.permissions().inner;
    if (perm.unixHas(
        std.fs.File.PermissionsUnix.Class.other,
        std.fs.File.PermissionsUnix.Permission.execute,
    )) return true;
    return false;
}

fn validPathAbs(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    const md = file.metadata() catch return false;
    if (md.kind() != .file) return false;
    const perm = md.permissions().inner;
    if (perm.unixHas(
        std.fs.File.PermissionsUnix.Class.other,
        std.fs.File.PermissionsUnix.Permission.execute,
    )) return true;
    return false;
}

/// TODO BUG arg should be absolute but argv[0] should only be absolute IFF
/// there was a / is the original token.
pub fn makeAbsExecutable(a: Allocator, str: []const u8) Error![]u8 {
    if (str[0] == '/') {
        if (!validPathAbs(str)) return Error.ExeNotFound;
        return a.dupe(u8, str) catch return Error.Memory;
    } else if (std.mem.indexOf(u8, str, "/")) |_| {
        if (!validPath(str)) return Error.ExeNotFound;
        var cwd: [2048]u8 = undefined;
        return std.mem.join(
            a,
            "/",
            &[2][]const u8{
                std.fs.cwd().realpath(".", &cwd) catch return Error.NotFound,
                str,
            },
        ) catch return Error.Memory;
    }

    var next: []u8 = "";
    for (paths) |path| {
        next = std.mem.join(a, "/", &[2][]const u8{ path, str }) catch return Error.Memory;
        if (validPathAbs(next)) return next;
        a.free(next);
    }
    return Error.ExeNotFound;
}

/// Caller will own memory
fn makeExeZ(a: Allocator, str: []const u8) Error!ARG {
    var exe = try makeAbsExecutable(a, str);
    if (a.resize(exe, exe.len + 1)) {
        exe.len += 1;
    } else {
        exe = a.realloc(exe, exe.len + 1) catch return Error.Memory;
    }
    exe[exe.len - 1] = 0;
    return exe[0 .. exe.len - 1 :0];
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
fn binary(a: Allocator, itr: *ParsedIterator) Error!Binary {
    var argv = ArrayList(?ARG).init(a);
    defer itr.close();

    var exeZ: ?ARG = makeExeZ(a, itr.first().cannon()) catch |e| {
        log.warn("path missing {s}\n", .{itr.first().cannon()});
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
        errdefer a.*.free(eslice);
        var parsed = Parser.parse(a, eslice) catch unreachable;
        var io: StdIo = StdIo{ .in = prev_stdout orelse STDIN_FILENO };
        var condition: ?Conditional = conditional_rule;

        // peek is now the exec operator because of how the iterator works :<
        if (peek.kind == .oper) {
            switch (peek.kind.oper) {
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
            if (maybeio.kind == .io) {
                switch (maybeio.kind.io) {
                    .Out, .Append => {
                        if (fs.openFile(maybeio.cannon(), true)) |file| {
                            io.out = file.handle;
                            if (maybeio.kind.io == .Append) {
                                file.seekFromEnd(0) catch return Error.StdIOError;
                            }
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

        var stk: CallableStack = undefined;
        const exe_str = parsed.first().cannon();
        if (bi.exists(exe_str)) {
            stk = CallableStack{
                .callable = .{ .builtin = try builtin(a.*, parsed) },
                .stdio = io,
                .conditional = condition,
            };
        } else {
            if (binary(a.*, &parsed)) |bin| {
                stk = CallableStack{
                    .callable = .{ .exec = bin },
                    .stdio = io,
                    .conditional = condition,
                };
            } else |e| {
                if (bi.existsOptional(exe_str)) {
                    stk = CallableStack{
                        .callable = .{ .builtin = try builtin(a.*, parsed) },
                        .stdio = io,
                        .conditional = condition,
                    };
                } else {
                    return e;
                }
            }
        }
        stack.append(stk) catch return Error.Memory;
        a.free(eslice);
    }
    return stack.toOwnedSlice() catch return Error.Memory;
}

fn execBuiltin(h: *HSH, b: *Builtin) Error!u8 {
    const bi_func = bi.strExec(b.builtin);
    const res = bi_func(h, &b.argv) catch |err| {
        log.err("builtin error {}\n", .{err});
        return 255;
    };
    while (b.argv.next()) |_| {}
    return res;
}

fn execBin(e: Binary) Error!void {
    // TODO manage env
    const res = std.os.execveZ(e.arg, e.argv, @ptrCast(std.os.environ));
    switch (res) {
        error.FileNotFound => {
            // we validate exes internally now this should be impossible
            log.err("exe not found {s}\n", .{e.arg});
            unreachable;
        },
        else => log.err("exec error {}\n", .{res}),
    }
}

fn free(a: Allocator, s: *CallableStack) void {
    // TODO implement
    switch (s.callable) {
        .builtin => |b| {
            a.free(b.argv.tokens);
        },
        .exec => |e| {
            // TODO validate this clears all pointers correctly
            for (e.argv) |*marg| {
                if (marg.*) |argz| {
                    var arg = std.mem.span(argz);
                    a.free(arg);
                }
            }
            a.free(e.argv);
        },
    }
}

/// input is a string ownership is retained by the caller
pub fn exec(h: *HSH, input: []const u8) Error!void {
    // HACK I don't like it either, but LOOK OVER THERE!!!
    paths = h.hfs.names.paths.items;

    var titr = TokenIterator{ .raw = input };

    const stack = mkCallableStack(&h.alloc, &titr) catch |e| {
        log.debug("unable to make stack {}\n", .{e});
        return e;
    };
    defer h.alloc.free(stack);

    if (stack.len == 1 and
        stack[0].callable == .builtin and
        stack[0].stdio.in == STDIN_FILENO and
        stack[0].stdio.out == STDOUT_FILENO)
    {
        _ = try execBuiltin(h, &stack[0].callable.builtin);
        free(h.alloc, &stack[0]);
        return;
    }

    h.tty.setOrig() catch |e| {
        log.err("TTY didn't respond {}\n", .{e});
        return Error.Unknown;
    };

    errdefer {
        h.tty.setRaw() catch |e| {
            log.err("TTY didn't respond as expected after exec error{}\n", .{e});
        };
    }

    var fpid: std.os.pid_t = 0;
    for (stack) |*s| {
        defer free(h.alloc, s);
        if (s.conditional) |cond| {
            if (fpid == 0) unreachable;
            var waited_job = jobs.waitForPid(fpid) catch @panic("job doesn't exist");
            switch (cond) {
                .After => {},
                .Failure => {
                    if (waited_job.exit_code) |ec| {
                        if (ec == 0) continue;
                    }
                },
                .Success => {
                    if (waited_job.exit_code) |ec| {
                        if (ec != 0) continue;
                    }
                },
            }
            // repush original because spinning will revert
            h.tty.setOrig() catch |e| {
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
            .status = if (s.stdio.pipe) .piped else .running,
            .pid = fpid,
            .name = h.alloc.dupe(u8, name) catch return Error.Memory,
        }) catch return Error.Memory;
        if (s.stdio.in != std.os.STDIN_FILENO) std.os.close(s.stdio.in);
        if (s.stdio.out != std.os.STDOUT_FILENO) std.os.close(s.stdio.out);
        if (s.stdio.err != std.os.STDERR_FILENO) std.os.close(s.stdio.err);
    }

    _ = jobs.waitForFg();
    h.tty.setRaw() catch log.err("Unable to setRaw after child event\n", .{});
    h.tty.setOwner(null) catch log.err("Unable to setOwner after child event\n", .{});
}

/// I hate all of this but stdlib likes to panic instead of manage errors
/// so we're doing the whole ChildProcess thing now
pub const ERes = struct {
    stdout: [][]u8,
};

/// Collects, and reformats argv into it's null terminated counterpart for
/// execvpe. Caller retains ownership of memory.
pub fn child(a: Allocator, argv: []const []const u8) !ERes {
    signal.block();
    defer signal.unblock();
    var list = ArrayList(?[*:0]u8).init(a);
    for (argv) |arg| {
        try list.append((try a.dupeZ(u8, arg)).ptr);
    }
    var argvZ: [:null]?[*:0]u8 = try list.toOwnedSliceSentinel(null);

    defer {
        for (argvZ) |*argm| {
            if (argm.*) |arg| {
                a.free(std.mem.span(arg));
            }
        }
        a.free(argvZ);
    }
    return childZ(a, argvZ);
}

/// Preformatted version of child. Accepts the null, and 0 terminated versions
/// to pass directly to exec. Caller maintains ownership of argv
pub fn childZ(a: Allocator, argv: [:null]const ?[*:0]const u8) !ERes {
    var pipe = std.os.pipe2(0) catch unreachable;
    const pid = std.os.fork() catch unreachable;
    if (pid == 0) {
        // we kid nao
        std.os.dup2(pipe[1], std.os.STDOUT_FILENO) catch unreachable;
        std.os.close(pipe[0]);
        std.os.close(pipe[1]);
        std.os.execvpeZ(argv[0].?, argv.ptr, @ptrCast(std.os.environ)) catch {
            unreachable;
        };
        unreachable;
    }
    std.os.close(pipe[1]);
    defer std.os.close(pipe[0]);

    var f = std.fs.File{ .handle = pipe[0] };
    var r = f.reader();
    var list = std.ArrayList([]u8).init(a);

    while (try r.readUntilDelimiterOrEofAlloc(a, '\n', 2048)) |line| {
        try list.append(line);
    }
    return ERes{
        .stdout = try list.toOwnedSlice(),
    };
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
        free(a, s);
    }
    a.free(stk);
}
