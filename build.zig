const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to a portable baseline CPU so binaries run on hosts without the
    // build machine's AVX2/BMI extensions (e.g. the virgin-media VM host).
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
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

    // fx-agent-gardener: sibling executable sharing the exact same link
    // recipe (same libdatalog.so C-FFI surface, same store dir).
    const gardener = b.addExecutable(.{
        .name = "fx-agent-gardener",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gardener.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gardener.root_module.addIncludePath(b.path("../datalog-dafsa/src"));
    gardener.root_module.linkSystemLibrary("datalog", .{});
    gardener.root_module.addLibraryPath(.{ .cwd_relative = "../datalog-dafsa" });
    gardener.root_module.addRPathSpecial("$ORIGIN");
    gardener.root_module.link_libc = true;

    b.installArtifact(gardener);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run fx-agent-memory");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // gardener unit tests (tokenize/norm/firstInt) — same module as the
    // gardener exe, so they compile against the real libdatalog C-FFI surface.
    const gardener_tests = b.addTest(.{ .root_module = gardener.root_module });
    const run_gardener_tests = b.addRunArtifact(gardener_tests);
    test_step.dependOn(&run_gardener_tests.step);
}
