const std = @import("std");
//const deps = @import("deps.zig");

const EXECUTABLES = .{
    .{ "awtfdb-manage", "src/main.zig" },
    .{ "awtfdb-watcher", "src/rename_watcher_main.zig" },
    .{ "awtfdb-janitor", "src/janitor_main.zig" },
    .{ "ainclude", "src/include_main.zig" },
    .{ "afind", "src/find_main.zig" },
    .{ "als", "src/ls_main.zig" },
    .{ "arm", "src/rm_main.zig" },
    .{ "atags", "src/tags_main.zig" },
    .{ "awtfdb-metrics", "src/metrics_main.zig" },
    .{ "amv", "src/mv_main.zig" },
};

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_pkg = b.dependency("sqlite", .{ .optimize = optimize, .target = target });
    const pcre_pkg = b.dependency("libpcre.zig", .{ .optimize = optimize, .target = target });
    const magic_pkg = b.dependency("libmagic.zig", .{ .optimize = optimize, .target = target });
    const expiring_hash_map_pkg = b.dependency("expiring_hash_map", .{ .optimize = optimize, .target = target });
    const tunez_pkg = b.dependency("tunez", .{ .optimize = optimize, .target = target });
    const ulid_pkg = b.dependency("zig-ulid", .{ .optimize = optimize, .target = target });
    const libexif_pkg = b.dependency("libexif", .{ .optimize = optimize, .target = target });
    const Mod = struct { name: []const u8, mod: *std.Build.Module };

    const mod_deps = &[_]Mod{
        .{ .name = "sqlite", .mod = sqlite_pkg.module("sqlite") },
        .{ .name = "libpcre", .mod = pcre_pkg.module("libpcre") },
        .{ .name = "libmagic.zig", .mod = magic_pkg.module("libmagic") },
        .{ .name = "expiring_hash_map", .mod = expiring_hash_map_pkg.module("expiring-hash-map") },
        .{ .name = "tunez", .mod = tunez_pkg.module("tunez") },
        .{ .name = "ulid", .mod = ulid_pkg.module("zig-ulid") },
    };

    const static_deps = &[_]*std.Build.Step.Compile{
        sqlite_pkg.artifact("sqlite"),
        libexif_pkg.artifact("exif"),
    };

    const exe_tests = b.addTest(
        .{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
        },
    );

    const run_unit_tests = b.addRunArtifact(exe_tests);

    for (mod_deps) |dep| {
        exe_tests.root_module.addImport(dep.name, dep.mod);
    }

    for (static_deps) |lib| {
        exe_tests.linkLibrary(lib);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // TODO make test spit out the path on stdout
    const build_test_step = b.step("build-test-only", "Only build tests (sidestepping some sort of bug on 0.13)");
    build_test_step.dependOn(&exe_tests.step);

    //if (optimize == .Debug or optimize == .ReleaseSafe) {

    if (true) {
        // faster build by making a single executable
        const single_exe = b.addExecutable(
            .{
                .name = "wrapper-awtfdb",
                .root_source_file = b.path("src/wrapmain.zig"),
                .optimize = optimize,
                .target = target,
            },
        );

        for (mod_deps) |dep| {
            single_exe.root_module.addImport(dep.name, dep.mod);
        }

        for (static_deps) |lib| {
            single_exe.linkLibrary(lib);
        }

        b.installArtifact(single_exe);

        const hardlink_install = try b.allocator.create(CustomHardLinkStep);

        const hardlink_step = std.Build.Step.init(.{
            .id = .custom,
            .name = "link the utils",
            .owner = b,
            .makeFn = CustomHardLinkStep.make,
        });
        hardlink_install.* = .{
            .builder = b,
            .step = hardlink_step,
            .exe = single_exe,
        };
        hardlink_install.step.dependOn(&single_exe.step);
        b.getInstallStep().dependOn(&hardlink_install.step);
    }
    //    } else {
    //        // release modes build all exes separately
    //        inline for (EXECUTABLES) |exec_decl| {
    //            const exec_name = exec_decl.@"0";
    //            const exec_entrypoint = exec_decl.@"1";
    //
    //            const tool_exe = b.addExecutable(
    //                .{
    //                    .name = exec_name,
    //                    .root_source_file = .{ .path = exec_entrypoint },
    //                    .optimize = optimize,
    //                    .target = target,
    //                },
    //            );
    //
    //            b.installArtifact(tool_exe);
    //            comptime addAllTo(mod_deps, static_deps, tool_exe);
    //        }
    //    }
}

const CustomHardLinkStep = struct {
    builder: *std.Build,
    step: std.Build.Step,
    exe: *std.Build.Step.Compile,

    const Self = @This();

    fn make(step: *std.Build.Step, node: std.Progress.Node) !void {
        _ = node;
        const self: *Self = @fieldParentPtr("step", step);
        const builder = self.builder;

        const wrapmain_path = self.exe.getEmittedBin().getPath(builder);
        inline for (EXECUTABLES) |exec_decl| {
            const exec_name = exec_decl.@"0";
            const full_dest_path = builder.getInstallPath(.{ .bin = {} }, exec_name);
            std.debug.print("{s} -> {s}\n", .{ wrapmain_path, full_dest_path });
            _ = try std.fs.Dir.updateFile(
                std.fs.cwd(),
                wrapmain_path,
                std.fs.cwd(),
                full_dest_path,
                .{},
            );
        }
    }
};
