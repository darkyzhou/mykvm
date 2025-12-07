//! Zero-copy V4L2 video pipeline
//! Uses shared DMABUF between capture and encoder for zero-copy operation
//! Reference: https://www.kernel.org/doc/html/latest/userspace-api/dma-buf-alloc-exchange.html

const std = @import("std");
const capture = @import("./capture.zig");
const dma = @import("./dma.zig");
const encode = @import("./encode.zig");
const edid = @import("./edid.zig");
const utils = @import("./utils.zig");
const Server = @import("./server.zig");
const Encoder = encode.Encoder;
const posix = std.posix;
const log = std.log.scoped(.video);

const ioctl = utils.ioctl;

const c = @cImport({
    @cInclude("linux/videodev2.h");
});

const NUM_BUFFERS = 6;

pub fn run(
    alloc: std.mem.Allocator,
    server: *Server,
    capture_device: [:0]const u8,
    encoder_device: [:0]const u8,
    bitrate: u32,
) !void {
    var first_run = true;

    while (true) {
        if (!first_run) {
            log.info("Attempting to recover connection...", .{});
            const signal = edid.waitForSignal(capture_device, 300) catch |err| {
                log.err("Recovery failed (signal wait): {}", .{err});
                std.Thread.sleep(std.time.ns_per_s * 2);
                continue;
            };
            log.info("Signal recovered: {}x{}", .{ signal.width, signal.height });
        }

        runSession(alloc, server, capture_device, encoder_device, bitrate, first_run) catch |err| {
            log.err("Session error: {}", .{err});
            if (first_run) return err;
        };

        first_run = false;
        std.Thread.sleep(std.time.ns_per_s * 2);
    }
}

fn runSession(
    alloc: std.mem.Allocator,
    server: *Server,
    capture_device: [:0]const u8,
    encoder_device: [:0]const u8,
    bitrate: u32,
    first_run: bool,
) !void {
    log.info("Starting zero-copy session...", .{});
    log.info("Capture device: {s}", .{capture_device});
    log.info("Encoder device: {s}, bitrate: {}", .{ encoder_device, bitrate });

    const format_info = try probeFormat(capture_device);
    log.info("Capture format: {}x{}, buffer size: {} bytes", .{
        format_info.width,
        format_info.height,
        format_info.buffer_size,
    });

    log.info("Opening DMA Heap...", .{});
    var heap = dma.DmaHeap.init() catch |err| {
        log.err("Failed to open DMA Heap: {}", .{err});
        return err;
    };
    defer heap.deinit();

    log.info("Allocating {} shared DMABUF buffers ({} bytes each)...", .{
        NUM_BUFFERS,
        format_info.buffer_size,
    });
    var dma_buffers: [NUM_BUFFERS]dma.DmaBuffer = undefined;
    var allocated_count: usize = 0;
    errdefer {
        for (0..allocated_count) |i| {
            dma_buffers[i].deinit();
        }
    }

    for (0..NUM_BUFFERS) |i| {
        dma_buffers[i] = heap.alloc(format_info.buffer_size) catch |err| {
            log.err("Failed to allocate DMA buffer {}: {}", .{ i, err });
            return err;
        };
        allocated_count = i + 1;
        log.info("Allocated DMA buffer {}, fd={}", .{ i, dma_buffers[i].fd });
    }
    defer {
        for (&dma_buffers) |*buf| {
            buf.deinit();
        }
    }

    log.info("Initializing M2M encoder with shared DMABUF...", .{});
    var enc = Encoder.init(alloc, encoder_device, .{
        .width = format_info.width,
        .height = format_info.height,
        .input_format = c.V4L2_PIX_FMT_UYVY,
        .output_format = c.V4L2_PIX_FMT_H264,
        .bitrate = bitrate,
        .bytesperline = format_info.bytesperline,
        .sizeimage = format_info.buffer_size,
    }, &dma_buffers) catch |err| {
        log.err("Failed to initialize encoder: {}", .{err});
        return err;
    };
    defer enc.deinit();

    log.info("Initializing V4L2 capture with shared DMABUF...", .{});
    var cap = capture.Capture.init(alloc, capture_device, c.V4L2_PIX_FMT_UYVY, &dma_buffers) catch |err| {
        log.err("Failed to initialize capture: {}", .{err});
        return err;
    };
    defer cap.deinit();

    log.info("Zero-copy pipeline ready, starting capture loop...", .{});

    var timeout_count: usize = 0;
    while (true) {
        const cap_result = cap.dequeueBuffer(2000) catch |err| {
            if (err == error.Timeout) {
                timeout_count += 1;
                if (timeout_count >= 3) {
                    log.warn("Too many capture timeouts, exiting session", .{});
                    break;
                }
                continue;
            }

            log.err("Capture dequeue error: {}", .{err});
            if (first_run) {
                return err;
            }
            break;
        };
        timeout_count = 0;

        const enc_result = enc.encodeFromBuffer(cap_result.index, cap_result.bytesused) catch |err| {
            log.err("Encode error: {}", .{err});
            cap.queueBuffer(cap_result.index) catch |qerr| {
                log.err("Failed to re-queue capture buffer: {}", .{qerr});
            };
            continue;
        };

        if (enc_result.reclaimed_idx) |reclaimed_idx| {
            cap.queueBuffer(reclaimed_idx) catch |err| {
                log.err("Failed to re-queue buffer {}: {}", .{ reclaimed_idx, err });
            };
        }

        server.broadcast(enc_result.data) catch |err| {
            log.err("Broadcast error: {}", .{err});
            continue;
        };
    }
}

