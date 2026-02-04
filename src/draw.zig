cursor: u32 = 0,
cursor_reposition: bool = true,
writer: *Writer,
unbuffered: *Writer,
before: Writer = undefined,
b: Writer = undefined,
right: Writer = undefined,
after: Writer = undefined,
term_size: Cord = .{},
lines: u16 = 0,
internal: []u8,

const Draw = @This();

pub const Layout = @import("draw/layout.zig");
const draw_buffer_size = 8192 * 4 * 16;

pub const Cord = struct {
    x: isize = 0,
    y: isize = 0,
};

pub const Attr = enum {
    reset,
    bold,
    dim,
    italic,
    underline,
    reverse,
    reverse_bold, // Not in standard
    reverse_dim,
    strikeout,

    pub fn format(a: Attr, w: *Writer) !void {
        switch (a) {
            .reset => try w.writeAll("\x1B[0m"),
            .bold => try w.writeAll("\x1B[1m"),
            .dim => try w.writeAll("\x1B[2m"),
            .reverse => try w.writeAll("\x1B[7m"),
            .reverse_bold => try w.writeAll("\x1B[1m\x1B[7m"),
            .reverse_dim => try w.writeAll("\x1B[2m\x1B[7m"),
            else => unreachable,
        }
    }
};

pub const Color = enum {
    none,
    black,
    blue,
    cyan,
    gray,
    green,
    magenta,
    orange,
    red,
    white,
    yellow,

    pub fn fmtBg(c: Color, w: *Writer) !void {
        try w.writeAll(switch (c) {
            .none => return,
            .black => "\x1B[40m",
            .blue => "\x1B[44m",
            .cyan => "\x1B[46m",
            .gray => "\x1B[100m",
            .green => "\x1B[42m",
            .magenta => "\x1B[45m",
            .orange => "\x1B[43m",
            .red => "\x1B[41m",
            .white => "\x1B[47m",
            .yellow => "\x1B[103m",
        });
    }

    pub fn fmtFg(c: Color, w: *Writer) !void {
        try w.writeAll(switch (c) {
            .none => return,
            .black => "\x1B[30m",
            .blue => "\x1B[34m",
            .cyan => "\x1B[36m",
            .gray => "\x1B[90m",
            .green => "\x1B[32m",
            .magenta => "\x1B[35m",
            .orange => "\x1B[33m",
            .red => "\x1B[31m",
            .white => "\x1B[37m",
            .yellow => "\x1B[93m",
        });
    }
};

