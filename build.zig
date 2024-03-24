const std = @import("std");

// near default build.zig from 0.11.0-dev.1908+06b263825a
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const src = .{ .path = "src/main.zig" };

    const opts = b.addOptions();
    opts.addOption(
        std.SemanticVersion,
        "version",
        std.SemanticVersion.parse(version(b)) catch unreachable,
    );

    const log = b.createModule(.{
        .root_source_file = .{ .path = "src/log.zig" },
    });

    const exe = b.addExecutable(.{
        .name = "hsh",
        .root_source_file = src,
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addOptions("hsh_build", opts);
    exe.root_module.addImport("log", log);

    b.installArtifact(exe);

    // hsh doesn't like to be run from within zig build
    //const run_cmd = b.addRunArtifact(exe);
    //run_cmd.step.dependOn(b.getInstallStep());
    //if (b.args) |args| {
    //    run_cmd.addArgs(args);
    //}
    //const run_step = b.step("run", "Run the app");
    //run_step.dependOn(&run_cmd.step);

    // TODO enable sysinstall with keyword
    //const install_step = b.step("sysinstall", "install to system");
    //install_step.dependOn(&b.addInstallArtifact(exe).step);

    // TESTS
    const unit_tests = b.addTest(.{
        .root_source_file = src,
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addOptions("hsh_build", opts);
    unit_tests.root_module.addImport("log", log);
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
    const git_wide = b.runAllowFail(&[_][]const u8{
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
