const std = @import("std");
const Writer = std.fs.File.Writer;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Draw = @import("draw.zig");
const Lexeme = Draw.Lexeme;
const Drawable = Draw.Drawable;
const render = Draw.render;

pub fn prompt(d: *const Drawable, tkn: *Tokenizer, env: std.process.EnvMap) !void {
    try render(d, .{
        .sibling = &[_]Lexeme{
            .{
                .char = env.get("USER") orelse "[username unknown]",
                .attr = .Bold,
                .fg = .Blue,
            },
            .{ .char = "@" },
            .{ .char = "host" },
            .{ .char = " $ " },
            .{ .char = tkn.raw.items },
        },
        // tkn.raw.items.len,
        // tkn.tokens.items.len,
    });
}
