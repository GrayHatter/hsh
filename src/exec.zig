const STDIN_FD = std.Io.File.stdin().handle;
const STDOUT_FD = std.Io.File.stdout().handle;
const STDERR_FD = std.Io.File.stderr().handle;

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
    in: fd_t = STDIN_FD,
    out: fd_t = STDOUT_FD,
    err: fd_t = STDERR_FD,
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
    success,
    failure,
    after,
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

var paths: []const Fs.Named = undefined;

pub fn execFromInput(str: []const u8, a: Allocator, _: Io) ![]u8 {
    var itr = TokenIterator{ .raw = str };
    const tokens = try itr.toSlice(a);
    defer a.free(tokens);
    var ps = try Resolver.iterate(a, tokens);
    defer ps.raze(a);
    return a.dupe(u8, ps.first().resolved.str);
}

const ExeKind = enum {
    exe,
    builtin,
    function,
};

pub fn executableType(str: []const u8, a: Allocator, io: Io) ?ExeKind {
    if (Funcs.exists(str)) return .function;
    if (bi.exists(str)) return .builtin;
    const plsfree = makeAbsExecutable(str, a, io) catch {
        if (bi.existsOptional(str)) {
            return .builtin;
        }
        return null;
    };
    a.free(plsfree);
    return .exe;
}

pub fn executable(str: []const u8, a: Allocator, io: Io) bool {
    return executableType(str, a, io) != null;
}

fn validPath(path: []const u8, io: Io) bool {
    const file = Fs.openFile(path, io, .open) orelse return false;
    defer file.close(io);
    if (file.stat(io)) |stat| {
        if (stat.kind != .file) return false;
        return stat.permissions.toMode() & 0o111 > 0;
    } else |_| return false;
}

fn validPathAbs(path: []const u8, io: Io) bool {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    if (file.stat(io)) |stat| {
        if (stat.kind != .file) return false;
        return stat.permissions.toMode() & 0o111 > 0;
    } else |_| return false;
}

/// TODO BUG arg should be absolute but argv[0] should only be absolute IFF
/// there was a / is the original token.
pub fn makeAbsExecutable(str: []const u8, a: Allocator, io: Io) Error![]u8 {
    if (str.len == 0) return Error.NotFound; // Is this always NotFound?
    if (str[0] == '/') {
        if (!validPathAbs(str, io)) return Error.ExeNotFound;
        return try a.dupe(u8, str);
    } else if (std.mem.indexOf(u8, str, "/")) |_| {
        if (!validPath(str, io)) return Error.ExeNotFound;
        var cwd: [2048]u8 = undefined;
        var cwd_fd = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return error.Unknown;
        log.debug("path abs {}\n", .{cwd_fd});
        const length = cwd_fd.realPath(io, &cwd) catch return Error.NotFound;
        return try std.mem.join(a, "/", &[2][]const u8{ cwd[0..length], str });
    }

    var next: []u8 = "";
    for (paths) |path| {
        next = try std.mem.join(a, "/", &[2][]const u8{ path.dir.name, str });
        if (validPathAbs(next, io)) return next;
        a.free(next);
    }
    return Error.ExeNotFound;
}

/// Caller will own memory
fn makeExeZ(str: []const u8, a: Allocator, io: Io) Error!ARG {
    var exe = try makeAbsExecutable(str, a, io);
    if (a.resize(exe, exe.len + 1)) {
        exe.len += 1;
    } else {
        exe = try a.realloc(exe, exe.len + 1);
    }
    exe[exe.len - 1] = 0;
    return exe[0 .. exe.len - 1 :0];
}

fn mkBuiltin(parsed: ParsedIterator, a: Allocator) Error!Builtin {
    var itr = parsed;
    itr.tokens = try a.dupe(Token, itr.tokens);
    return Builtin{ .builtin = itr.first().resolved.str, .argv = itr };
}

/// Caller owns memory of argv, and the open fds
fn mkBinary(itr: *ParsedIterator, a: Allocator, io: Io) Error!Binary {
    var argv: ArrayList(?ARG) = .{};
    errdefer argv.deinit(a);
    errdefer for (argv.items) |arg| {
        a.free(std.mem.span(arg.?));
    };

    try argv.append(a, makeExeZ(itr.first().resolved.str, a, io) catch |e| {
        log.warn("path missing {s}\n", .{itr.first().resolved.str});
        return e;
    });

    while (itr.next()) |t| {
        try argv.append(a, try a.dupeZ(u8, t.resolved.str));
    }

    return Binary{
        .arg = argv.items[0].?,
        .argv = try argv.toOwnedSliceSentinel(a, null),
    };
}

