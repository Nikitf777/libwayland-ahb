const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "vkwl",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (target.result.abi != .android) {
        std.debug.panic(
            "this project targets Android; got {s}-{s}-{s}",
            .{
                @tagName(target.result.cpu.arch),
                @tagName(target.result.os.tag),
                @tagName(target.result.abi),
            },
        );
    }

    const prefix = b.option(
        []const u8,
        "android-prefix",
        "Termux prefix containing include/, <triple>/lib, and opt/ndk-multilib (default: $PREFIX)",
    ) orelse b.graph.environ_map.get("PREFIX") orelse
        "/data/data/com.termux/files/usr";

    const triple = androidTriple(target.result.cpu.arch);
    const kit_dir = makeLibcKit(b, prefix, triple);

    lib.setLibCFile(b.addWriteFiles().add("libc-android.txt", b.fmt(
        \\include_dir={s}/include
        \\sys_include_dir={s}/include
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ prefix, prefix, kit_dir })));

    lib.root_module.link_libc = true;
    lib.root_module.linkSystemLibrary("dl", .{});
    lib.root_module.addLibraryPath(.{ .cwd_relative = kit_dir });

    // Wayland client/EGL window helpers live in the Termux prefix.  The
    // generated android_wlegl protocol C file and the variadic perform thunk
    // are compiled into the shim.
    lib.root_module.addIncludePath(b.path("src"));
    lib.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    lib.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include", triple }) });
    lib.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    lib.root_module.linkSystemLibrary("wayland-client", .{});
    lib.root_module.linkSystemLibrary("wayland-egl", .{});
    lib.root_module.addCSourceFile(.{
        .file = b.path("src/native_window_shim.c"),
        .flags = &.{},
    });
    lib.root_module.addCSourceFile(.{
        .file = b.path("src/protocol/android_wlegl_client.c"),
        .flags = &.{},
    });

    b.installArtifact(lib);
}

fn androidTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        else => std.debug.panic("unsupported Android architecture: {s}", .{@tagName(arch)}),
    };
}

/// Zig needs the Android CRT objects and the bionic linker stubs in the same
/// directory.  ndk-sysroot ships the CRT files, ndk-multilib ships the stubs,
/// so build a small symlink farm inside the local Zig cache.
fn makeLibcKit(b: *std.Build, prefix: []const u8, triple: []const u8) []const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();

    const kit_dir = b.pathFromRoot(b.pathJoin(&.{ ".zig-cache", "libc-kit", triple }));
    cwd.deleteTree(io, kit_dir) catch |err| {
        std.debug.panic("unable to clear libc kit at {s}: {s}", .{ kit_dir, @errorName(err) });
    };
    cwd.createDirPath(io, kit_dir) catch |err| {
        std.debug.panic("unable to create libc kit at {s}: {s}", .{ kit_dir, @errorName(err) });
    };

    const crt_dir = b.pathJoin(&.{ prefix, triple, "lib" });
    for ([_][]const u8{ "crtbegin_so.o", "crtend_so.o" }) |name| {
        const src = b.pathJoin(&.{ crt_dir, name });
        linkIntoKit(b, cwd, io, src, kit_dir, name);
    }

    const ndk_lib_dir = b.pathJoin(&.{ prefix, "opt", "ndk-multilib", triple, "lib" });
    var dir = cwd.openDir(io, ndk_lib_dir, .{ .iterate = true }) catch |err| {
        std.debug.panic(
            "unable to open {s}: {s}. Install the ndk-multilib package.",
            .{ ndk_lib_dir, @errorName(err) },
        );
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| {
        std.debug.panic("unable to read {s}: {s}", .{ ndk_lib_dir, @errorName(err) });
    }) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".so")) continue;
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const src = b.pathJoin(&.{ ndk_lib_dir, entry.name });
        linkIntoKit(b, cwd, io, src, kit_dir, entry.name);
    }

    return kit_dir;
}

fn linkIntoKit(
    b: *std.Build,
    cwd: std.Io.Dir,
    io: std.Io,
    src: []const u8,
    kit_dir: []const u8,
    name: []const u8,
) void {
    cwd.access(io, src, .{}) catch |err| {
        std.debug.panic(
            "missing NDK file {s}: {s}. Install ndk-sysroot and ndk-multilib.",
            .{ src, @errorName(err) },
        );
    };

    const dst = b.pathJoin(&.{ kit_dir, name });
    cwd.symLink(io, src, dst, .{}) catch |err| {
        std.debug.panic("unable to link {s} -> {s}: {s}", .{ dst, src, @errorName(err) });
    };
}
