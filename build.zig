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
    sqlite_static_mod.addIncludePath(sqlite_c_dep.path("."));
    sqlite_static_mod.addIncludePath(sqlite_dep.path("c"));
    sqlite_static_mod.addCSourceFile(.{
        .file = sqlite_c_dep.path("sqlite3.c"),
        .flags = &.{"-std=c99"},
    });
    sqlite_static_mod.addCSourceFile(.{
        .file = sqlite_dep.path("c/workaround.c"),
        .flags = &.{"-std=c99"},
    });
    const sqlite_static_lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = sqlite_static_mod,
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

    // Link statically against musl so the artifact carries no interpreter at
    // all. A *dynamically* linked musl binary bakes /lib/ld-musl-x86_64.so.1,
    // which exists on neither NixOS nor a typical glibc distro — that is how a
    // "successful" nix build produced something unrunnable. Conditioned on the
    // ABI, not the OS, so a native glibc `zig build` stays dynamic (statically
    // linking glibc is its own minefield: NSS still dlopen()s at runtime).
    //
    // macOS deliberately has no static case: Apple ships no static libSystem
    // and forbids fully static executables. Its portable form is a dynamic
    // binary linking only /usr/lib/libSystem.B.dylib, present on every Mac.
    const exe = b.addExecutable(.{
        .name = "ffpw",
        .root_module = root_module,
        .linkage = if (target.result.abi.isMusl()) .static else null,
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

    // Actually RUN the compiled test binary. Depending on `tests.step` alone
    // only COMPILES it — every assertion then silently "passes" (a false green
    // that hid an untested sqlite query path). `addRunArtifact` is the gate
    // that makes `zig build test` execute the tests on every platform.
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `test-compile` installs the test binary without running it. The Nix
    // flake's `checks.test` uses this on Linux so it can re-launch the
    // binary through Nix's dynamic linker (Zig 0.16 bakes an FHS loader
    // path that doesn't exist in the build sandbox — mirrors c0/libjxlz).
    const test_compile_step = b.step("test-compile", "Compile test binary without running it");
    test_compile_step.dependOn(&b.addInstallArtifact(tests, .{
        .dest_dir = .{ .override = .{ .custom = "test-bins" } },
        .dest_sub_path = "tests",
    }).step);
}
