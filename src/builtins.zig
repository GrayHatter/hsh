// files should be lowercased, but #YOLO
pub const Alias = @import("builtins/alias.zig");
pub const Export = @import("builtins/export.zig");
pub const Set = @import("builtins/set.zig");
//pub const Source = @import("builtins/source.zig");
pub const Which = @import("builtins/which.zig");

var Self = @This();

pub const Err = error{
    Unknown,
    Memory,
    OutOfMemory,
    IO,
    StdOut,
    InvalidToken,
    InvalidCommand,
    FileSysErr,
    Overflow,
    InvalidCharacter,
};

pub const BuiltinFn = *const fn (*Hsh, *ParsedIterator, Allocator, Io) Err!u8;

pub const Builtins = union(enum) {
    //pipeline: Pipeline,
    @"export": Export,
    alias: Alias,
    bg: Jobs.Bg,
    cd: Cd,
    die: Die,
    echo: Echo,
    exit: Exit,
    fg: Jobs.Fg,
    jobs: Jobs,
    set: Set,
    //source: Source,
    which: Which,
    // DEBUGGING BUILTINS
    tty: Tty,
};

/// Optional builtins "exist" only if they don't already exist on the system.
pub const BuiltinWeak = enum {
    status,
    version,
};

var global_io: std.Io = undefined;
pub fn init(a: Allocator, io: Io) void {
    global_io = io;
    Export.init();
    Alias.init();
    Set.init(a);
}

pub fn save(h: *Hsh, w: *Writer) !void {
    try Set.save(h, w);
    try Alias.save(h, w);
    try Export.save(h, w);
}

pub fn raze(a: Allocator) void {
    Set.raze(a);
    Alias.raze(a);
    Export.raze(a);
}

pub fn builtinToName(comptime bi: Builtins) []const u8 {
    return @tagName(bi);
}

pub fn exec(self: Builtins) BuiltinFn {
    return switch (self) {
        inline else => |_, t| @TypeOf(t).call,
    };
}

/// Optional builtins "exist" only if they don't already exist on the system.
pub fn execOpt(self: BuiltinWeak) BuiltinFn {
    return switch (self) {
        .status => status,
        .version => version,
    };
}

/// Caller must ensure this builtin exists by calling exists, or optionalExists
pub fn strExec(str: []const u8) BuiltinFn {
    inline for (@typeInfo(Builtins).@"union".fields) |f| {
        if (eql(u8, f.name, str)) return f.type.call;
    }
    inline for (@typeInfo(BuiltinWeak).@"enum".fields) |f| {
        if (eql(u8, f.name, str)) return execOpt(@enumFromInt(f.value));
    }
    log.err("strExec panic on {s}\n", .{str});
    unreachable;
}

pub fn exists(str: []const u8) bool {
    inline for (@typeInfo(Builtins).@"union".fields) |f| {
        if (std.mem.eql(u8, f.name, str)) return true;
    }
    return false;
}

/// Optional builtins "exist" only if they don't already exist on the system.
/// this is not enforced internally callers are expected to behave
pub fn existsOptional(str: []const u8) bool {
    inline for (@typeInfo(BuiltinWeak).@"enum".fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, str)) return true;
    }
    return false;
}

/// reusable print function for builtins
pub fn print(comptime format: []const u8, args: anytype) Err!void {
    var b: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(global_io, &b);
    stdout.interface.print(format, args) catch |err| {
        log.err(
            "Builtin unable to write to stdout: {}\n    but stderr will work right?\n",
            .{err},
        );
        return Err.StdOut;
    };
    stdout.interface.flush() catch unreachable;
}

pub const Cd = struct {
    /// Someone should add some sane input sanitzation to this
    fn call(hsh: *Hsh, titr: *ParsedIterator, a: Allocator, io: Io) Err!u8 {
        // TODO pushd and popd
        assert(eql(u8, "cd", titr.first().resolved.str));
        defer titr.raze(a);

        while (titr.next()) |t| {
            hsh.fs.cd(t.resolved.str, a, io) catch |err| {
                log.err("Unable to change directory because {}\n", .{err});
                return 1;
            };
            return 0;
        } else {
            hsh.fs.cd("", a, io) catch @panic("CD $HOME should never fail");
            return 0;
        }
    }
};

pub const Die = struct {
    pub fn call(_: *Hsh, _: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
        unreachable;
    }
};

pub const Exit = struct {
    pub fn call(_: *Hsh, i: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
        std.debug.assert(std.mem.eql(u8, "exit", i.first().resolved.str));
        var code: u8 = 0;
        if (i.next()) |next| {
            const parsed_code = std.fmt.parseInt(isize, next.resolved.str, 10) catch |err| {
                log.err("Failed to parse exit code because {}\n", .{err});
                return err;
            };
            code = @truncate(@as(usize, @bitCast(parsed_code)));
        } else {
            // TODO: Get exit code of last command
        }
        if (true) unreachable;
        //hsh.draw.raze();
        //hsh.tty.raze();
        //hsh.raze();
        //std.posix.exit(code);
    }
};

