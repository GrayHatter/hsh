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
    StdIOerror,
};

const Arg = [*:0]u8;
const ArgV = [:null]?Arg;

pub const Options = struct {
    fork: bool,

    pub const default: Options = .{
        .fork = true,
    };

    pub const no_fork: Options = .{
        .fork = false,
    };
};

const ProcIo = struct {
    in: ?system.fd_t = null,
    out: ?system.fd_t = null,
    err: ?system.fd_t = null,
    pipe: bool = false,

    pub const stdin_fd = Io.File.stdin().handle;
    pub const stdout_fd = Io.File.stdout().handle;
    pub const stderr_fd = Io.File.stderr().handle;

    inline fn dup(pio: ProcIo) !void {
        if (pio.in) |in| {
            if (system.dup2(in, stdin_fd) < 0) return error.OSErr;
            if (system.close(in) != 0) return error.OSErr;
        }
        if (pio.out) |out| {
            if (system.dup2(out, stdout_fd) < 0) return error.OSErr;
            if (system.close(out) != 0) return error.OSErr;
        }
        if (pio.err) |err| {
            if (system.dup2(err, stderr_fd) < 0) return error.OSErr;
            if (system.close(err) != 0) return error.OSErr;
        }
    }

    inline fn closeAll(pio: ProcIo) void {
        if (pio.in) |in| if (system.close(in) != 0) unreachable;
        if (pio.out) |out| if (system.close(out) != 0) unreachable;
        if (pio.err) |err| if (system.close(err) != 0) unreachable;
    }

    fn isSimple(pio: ProcIo) bool {
        return pio.in == null and pio.out == null and pio.err == null;
    }
};

const Binary = struct {
    arg: Arg,
    argv: ArgV,

    /// Caller owns memory of argv, and the open fds
    fn init(parsed: ParsedIterator, fs: Fs, a: Allocator, io: Io) !Binary {
        var argv: ArrayList(?Arg) = .{};
        errdefer argv.deinit(a);
        errdefer for (argv.items) |arg| {
            a.free(std.mem.span(arg.?));
        };

        var itr = try parsed.clone(a);
        defer itr.raze(a);
        try argv.append(a, makeExeZ(itr.first().resolved.str, fs, a, io) catch |e| {
            log.warn("path missing {s}\n", .{itr.first().resolved.str});
            return e;
        });

        while (itr.next()) |t| {
            try argv.append(a, try a.dupeZ(u8, t.resolved.str));
        }

        return .{
            .arg = argv.items[0].?,
            .argv = try argv.toOwnedSliceSentinel(a, null),
        };
    }

    fn exec(e: Binary, a: Allocator) noreturn {
        // TODO manage env
        const environ = Variables.henviron(a);
        _ = system.execve(e.arg, e.argv, @ptrCast(environ));
        system.abort();
        //switch (res) {
        //    error.FileNotFound => {
        //        // we validate exes internally now this should be impossible
        //        log.err("exe not found {s}\n", .{e.arg});
        //        unreachable;
        //    },
        //    else => log.err("exec error {}\n", .{res}),
        //}
    }
};

const Builtin = struct {
    builtin: []const u8,
    argv: ParsedIterator,

    fn init(parsed: ParsedIterator, a: Allocator) !Builtin {
        var itr = try parsed.clone(a);
        log.debug("builtin str '{s}'\n", .{itr.first().resolved.str});
        return .{
            .builtin = itr.first().resolved.str,
            .argv = itr,
        };
    }

    fn oneshot(b: *Builtin, h: *Hsh, a: Allocator, io: Io) u8 {
        const bi_func = builtins.strExec(b.builtin);
        const res = bi_func(h, &b.argv, a, io) catch |err| {
            log.err("builtin error {}\n", .{err});
            system.exit(255);
        };
        b.argv.raze(a);
        return res;
    }

    fn exec(b: *Builtin, h: *Hsh, a: Allocator, io: Io) noreturn {
        system.exit(b.oneshot(h, a, io));
    }
};

const Logic = struct {
    logic: logic_.Logicizer,

    fn init(a: Allocator, t: Token) !Logic {
        return .{
            .logic = logic_.Logicizer.init(a, t) catch |e| {
                log.err("Unable to make logic {}\n", .{e});
                return error.Unknown;
            },
        };
    }
    fn exec(l: *Logic, h: *Hsh, a: Allocator, io: Io) !void {
        var logic: ?*logic_.Logicizer = &l.logic;
        log.warn("TODO handle signals\n", .{});
        while (logic) |lexec| {
            logic = lexec.exec(h, a, io) catch |err| {
                log.err("error found when attempting to exec logic {}\n", .{err});
                return error.Unknown;
            };
        }
    }
};

const Conditional = enum {
    success,
    failure,
    after,
};

