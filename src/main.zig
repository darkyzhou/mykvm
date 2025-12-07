const std = @import("std");

const epaper = @import("./epaper.zig");
const edid = @import("./edid.zig");
const args = @import("./args.zig");
const usb = @import("./usb.zig");
const utils = @import("./utils.zig");
const video = @import("./video.zig");

const HttpsServer = @import("./https.zig");
const Server = @import("./server.zig");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_scope_levels = &.{
        .{ .scope = .websocket, .level = .warn },
    },
};

var g_display: ?*epaper.Display = null;
var g_hid_keyboard: ?*usb.HidKeyboard = null;
var g_hid_mouse: ?*usb.HidMouse = null;

fn handleSignal(sig: i32) callconv(.c) void {
    log.info("Received signal {}, shutting down...", .{sig});

    if (g_hid_keyboard) |kbd| {
        kbd.deinit();
    }
    if (g_hid_mouse) |mouse| {
        mouse.deinit();
    }

    usb.cleanupGadget();

    if (g_display) |display| {
        display.shutdown();
    }

    std.posix.exit(0);
}

fn setupSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const cli_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, cli_args);
    const config = try args.parse(alloc, cli_args);
    defer config.deinit(alloc);

    var display = epaper.Display.init(alloc, config.no_epaper) catch |err| {
        log.warn("Failed to initialize e-Paper display: {}", .{err});
        return err;
    };
    defer display.deinit();

    g_display = &display;
    setupSignalHandlers();

    const device_z = try alloc.dupeZ(u8, config.device);
    defer alloc.free(device_z);
    const encoder_z = try alloc.dupeZ(u8, config.encoder);
    defer alloc.free(encoder_z);

    var edid_ok = true;
    edid.setEdidWithRetry(device_z, .@"1080p25") catch |err| {
        log.warn("Failed to set EDID: {}", .{err});
        edid_ok = false;
    };
    display.updateEdidStatus(edid_ok);

    log.info("Waiting for HDMI signal...", .{});
    const signal_info = edid.waitForSignal(device_z, 300) catch |err| {
        log.err("No HDMI signal detected: {}", .{err});
        log.err("Please connect HDMI cable and restart.", .{});
        display.updateHdmiStatus(false);
        return err;
    };
    log.info("HDMI signal detected: {}x{} @ {}fps", .{ signal_info.width, signal_info.height, signal_info.fps });
    display.updateHdmiStatus(true);

    var hid_keyboard: usb.HidKeyboard = .init();
    defer hid_keyboard.deinit();
    g_hid_keyboard = &hid_keyboard;

    var hid_mouse: usb.HidMouse = .init();
    defer hid_mouse.deinit();
    g_hid_mouse = &hid_mouse;

    {
        var hid_ok = true;
        usb.setupGadget() catch |err| {
            log.warn("Failed to setup USB gadget: {}", .{err});
            hid_ok = false;
        };

        hid_keyboard.open() catch |err| {
            log.warn("Failed to open HID keyboard device: {}", .{err});
            hid_ok = false;
        };
        hid_mouse.open() catch |err| {
            log.warn("Failed to open HID mouse device: {}", .{err});
            hid_ok = false;
        };
        display.updateHidStatus(hid_ok);
    }

    var server = Server.init(alloc, &hid_keyboard, &hid_mouse);
    defer server.deinit();

    const v4l2_thread = try std.Thread.spawn(.{}, video.run, .{
        alloc,
        &server,
        device_z,
        encoder_z,
        config.bitrate,
    });

    display.showStatus(utils.getLocalIp() orelse config.listen, config.port);
    display.sleep();

    log.info("Server init: https://{s}:{d}", .{ config.listen, config.port });
    const https_thread = try std.Thread.spawn(.{}, HttpsServer.run, .{
        alloc,
        &server,
        config.listen,
        config.port,
        config.tls_cert_path,
        config.tls_key_path,
    });

    v4l2_thread.join();
    https_thread.join();
}