pub const Echo = struct {
    pub fn call(_: *Hsh, pi: *ParsedIterator, a: Allocator, _: Io) Err!u8 {
        std.debug.assert(std.mem.eql(u8, "echo", pi.first().resolved.str));
        defer pi.raze(a);
        var newline = true;

        if (pi.next()) |next| {
            if (std.mem.eql(u8, "-n", next.resolved.str)) {
                newline = false;
            } else {
                try print("{s} ", .{next.resolved.str});
            }
        }
        while (pi.next()) |next| {
            try print("{s} ", .{next.resolved.str});
        }
        if (newline) try print("\n", .{});
        return 0;
    }
};

pub const Jobs = struct {
    const Jobs_ = @import("jobs.zig");
    pub fn call(hsh: *Hsh, _: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
        for (hsh.jobs.jobs.items) |j| {
            try print("{}", .{j});
        }
        return 0;
    }
    pub const Fg = struct {
        /// TODO implement job selection support
        fn call(hsh: *Hsh, _: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
            if (hsh.jobs.getBgPtr()) |job| {
                try print("Restarting job\n", .{});
                if (!job.forground(&hsh.tty)) {
                    try print("Not not alive\n", .{});
                    return 1;
                }
                return 0;
            }
            try print("No resumeable jobs\n", .{});
            return 1;
        }
    };
    pub const Bg = struct {
        fn call(_: *Hsh, _: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
            print("bg not yet implemented\n", .{}) catch return Err.Unknown;
            return 0;
        }
    };
};

fn noimpl(_: *Hsh, i: *ParsedIterator) Err!u8 {
    print("{s} not yet implemented\n", .{i.first().resolved.str});
    while (i.next()) |_| {}
    return 0;
}

test "builtins" {
    const str = @tagName(Builtins.alias);
    var bi: bool = false;
    inline for (@typeInfo(Builtins).@"union".fields) |f| {
        if (std.mem.eql(u8, f.name, str)) bi = true;
    }
    try std.testing.expect(bi);
    var bi2 = false;
    const never = "pleasegodletthisneverbecomeabuiltin";
    inline for (@typeInfo(Builtins).@"union".fields[0..]) |f| {
        if (std.mem.eql(u8, f.name, never)) bi2 = true;
    }
    try std.testing.expect(!bi2);
}

test "builtins alias" {
    try std.testing.expect(exists(@tagName(Builtins.alias)));
    try std.testing.expect(exists(@tagName(Builtins.cd)));
    try std.testing.expect(exists(@tagName(Builtins.echo)));
    try std.testing.expect(exists(@tagName(Builtins.which)));

    try std.testing.expect(!exists("BLERG"));
}

//DEBUGGING BUILTINS
pub const Tty = struct {
    fn call(hsh: *Hsh, pi: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
        std.debug.assert(std.mem.eql(u8, "tty", pi.first().resolved.str));

        if (pi.next()) |next| {
            if (std.mem.eql(u8, "raw", next.resolved.str)) {
                try print("changing tty from \n{any}\n", .{hsh.tty.getAttr().?});
                hsh.tty.setRaw() catch return Err.Unknown;
                try print("to raw \n{}\n", .{hsh.tty.getAttr().?});
            } else if (std.mem.eql(u8, "orig", next.resolved.str)) {
                try print("changing tty from \n{any}\n", .{hsh.tty.getAttr().?});
                hsh.tty.setOrig() catch return Err.Unknown;
                try print("to orig \n{}\n", .{hsh.tty.getAttr().?});
            } else {
                try print("changing tty from \n{any}\n", .{hsh.tty.getAttr().?});
            }
        } else {
            try print("current tty settings \n{any}\n", .{hsh.tty.getAttr().?});
        }

        return 0;
    }
};

// Optional builtins may not be available depending on path binaries

fn status(_: *Hsh, _: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
    print("status not yet implemented\n", .{}) catch return Err.Unknown;
    return 0;
}

fn version(_: *Hsh, _: *ParsedIterator, _: Allocator, _: Io) Err!u8 {
    try print("version: {}\n", .{hsh_build.version});
    return 0;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const eql = std.mem.eql;
const Hsh = @import("hsh.zig");
const log = @import("log.zig");
const hsh_build = @import("hsh_build");
pub const Token = @import("token.zig");
pub const ParsedIterator = @import("parse.zig").Iterator;
pub const Variables = @import("variables.zig");
const assert = std.debug.assert;
