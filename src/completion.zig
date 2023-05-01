const std = @import("std");
const ArrayList = std.ArrayList;
const HSH = @import("hsh.zig").HSH;
const _tkn = @import("tokenizer.zig");
const Token = _tkn.Token;
const TokenType = _tkn.TokenType;

pub const CompOption = struct {
    str: []u8,
    kind: std.fs.File.Kind,
    pub fn format(self: CompOption, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try std.fmt.format(out, "CompOption{{{s}, {s}}}", .{ self.str, @tagName(self.kind) });
    }
};

fn complete_cwd(hsh: *HSH, _: Token) ![]CompOption {
    var list = ArrayList(CompOption).init(hsh.alloc);
    var itr = hsh.fs.cwdi.iterate();
    while (try itr.next()) |each| {
        switch (each.kind) {
            .File, .Directory => {
                try list.append(CompOption{
                    .str = try hsh.alloc.dupe(u8, each.name),
                    .kind = each.kind,
                });
            },
            else => unreachable,
        }
    }
    return list.toOwnedSlice();
}

fn complete_cwd_token(hsh: *HSH, t: Token) ![]CompOption {
    var list = ArrayList(CompOption).init(hsh.alloc);
    var itr = hsh.fs.cwdi.iterate();
    while (try itr.next()) |each| {
        switch (each.kind) {
            .File, .Directory => {
                if (!std.mem.startsWith(u8, each.name, t.cannon())) continue;
                try list.append(CompOption{
                    .str = try hsh.alloc.dupe(u8, each.name),
                    .kind = each.kind,
                });
            },
            else => unreachable,
        }
    }
    return list.toOwnedSlice();
}

/// Caller owns both the array of options, and the option text memory for each as well
pub fn complete(hsh: *HSH, t: Token) ![]CompOption {
    switch (t.type) {
        .WhiteSpace => return try complete_cwd(hsh, t),
        .String, .Char => return try complete_cwd_token(hsh, t),
        else => |this| {
            std.debug.print("completion failure {}\n", .{this});
            unreachable;
        },
    }
}