const CallableStack = struct {
    callable: Callable,
    proc_io: ProcIo = .{},
    conditional: ?Conditional = null,

    fn raze(s: *CallableStack, a: Allocator) void {
        switch (s.callable) {
            .builtin => {}, // Free'd by the executor
            .binary => |bin| {
                // TODO validate this clears all pointers correctly
                for (bin.argv) |*marg| {
                    if (marg.*) |argz| {
                        const arg = std.mem.span(argz);
                        a.free(arg);
                    }
                }
                a.free(bin.argv);
            },
            .logic => |*l| l.logic.raze(),
        }
    }
};

const Callable = union(enum) {
    binary: Binary,
    builtin: Builtin,
    logic: Logic,

    pub fn initBinary(itr: ParsedIterator, fs: Fs, a: Allocator, io: Io) !Callable {
        return .{ .binary = try .init(itr, fs, a, io) };
    }
    pub fn initBuiltin(itr: ParsedIterator, a: Allocator) !Callable {
        return .{ .builtin = try .init(itr, a) };
    }
    pub fn initLogic(a: Allocator, t: Token) !Callable {
        return .{ .logic = try .init(a, t) };
    }
};

const ExeKind = enum {
    exe,
    builtin,
    function,
};

pub fn execFromInput(str: []const u8, a: Allocator, io: Io) ![]u8 {
    var itr = TokenIterator{ .raw = str };
    const tokens = try itr.toSlice(a);
    defer a.free(tokens);
    var ps = try Resolver.iterate(a, tokens);
    try ps.resolveAll(a, io);
    defer ps.raze(a);
    return a.dupe(u8, ps.first().resolved.str);
}

pub fn executableType(str: []const u8, fs: Fs, a: Allocator, io: Io) ?ExeKind {
    if (Funcs.exists(str)) return .function;
    if (builtins.exists(str)) return .builtin;
    const plsfree = makeAbsExecutable(str, fs, a, io) catch {
        if (builtins.existsOptional(str)) return .builtin;
        return null;
    };
    a.free(plsfree);
    return .exe;
}

pub fn executable(str: []const u8, fs: Fs, a: Allocator, io: Io) bool {
    return executableType(str, fs, a, io) != null;
}

fn validPath(path: []const u8, io: Io) bool {
    const file = Fs.open(path, io) orelse return false;
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
pub fn makeAbsExecutable(str: []const u8, fs: Fs, a: Allocator, io: Io) ![]u8 {
    if (str.len == 0) return error.NotFound; // Is this always NotFound?
    if (str[0] == '/') {
        if (!validPathAbs(str, io)) return error.ExeNotFound;
        return try a.dupe(u8, str);
    } else if (findScalar(u8, str, '/')) |_| {
        if (!validPath(str, io)) return error.ExeNotFound;
        return try concat(a, u8, &[3][]const u8{ fs.cwd.name, "/", str });
    }

    var next: []u8 = "";
    for (fs.paths.items) |path| {
        if (path == .closed_dir) continue;
        next = try std.mem.join(a, "/", &[2][]const u8{ path.dir.name, str });
        if (validPathAbs(next, io)) return next;
        a.free(next);
    }
    return error.ExeNotFound;
}

/// Caller will own memory
fn makeExeZ(str: []const u8, fs: Fs, a: Allocator, io: Io) !Arg {
    var exe = try makeAbsExecutable(str, fs, a, io);
    if (a.resize(exe, exe.len + 1)) {
        exe.len += 1;
    } else {
        exe = try a.realloc(exe, exe.len + 1);
    }
    exe[exe.len - 1] = 0;
    return exe[0 .. exe.len - 1 :0];
}

fn mkCallableStack(itr: *TokenIterator, fs: Fs, a: Allocator, io: Io) ![]CallableStack {
    var stack: ArrayList(CallableStack) = .{};
    errdefer stack.deinit(a);
    errdefer for (stack.items) |stk| switch (stk.callable) {
        .binary => |b| for (b.argv) |argZ| if (argZ) |arg| a.free(std.mem.span(arg)),
        else => unreachable,
    };
    var prev_stdout: ?system.fd_t = null;
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
                .callable = try .initLogic(a, peek),
                .proc_io = .{ .in = ProcIo.stdin_fd },
                .conditional = null,
            });
            return try stack.toOwnedSlice(a);
        }

        const eslice = itr.toSliceExec(a) catch unreachable;
        defer a.free(eslice);
        var parsed = Resolver.iterate(a, eslice) catch unreachable;
        try parsed.resolveAll(a, io);
        defer parsed.raze(a);

        var io_mode: ProcIo = .{ .in = prev_stdout };
        const condition: ?Conditional = conditional_rule;

        // peek is now the exec operator because of how the iterator works :<
        if (peek.kind == .oper) {
            switch (peek.kind.oper) {
                .pipe => {
                    const pipe = system.pipe2(.{}) catch return error.OSErr;
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
                            return error.StdIOerror;
                        };
                        if (appnd == .Append) {
                            assert(system.lseek(f.handle, 0, system.SEEK.END) >= 0);
                        }
                        io_mode.out = f.handle;
                    },
                    .In, .HDoc => {
                        if (prev_stdout) |out| {
                            if (system.close(out) != 0) unreachable;
                            prev_stdout = null;
                        }
                        if (Fs.writable(maybeio.str, io, .create)) |file| {
                            io_mode.in = file.handle;
                        }
                    },
                    .Err => unreachable,
                }
            }
        }

        for (eslice) |s| log.debug("exe slice {}\n", .{s});
        const exe_str = parsed.first().resolved.str;
        const stk: CallableStack = if (builtins.exists(exe_str)) .{
            .callable = try .initBuiltin(parsed, a),
            .proc_io = io_mode,
            .conditional = condition,
        } else if (Callable.initBinary(parsed, fs, a, io)) |bin| .{
            .callable = bin,
            .proc_io = io_mode,
            .conditional = condition,
        } else |err| if (builtins.existsOptional(exe_str)) .{
            .callable = try .initBuiltin(parsed, a),
            .proc_io = io_mode,
            .conditional = condition,
        } else return err;
        try stack.append(a, stk);
    }
    return try stack.toOwnedSlice(a);
}

