const std = @import("std");

const Config = @This();

var alloc: std.mem.Allocator = undefined;

pub const Option = enum{
    
};


pub fn init(a: std.mem.Allocator) void {
    alloc = a;
}

pub fn get(