fn mkLogic(a: Allocator, t: Token) !Logic {
    return .{ .logic = try logic_.Logicizer.init(a, t) };
}

fn mkCallableStack(itr: *TokenIterator, a: Allocator, io: Io) Error![]CallableStack {
    var stack: ArrayList(CallableStack) = .{};
    errdefer stack.deinit(a);
    errdefer for (stack.items) |stk| switch (stk.callable) {
        .exec => |b| for (b.argv) |argZ| if (argZ) |arg| a.free(std.mem.span(arg)),
        else => unreachable,
    };
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
            try stack.append(a, .{
                .callable = .{ .logic = mkLogic(a, peek) catch |err| {
                    log.err("Unable to make logic {}\n", .{err});
                    return Error.Unknown;
                } },
                .stdio = StdIo{ .in = STDIN_FD },
                .conditional = null,
            });
            return try stack.toOwnedSlice(a);
        }

        const eslice = itr.toSliceExec(a) catch unreachable;
        defer a.free(eslice);
        var parsed = Resolver.iterate(a, eslice) catch unreachable;
        try parsed.resolveAll(a, io);
        defer parsed.raze(a);

        var io_mode: StdIo = StdIo{ .in = prev_stdout orelse STDIN_FD };
        const condition: ?Conditional = conditional_rule;

        // peek is now the exec operator because of how the iterator works :<
        if (peek.kind == .oper) {
            switch (peek.kind.oper) {
                .pipe => {
                    const pipe = system.pipe2(.{}) catch return Error.OSErr;
                    io_mode.pipe = true;
                    io_mode.out = pipe[1];
                    prev_stdout = pipe[0];
                },
                .fail => conditional_rule = .failure,
                .success => conditional_rule = .success,
                .next => conditional_rule = .after,
                .background => {},
            }
        }

        for (eslice) |maybeio| {
            if (maybeio.kind == .io) {
                switch (maybeio.kind.io) {
                    .Out, .Append => |appnd| {
                        const f = Fs.openFileStdout(maybeio.str, io, appnd == .Append) catch |err| {
                            switch (err) {
                                error.NoClobber => log.err("Noclobber is enabled.\n", .{}),
                                else => log.err("Failed to open file {s}\n", .{maybeio.str}),
                            }
                            return Error.StdIOError;
                        };
                        if (appnd == .Append) {
                            std.debug.assert(linux.lseek(f.handle, 0, linux.SEEK.END) >= 0);
                        }
                        io_mode.out = f.handle;
                    },
                    .In, .HDoc => {
                        if (prev_stdout) |out| {
                            std.posix.close(out);
                            prev_stdout = null;
                        }
                        if (Fs.openFile(maybeio.str, io, .create)) |file| {
                            io_mode.in = file.handle;
                        }
                    },
                    .Err => unreachable,
                }
            }
        }

        for (eslice) |s| log.debug("exe slice {}\n", .{s});
        const exe_str = parsed.first().resolved.str;
        const stk: CallableStack = if (bi.exists(exe_str)) .{
            .callable = .{ .builtin = try mkBuiltin(parsed, a) },
            .stdio = io_mode,
            .conditional = condition,
        } else if (mkBinary(&parsed, a, io)) |bin| .{
            .callable = .{ .exec = bin },
            .stdio = io_mode,
            .conditional = condition,
        } else |err| if (bi.existsOptional(exe_str)) .{
            .callable = .{ .builtin = try mkBuiltin(parsed, a) },
            .stdio = io_mode,
            .conditional = condition,
        } else return err;
        try stack.append(a, stk);
    }
    return try stack.toOwnedSlice(a);
}

fn execBuiltin(b: *Builtin, h: *Hsh, a: Allocator, io: Io) Error!u8 {
    const bi_func = bi.strExec(b.builtin);
    const res = bi_func(h, &b.argv, a, io) catch |err| {
        log.err("builtin error {}\n", .{err});
        return 255;
    };
    b.argv.raze(a);
    return res;
}

fn execBin(e: Binary, a: Allocator) Error!void {
    // TODO manage env

    const environ = Variables.henviron(a);
    const res = linux.execve(e.arg, e.argv, @ptrCast(environ));
    std.debug.assert(res >= 0);
    //switch (res) {
    //    error.FileNotFound => {
    //        // we validate exes internally now this should be impossible
    //        log.err("exe not found {s}\n", .{e.arg});
    //        unreachable;
    //    },
    //    else => log.err("exec error {}\n", .{res}),
    //}
}

