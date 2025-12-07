//! Native V4L2 Capture with DMABUF support
//! This bypasses libv4l2cpp to enable zero-copy buffer sharing with encoder

const std = @import("std");
const posix = std.posix;
const dma = @import("./dma.zig");
const utils = @import("./utils.zig");
const log = std.log.scoped(.capture);

const ioctl = utils.ioctl;

const c = @cImport({
    @cInclude("linux/videodev2.h");
});

const BUF_TYPE_VIDEO_CAPTURE = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
const MEMORY_DMABUF = c.V4L2_MEMORY_DMABUF;
const CAP_VIDEO_CAPTURE = c.V4L2_CAP_VIDEO_CAPTURE;
const CAP_STREAMING = c.V4L2_CAP_STREAMING;

const v4l2_format = c.struct_v4l2_format;
const v4l2_requestbuffers = c.struct_v4l2_requestbuffers;
const v4l2_buffer = c.struct_v4l2_buffer;
const v4l2_capability = c.struct_v4l2_capability;

/// V4L2 Capture device with DMABUF support
pub const Capture = struct {
    fd: posix.fd_t,
    width: u32,
    height: u32,
    format: u32,
    buffer_size: u32,
    num_buffers: u32,
    dmabuf_fds: []posix.fd_t, // External DMABUF fds (not owned)
    streaming: bool,
    alloc: std.mem.Allocator,

    const Self = @This();

    /// Initialize capture device with external DMABUF buffers
    pub fn init(
        alloc: std.mem.Allocator,
        device: [:0]const u8,
        format: u32,
        dmabuf_fds: []const dma.DmaBuffer,
    ) !Self {
        log.info("Opening {s}...", .{device});

        const fd = try posix.open(device, .{ .ACCMODE = .RDWR }, 0);
        errdefer posix.close(fd);

        // Query capabilities
        var cap = std.mem.zeroes(v4l2_capability);
        if (ioctl(fd, c.VIDIOC_QUERYCAP, @intFromPtr(&cap)) != .SUCCESS) {
            log.err("VIDIOC_QUERYCAP failed", .{});
            return error.QueryCapFailed;
        }

        if (cap.capabilities & CAP_VIDEO_CAPTURE == 0) {
            log.err("Device does not support capture", .{});
            return error.NotCaptureDevice;
        }
        if (cap.capabilities & CAP_STREAMING == 0) {
            log.err("Device does not support streaming", .{});
            return error.NoStreaming;
        }

        // Get current format first to learn resolution
        var fmt = std.mem.zeroes(v4l2_format);
        fmt.type = BUF_TYPE_VIDEO_CAPTURE;

        if (ioctl(fd, c.VIDIOC_G_FMT, @intFromPtr(&fmt)) != .SUCCESS) {
            log.err("Failed to get format", .{});
            return error.GetFormatFailed;
        }

        const current_width = fmt.fmt.pix.width;
        const current_height = fmt.fmt.pix.height;

        // Set desired format
        fmt.fmt.pix.pixelformat = format;

        if (ioctl(fd, c.VIDIOC_S_FMT, @intFromPtr(&fmt)) != .SUCCESS) {
            log.err("Failed to set format", .{});
            return error.SetFormatFailed;
        }

        const width = fmt.fmt.pix.width;
        const height = fmt.fmt.pix.height;
        const actual_format = fmt.fmt.pix.pixelformat;
        const buffer_size = fmt.fmt.pix.sizeimage;

        const fmt_str = utils.fourccToString(actual_format);
        log.info("Format {s} {}x{}, buffer size {}", .{
            &fmt_str,
            width,
            height,
            buffer_size,
        });

        if (current_width != width or current_height != height) {
            log.info("Resolution changed from {}x{} to {}x{}", .{
                current_width,
                current_height,
                width,
                height,
            });
        }

        const num_buffers: u32 = @intCast(dmabuf_fds.len);

        // Request buffers with DMABUF memory type
        var reqbuf = std.mem.zeroes(v4l2_requestbuffers);
        reqbuf.count = num_buffers;
        reqbuf.type = BUF_TYPE_VIDEO_CAPTURE;
        reqbuf.memory = MEMORY_DMABUF;

        if (ioctl(fd, c.VIDIOC_REQBUFS, @intFromPtr(&reqbuf)) != .SUCCESS) {
            log.err("Failed to request DMABUF buffers", .{});
            return error.ReqBufsFailed;
        }

        log.info("Requested {} DMABUF buffers", .{reqbuf.count});

        // Store dmabuf fds
        const fds = try alloc.alloc(posix.fd_t, num_buffers);
        for (dmabuf_fds, 0..) |buf, i| {
            fds[i] = buf.fd;
        }

        // Queue all buffers
        for (0..num_buffers) |i| {
            var buf = std.mem.zeroes(v4l2_buffer);
            buf.type = BUF_TYPE_VIDEO_CAPTURE;
            buf.memory = MEMORY_DMABUF;
            buf.index = @intCast(i);
            buf.m.fd = fds[i];

            if (ioctl(fd, c.VIDIOC_QBUF, @intFromPtr(&buf)) != .SUCCESS) {
                log.err("Failed to queue buffer {}", .{i});
                alloc.free(fds);
                return error.QBufFailed;
            }
        }

        log.info("Queued {} buffers", .{num_buffers});

        // Start streaming
        var buf_type: u32 = BUF_TYPE_VIDEO_CAPTURE;
        if (ioctl(fd, c.VIDIOC_STREAMON, @intFromPtr(&buf_type)) != .SUCCESS) {
            log.err("Failed to start streaming", .{});
            alloc.free(fds);
            return error.StreamOnFailed;
        }

        log.info("Streaming started", .{});

        return Self{
            .fd = fd,
            .width = width,
            .height = height,
            .format = actual_format,
            .buffer_size = buffer_size,
            .num_buffers = num_buffers,
            .dmabuf_fds = fds,
            .streaming = true,
            .alloc = alloc,
        };
    }

    /// Wait for a buffer to be ready (returns buffer index and bytes used)
    pub fn dequeueBuffer(self: *Self, timeout_ms: i32) !struct { index: u32, bytesused: u32 } {
        // Poll for readability
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const poll_result = posix.poll(&pfd, timeout_ms) catch |err| {
            return err;
        };

        if (poll_result == 0) {
            return error.Timeout;
        }

        // Dequeue buffer
        var buf = std.mem.zeroes(v4l2_buffer);
        buf.type = BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = MEMORY_DMABUF;

        if (ioctl(self.fd, c.VIDIOC_DQBUF, @intFromPtr(&buf)) != .SUCCESS) {
            return error.DQBufFailed;
        }

        return .{ .index = buf.index, .bytesused = buf.bytesused };
    }

    /// Re-queue a buffer for capture
    pub fn queueBuffer(self: *Self, index: u32) !void {
        var buf = std.mem.zeroes(v4l2_buffer);
        buf.type = BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = MEMORY_DMABUF;
        buf.index = index;
        buf.m.fd = self.dmabuf_fds[index];

        if (ioctl(self.fd, c.VIDIOC_QBUF, @intFromPtr(&buf)) != .SUCCESS) {
            return error.QBufFailed;
        }
    }

    /// Stop streaming and release resources
    pub fn deinit(self: *Self) void {
        if (self.streaming) {
            var buf_type: u32 = BUF_TYPE_VIDEO_CAPTURE;
            _ = ioctl(self.fd, c.VIDIOC_STREAMOFF, @intFromPtr(&buf_type));
            self.streaming = false;
        }

        self.alloc.free(self.dmabuf_fds);
        posix.close(self.fd);
        log.info("Closed", .{});
    }

    pub fn getWidth(self: *const Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *const Self) u32 {
        return self.height;
    }

    pub fn getFormat(self: *const Self) u32 {
        return self.format;
    }

    pub fn getBufferSize(self: *const Self) u32 {
        return self.buffer_size;
    }
};
