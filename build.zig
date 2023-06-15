const std = @import("std");

// near default build.zig from 0.11.0-dev.1908+06b263825a
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hsh",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const exe_opt = b.addOptions();
    exe.addOptions("hsh_build", exe_opt);
    exe_opt.addOption(
        std.SemanticVersion,
        "version",
        std.SemanticVersion.parse(version(b)) catch unreachable,
    );

    const log = b.createModule(.{
        .source_file = .{ .path = "src/log.zig" },
    });

    exe.addModule("log", log);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addOptions("hsh_build", exe_opt);
    unit_tests.addModule("log", log);
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn version(b: *std.Build) []const u8 {
    if (!std.process.can_spawn) {
        std.debug.print("Can't get a version number\n", .{});
        std.process.exit(1);
    }

    var code: u8 = undefined;
    var git_wide = b.execAllowFail(&[_][]const u8{
        "git",
        "describe",
        "--dirty",
        "--always",
    }, &code, .Ignore) catch {
        std.process.exit(2);
    };

    var git = std.mem.trim(u8, git_wide, " \r\n");
    return if (std.mem.startsWith(u8, git, "v")) git[1..] else git;
}
