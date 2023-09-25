const std = @import("std");
const hsh = @import("hsh.zig");
const HSH = hsh.HSH;
const jobs = @import("jobs.zig");
const tokenizer = @import("tokenizer.zig");
const Allocator = mem.Allocator;
const Tokenizer = tokenizer.Tokenizer;
const ArrayList = std.ArrayList;
const Kind = tokenizer.Kind;
const Token = @import("token.zig");
const TokenIterator = Token.Iterator;
const parse = @import("parse.zig");
const Parser = parse.Parser;
const ParsedIterator = parse.ParsedIterator;
const log = @import("log");
const mem = std.mem;
const fd_t = std.os.fd_t;
const bi = @import("builtins.zig");
const fs = @import("fs.zig");
const signal = @import("signals.zig");
const logic_ = @import("logic.zig");
const Variables = @import("variables.zig");

const STDIN_FILENO = std.os.STDIN_FILENO;
const STDOUT_FILENO = std.os.STDOUT_FILENO;
const STDERR_FILENO = std.os.STDERR_FILENO;

pub const Error = error{
    InvalidSrc,
    InvalidLogic,
    Unknown,
    OSErr,
    OutOfMemory,
    NotFound,
    ExecFailed,
    ChildExecFailed,
    ExeNotFound,
    Pipeline,
    Parse,
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

const Logic = struct {
    logic: logic_.Logicizer,
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
        logic: Logic,
    },
    stdio: StdIo,
    conditional: ?Conditional = null,
};

var paths: []const []const u8 = undefined;

pub fn execFromInput(h: *HSH, str: []const u8) ![]u8 {
    var itr = TokenIterator{ .raw = str };
    var tokens = try itr.toSlice(h.alloc);
    defer h.alloc.free(tokens);
    var ps = try Parser.parse(h.tkn.alloc, tokens);
    defer ps.raze();
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
    if (str.len == 0) return Error.NotFound; // Is this always NotFound?
    if (str[0] == '/') {
        if (!validPathAbs(str)) return Error.ExeNotFound;
        return try a.dupe(u8, str);
    } else if (std.mem.indexOf(u8, str, "/")) |_| {
        if (!validPath(str)) return Error.ExeNotFound;
        var cwd: [2048]u8 = undefined;
        return try std.mem.join(
            a,
            "/",
            &[2][]const u8{
                std.fs.cwd().realpath(".", &cwd) catch return Error.NotFound,
                str,
            },
        );
    }

    var next: []u8 = "";
    for (paths) |path| {
        next = try std.mem.join(a, "/", &[2][]const u8{ path, str });
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
        exe = try a.realloc(exe, exe.len + 1);
    }
    exe[exe.len - 1] = 0;
    return exe[0 .. exe.len - 1 :0];
}

fn mkBuiltin(a: Allocator, parsed: ParsedIterator) Error!Builtin {
    var itr = parsed;
    itr.tokens = try a.dupe(Token, itr.tokens);
    return Builtin{
        .builtin = itr.first().cannon(),
        .argv = itr,
    };
}

/// Caller owns memory of argv, and the open fds
fn mkBinary(a: Allocator, itr: *ParsedIterator) Error!Binary {
    var argv = ArrayList(?ARG).init(a);
    defer itr.raze();

    var exeZ: ?ARG = makeExeZ(a, itr.first().cannon()) catch |e| {
        log.warn("path missing {s}\n", .{itr.first().cannon()});
        return e;
    };
    try argv.append(exeZ);

    while (itr.next()) |t| {
        try argv.append(
            try a.dupeZ(u8, t.cannon()),
        );
    }
    return Binary{
        .arg = exeZ.?,
        .argv = try argv.toOwnedSliceSentinel(null),
    };
}

fn mkLogic(a: Allocator, t: Token) !Logic {
    return .{
        .logic = try logic_.Logicizer.init(a, t),
    };
}

