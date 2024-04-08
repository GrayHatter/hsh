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
    try Draw.draw(&hsh.draw, LexTree{
        .siblings = @constCast(&[_]Lexeme{
            .{ .char = good },
            .{ .char = bad, .style = .{ .bg = .red } },
        }),
    });
}

fn userText(hsh: *HSH, tkn: *Tokenizer) !void {
    if (std.mem.indexOf(u8, tkn.raw.items, "\n")) |_| return userTextMultiline(hsh, tkn);

    const err = if (tkn.err_idx > 0) tkn.err_idx else tkn.raw.items.len;
    const good = tkn.raw.items[0..err];
    const bad = tkn.raw.items[err..];
    try Draw.draw(&hsh.draw, LexTree{
        .siblings = @constCast(&[_]Lexeme{
            .{ .char = good },
            .{ .char = bad, .style = .{ .bg = .red } },
        }),
    });
}

fn prompt(d: *Draw.Drawable, u: ?[]const u8, cwd: []const u8) !void {
    try Draw.draw(d, .{
        .siblings = @constCast(&[_]Lexeme{
            .{
                .char = u orelse "[username unknown]",
                .style = .{
                    .attr = .bold,
                    .fg = .blue,
                },
            },
            .{ .char = "@" },
            .{ .char = "host " },
            .{ .char = cwd },
            .{ .char = " $ " },
        }),
    });
}

pub fn draw(hsh: *HSH) !void {
    var tkn = hsh.tkn;
    const bgjobs = Jobs.getBgSlice(hsh.alloc) catch unreachable;
    defer hsh.alloc.free(bgjobs);
    try jobsContext(hsh, bgjobs);
    //try ctxContext(hsh, try Context.fetch(hsh, .git));

    try prompt(&hsh.draw, hsh.env.get("USER"), hsh.hfs.names.cwd_short);
    try userText(hsh, &tkn);
    // try drawRight(&hsh.draw, .{
    //     .siblings = @constCast(&[_]Lexeme{
    //         .{ .char = try std.fmt.bufPrint(&tokens, "({}) ({}) [{}]", .{
    //             tkn.raw.items.len,
    //             tkn.tokens.items.len,
    //             tkn.c_tkn,
    //         }) },
    //     }),
    // });
}

fn jobsContext(hsh: *HSH, jobs: []*Job) !void {
    for (jobs) |j| {
        const lex = LexTree{
            .siblings = @constCast(&[_]Lexeme{
                .{ .char = "[ " },
                if (j.status == .background) spinner(.dots2t3) else .{ .char = "Z" },
                .{ .char = " " },
                .{ .char = j.name orelse "Unknown Job" },
                .{ .char = " ]" },
            }),
        };
        try Draw.drawBefore(&hsh.draw, lex);
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
