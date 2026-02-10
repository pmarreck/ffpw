const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the zig-sqlite wrapper dependency (for its Zig source files and include paths)
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the upstream C sqlite amalgamation (zig-sqlite's own dependency)
    const sqlite_c_dep = sqlite_dep.builder.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    // Build sqlite3 as a STATIC library ourselves, instead of using the
    // dependency's hardcoded dynamic build.
    const sqlite_static_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const sqlite_static_lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = sqlite_static_mod,
    });
    sqlite_static_lib.addIncludePath(sqlite_c_dep.path("."));
    sqlite_static_lib.addIncludePath(sqlite_dep.path("c"));
    sqlite_static_lib.addCSourceFile(.{
        .file = sqlite_c_dep.path("sqlite3.c"),
        .flags = &.{"-std=c99"},
    });
    sqlite_static_lib.addCSourceFile(.{
        .file = sqlite_dep.path("c/workaround.c"),
        .flags = &.{"-std=c99"},
    });

    // Create the sqlite Zig module, but link it against OUR static lib
    // instead of the dependency's dynamic one.
    const sqlite_mod = b.addModule("sqlite", .{
        .root_source_file = sqlite_dep.path("sqlite.zig"),
        .link_libc = true,
    });
    sqlite_mod.addIncludePath(sqlite_dep.path("c"));
    sqlite_mod.addIncludePath(sqlite_c_dep.path("."));
    sqlite_mod.linkLibrary(sqlite_static_lib);

    // Main executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("sqlite", sqlite_mod);

    const exe = b.addExecutable(.{
        .name = "ffpw",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ffpw");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("sqlite", sqlite_mod);

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests.step);
}
