const std = @import("std");

pub fn build(b: *std.Build) void {
    const use_llvm = null;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption(
        std.SemanticVersion,
        "version",
        std.SemanticVersion.parse(version(b)) catch unreachable,
    );

    const hsh = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "hsh",
        .root_module = hsh,
        .use_llvm = use_llvm,
    });
    exe.root_module.addOptions("hsh_build", opts);

    b.installArtifact(exe);

    // TESTS
    const unit_tests = b.addTest(.{
        .root_module = hsh,
        .use_llvm = use_llvm,
    });
    unit_tests.root_module.addOptions("hsh_build", opts);
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
    }, &code, .ignore) catch {
        std.process.exit(2);
    };

    var git = std.mem.trim(u8, git_wide, " \r\n");
    return if (std.mem.startsWith(u8, git, "v")) git[1..] else git;
}
