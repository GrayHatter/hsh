const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub const IOKind = enum {
    In,
    HDoc,
    Out,
    Append,
    Err,
};

pub const OpKind = enum {
    Pipe,
    Next,
    Success,
    Fail,
    Background,
};
pub const Error = error{
    Unknown,
    Memory,
    LineTooLong,
    TokenizeFailed,
    InvalidSrc,
    InvalidLogic,
    OpenGroup,
    OpenLogic,
    Empty,
};

pub const Reserved = enum {
    If,
    Then,
    Else,
    Elif,
    Fi,
    Do,
    Done,
    Case,
    Esac,
    While,
    Until,
    For,
    In,

    pub fn fromStr(str: []const u8) ?Reserved {
        var lower: [6]u8 = undefined;
        inline for (@typeInfo(Reserved).Enum.fields) |f| {
            const name = std.ascii.lowerString(&lower, f.name);
            if (std.mem.eql(u8, str, name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const Logic = struct {};

pub const Kind = union(enum) {
    // legacy types, TODO REMOVE
    ws: void,
    path: void,
    vari: void,

    comment: void,

    // new types
    err: void,
    io: IOKind,
    logic: Logic,
    nos: void,
    oper: OpKind,
    quote: void,
    resr: Reserved,
    subp: void,
    word: void,
};

pub const Token = struct {
    str: []const u8,
    kind: Kind = .nos,
    parsed: bool = false,
    subtoken: u8 = 0,
    // I hate this but I've spent too much time on this already #YOLO
    resolved: ?[]u8 = null,
    substr: ?[]const u8 = null,

    pub fn make(str: []const u8, k: Kind) Token {
        return Token{
            .str = str,
            .kind = k,
        };
    }

    pub fn format(self: Token, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        // this is what net.zig does, so it's what I do
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "Token({}){{{s}}}", .{ self.kind, self.str });
    }

    pub fn cannon(self: Token) []const u8 {
        if (self.resolved) |r| return r;

        return switch (self.kind) {
            .quote => return self.str[1 .. self.str.len - 1],
            .io, .vari, .path => return self.substr orelse self.str,
            .comment => return self.str[0..0],
            else => self.str,
        };
    }
};

pub const TokenIterator = struct {
    raw: []const u8,
    index: ?usize = null,
    token: Token = undefined,

    exec_index: ?usize = null,

    const Self = @This();

    pub fn first(self: *Self) *const Token {
        self.restart();
        if (self.next()) |n| {
            return n;
        } else {
            self.token = .{ .str = "" };
            return &self.token;
        }
    }

    pub fn next(self: *Self) ?*const Token {
        if (self.index) |i| {
            if (i >= self.raw.len) {
                return null;
            }
            if (Tokenizer.any(self.raw[i..])) |t| {
                self.token = t;
                self.index = i + t.str.len;
                return &self.token;
            } else |e| {
                std.debug.print("tokenizer error {}\n", .{e});
                return null;
            }
        } else {
            self.index = 0;
            return self.next();
        }
    }

    pub fn skip(self: *Self) void {
        _ = self.next();
    }

    /// returns next until index reaches an executable boundary,
    /// returns null if index is at that boundary.
    pub fn nextExec(self: *Self) ?*const Token {
        if (self.exec_index) |_| {} else {
            self.exec_index = self.index;
        }

        const t_ = self.next();
        if (t_) |t| {
            switch (t.kind) {
                .oper => {
                    self.index.? -= t.str.len;
                    return null;
                },
                else => {},
            }
        }
        return t_;
    }

    // caller owns the memory, this will reset the index
    pub fn toSlice(self: *Self, a: Allocator) ![]Token {
        var list = ArrayList(Token).init(a);
        self.index = 0;
        while (self.next()) |n| {
            try list.append(n.*);
        }
        return list.toOwnedSlice();
    }

    // caller owns the memory, this will will move the index so calling next
    // will return the command delimiter (if existing),
    // Any calls to toSliceExec when current index is a command delemiter will
    // start at the following word slice.
    // calling this invalidates the previously returned pointer from next/peek
    pub fn toSliceExec(self: *Self, a: Allocator) ![]Token {
        var list = ArrayList(Token).init(a);
        if (self.nextExec()) |n| {
            try list.append(n.*);
        } else if (self.next()) |n| {
            if (n.kind != .oper) {
                try list.append(n.*);
            }
        }
        while (self.nextExec()) |n| {
            try list.append(n.*);
        }
        return list.toOwnedSlice();
    }

    /// Returns a Tokenizer error, or toSlice() with index = 0
    pub fn toSliceError(self: *Self, a: Allocator) Error![]Token {
        var i: usize = 0;
        while (i < self.raw.len) {
            const t = try Tokenizer.any(self.raw[i..]);
            i += t.str.len;
        }
        self.index = 0;
        return self.toSlice(a) catch return Error.Memory;
    }

    pub fn peek(self: *Self) ?*const Token {
        const old = self.index;
        defer self.index = old;
        return self.next();
    }

    pub fn restart(self: *Self) void {
        self.index = 0;
        self.exec_index = null;
    }

    /// Jumps back to the token at most recent nextExec call
    pub fn restartExec(self: *Self) void {
        self.index = self.exec_index;
        self.exec_index = null;
    }
};
