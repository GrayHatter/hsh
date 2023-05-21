const Hsh = @import("../hsh.zig");
const HSH = Hsh.HSH;
const tokenizer = @import("../tokenizer.zig");
const Token = tokenizer.Token;
const Err = @import("../builtins.zig").Err;

const Alias = struct {
    name: []const u8,
    value: []const u8,
};

const aliases: [30]Alias = undefined;

pub fn alias(h: *HSH, tks: []const Token) Err!void {
    if (tks.len > 2) {
        // maybe add one?
    }

    h.tty.print("aliases\n", .{}) catch {};
    for (aliases) |a| {
        h.tty.print("{}\n", .{a}) catch {};
    }
}

pub fn add() void {}

pub fn del() void {}
