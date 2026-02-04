username: []const u8 = "[username unknown]",
hostname: []const u8 = "host",
cwd: *const []const u8,
brace: []const u8 = " $ ",

var si: usize = 0;
const uninit_cwd: []const u8 = "[prompt cwd currently unset]";

const Prompt = @This();

const Spinners = enum {
    corners,
    dots2t3,

    pub const glyphs = struct {
        const dots: []const []const u8 = &[_][]const u8{
            "⡄", "⡆", "⠆", "⠇", "⠃", "⠋", "⠉", "⠙", "⠘",
            "⠸", "⠰", "⢰", "⢠", "⣠", "⣀", "⣄",
        };
        const corners: []const []const u8 = &[_][]const u8{ "◢", "◣", "◤", "◥" };
    };

    pub fn spin(s: Spinners, pos: usize) []const u8 {
        return switch (s) {
            .corners => glyphs.corners[pos % glyphs.corners.len],
            .dots2t3 => glyphs.dots[pos % glyphs.dots.len],
        };
    }
};

pub fn init(user: []const u8, host: ?[]const u8) Prompt {
    return .{
        .username = user,
        .hostname = host orelse "host",
        .cwd = &uninit_cwd,
    };
}

pub fn render(p: Prompt, draw: *Draw, line: []const u8) !void {
    //const bgjobs = Jobs.getBgSlice(hsh.alloc) catch unreachable;
    //defer hsh.alloc.free(bgjobs);
    //try jobsContext(hsh, bgjobs);
    //try ctxContext(hsh, try Context.fetch(hsh, .git));

    try p.prompt(draw);
    try p.userText(draw, line, "");
}

fn spinner(s: Spinners) Lexeme {
    // TODO if >1 spinners are in use, this will double increment
    si += 1;
    return .str(s.spin(si));
}

fn userTextMultiline(_: Prompt, draw: *Draw, tkn: *Tokenizer) !void {
    const err = if (tkn.err_idx > 0) tkn.err_idx else tkn.raw.items.len;
    const good = tkn.raw.items[0..err];
    const bad = tkn.raw.items[err..];
    draw.draw(.{ .siblings = &.{ .str(good), .styled(bad, .red_bg) } });
}

fn userText(_: Prompt, draw: *Draw, good: []const u8, bad: []const u8) !void {
    draw.draw(&[_]Lexeme{ .str(good), .styled(bad, .{ .bg = .red }) });
}

fn prompt(p: Prompt, draw: *Draw) !void {
    const lex = &[_]Lexeme{
        .styled(p.username, .blue_bold), .str("@"),
        .str(p.hostname),                .str(" "),
        .alt(p.cwd.*, .dir),             .str(p.brace),
    };

    draw.draw(lex);
}

fn jobsContext(draw: *Draw, jobs: *const Jobs) !void {
    for (jobs) |j| {
        const lex = [_]Lexeme{
            .str("[ "), if (j.status == .background) .str(spinner(.dots2t3)) else .str("Z"),
            .str(" "),  .str(j.name orelse "Unknown Job"),
            .str(" ]"),
        };
        draw.drawBefore(&lex);
    }
}

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Draw = @import("draw.zig");
const Jobs = @import("jobs.zig");
const Feature = @import("hsh.zig").Features;
const Lexeme = Draw.Lexeme;
const fmt = @import("fmt.zig");
