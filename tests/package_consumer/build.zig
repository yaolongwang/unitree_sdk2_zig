const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Use the native SDK bridge") orelse (target.result.os.tag == .linux);
    const sysroot = b.option([]const u8, "sysroot", "Target GNU sysroot");
    const gcc_version = b.option([]const u8, "gcc-version", "GNU C++ header/runtime version");
    const sdk = b.dependency("unitree_sdk2", .{
        .target = target,
        .optimize = optimize,
        .native = native,
        .sysroot = sysroot,
        .@"gcc-version" = gcc_version,
    });
    const executable = b.addExecutable(.{
        .name = "unitree_consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "unitree_sdk2", .module = sdk.module("unitree_sdk2") }},
        }),
    });
    const options = b.addOptions();
    options.addOption(bool, "native", native);
    executable.root_module.addOptions("options", options);
    b.installArtifact(executable);
    if (native) @import("unitree_sdk2").installRuntime(b, sdk);
    b.step("run", "Run the downstream package smoke test").dependOn(&b.addRunArtifact(executable).step);
}
