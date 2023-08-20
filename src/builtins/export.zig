const std = @import("std");
const hsh = @import("../hsh.zig");
const HSH = hsh.HSH;
const bi = @import("../builtins.zig");
const Err = bi.Err;
const ParsedIterator = @import("../parse.zig").ParsedIterator;
const State = bi.State;
const print = bi.print;
const log = @import("log");
const Variables = @import("../variables.zig");

pub const Exports = struct {
    name: []const u8, // name is owned internally
    value: []const u8, // value is both tied and owned by Variables
    //
    pub fn format(self: Exports, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (fmt.len == 4) { // this is a cheeky hack, if I needed this code to
            // be more correct, or if it was a library, I'd
            // wouldn't just check the length here, I'd also
            // ensure the strings match as well.
            // ftm here, is a string known at comptime that
            // allows the zig compiler to build a very efficent
            // function. If you look in the save function below,
            // there's a format line with {save} which is those
            // 4 char. The 'export' line just below {s} means
            // write a string here. 2 more lines down there's no
            // export, because that line will be written to the
            // terminal if/when the user requests a list of
            // exports. But the save file needs the export
            // prefix to know how to process it :)
            try std.fmt.format(out, "export {s}='{s}'", .{ self.name, self.value });
        } else {
            try std.fmt.format(out, "{s}='{s}'", .{ self.name, self.value });
        }
    }
};

var export_list: std.ArrayList(Exports) = undefined;

/// Because hsh is a system shell, instead of variables being local, or
/// requiring the user to write exports to an additional file. hsh will make an
/// attempt to both save and restore any known `exports`. Rather than have
/// export be made aware of the semantics around reading/writing/save/restore.
/// All it's required do to is to notifiy the core hsh instance, that it's
/// available, and when hsh needs to to a read, or a write, it's able to call
/// the save function provided.
pub fn init(a: std.mem.Allocator) void {
    // Set up the local list of exports
    export_list = std.ArrayList(Exports).init(a);
    // hsh.addState registers and stores the context required to save the list
    // of exports to the hshrc (hsh run commands) file.
    hsh.addState(State{
        .name = "exports",
        .ctx = &export_list,
        .api = &.{ .save = save }, // the save API defines the functions
        // required to save the export data
    }) catch unreachable;
}

pub fn raze(a: std.mem.Allocator) void {
    // Frees the memory used for each name truncates the list of exports and then
    // frees the array and returns the memory back to the os.
    for (export_list.items) |ex| {
        a.free(ex.name);
    }
    export_list.clearAndFree();
}

/// This is the function defined by "save state" API in hsh
/// this function takes in an hsh core instance, (so it can allocate memory)
/// and returns a list [] of a list [] of bit chars -> [][]u8. A string would be
/// just []u8 (a list of char. So this is a list of strings.
fn save(h: *HSH, _: *anyopaque) ?[][]const u8 {
    var list = h.alloc.alloc([]u8, export_list.items.len) catch return null;
    for (export_list.items, 0..) |ex, i| {
        list[i] = std.fmt.allocPrint(h.alloc, "{save}\n", .{ex}) catch continue;
    }
    return list;
}

fn print_all() Err!u8 {
    // print the list of known exports to the terminal
    for (export_list.items) |ex| {
        // there's no word in the {} so it'll use the default format in the
        // function above
        try print("{}\n", .{ex});
    }
    return 0;
}

/// Named exports because I didn't want to fight the compiler for the word
/// export
pub fn exports(h: *HSH, pitr: *ParsedIterator) Err!u8 {
    const expt = pitr.first();
    // optional debug statement that 1) suppresses the unused variable error,
    // but also checks to make sure there's no bug where non 'export' commands
    // leak into this on.
    std.debug.assert(std.mem.eql(u8, expt.cannon(), "export"));

    const name = pitr.next();
    if (name == null or std.mem.eql(u8, name.?.cannon(), "-p")) {
        return print_all();
    }

    if (std.mem.indexOf(u8, name.?.cannon(), "=")) |_| {
        // this is a zigism, if the above function isn't null place in into the
        // var name with the vert bars here |_| means ignore, just check for
        // null but you could use the index of the = char by using |index|
        // instead.

        // split on =, lhs = key, rhs = value
        var keyitr = std.mem.split(u8, name.?.cannon(), "=");
        var key = keyitr.first();
        var value = keyitr.rest();
        // push into variables
        add(key, value) catch {
            log.err("", .{});
            return 1;
        };
        return 0;
    } else {
        // no = in the string, so it needs to already exist within variables.

        // search for variable in map
        // if not exists, return error
        // add to i
        var key = h.alloc.dupe(u8, name.?.cannon()) catch return Err.Memory;
        var value = Variables.get(key) orelse {
            log.err("Attempted to export an non-existant name\n", .{});
            return 1;
        };
        // orelse is another zigism, where if the value is null, the code behind
        // orelse will run, so it's like calling a function
        // var pre_check = someint_or_maybe_null() orelse 0;
        // var pre_check = someint_or_maybe_null() orelse 0;
        // is the same as
        // var pre_check = someint_or_maybe_null();
        // if (pre_check == null) pre_check = 0;
        // the extra trick here is you're able to return an error instead of
        // giving a default value.
        add(key, value) catch {
            log.err("", .{});
            return 1;
        };
        return 0;
    }
    unreachable; // there's a logic error here so crash if we hit it.
}

/// TODO method to remove an export
pub fn unexport(_: *HSH, _: *ParsedIterator) Err!u8 {}

fn add(k: []const u8, v: []const u8) !void {
    return try export_list.append(Exports{
        .name = k,
        .value = v,
    });
}