pub const Style = struct {
    attr: ?Attr = null,
    fg: ?Color = null,
    bg: ?Color = null,

    pub const none: Style = .{};

    pub const blue_bold: Style = .{ .attr = .bold, .fg = .blue };
    pub const cyan: Style = .{ .fg = .cyan };
    pub const green: Style = .{ .fg = .green };
    pub const green_bold: Style = .{ .attr = .bold, .fg = .green };
    pub const magenta_bold: Style = .{ .fg = .magenta, .attr = .bold };
    pub const orange: Style = .{ .fg = .orange };
    pub const red: Style = .{ .fg = .red };
    pub const red_bg: Style = .{ .bg = .red };
    pub const red_bold: Style = .{ .fg = .red, .attr = .bold };

    pub fn format(s: Style, w: *Writer) !void {
        if (s.attr) |a| try a.format(w);
        if (s.fg) |fg| try fg.fmtFg(w);
        if (s.bg) |bg| try bg.fmtBg(w);
    }

    pub fn reset(_: Style, w: *Writer) !void {
        try Color.none.fmtBg(w);
        try Color.none.fmtFg(w);
        try Attr.reset.format(w);
    }

    pub fn reverse(s: *Style) void {
        if (s.attr) |a| {
            s.attr = switch (a) {
                .reset => .reverse,
                .bold => .reverse_bold,
                .dim => .reverse_dim,
                .reverse => .reset,
                .reverse_bold => .reverse_bold,
                .reverse_dim => .reverse_bold,
                else => unreachable,
            };
        } else s.attr = .reverse;
    }

    pub fn fromName(name: []const u8) Style {
        //rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:
        //or=40;31;01:mi=00:su=37;41:sg=30;43:ca=00:tw=30;42:ow=34;42:st=37;44:ex=01;32:*.7z=01;31:
        //*.ace=01;31:*.alz=01;31:*.apk=01;31:*.arc=01;31:*.arj=01;31:*.bz=01;31:*.bz2=01;31:
        //*.cab=01;31:*.cpio=01;31:*.crate=01;31:*.deb=01;31:*.drpm=01;31:*.dwm=01;31:*.dz=01;31:
        //*.ear=01;31:*.egg=01;31:*.esd=01;31:*.gz=01;31:*.jar=01;31:*.lha=01;31:*.lrz=01;31:
        //*.lz=01;31:*.lz4=01;31:*.lzh=01;31:*.lzma=01;31:*.lzo=01;31:*.pyz=01;31:*.rar=01;31:
        //*.rz=01;31:*.sar=01;31:*.swm=01;31:*.t7z=01;31:*.tar=01;31:*.taz=01;31:
        //*.tbz=01;31:*.tbz2=01;31:*.tgz=01;31:*.tlz=01; 31:*.txz=01;31:*.tz=01;31:*.tzo=01;31:
        //*.tzst=01;31:*.war=01;31:*.whl=01;31:*.wim=01;31:*.xz=01;31:*.z=01;31:
        //*.zip=01;31:*.zoo=01;31:*.zst=01;31:*.avif=01;35:
        //*.jpg=01;35:*.jpeg=01;35:*.jxl=01;35:*.mjpg=01;35:*.mjpeg=01;35:*.gif=01;35:*.bmp=01;35:
        //*.pbm=01;35:*.pgm=01;35:*.ppm=01;35:*.tga=01;35:*.xbm=01;35:*.xpm=01;35:*.tif=01;35:
        //*.tiff=01;35:*.png=01;35:*.svg=01;35:*.svgz=01;35:*.mng=01;35:*.pcx=01;35:
        //*.mov=01;35:*.mpg=01;35:*.mpeg=01;35:*.m2v=01;35:*.mkv=01;35:*.webm=01;35:*.webp=01;35:
        //*.ogm=01;35:*.mp4=01;35:*.m4v=01;35:*.mp4v=01;35:*.vob=01;35:*.qt=01;35:*.nuv=01;35:
        //*.wmv=01;35: *.asf=01;35:*.rm=01;35:*.rmvb=01;35:*.flc=01;3 5:*.avi=01;35:*.fli=01;35:
        //*.flv=01;35:*.gl=01;35:*.dl=01;35:*.xcf=01;35:*.xwd=01;35:*.yuv=01;35:*.cgm=01;35:
        //*.emf=01;35:*.ogv=01;35:*.ogx=01;35:*.aac=00;36:
        //*.au=00;36:*.flac=00;36:*.m4a=00;36:*.mid=00;36:*.midi=00;36:*.mka=00;36:*.mp3=00;36:
        //*.mpc=00;36:*.ogg=00;36:*.ra=00;36:*.wav=00;36:*.oga=00;36:*.opus=00;36:*.spx=00;36:
        //*.xspf=00;36:*~=00;90:*#=00;90:*.bak=00;90:
        //*.old=00;90:*.orig=00;90:*.part=00;90:
        //*.rej=00;90: :*.swp=00;90:*.tmp=00;90:

        return if (endsWith(u8, name, ".mp3"))
            .cyan
        else if (endsWith(u8, name, ".mkv"))
            .magenta_bold
        else if (endsWith(u8, name, ".mp4"))
            .magenta_bold
        else if (endsWith(u8, name, ".zig"))
            .orange
        else if (endsWith(u8, name, ".tar"))
            .red_bold
        else if (endsWith(u8, name, ".tar.gz"))
            .red_bold
        else
            .none;
    }
};

pub const Lexeme = struct {
    bytes: []const u8,
    formatFn: ?*const fmt.FmtFn = null,
    padding: ?Padding = null,
    style: ?Style = null,

    pub const Padding = struct {
        byte: u8 = ' ',
        left: u16 = 0,
        right: u16 = 0,
    };

    pub fn str(s: []const u8) Lexeme {
        return .{ .bytes = s };
    }

    pub fn styled(s: []const u8, sty: Style) Lexeme {
        return .{ .bytes = s, .style = sty };
    }

    pub fn alt(s: []const u8, comptime fn_name: @EnumLiteral()) Lexeme {
        return .{
            .bytes = s,
            .formatFn = @field(fmt, @tagName(fn_name)),
        };
    }

    pub fn format(l: Lexeme, w: *Writer) !void {
        if (l.padding) |pad| _ = try w.splatByte(pad.byte, pad.left);

        if (l.style) |style| _ = try w.print("{f}", .{style});
        if (l.formatFn) |formatFn| {
            try formatFn(l.bytes, w);
        } else {
            try w.print("{s}", .{l.bytes});
        }
        if (l.style) |style| try style.reset(w);

        if (l.padding) |pad| _ = try w.splatByte(pad.byte, pad.right);
    }
};

var colorize: bool = true;

const Direction = enum {
    up,
    down,
    left,
    right,
    absolute,
};
pub fn move(d: *Draw, comptime dir: Direction, width: u16) !void {
    if (width == 0) return;
    try d.writer.print(comptime switch (dir) {
        .up => "\x1B[{}A",
        .down => "\x1B[{}B",
        .left => "\x1B[{}D",
        .right => "\x1B[{}C",
        .absolute => "\x1B[{}G",
    }, .{width});
}

