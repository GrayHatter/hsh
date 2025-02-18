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
const Jobs = @import("jobs.zig");

var si: usize = 0;

pub const Prompt = @This();

const Spinners = enum {
    corners,
    dots2t3,

    pub const glyphs = struct {
        const dots = [_][]const u8{ "⡄", "⡆", "⠆", "⠇", "⠃", "⠋", "⠉", "⠙", "⠘", "⠸", "⠰", "⢰", "⢠", "⣠", "⣀", "⣄" };
        const corners = [_][]const u8{ "◢", "◣", "◤", "◥" };
    };

    pub fn spin(s: Spinners, pos: usize) []const u8 {
        const art = switch (s) {
            .corners => &glyphs.corners,
            .dots2t3 => &glyphs.dots,
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
    try Draw.draw(&hsh.draw, .{
        .siblings = &[_]Lexeme{
            .{ .char = good },
            .{ .char = bad, .style = .{ .bg = .red } },
        },
    });
}

fn userText(hsh: *HSH, good: []const u8, bad: []const u8) !void {
    //if (std.mem.indexOf(u8, tkn.raw.items, "\n")) |_| return userTextMultiline(hsh, tkn);

    try Draw.draw(&hsh.draw, &[_]Lexeme{
        .{ .char = good },
        .{ .char = bad, .style = .{ .bg = .red } },
    });
}

fn prompt(d: *Draw.Drawable, u: ?[]const u8, cwd: []const u8) !void {
    try Draw.draw(d, &[_]Lexeme{
        .{ .char = u orelse "[username unknown]", .style = .{ .attr = .bold, .fg = .blue } },
        .{ .char = "@" },
        .{ .char = "host " },
        .{ .char = cwd },
        .{ .char = " $ " },
    });
}

pub fn draw(hsh: *HSH, line: []const u8) !void {
    const bgjobs = Jobs.getBgSlice(hsh.alloc) catch unreachable;
    defer hsh.alloc.free(bgjobs);
    try jobsContext(hsh, bgjobs);
    //try ctxContext(hsh, try Context.fetch(hsh, .git));

    try prompt(&hsh.draw, hsh.env.get("USER"), hsh.hfs.names.cwd_short);
    try userText(hsh, line, "");
}

fn jobsContext(hsh: *HSH, jobs: []*Job) !void {
    for (jobs) |j| {
        const lex = [_]Lexeme{
            .{ .char = "[ " },
            if (j.status == .background) spinner(.dots2t3) else .{ .char = "Z" },
            .{ .char = " " },
            .{ .char = j.name orelse "Unknown Job" },
            .{ .char = " ]" },
        };

        try Draw.drawBefore(&hsh.draw, &lex);
    }
}

pub fn ctxContext(hsh: *HSH, word: Lexeme) !void {
    try Draw.drawBefore(&hsh.draw, LexTree{
        .siblings = &[_]Lexeme{
            .{ .char = "[ " },
            word,
            .{ .char = " ]" },
        },
    });
}
