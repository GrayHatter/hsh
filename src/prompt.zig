const TTY = TTY_.TTY;
const TTY_ = @import("tty.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub fn prompt(tty: *TTY, tkn: *Tokenizer) !void {
    try tty.prompt("\r{s}@{s}({})({}) # {s}", .{
        "username",
        "host",
        tkn.raw.items.len,
        tkn.tokens.items.len,
        tkn.raw.items,
    });
}