pub fn init(a: Allocator, hsh: *Hsh) !Draw {
    colorize = hsh.enabled(.colorize);
    const buffer = try a.alloc(u8, draw_buffer_size);
    return .{
        .writer = &hsh.tty.out.w.interface,
        .unbuffered = &hsh.tty.out.unbuffered.interface,
        .before = .fixed(buffer[0..][0 .. draw_buffer_size / 4]),
        .b = .fixed(buffer[draw_buffer_size / 4 * 1 ..][0 .. draw_buffer_size / 4]),
        .right = .fixed(buffer[draw_buffer_size / 4 * 2 ..][0 .. draw_buffer_size / 4]),
        .after = .fixed(buffer[draw_buffer_size / 4 * 3 ..][0 .. draw_buffer_size / 4]),
        .internal = buffer,
    };
}

pub fn key(d: *Draw, c: u8) !void {
    try d.unbuffered.writeByte(c);
}

pub fn clear(d: *Draw) void {
    _ = d.before.consumeAll();
    _ = d.after.consumeAll();
    _ = d.right.consumeAll();
    _ = d.b.consumeAll();
}

pub fn reset(d: *Draw) void {
    d.clear();
    d.lines = 0;
    d.cursor = 0;
}

pub fn raze(d: *Draw, a: Allocator) void {
    a.free(d.internal);
}

fn drawLexemeMany(buf: *Writer, _: usize, _: usize, s: []const Lexeme) void {
    for (s) |sib| buf.print("{f}", .{sib}) catch unreachable;
}

pub fn drawBefore(d: *Draw, t: []const Lexeme) void {
    drawLexemeMany(&d.before, 0, 0, t);
    d.before.writeAll("\x1B[K") catch unreachable;
}

pub fn drawAfter(d: *Draw, t: []const Lexeme) void {
    d.after.writeByte('\n') catch unreachable;
    drawLexemeMany(&d.after, 0, 0, t);
}

pub fn drawRight(d: *Draw, tree: []const Lexeme) void {
    drawLexemeMany(&d.right, 0, 0, tree);
}

pub fn draw(d: *Draw, tree: []const Lexeme) void {
    drawLexemeMany(&d.b, 0, 0, tree);
}

/// Renders the "prompt" line
/// hsh is based around the idea of user keyboard-driven input, so plugin should
/// provide the context, expecting not to know about, or touch the final user
/// input line
pub fn render(d: *Draw) error{WriteFailed}!void {
    try d.writer.writeByte('\r');
    try d.move(.up, d.lines);
    d.lines = 0;
    // TODO vert position

    if (d.before.buffered().len > 0) {
        try d.writer.writeAll(d.before.buffered());
        try d.writer.writeByte('\n');
        d.lines += @intCast(1 + count(u8, d.before.buffered(), '\n'));
    }

    if (d.after.buffered().len > 0) {
        try d.writer.writeAll(d.after.buffered());
        const after_lines = count(u8, d.after.buffered(), '\n');
        try d.writer.writeAll("\x1B[K");
        try d.move(.up, @intCast(after_lines));
    }

    if (d.right.buffered().len > 0) {
        try d.writer.writeAll("\r\x1B[K");
        // Assumes that movement becomes a nop once at term width
        try d.move(.absolute, @intCast(d.term_size.x));
        // printable [...] to give a blank buffer (I hate line wrapping)
        const printable = countPrintable(d.right.buffered());
        try d.move(.left, @intCast(printable));
        try d.writer.writeAll(d.right.buffered());
    }

    try d.writer.writeAll("\r\x1B[K");
    try d.writer.writeByte('\r');
    try d.writer.writeAll(d.b.buffered());
    try d.move(.left, @truncate(d.cursor));
    // TODO save backtrack line count?
    d.lines += @intCast(count(u8, d.b.buffered(), '\n'));
    try d.writer.flush();
}

pub fn clearCtx(d: *Draw) void {
    d.move(.up, d.lines) catch {};
    d.writer.writeAll("\r\x1B[J") catch {};
    d.writer.writeAll(d.b.buffered()) catch {};
    d.lines = @intCast(count(u8, d.b.buffered(), '\n'));
}

/// Any context before the prompt line should be cleared and replaced with the
/// prompt before exec.
pub fn clear_before_exec(_: *Draw) void {}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Tty = @import("tty.zig");
const Hsh = @import("hsh.zig");
const Features = Hsh.Features;
const countPrintable = Layout.countPrintable;
const count = std.mem.countScalar;
const fmt = @import("fmt.zig");
const endsWith = std.mem.endsWith;