/// input is a string ownership is retained by the caller
pub fn exec(input: []const u8, h: *Hsh, a: Allocator, io: Io, options: Options) !void {
    // HACK I don't like it either, but LOOK OVER THERE!!!

    if (!options.fork) return error.NotImplemented;

    var titr = TokenIterator{ .raw = input };

    const stack = mkCallableStack(&titr, h.fs, a, io) catch |e| {
        log.debug("unable to make stack {}\n", .{e});
        return e;
    };

    // TODO replace this hack with real logic to determine what env builtins
    // need to execute in.
    if (stack.len == 1 and stack[0].proc_io.isSimple()) oneshot: {
        log.debug("one shot {}\n", .{stack[0].callable});
        switch (stack[0].callable) {
            .builtin => |*bi| _ = bi.oneshot(h, a, io),
            .logic => |*lg| try lg.exec(h, a, io),
            .binary => break :oneshot,
        }
        _ = h.jobs.waitForFg();
        stack[0].raze(a);
        return;
    }
    defer a.free(stack);

    h.tty.set(.normal) catch |e| {
        log.err("TTY didn't respond {}\n", .{e});
        return error.Unknown;
    };
    defer h.tty.set(.raw) catch log.err("Unable to setRaw after child event\n", .{});
    defer h.tty.setOwner(null) catch log.err("Unable to setOwner after child event\n", .{});

    errdefer h.tty.set(.raw) catch |e| {
        log.err("TTY didn't respond as expected after exec error{}\n", .{e});
    };

    // This is where I'd like environ to live, but I'm not ready to change the
    // api in this commit
    //const environ = Variables.henviron();

    var fpid: system.pid_t = 0;
    for (stack) |*s| {
        defer s.raze(a);
        if (s.conditional) |cond| {
            if (fpid == 0) unreachable;
            const waited_job = h.jobs.waitFor(fpid) catch @panic("job doesn't exist");
            switch (cond) {
                .after => {},
                .failure => if (waited_job.status == .exited and waited_job.status.exited == 0) continue,
                .success => if (waited_job.status == .exited and waited_job.status.exited != 0) continue,
            }
            // repush original because spinning will revert
            h.tty.set(.normal) catch |e| {
                log.err("TTY didn't respond {}\n", .{e});
                return error.Unknown;
            };
        }

        fpid = @intCast(system.fork());
        if (fpid < 0) unreachable;
        if (fpid == 0) {
            s.proc_io.dup() catch return error.OSError;
            defer comptime unreachable;

            switch (s.callable) {
                .builtin => |*b| b.exec(h, a, io),
                .binary => |bin| bin.exec(a),
                .logic => unreachable,
            }
        }
        // Parent

        //log.err("chld pid {}\n", .{fpid});
        const name = switch (s.callable) {
            .builtin => |b| b.builtin,
            .binary => |e| std.mem.sliceTo(e.arg, 0),
            .logic => "logic stuff",
        };
        try h.jobs.add(.{
            .status = .{ .running = if (s.proc_io.pipe) .pipeline else .forground },
            .pid = fpid,
            .name = try a.dupe(u8, name),
        }, a);

        s.proc_io.closeAll();
    }

    _ = h.jobs.waitForFg();
}