fn execLogic(l: *Logic, h: *Hsh, a: Allocator, io: Io) Error!void {
    var logic: ?*logic_.Logicizer = &l.logic;
    log.warn("TODO handle signals\n", .{});
    while (logic) |lexec| {
        logic = lexec.exec(h, a, io) catch |err| {
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
                    const arg = std.mem.span(argz);
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
pub fn exec(input: []const u8, h: *Hsh, a: Allocator, io: Io) Error!void {
    // HACK I don't like it either, but LOOK OVER THERE!!!
    paths = h.fs.paths.items;
    var tty = h.tty;

    var titr = TokenIterator{ .raw = input };
    //defer Variables.razeEphemeral();

    const stack = mkCallableStack(&titr, a, io) catch |e| {
        log.debug("unable to make stack {}\n", .{e});
        return e;
    };
    defer a.free(stack);

    // TODO replace this hack with real logic to determine what env builtins
    // need to execute in.
    if (stack.len == 1 and
        stack[0].stdio.in == STDIN_FD and
        stack[0].stdio.out == STDOUT_FD)
    {
        if (stack[0].callable == .builtin) {
            _ = try execBuiltin(&stack[0].callable.builtin, h, a, io);
            free(a, &stack[0]);
            _ = h.jobs.waitForFg();
            tty.setRaw() catch log.err("Unable to setRaw after child event\n", .{});
            tty.setOwner(null) catch log.err("Unable to setOwner after child event\n", .{});
            return;
        }

        if (stack[0].callable == .logic) {
            execLogic(&stack[0].callable.logic, h, a, io) catch return Error.Unknown;
            free(a, &stack[0]);
            _ = h.jobs.waitForFg();
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

    var fpid: std.posix.pid_t = 0;
    for (stack) |*s| {
        defer free(a, s);
        if (s.conditional) |cond| {
            if (fpid == 0) unreachable;
            const waited_job = h.jobs.waitFor(fpid) catch @panic("job doesn't exist");
            switch (cond) {
                .after => {},
                .failure => {
                    if (waited_job.exit_code) |ec| {
                        if (ec == 0) continue;
                    }
                },
                .success => {
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

        fpid = @intCast(linux.fork());
        if (fpid < 0) unreachable;
        if (fpid == 0) {
            if (s.stdio.in != std.posix.STDIN_FILENO) {
                if (linux.dup2(s.stdio.in, std.posix.STDIN_FILENO) < 0) return Error.OSErr;
                std.posix.close(s.stdio.in);
            }
            if (s.stdio.out != std.posix.STDOUT_FILENO) {
                if (linux.dup2(s.stdio.out, std.posix.STDOUT_FILENO) < 0) return Error.OSErr;
                std.posix.close(s.stdio.out);
            }
            if (s.stdio.err != std.posix.STDERR_FILENO) {
                if (linux.dup2(s.stdio.err, std.posix.STDERR_FILENO) < 0) return Error.OSErr;
                std.posix.close(s.stdio.err);
            }

            switch (s.callable) {
                .builtin => |*b| {
                    std.posix.system.exit(try execBuiltin(b, h, a, io));
                },
                .exec => |e| {
                    try execBin(e, a);
                    unreachable;
                },
                .logic => unreachable,
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
        try h.jobs.add(.{
            .status = if (s.stdio.pipe) .piped else .running,
            .pid = fpid,
            .name = try a.dupe(u8, name),
        }, a);
        if (s.stdio.in != std.posix.STDIN_FILENO) std.posix.close(s.stdio.in);
        if (s.stdio.out != std.posix.STDOUT_FILENO) std.posix.close(s.stdio.out);
        if (s.stdio.err != std.posix.STDERR_FILENO) std.posix.close(s.stdio.err);
    }

    _ = h.jobs.waitForFg();
    tty.setRaw() catch log.err("Unable to setRaw after child event\n", .{});
    tty.setOwner(null) catch log.err("Unable to setOwner after child event\n", .{});
}

/// I hate all of this but stdlib likes to panic instead of manage errors
/// so we're doing the whole ChildProcess thing now
pub const ChildResult = struct {
    job: *const Jobs.Job,
    stdout: []u8,
};

/// Tokenizes, parses, and executes a a valid argv string.
pub fn childParsed(argv: []const u8, h: *Hsh, a: Allocator, io: Io) Error!ChildResult {
    var itr = TokenIterator{ .raw = argv };

    const slice = try itr.toSliceExec(a);
    defer a.free(slice);

    var parsed = Resolver.iterate(a, slice) catch return Error.Parse;
    defer parsed.raze(a);
    var list = ArrayListManaged([]const u8).init(a);
    while (parsed.next()) |p| {
        try list.append(p.resolved.str);
        log.debug("Exec.childParse {} {s}\n", .{ list.items.len, p.resolved.str });
    } // Precomptue
    const strs = try list.toOwnedSlice();
    defer a.free(strs);

    return child(strs, h, a, io);
}

/// Collects, and reformats argv into it's null terminated counterpart for
/// execvpe. Caller retains ownership of memory.
pub fn child(argv: []const []const u8, h: *Hsh, a: Allocator, io: Io) !ChildResult {
    if (argv.len == 0 or argv[0].len == 0) return Error.NotFound;
    signal.block();
    defer signal.unblock();
    var list: ArrayList(?[*:0]u8) = .{};
    for (argv) |arg| {
        try list.append(a, (try a.dupeZ(u8, arg)).ptr);
    }
    const argvZ: [:null]?[*:0]u8 = try list.toOwnedSliceSentinel(a, null);

    defer {
        for (argvZ) |*argm| {
            if (argm.*) |arg| {
                a.free(std.mem.span(arg));
            }
        }
        a.free(argvZ);
    }
    return childZ(argvZ, h, a, io);
}

/// Preformatted version of child. Accepts the null, and 0 terminated versions
/// to pass directly to exec. Caller maintains ownership of argv
pub fn childZ(argv: [:null]const ?[*:0]const u8, h: *Hsh, a: Allocator, io: Io) Error!ChildResult {
    const pipe = system.pipe2(.{}) catch unreachable;
    const pid = linux.fork();
    if (pid < 0) unreachable;
    if (pid == 0) {
        // we kid nao
        _ = linux.dup2(pipe[1], std.posix.STDOUT_FILENO);
        _ = linux.close(pipe[0]);
        _ = linux.close(pipe[1]);
        const environ = Variables.henviron(a);
        _ = linux.execve(argv[0].?, argv.ptr, environ);
        //catch {
        //    log.err("Unexpected error in childZ\n", .{});
        //    return Error.ChildExecFailed;
        //};
        unreachable;
    }
    std.posix.close(pipe[1]);
    defer std.posix.close(pipe[0]);
    const name = std.mem.span(argv[0].?);
    try h.jobs.add(.{
        .status = .child,
        .pid = @intCast(pid),
        .name = try a.dupe(u8, name[0 .. name.len - 1]),
    }, a);

    var r_b: [0x8000]u8 = undefined;

    var f = std.Io.File{ .handle = pipe[0] };
    var r = f.reader(io, &r_b);

    const job = h.jobs.waitFor(@intCast(pid)) catch return error.Unknown;
    const output = r.interface.allocRemaining(a, .limited(0x8000)) catch unreachable;

    return .{ .job = job, .stdout = output };
}

test "mkstack" {
    var a = std.testing.allocator;
    const io = std.testing.io;
    paths = &[1]Fs.Named{.{ .dir = .{ .name = "/usr/bin", .dir = undefined } }};
    var ti = TokenIterator{ .raw = "ls | sort" };

    try std.testing.expectEqualStrings("ls", ti.first().str);
    ti.skip();
    try std.testing.expectEqualStrings("|", ti.next().?.str);
    ti.skip();
    try std.testing.expectEqualStrings("sort", ti.next().?.str);

    ti.restart();
    const stk = try mkCallableStack(&ti, a, io);
    try std.testing.expect(stk.len == 2);
    for (stk) |*s| free(a, s);
    a.free(stk);

    ti = TokenIterator{ .raw = "zig build && zig-out/bin/hsh" };
    ti.restart();
    const stk2 = try mkCallableStack(&ti, a, io);
    for (stk2) |*s| free(a, s);
    a.free(stk2);

    try std.testing.expectEqualStrings("zig", ti.first().str);
    ti.skip();
    try std.testing.expectEqualStrings("build", ti.next().?.str);
    ti.skip();
    try std.testing.expectEqualStrings("&&", ti.next().?.str);
    ti.skip();
    try std.testing.expectEqualStrings("zig-out/bin/hsh", ti.next().?.str);
}

test {
    _ = std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const system = Io.Threaded;

const Hsh = @import("hsh.zig");
const Jobs = @import("jobs.zig");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const ArrayList = std.ArrayList;
const ArrayListManaged = std.array_list.Managed;
const Token = @import("token.zig");
const TokenIterator = Token.Iterator;
const parse = @import("parse.zig");
const Resolver = parse.Resolver;
const ParsedIterator = parse.Iterator;
const log = @import("log.zig");
const fd_t = std.posix.fd_t;
const bi = @import("builtins.zig");
const Fs = @import("fs.zig");
const signal = @import("signals.zig");
const logic_ = @import("logic.zig");
const Variables = @import("variables.zig");
const Funcs = @import("funcs.zig");
const linux = std.os.linux;
