const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Linux: static musl binary by default (smaller resident memory, no libc to load).
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{},
    });

    // Release by default: this is a long-running daemon, Debug would waste CPU and RAM.
    const optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "debug, safe, fast or small (default: small)",
    ) orelse .small;

    // zig-yaml, vendored (MIT) with the small fixes needed for Zig 0.17: see vendor/zig-yaml/README.md
    const yaml = b.createModule(.{
        .root_source_file = b.path("vendor/zig-yaml/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zig-clap, vendored (MIT): command-line parsing, see vendor/zig-clap/README.md
    const clap = b.createModule(.{
        .root_source_file = b.path("vendor/zig-clap/clap.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zpawn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = optimize != .debug,
            .imports = &.{
                .{ .name = "yaml", .module = yaml },
                .{ .name = "clap", .module = clap },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build test`: unit tests live in test/, never inline in src/.
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = .debug,
        .link_libc = true,
        .imports = &.{.{ .name = "yaml", .module = yaml }},
    });
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/config_test.zig"),
            .target = target,
            .optimize = .debug,
            .link_libc = true,
            .imports = &.{.{ .name = "config", .module = config_mod }},
        }),
    });
    const test_step = b.step("test", "Run the unit tests (test/*_test.zig)");
    test_step.dependOn(&b.addRunArtifact(unit).step);
}
