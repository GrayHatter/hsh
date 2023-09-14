const HSH = @import("hsh.zig").HSH;

const State = @This();

name: []const u8,
ctx: *anyopaque,
api: *const API,

pub const API = struct {
    /// each line returned must be allocated by `h.alloc` because it will be
    /// freed by the same once written.
    /// Save will only insert whitespace between sections, and will not
    /// otherwise attemte to modify the data in any way. API is required to
    /// provide it's own white space where required.
    save: *const fn (h: *HSH, _: *anyopaque) ?[][]const u8,
};

pub fn save(self: *State, h: *HSH) ?[][]const u8 {
    return self.api.save(h, self.ctx);
}

pub fn getName(self: *State) []const u8 {
    return self.name;
}

pub fn getCtx(self: *State) *anyopaque {
    return self.ctx;
}
