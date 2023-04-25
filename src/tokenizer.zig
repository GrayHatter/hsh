const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = io.Reader(File, File.ReadError, File.read);
const io = std.io;
const File = fs.File;
const fs = std.fs;

pub const TokenType = enum(u8) {
    Unknown,
    String,
};

pub const Token = struct {
    raw: []const u8,
    type: TokenType = TokenType.Unknown,
};

pub const Tokenizer = struct {
    alloc: Allocator,
    raw: ArrayList(u8),
    tokens: ArrayList(Token),

    pub const TokenError = error{
        None,
        Unknown,
        LineTooLong,
        ParseError,
    };

    const Builtin = [_][]const u8{
        "alias",
        "which",
        "echo",
    };

    pub fn init(a: Allocator) Tokenizer {
        return Tokenizer{
            .alloc = a,
            .raw = ArrayList(u8).init(a),
            .tokens = ArrayList(Token).init(a),
        };
    }

    pub fn raze(self: Tokenizer) void {
        self.alloc.deinit();
    }

    pub fn parse_string(self: *Tokenizer, src: []const u8) TokenError!Token {
        _ = self;
        var end: usize = 0;
        for (src, 0..) |s, i| {
            end = i;
            if (s == ' ') {
                break;
            }
        } else end += 1;
        return Token{
            .raw = src[0..end],
            .type = TokenType.String,
        };
    }

    pub fn parse(self: *Tokenizer) TokenError!void {
        self.tokens.clearAndFree();
        var start: usize = 0;
        while (start < self.raw.items.len) {
            const t = self.parse_string(self.raw.items[start..]);
            if (t) |tt| {
                if (tt.raw.len > 0) {
                    self.tokens.append(tt) catch unreachable;
                    start += tt.raw.len;
                } else {
                    start += 1;
                }
            } else |_| {
                return TokenError.ParseError;
            }
        }
    }

    pub fn dump_parsed(self: Tokenizer) !void {
        std.debug.print("\n\n", .{});
        for (self.tokens.items) |i| {
            std.debug.print("{}\n", .{i});
            std.debug.print("{s}\n", .{i.raw});
        }
    }

    pub fn tab(self: Tokenizer) !bool {
        _ = self;
        return true;
    }

    pub fn pop(self: *Tokenizer) TokenError!void {
        _ = self.raw.popOrNull();
    }
    pub fn consumec(self: *Tokenizer, c: u8) TokenError!void {
        self.raw.append(c) catch return TokenError.Unknown;
    }

    pub fn clear(self: *Tokenizer) void {
        self.raw.clearAndFree();
        self.tokens.clearAndFree();
    }

    pub fn consumes(self: *Tokenizer, r: Reader) TokenError!void {
        var buf: [2 ^ 8]u8 = undefined;
        var line = r.readUntilDelimiterOrEof(&buf, '\n') catch |e| {
            if (e == error.StreamTooLong) {
                return TokenError.LineTooLong;
            }
            return TokenError.Unknown;
        };
        self.raw.appendSlice(line.?) catch return TokenError.Unknown;
    }
};
