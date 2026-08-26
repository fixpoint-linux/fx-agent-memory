const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "fx-agent-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link libdatalog.so (the still-C datalog core) via C-FFI, exactly the
    // fx-core pattern: include the public dl.h + index.h headers and link the
    // shared library from the datalog-dafsa project dir.
    exe.root_module.addIncludePath(b.path("../datalog-dafsa/src"));
    exe.root_module.linkSystemLibrary("datalog", .{});
    exe.root_module.addLibraryPath(.{ .cwd_relative = "../datalog-dafsa" });
    // Find libdatalog.so next to the installed binary (libembed.so is dlopen'd
    // at runtime via the same dir).
    exe.root_module.addRPathSpecial("$ORIGIN");
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run fx-agent-memory");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