fn mkCallableStack(a: Allocator, itr: *TokenIterator) Error![]CallableStack {
    var stack = ArrayList(CallableStack).init(a);
    var prev_stdout: ?fd_t = null;
    var conditional_rule: ?Conditional = null;

    // Ok... if you've figured out how this loop *actually* works... well then I
    // want you to know two things... First: I'm not sorry! You clearly deserved
    // to learn this! Second: yes, I was dropped on my head as a child. Also, as
    // a warning to anyone that hasn't figured it out, be careful! There are
    // things that you can't unknow!
    while (itr.peek()) |peek| {
        // TEMP HACK (wanna take bets on how long this temp hack lives?
        if (peek.kind == .logic) {
            log.warn("Hack in use\n", .{});
            try stack.append(CallableStack{
                .callable = .{ .logic = mkLogic(a, peek.*) catch |err| {
                    log.err("Unable to make logic {}\n", .{err});
                    return Error.Unknown;
                } },
                .stdio = StdIo{ .in = STDIN_FILENO },
                .conditional = null,
            });
            return try stack.toOwnedSlice();
        }

        var eslice = itr.toSliceExec(a) catch unreachable;
        errdefer a.free(eslice);
        var parsed = Parser.parse(a, eslice) catch |err| {
            if (err == error.Empty) continue;
            return Error.Parse;
        };
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
                    .Out, .Append => |appnd| {
                        const f = fs.openFileStdout(maybeio.cannon(), appnd == .Append) catch |err| {
                            switch (err) {
                                fs.Error.NoClobber => log.err("Noclobber is enabled.\n", .{}),
                                else => log.err("Failed to open file {s}\n", .{maybeio.cannon()}),
                            }
                            return Error.StdIOError;
                        };
                        io.out = f.handle;
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
        for (eslice) |s| log.debug("exe slice {}\n", .{s});
        const exe_str = parsed.first().cannon();
        if (bi.exists(exe_str)) {
            stk = CallableStack{
                .callable = .{ .builtin = try mkBuiltin(a, parsed) },
                .stdio = io,
                .conditional = condition,
            };
        } else {
            if (mkBinary(a, &parsed)) |bin| {
                stk = CallableStack{
                    .callable = .{ .exec = bin },
                    .stdio = io,
                    .conditional = condition,
                };
            } else |e| {
                if (bi.existsOptional(exe_str)) {
                    stk = CallableStack{
                        .callable = .{ .builtin = try mkBuiltin(a, parsed) },
                        .stdio = io,
                        .conditional = condition,
                    };
                } else {
                    return e;
                }
            }
        }
        try stack.append(stk);
        a.free(eslice);
    }
    return try stack.toOwnedSlice();
}

fn execBuiltin(h: *HSH, b: *Builtin) Error!u8 {
    const bi_func = bi.strExec(b.builtin);
    const res = bi_func(h, &b.argv) catch |err| {
        log.err("builtin error {}\n", .{err});
        return 255;
    };
    b.argv.raze();
    return res;
}

fn execBin(e: Binary) Error!void {
    // TODO manage env

    const environ = Variables.henviron();
    const res = std.os.execveZ(e.arg, e.argv, @ptrCast(environ));
    switch (res) {
        error.FileNotFound => {
            // we validate exes internally now this should be impossible
            log.err("exe not found {s}\n", .{e.arg});
            unreachable;
        },
        else => log.err("exec error {}\n", .{res}),
    }
}

fn execLogic(h: *HSH, l: *Logic) Error!void {
    var logic: ?*logic_.Logicizer = &l.logic;
    log.warn("TODO handle signals\n", .{});
    while (logic) |lexec| {
        logic = lexec.exec(h) catch |err| {
            log.err("Error found when attempting to exec logic {}\n", .{err});
            return Error.Unknown;
        };
    }
}

fn free(a: Allocator, s: *CallableStack) void {
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
        .logic => |*l| {
            l.logic.raze();
        },
    }
}

