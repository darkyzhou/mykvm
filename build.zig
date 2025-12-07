const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
            .cpu_model = .baseline,
        },
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    // Create websocket module manually to enable blocking mode
    const websocket_dep = b.dependency("websocket", .{});
    const websocket_module = b.addModule("websocket_custom", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = websocket_dep.path("src/websocket.zig"),
        .link_libc = true,
    });
    // Force blocking mode for HTTP integration
    const ws_options = b.addOptions();
    ws_options.addOption(bool, "websocket_blocking", true);
    websocket_module.addOptions("build", ws_options);

    const tls = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });

    const pnpm_build = b.addSystemCommand(&.{ "pnpm", "build" });
    pnpm_build.setCwd(b.path("web"));

    const exe = b.addExecutable(.{
        .name = "mykvm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "websocket", .module = websocket_module },
                .{ .name = "tls", .module = tls.module("tls") },
            },
        }),
    });
    exe.step.dependOn(&pnpm_build.step);

    exe.root_module.addAnonymousImport("web_dist_tar", .{
        .root_source_file = b.path("web/dist.tar"),
    });

    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "src/epaper/Config/DEV_Config.c",
            "src/epaper/Config/dev_hardware_SPI.c",
            "src/epaper/Config/RPI_gpiod.c",
            "src/epaper/e-Paper/EPD_2in13_V4.c",
            "src/epaper/GUI/GUI_Paint.c",
            "src/epaper/Fonts/font8.c",
            "src/epaper/Fonts/font12.c",
            "src/epaper/Fonts/font16.c",
            "src/epaper/Fonts/font20.c",
            "src/epaper/Fonts/font24.c",
            "src/epaper/Fonts/font12CN.c",
            "src/epaper/Fonts/font24CN.c",
        },
        .flags = &.{
            "-DRPI",
            "-DUSE_DEV_LIB",
        },
    });

    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "lib/libgpiod/lib/core.c",
            "lib/libgpiod/lib/ctxless.c",
            "lib/libgpiod/lib/helpers.c",
            "lib/libgpiod/lib/iter.c",
            "lib/libgpiod/lib/misc.c",
        },
        .flags = &.{
            "-D_GNU_SOURCE",
            "-DGPIOD_VERSION_STR=\"1.6.4\"",
        },
    });
    exe.root_module.addIncludePath(b.path("src/epaper/Config"));
    exe.root_module.addIncludePath(b.path("src/epaper/e-Paper"));
    exe.root_module.addIncludePath(b.path("src/epaper/GUI"));
    exe.root_module.addIncludePath(b.path("src/epaper/Fonts"));
    exe.root_module.addIncludePath(b.path("lib/libgpiod/include"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
