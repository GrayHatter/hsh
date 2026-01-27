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
    return .str(s.spin(si));
}

fn userTextMultiline(hsh: *Hsh, tkn: *Tokenizer) !void {
    const err = if (tkn.err_idx > 0) tkn.err_idx else tkn.raw.items.len;
    const good = tkn.raw.items[0..err];
    const bad = tkn.raw.items[err..];
    hsh.draw.draw(.{
        .siblings = &[_]Lexeme{
            .str(good),
            .styled(bad, .{ .bg = .red }),
        },
    });
}

fn userText(hsh: *Hsh, good: []const u8, bad: []const u8) !void {
    //if (std.mem.indexOf(u8, tkn.raw.items, "\n")) |_| return userTextMultiline(hsh, tkn);

    hsh.draw.draw(&[_]Lexeme{
        .str(good),
        .styled(bad, .{ .bg = .red }),
    });
}

fn prompt(d: *Draw.Drawable, u: ?[]const u8, cwd: []const u8) !void {
    d.draw(&[_]Lexeme{
        .styled(u orelse "[username unknown]", .{ .attr = .bold, .fg = .blue }),
        .str("@"),
        .str("host "),
        .str(cwd),
        .str(" $ "),
    });
}

pub fn draw(hsh: *Hsh, line: []const u8) !void {
    //const bgjobs = Jobs.getBgSlice(hsh.alloc) catch unreachable;
    //defer hsh.alloc.free(bgjobs);
    //try jobsContext(hsh, bgjobs);
    //try ctxContext(hsh, try Context.fetch(hsh, .git));

    try prompt(&hsh.draw, hsh.env.getPosix("USER"), hsh.fs.cwd_name);
    try userText(hsh, line, "");
}

fn jobsContext(hsh: *Hsh, jobs: []*Job) !void {
    for (jobs) |j| {
        const lex = [_]Lexeme{
            .str("[ "),
            if (j.status == .background) .str(spinner(.dots2t3)) else .str("Z"),
            .str(" "),
            .str(j.name orelse "Unknown Job"),
            .str(" ]"),
        };

        Draw.drawBefore(&hsh.draw, &lex);
    }
}

//pub fn ctxContext(hsh: *Hsh, word: Lexeme) !void {
//    try Draw.drawBefore(&hsh.draw, LexTree{
//        .siblings = &[_]Lexeme{
//            .str("[ " },
//            word,
//            .str(" ]" },
//        },
//    });
//}

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Draw = @import("draw.zig");
const Hsh = @import("hsh.zig");
const Job = @import("jobs.zig").Job;
const Feature = @import("hsh.zig").Features;
const Lexeme = Draw.Lexeme;
const Drawable = Draw.Drawable;
const Jobs = @import("jobs.zig");