/// input is a string ownership is retained by the caller
pub fn exec(h_: *HSH, input: []const u8) Error!void {
    // HACK I don't like it either, but LOOK OVER THERE!!!
    paths = h_.hfs.names.paths.items;
    var a = h_.alloc;
    var tty = h_.tty;

    var titr = TokenIterator{ .raw = input };

    const stack = mkCallableStack(a, &titr) catch |e| {
        log.debug("unable to make stack {}\n", .{e});
        return e;
    };
    defer a.free(stack);

    // TODO replace this hack with real logic to determine what env builtins
    // need to execute in.
    if (stack.len == 1 and
        stack[0].stdio.in == STDIN_FILENO and
        stack[0].stdio.out == STDOUT_FILENO)
    {
        if (stack[0].callable == .builtin) {
            _ = try execBuiltin(h_, &stack[0].callable.builtin);
            free(a, &stack[0]);
            _ = jobs.waitForFg();
            tty.setRaw() catch log.err("Unable to setRaw after child event\n", .{});
            tty.setOwner(null) catch log.err("Unable to setOwner after child event\n", .{});
            return;
        }

        if (stack[0].callable == .logic) {
            execLogic(h_, &stack[0].callable.logic) catch return Error.Unknown;
            free(a, &stack[0]);
            _ = jobs.waitForFg();
            return;
        }
    }

    tty.setOrig() catch |e| {
        log.err("TTY didn't respond {}\n", .{e});
        return Error.Unknown;
    };

    errdefer {
        tty.setRaw() catch |e| {
            log.err("TTY didn't respond as expected after exec error{}\n", .{e});
        };
    }

    // This is where I'd like environ to live, but I'm not ready to change the
    // api in this commit
    //const environ = Variables.henviron();

    var fpid: std.os.pid_t = 0;
    for (stack) |*s| {
        defer free(a, s);
        if (s.conditional) |cond| {
            if (fpid == 0) unreachable;
            var waited_job = jobs.waitFor(fpid) catch @panic("job doesn't exist");
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
            tty.setOrig() catch |e| {
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
                    std.os.exit(try execBuiltin(h_, b));
                },
                .exec => |e| {
                    try execBin(e);
                    unreachable;
                },
                .logic => |_| {
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
            .logic => "logic stuff",
        };
        try jobs.add(jobs.Job{
            .status = if (s.stdio.pipe) .piped else .running,
            .pid = fpid,
            .name = try a.dupe(u8, name),
        });
        if (s.stdio.in != std.os.STDIN_FILENO) std.os.close(s.stdio.in);
        if (s.stdio.out != std.os.STDOUT_FILENO) std.os.close(s.stdio.out);
        if (s.stdio.err != std.os.STDERR_FILENO) std.os.close(s.stdio.err);
    }

    _ = jobs.waitForFg();
    tty.setRaw() catch log.err("Unable to setRaw after child event\n", .{});
    tty.setOwner(null) catch log.err("Unable to setOwner after child event\n", .{});
}

/// I hate all of this but stdlib likes to panic instead of manage errors
/// so we're doing the whole ChildProcess thing now
pub const ChildResult = struct {
    job: *jobs.Job,
    stdout: [][]u8,
};

/// Tokenizes, parses, and executes a a valid argv string.
pub fn childParsed(a: Allocator, argv: []const u8) Error!ChildResult {
    var itr = TokenIterator{ .raw = argv };

    var slice = try itr.toSliceExec(a);
    defer a.free(slice);

    var parsed = Parser.parse(a, slice) catch return Error.Parse;
    defer parsed.raze();
    var list = ArrayList([]const u8).init(a);
    while (parsed.next()) |p| {
        try list.append(p.cannon());
        log.debug("Exec.childParse {} {s}\n", .{ list.items.len, p.cannon() });
    } // Precomptue
    var strs = try list.toOwnedSlice();
    defer a.free(strs);

    return child(a, strs);
}

/// Collects, and reformats argv into it's null terminated counterpart for
/// execvpe. Caller retains ownership of memory.
pub fn child(a: Allocator, argv: []const []const u8) !ChildResult {
    if (argv.len == 0 or argv[0].len == 0) return Error.NotFound;
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
pub fn childZ(a: Allocator, argv: [:null]const ?[*:0]const u8) Error!ChildResult {
    var pipe = std.os.pipe2(0) catch unreachable;
    const pid = std.os.fork() catch unreachable;
    if (pid == 0) {
        // we kid nao
        std.os.dup2(pipe[1], std.os.STDOUT_FILENO) catch unreachable;
        std.os.close(pipe[0]);
        std.os.close(pipe[1]);
        std.os.execvpeZ(argv[0].?, argv.ptr, @ptrCast(std.os.environ)) catch {
            log.err("Unexpected error in childZ\n", .{});
            return Error.ChildExecFailed;
        };
        unreachable;
    }
    std.os.close(pipe[1]);
    defer std.os.close(pipe[0]);
    const name = std.mem.span(argv[0].?);
    try jobs.add(jobs.Job{
        .status = .child,
        .pid = pid,
        .name = try a.dupe(u8, name[0 .. name.len - 1]),
    });

    var f = std.fs.File{ .handle = pipe[0] };
    var r = f.reader();
    var list = std.ArrayList([]u8).init(a);

    var job = jobs.waitFor(pid) catch return Error.Unknown;

    while (r.readUntilDelimiterOrEofAlloc(a, '\n', 2048) catch unreachable) |line| {
        try list.append(line);
    }

    return .{
        .job = job,
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
    ti.skip();
    try std.testing.expectEqualStrings("|", ti.next().?.cannon());
    ti.skip();
    try std.testing.expectEqualStrings("sort", ti.next().?.cannon());

    paths = &[_][]const u8{"/usr/bin"};

    var a = std.testing.allocator;
    ti.restart();
    var stk = try mkCallableStack(a, &ti);
    try std.testing.expect(stk.len == 2);
    for (stk) |*s| {
        free(a, s);
    }
    a.free(stk);
}