fn probeFormat(device: [:0]const u8) !struct {
    width: u32,
    height: u32,
    buffer_size: u32,
    bytesperline: u32,
} {
    const fd = try posix.open(device, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
    defer posix.close(fd);

    var cap = std.mem.zeroes(c.struct_v4l2_capability);
    if (ioctl(fd, c.VIDIOC_QUERYCAP, @intFromPtr(&cap)) != .SUCCESS) {
        log.err("Probe: VIDIOC_QUERYCAP failed", .{});
        return error.QueryCapFailed;
    }

    if (cap.capabilities & c.V4L2_CAP_VIDEO_CAPTURE == 0) {
        log.err("Probe: Device does not support capture", .{});
        return error.NotCaptureDevice;
    }

    var fmt = std.mem.zeroes(c.struct_v4l2_format);
    fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;

    if (ioctl(fd, c.VIDIOC_G_FMT, @intFromPtr(&fmt)) != .SUCCESS) {
        log.err("Probe: Failed to get format", .{});
        return error.GetFormatFailed;
    }

    fmt.fmt.pix.pixelformat = c.V4L2_PIX_FMT_UYVY;

    if (ioctl(fd, c.VIDIOC_S_FMT, @intFromPtr(&fmt)) != .SUCCESS) {
        log.err("Probe: Failed to set format", .{});
        return error.SetFormatFailed;
    }

    if (ioctl(fd, c.VIDIOC_G_FMT, @intFromPtr(&fmt)) != .SUCCESS) {
        log.err("Probe: Failed to get format after set", .{});
        return error.GetFormatFailed;
    }

    const width = fmt.fmt.pix.width;
    const height = fmt.fmt.pix.height;
    const buffer_size = fmt.fmt.pix.sizeimage;
    const bytesperline = fmt.fmt.pix.bytesperline;

    const fmt_str = utils.fourccToString(fmt.fmt.pix.pixelformat);
    log.info("Probe: Format {s} {}x{}, sizeimage={}, bytesperline={}", .{
        &fmt_str,
        width,
        height,
        buffer_size,
        bytesperline,
    });

    return .{
        .width = width,
        .height = height,
        .buffer_size = buffer_size,
        .bytesperline = bytesperline,
    };
}
