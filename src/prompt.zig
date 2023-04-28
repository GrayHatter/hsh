const std = @import("std");
const Writer = std.fs.File.Writer;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Draw = @import("draw.zig");
const Lexeme = Draw.Lexeme;
const Drawable = Draw.Drawable;
const render = Draw.render;

fn user_text() void {}

pub fn prompt(d: *const Drawable, tkn: *Tokenizer, env: std.process.EnvMap) !void {
    var b_raw: [8]u8 = undefined;
    var b_tkns: [8]u8 = undefined;
    try render(d, .{
        .sibling = &[_]Lexeme{
            .{
                .char = env.get("USER") orelse "[username unknown]",
                .attr = .Bold,
                .fg = .Blue,
            },
            .{ .char = "@" },
            .{ .char = "host" },
            .{ .char = try std.fmt.bufPrint(
                &b_raw,
                "({}) ",
                .{tkn.raw.items.len},
            ) },
            .{ .char = try std.fmt.bufPrint(
                &b_tkns,
                "({}) ",
                .{tkn.tokens.items.len},
            ) },
            .{ .char = " $ " },
            .{ .char = if (tkn.err_idx > 0) tkn.raw.items[0..tkn.err_idx] else tkn.raw.items },
            .{
                .char = if (tkn.err_idx > 0) tkn.raw.items[tkn.err_idx..] else "",
                .bg = .Red,
            },
        },
    });
}
