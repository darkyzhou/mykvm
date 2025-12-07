const std = @import("std");
const posix = std.posix;
const utils = @import("./utils.zig");
const ioctl = utils.ioctl;
const log = std.log.scoped(.edid);

const c = @cImport({
    @cInclude("linux/videodev2.h");
    @cInclude("linux/v4l2-common.h");
});

const edid_720p60 = @embedFile("./720p60edid");
const edid_1080p25 = @embedFile("./1080p25edid");
const edid_1080p30 = @embedFile("./1080p30edid");

pub const EdidPreset = enum {
    @"720p60",
    @"1080p25",
    @"1080p30",
};

pub fn setEdid(device: [:0]const u8, edid_data: []const u8) !void {
    const fd = try posix.open(device, .{ .ACCMODE = .RDWR }, 0);
    defer posix.close(fd);

    // Copy EDID data to stack buffer (kernel needs writable memory)
    var edid_buffer: [1024]u8 = undefined;
    if (edid_data.len > edid_buffer.len) {
        return error.EdidTooLarge;
    }
    @memcpy(edid_buffer[0..edid_data.len], edid_data);

    // Each EDID block is 128 bytes
    const blocks: u32 = @intCast(edid_data.len / 128);

    var edid = std.mem.zeroes(c.struct_v4l2_edid);
    edid.pad = 0;
    edid.start_block = 0;
    edid.blocks = blocks;
    edid.edid = &edid_buffer;

    const result = ioctl(fd, c.VIDIOC_S_EDID, @intFromPtr(&edid));
    if (result != .SUCCESS) {
        log.err("VIDIOC_S_EDID failed with errno: {} ({s})", .{ @intFromEnum(result), @tagName(result) });
        return error.SetEdidFailed;
    }
}

pub fn setEdidWithRetry(device: [:0]const u8, preset: EdidPreset) !void {
    const max_retries: u32 = 10;
    const edid_data: []const u8 = switch (preset) {
        .@"720p60" => edid_720p60,
        .@"1080p25" => edid_1080p25,
        .@"1080p30" => edid_1080p30,
    };

    var retry: u32 = 0;
    while (retry < max_retries) : (retry += 1) {
        if (setEdid(device, edid_data)) {
            log.info("EDID {s} set successfully after {} retries", .{ @tagName(preset), retry });
            return;
        } else |err| {
            log.warn("EDID set failed: {}, retry {}/{}", .{ err, retry + 1, max_retries });
            std.Thread.sleep(std.time.ns_per_s * 2);
        }
    }
}

/// Video signal information
pub const SignalInfo = struct {
    width: u32,
    height: u32,
    fps: u32,
};

/// Query DV timings and optionally apply them to the device
fn queryAndApplyDvTimings(fd: posix.fd_t, apply: bool) !SignalInfo {
    var timings = std.mem.zeroes(c.struct_v4l2_dv_timings);
    const query_result = ioctl(fd, c.VIDIOC_QUERY_DV_TIMINGS, @intFromPtr(&timings));
    if (query_result != .SUCCESS) {
        return error.NoSignal;
    }

    // Access bt timings - handle anonymous union by using pointer cast
    // struct v4l2_dv_timings { u32 type; union { struct v4l2_bt_timings bt; ... }; }
    const bt: *const c.struct_v4l2_bt_timings = @ptrCast(&timings.unnamed_0);
    if (bt.width == 0 or bt.height == 0) {
        return error.NoSignal;
    }

    // Apply the detected timings to the device (equivalent to v4l2-ctl --set-dv-bt-timings query)
    // This is REQUIRED for TC358743 - the driver does NOT automatically switch to detected resolution
    // See https://forums.raspberrypi.com/viewtopic.php?t=281972
    // Note: yavta does query -> set immediately without delay
    if (apply) {
        const set_result = ioctl(fd, c.VIDIOC_S_DV_TIMINGS, @intFromPtr(&timings));
        if (set_result != .SUCCESS) {
            log.err("VIDIOC_S_DV_TIMINGS failed with errno: {} ({s})", .{ @intFromEnum(set_result), @tagName(set_result) });
            return error.SetDvTimingsFailed;
        }
    }

    // Calculate FPS from pixel clock and total dimensions
    const tot_height: u64 = bt.height + bt.vfrontporch + bt.vsync + bt.vbackporch +
        bt.il_vfrontporch + bt.il_vsync + bt.il_vbackporch;
    const tot_width: u64 = bt.width + bt.hfrontporch + bt.hsync + bt.hbackporch;
    const fps: u32 = if (tot_width > 0 and tot_height > 0)
        @intCast(bt.pixelclock / (tot_width * tot_height))
    else
        0;

    return SignalInfo{
        .width = bt.width,
        .height = bt.height,
        .fps = fps,
    };
}

/// Check if HDMI signal is present by querying DV timings
pub fn querySignal(device: [:0]const u8) !SignalInfo {
    const fd = try posix.open(device, .{ .ACCMODE = .RDWR }, 0);
    defer posix.close(fd);
    return queryAndApplyDvTimings(fd, false);
}

/// Wait for HDMI signal with retry, then apply DV timings
pub fn waitForSignal(device: [:0]const u8, timeout_seconds: u32) !SignalInfo {
    const fd = try posix.open(device, .{ .ACCMODE = .RDWR }, 0);
    defer posix.close(fd);

    var elapsed: u32 = 0;
    const retry_interval: u32 = 2;

    while (elapsed < timeout_seconds) {
        if (queryAndApplyDvTimings(fd, false)) |_| {
            const info = try queryAndApplyDvTimings(fd, true);
            log.info("DV timings applied", .{});
            std.Thread.sleep(std.time.ns_per_ms * 100);

            return info;
        } else |_| {
            log.info("Waiting for HDMI signal... ({}/{}s)", .{ elapsed, timeout_seconds });
            std.Thread.sleep(std.time.ns_per_s * retry_interval);
            elapsed += retry_interval;
        }
    }

    return error.SignalTimeout;
}
