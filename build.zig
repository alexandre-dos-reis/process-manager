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

    const exe = b.addExecutable(.{
        .name = "zpawn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = optimize != .debug,
            .imports = &.{.{ .name = "yaml", .module = yaml }},
        }),
    });
    b.installArtifact(exe);
}
