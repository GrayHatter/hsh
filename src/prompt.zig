const std = @import("std");
const Writer = std.fs.File.Writer;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Draw = @import("draw.zig");
const HSH = @import("hsh.zig").HSH;
const Job = @import("jobs.zig").Job;
const Feature = @import("hsh.zig").Features;
const Lexeme = Draw.Lexeme;
const LexTree = Draw.LexTree;
const Drawable = Draw.Drawable;
const draw = Draw.draw;
const drawRight = Draw.drawRight;
const drawBefore = Draw.drawBefore;

var si: usize = 0;

const Spinners = enum {
    corners,
    dots2t3,

    const dots = [_][]const u8{ "⡄", "⡆", "⠆", "⠇", "⠃", "⠋", "⠉", "⠙", "⠘", "⠸", "⠰", "⢰", "⢠", "⣠", "⣀", "⣄" };
    const corners = [_][]const u8{ "◢", "◣", "◤", "◥" };
    pub fn spin(s: Spinners, pos: usize) []const u8 {
        const art = switch (s) {
            .corners => &[_][]const u8{ "◢", "◣", "◤", "◥" },
            .dots2t3 => &[_][]const u8{ "⡄", "⡆", "⠆", "⠇", "⠃", "⠋", "⠉", "⠙", "⠘", "⠸", "⠰", "⢰", "⢠", "⣠", "⣀", "⣄" },
        };
        return art[pos % art.len];
    }
};

fn spinner(s: Spinners) Lexeme {
    // TODO if >1 spinners are in use, this will double increment
    si += 1;
    return .{ .char = s.spin(si) };
}

fn userTextMultiline(hsh: *HSH, tkn: *Tokenizer) !void {
    const err = if (tkn.err_idx > 0) tkn.err_idx else tkn.raw.items.len;
    const good = tkn.raw.items[0..err];
    const bad = tkn.raw.items[err..];
    try draw(&hsh.draw, LexTree{ .siblings = &[_]Lexeme{
        .{ .char = good },
        .{ .char = bad, .bg = .Red },
    } });
}

fn userText(hsh: *HSH, tkn: *Tokenizer) !void {
    if (std.mem.indexOf(u8, tkn.raw.items, "\n")) |_| return userTextMultiline(hsh, tkn);

    const err = if (tkn.err_idx > 0) tkn.err_idx else tkn.raw.items.len;
    const good = tkn.raw.items[0..err];
    const bad = tkn.raw.items[err..];
    try draw(&hsh.draw, LexTree{ .siblings = &[_]Lexeme{
        .{ .char = good },
        .{ .char = bad, .bg = .Red },
    } });
}

pub fn prompt(hsh: *HSH, tkn: *Tokenizer) !void {
    try draw(&hsh.draw, .{
        .siblings = &[_]Lexeme{
            .{
                .char = hsh.env.get("USER") orelse "[username unknown]",
                .attr = .Bold,
                .fg = .Blue,
            },
            .{ .char = "@" },
            .{ .char = "host " },
            .{ .char = hsh.hfs.names.cwd_short },
            .{ .char = " $ " },
        },
    });
    try userText(hsh, tkn);
    var tokens: [16]u8 = undefined;
    if (!hsh.enabled(Feature.Debugging)) return;

    try drawRight(&hsh.draw, .{ .siblings = &[_]Lexeme{
        .{ .char = try std.fmt.bufPrint(&tokens, "({}) ({}) [{}]", .{
            tkn.raw.items.len,
            tkn.tokens.items.len,
            tkn.c_tkn,
        }) },
    } });
}

pub fn jobsContext(hsh: *HSH, jobs: []Job) !void {
    for (jobs) |j| {
        try drawBefore(&hsh.draw, LexTree{
            .siblings = &[_]Lexeme{
                .{ .char = "[ " },
                if (j.status == .Background) spinner(.dots2t3) else .{ .char = "Z" },
                .{ .char = " " },
                .{ .char = j.name orelse "Unknown Job" },
                .{ .char = " ]" },
            },
        });
    }
}

pub fn ctxContext(hsh: *HSH, word: Lexeme) !void {
    try drawBefore(&hsh.draw, LexTree{
        .siblings = &[_]Lexeme{
            .{ .char = "[ " },
            word,
            .{ .char = " ]" },
        },
    });
}