/// I hate all of this but stdlib likes to panic instead of manage errors
/// so we're doing the whole ChildProcess thing now
pub const ChildResult = struct {
    pid: i32,
    name: [*:0]const u8,
    stdout: File,

    pub fn waitCollectAlloc(res: ChildResult, a: Allocator, io: Io) []u8 {
        var r_b: [0x8000]u8 = undefined;
        var r = res.stdout.reader(io, &r_b);
        var job_: Jobs.Job = .init(res.pid, null);
        _ = job_.waitFor() catch unreachable;
        const output = r.interface.allocRemaining(a, .limited(0x8000)) catch unreachable;
        return output;
    }

    pub fn job(res: ChildResult, a: Allocator) Jobs.Job {
        const name = span(res.name);
        return .init(res.pid, a.dupe(u8, name) catch unreachable);
    }

    pub fn raze(res: ChildResult) void {
        if (system.close(res.stdout.handle) != 0) unreachable;
    }
};

/// Tokenizes, parses, and executes a a valid argv string.
pub fn childFromSlice(string: []const u8, h: *Hsh, a: Allocator, io: Io) !ChildResult {
    if (string.len == 0) return error.NotFound;
    signal.block();
    defer signal.unblock();

    var itr = TokenIterator{ .raw = string };

    const slice = try itr.toSliceExec(a);
    defer a.free(slice);

    var parsed = Resolver.iterate(a, slice) catch return error.Parse;
    defer parsed.raze(a);
    try parsed.resolveAll(a, io);

    var args_list: ArrayList(?[*:0]const u8) = .{};
    defer args_list.deinit(a);
    for (parsed.resolved.items) |arg| {
        try args_list.append(a, (try a.dupeZ(u8, arg.resolved.str)));
    }
    try args_list.append(a, null);

    defer while (args_list.pop()) |argZ| if (argZ) |arg| a.free(span(arg));

    const argv: [:null]const ?[*:0]const u8 = args_list.items[0 .. args_list.items.len - 1 :null];
    const chld = try childZ(argv, a);
    try h.jobs.add(chld.job(a), a);
    return chld;
}

/// Collects, and reformats argv into it's null terminated counterpart for
/// execvpe. Caller retains ownership of memory.
pub fn child(comptime argv: []const [:0]const u8, a: Allocator) !ChildResult {
    if (argv.len == 0) return error.NotFound;
    signal.block();
    defer signal.unblock();
    var list: [argv.len + 1]?[*:0]const u8 = @splat(null);
    inline for (list[0..argv.len], argv) |*dst, arg| dst.* = arg.ptr;
    return childZ(list[0..argv.len :null], a);
}

/// Preformatted version of child. Accepts the null, and 0 terminated versions
/// to pass directly to exec. Caller maintains ownership of argv
pub fn childZ(argv: [:null]const ?[*:0]const u8, a: Allocator) !ChildResult {
    const stdout_ours, const stdout_child = system.pipe2(.{}) catch unreachable;
    const pid = system.fork();
    if (pid < 0) unreachable;
    if (pid == 0) {
        // we kid nao
        defer comptime unreachable;
        _ = system.dup2(stdout_child, system.STDOUT_FILENO);
        _ = system.close(stdout_ours);
        _ = system.close(stdout_child);
        const environ = Variables.henviron(a);
        _ = system.execve(argv[0].?, argv.ptr, environ);
        system.abort();
    }
    if (system.close(stdout_child) != 0) unreachable;

    return .{
        .pid = @intCast(pid),
        .name = argv[0].?,
        .stdout = .{ .handle = stdout_ours },
    };
}

test "mkstack" {
    var a = std.testing.allocator;
    const io = std.testing.io;

    const fs: Fs = .testingFs();

    var ti = TokenIterator{ .raw = "ls | sort" };

    try std.testing.expectEqualStrings("ls", ti.first().str);
    ti.skip();
    try std.testing.expectEqualStrings("|", ti.next().?.str);
    ti.skip();
    try std.testing.expectEqualStrings("sort", ti.next().?.str);

    ti.restart();
    const stk = try mkCallableStack(&ti, fs, a, io);
    try std.testing.expect(stk.len == 2);
    for (stk) |*s| s.raze(a);
    a.free(stk);

    ti = TokenIterator{ .raw = "zig build && zig-out/bin/hsh" };
    ti.restart();
    const stk2 = try mkCallableStack(&ti, fs, a, io);
    for (stk2) |*s| s.raze(a);
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
const Reader = Io.Reader;
const File = Io.File;

const Hsh = @import("hsh.zig");
const system = @import("system.zig");
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
const builtins = @import("builtins.zig");
const Fs = @import("fs.zig");
const signal = @import("signals.zig");
const logic_ = @import("logic.zig");
const Variables = @import("variables.zig");
const Funcs = @import("funcs.zig");
const assert = std.debug.assert;
const findScalar = std.mem.findScalar;
const concat = std.mem.concat;
const span = std.mem.span;
