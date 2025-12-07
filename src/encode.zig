//! V4L2 Memory-to-Memory (M2M) Encoder with DMABUF support
//! Hardware H.264 encoding via bcm2835-codec-encode (/dev/video11)
//!
//! This encoder uses external DMABUF buffers for zero-copy input from capture device.
//!
//! Reference: https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/dev-encoder.html

const std = @import("std");
const dma = @import("./dma.zig");
const utils = @import("./utils.zig");
const posix = std.posix;
const log = std.log.scoped(.encode);

const ioctl = utils.ioctl;

const c = @cImport({
    @cInclude("linux/videodev2.h");
    @cInclude("linux/v4l2-controls.h");
    @cInclude("sys/mman.h");
});

/// Mapped buffer info (for CAPTURE/output buffers)
const MappedBuffer = struct {
    ptr: [*]u8,
    length: usize,
    plane_length: u32,
};

/// Encoder configuration
pub const EncoderConfig = struct {
    width: u32 = 1280,
    height: u32 = 720,
    input_format: u32 = c.V4L2_PIX_FMT_YUYV,
    output_format: u32 = c.V4L2_PIX_FMT_H264,
    bitrate: u32 = 1_000_000,
    gop_size: u32 = 3,
    bytesperline: ?u32 = null,
    sizeimage: ?u32 = null,
};

/// V4L2 M2M Encoder with DMABUF input
pub const Encoder = struct {
    alloc: std.mem.Allocator,
    fd: posix.fd_t,
    config: EncoderConfig,
    num_buffers: u32,
    input_sizeimage: u32,
    dmabuf_fds: []posix.fd_t, // External DMABUF fds (not owned)
    capture_buffers: []MappedBuffer, // H.264 output (MMAP)
    output_planes: []c.struct_v4l2_plane,
    capture_planes: []c.struct_v4l2_plane,
    streaming: bool,

    const Self = @This();

    /// Initialize the M2M encoder with external DMABUF buffers for input
    pub fn init(
        alloc: std.mem.Allocator,
        device: [:0]const u8,
        config: EncoderConfig,
        dmabuf_buffers: []const dma.DmaBuffer,
    ) !Self {
        log.info("Opening encoder device {s}...", .{device});
        log.info("Using DMABUF for zero-copy input", .{});

        const fd = try posix.open(device, .{ .ACCMODE = .RDWR }, 0);
        errdefer posix.close(fd);

        // Query capabilities
        var cap = std.mem.zeroes(c.struct_v4l2_capability);
        if (ioctl(fd, c.VIDIOC_QUERYCAP, @intFromPtr(&cap)) != .SUCCESS) {
            log.err("VIDIOC_QUERYCAP failed", .{});
            return error.QueryCapFailed;
        }

        if (cap.capabilities & c.V4L2_CAP_VIDEO_M2M_MPLANE == 0) {
            log.err("Device does not support M2M multiplanar", .{});
            return error.NotM2MDevice;
        }
        if (cap.capabilities & c.V4L2_CAP_STREAMING == 0) {
            log.err("Device does not support streaming", .{});
            return error.NoStreaming;
        }

        // Calculate frame size
        const bpp: u32 = switch (config.input_format) {
            c.V4L2_PIX_FMT_RGB24 => 3,
            else => 2,
        };
        const bytesperline = config.bytesperline orelse config.width * bpp;
        const sizeimage = config.sizeimage orelse config.width * config.height * bpp;

        // Set OUTPUT format (raw frames input)
        var fmt_out = std.mem.zeroes(c.struct_v4l2_format);
        fmt_out.type = c.V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        fmt_out.fmt.pix_mp.width = config.width;
        fmt_out.fmt.pix_mp.height = config.height;
        fmt_out.fmt.pix_mp.pixelformat = config.input_format;
        fmt_out.fmt.pix_mp.num_planes = 1;
        fmt_out.fmt.pix_mp.plane_fmt[0].sizeimage = sizeimage;
        fmt_out.fmt.pix_mp.plane_fmt[0].bytesperline = bytesperline;

        if (ioctl(fd, c.VIDIOC_S_FMT, @intFromPtr(&fmt_out)) != .SUCCESS) {
            log.err("Failed to set OUTPUT format", .{});
            return error.SetFormatFailed;
        }

        const out_fmt_str = utils.fourccToString(fmt_out.fmt.pix_mp.pixelformat);
        log.info("OUTPUT format: {s} {}x{}, sizeimage={}", .{
            &out_fmt_str,
            fmt_out.fmt.pix_mp.width,
            fmt_out.fmt.pix_mp.height,
            fmt_out.fmt.pix_mp.plane_fmt[0].sizeimage,
        });

        // Set CAPTURE format (H.264 output)
        var fmt_cap = std.mem.zeroes(c.struct_v4l2_format);
        fmt_cap.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        fmt_cap.fmt.pix_mp.width = config.width;
        fmt_cap.fmt.pix_mp.height = config.height;
        fmt_cap.fmt.pix_mp.pixelformat = config.output_format;
        fmt_cap.fmt.pix_mp.num_planes = 1;

        if (ioctl(fd, c.VIDIOC_S_FMT, @intFromPtr(&fmt_cap)) != .SUCCESS) {
            log.err("Failed to set CAPTURE format", .{});
            return error.SetFormatFailed;
        }

        const cap_fmt_str = utils.fourccToString(fmt_cap.fmt.pix_mp.pixelformat);
        log.info("CAPTURE format: {s} {}x{}, sizeimage={}", .{
            &cap_fmt_str,
            fmt_cap.fmt.pix_mp.width,
            fmt_cap.fmt.pix_mp.height,
            fmt_cap.fmt.pix_mp.plane_fmt[0].sizeimage,
        });

        // Set encoder controls
        setControl(fd, c.V4L2_CID_MPEG_VIDEO_BITRATE, @intCast(config.bitrate));
        setControl(fd, c.V4L2_CID_MPEG_VIDEO_GOP_SIZE, @intCast(config.gop_size));
        setControl(fd, c.V4L2_CID_MPEG_VIDEO_B_FRAMES, 0);
        setControl(fd, c.V4L2_CID_MPEG_VIDEO_H264_PROFILE, c.V4L2_MPEG_VIDEO_H264_PROFILE_CONSTRAINED_BASELINE);
        setControl(fd, c.V4L2_CID_MPEG_VIDEO_REPEAT_SEQ_HEADER, 1);

        const num_buffers: u32 = @intCast(dmabuf_buffers.len);

        // Request OUTPUT buffers (DMABUF mode)
        var reqbuf_out = std.mem.zeroes(c.struct_v4l2_requestbuffers);
        reqbuf_out.count = num_buffers;
        reqbuf_out.type = c.V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        reqbuf_out.memory = c.V4L2_MEMORY_DMABUF;

        if (ioctl(fd, c.VIDIOC_REQBUFS, @intFromPtr(&reqbuf_out)) != .SUCCESS) {
            log.err("Failed to request OUTPUT DMABUF buffers", .{});
            return error.ReqBufsFailed;
        }
        log.info("Requested {} OUTPUT DMABUF buffers", .{reqbuf_out.count});

        // Request CAPTURE buffers (MMAP mode)
        var reqbuf_cap = std.mem.zeroes(c.struct_v4l2_requestbuffers);
        reqbuf_cap.count = num_buffers;
        reqbuf_cap.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        reqbuf_cap.memory = c.V4L2_MEMORY_MMAP;

        if (ioctl(fd, c.VIDIOC_REQBUFS, @intFromPtr(&reqbuf_cap)) != .SUCCESS) {
            log.err("Failed to request CAPTURE buffers", .{});
            return error.ReqBufsFailed;
        }
        log.info("Allocated {} CAPTURE buffers (MMAP)", .{reqbuf_cap.count});

        // Store DMABUF fds
        const dmabuf_fds = try alloc.alloc(posix.fd_t, num_buffers);
        errdefer alloc.free(dmabuf_fds);
        for (dmabuf_buffers, 0..) |buf, i| {
            dmabuf_fds[i] = buf.fd;
        }

        // Allocate plane tracking arrays
        const output_planes = try alloc.alloc(c.struct_v4l2_plane, num_buffers);
        errdefer alloc.free(output_planes);

        const capture_planes = try alloc.alloc(c.struct_v4l2_plane, reqbuf_cap.count);
        errdefer alloc.free(capture_planes);

        // Query and mmap CAPTURE buffers, then queue them
        const capture_buffers = try alloc.alloc(MappedBuffer, reqbuf_cap.count);
        errdefer alloc.free(capture_buffers);

        for (0..reqbuf_cap.count) |i| {
            capture_planes[i] = std.mem.zeroes(c.struct_v4l2_plane);

            var buf = std.mem.zeroes(c.struct_v4l2_buffer);
            buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            buf.memory = c.V4L2_MEMORY_MMAP;
            buf.index = @intCast(i);
            buf.length = 1;
            buf.m.planes = &capture_planes[i];

            if (ioctl(fd, c.VIDIOC_QUERYBUF, @intFromPtr(&buf)) != .SUCCESS) {
                log.err("Failed to query CAPTURE buffer {}", .{i});
                return error.QueryBufFailed;
            }

            const length = capture_planes[i].length;
            const offset = capture_planes[i].m.mem_offset;

            const ptr = std.c.mmap(
                null,
                length,
                std.c.PROT.READ | std.c.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                offset,
            );
            if (ptr == std.c.MAP_FAILED) {
                log.err("Failed to mmap CAPTURE buffer {}", .{i});
                return error.MmapFailed;
            }

            capture_buffers[i] = .{
                .ptr = @ptrCast(ptr),
                .length = length,
                .plane_length = length,
            };

            // Queue CAPTURE buffer
            capture_planes[i].length = @intCast(length);
            buf.m.planes = &capture_planes[i];

            if (ioctl(fd, c.VIDIOC_QBUF, @intFromPtr(&buf)) != .SUCCESS) {
                log.err("Failed to queue CAPTURE buffer {}", .{i});
                return error.QBufFailed;
            }
        }
        log.info("Mapped and queued {} CAPTURE buffers", .{reqbuf_cap.count});

        // Start streaming
        var type_out: u32 = c.V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        if (ioctl(fd, c.VIDIOC_STREAMON, @intFromPtr(&type_out)) != .SUCCESS) {
            log.err("Failed to start OUTPUT stream", .{});
            return error.StreamOnFailed;
        }

        var type_cap: u32 = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        if (ioctl(fd, c.VIDIOC_STREAMON, @intFromPtr(&type_cap)) != .SUCCESS) {
            log.err("Failed to start CAPTURE stream", .{});
            return error.StreamOnFailed;
        }

        log.info("Encoder initialized and streaming", .{});

        return Self{
            .fd = fd,
            .config = config,
            .num_buffers = num_buffers,
            .input_sizeimage = sizeimage,
            .dmabuf_fds = dmabuf_fds,
            .capture_buffers = capture_buffers,
            .output_planes = output_planes,
            .capture_planes = capture_planes,
            .alloc = alloc,
            .streaming = true,
        };
    }

    /// Encode a frame from the DMABUF at given index
    /// The buffer must have been filled by the capture device first
    /// Returns encoded H.264 data and the index of reclaimed OUTPUT buffer (if any)
    pub fn encodeFromBuffer(self: *Self, index: u32, bytes_used: u32) !struct { data: []const u8, reclaimed_idx: ?u32 } {
        if (!self.streaming) {
            return error.NotStreaming;
        }

        // Queue OUTPUT buffer with DMABUF fd
        self.output_planes[index] = std.mem.zeroes(c.struct_v4l2_plane);
        self.output_planes[index].bytesused = bytes_used;
        self.output_planes[index].length = self.input_sizeimage;
        self.output_planes[index].m.fd = self.dmabuf_fds[index];

        var qbuf_out = std.mem.zeroes(c.struct_v4l2_buffer);
        qbuf_out.type = c.V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        qbuf_out.memory = c.V4L2_MEMORY_DMABUF;
        qbuf_out.index = index;
        qbuf_out.length = 1;
        qbuf_out.m.planes = &self.output_planes[index];

        if (ioctl(self.fd, c.VIDIOC_QBUF, @intFromPtr(&qbuf_out)) != .SUCCESS) {
            return error.QBufFailed;
        }

        // Wait for CAPTURE buffer
        var pfd = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const poll_result = posix.poll(&pfd, 5000) catch |err| {
            log.err("Poll error: {}", .{err});
            return error.PollFailed;
        };
        if (poll_result == 0) {
            return error.PollTimeout;
        }

        // Dequeue CAPTURE buffer
        var cap_plane = std.mem.zeroes(c.struct_v4l2_plane);
        var dqbuf_cap = std.mem.zeroes(c.struct_v4l2_buffer);
        dqbuf_cap.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        dqbuf_cap.memory = c.V4L2_MEMORY_MMAP;
        dqbuf_cap.length = 1;
        dqbuf_cap.m.planes = &cap_plane;

        if (ioctl(self.fd, c.VIDIOC_DQBUF, @intFromPtr(&dqbuf_cap)) != .SUCCESS) {
            return error.DQBufFailed;
        }

        const cap_idx = dqbuf_cap.index;
        const encoded_size = cap_plane.bytesused;
        const encoded_data = self.capture_buffers[cap_idx].ptr[0..encoded_size];

        // Re-queue CAPTURE buffer
        self.capture_planes[cap_idx] = std.mem.zeroes(c.struct_v4l2_plane);
        self.capture_planes[cap_idx].length = self.capture_buffers[cap_idx].plane_length;

        var reqbuf_cap = std.mem.zeroes(c.struct_v4l2_buffer);
        reqbuf_cap.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        reqbuf_cap.memory = c.V4L2_MEMORY_MMAP;
        reqbuf_cap.index = cap_idx;
        reqbuf_cap.length = 1;
        reqbuf_cap.m.planes = &self.capture_planes[cap_idx];

        if (ioctl(self.fd, c.VIDIOC_QBUF, @intFromPtr(&reqbuf_cap)) != .SUCCESS) {
            return error.QBufFailed;
        }

        // Try to dequeue OUTPUT buffer
        var out_plane = std.mem.zeroes(c.struct_v4l2_plane);
        var dqbuf_out = std.mem.zeroes(c.struct_v4l2_buffer);
        dqbuf_out.type = c.V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        dqbuf_out.memory = c.V4L2_MEMORY_DMABUF;
        dqbuf_out.length = 1;
        dqbuf_out.m.planes = &out_plane;

        var reclaimed: ?u32 = null;
        if (ioctl(self.fd, c.VIDIOC_DQBUF, @intFromPtr(&dqbuf_out)) == .SUCCESS) {
            reclaimed = dqbuf_out.index;
        }

        return .{ .data = encoded_data, .reclaimed_idx = reclaimed };
    }

    /// Try to reclaim an OUTPUT buffer
    pub fn reclaimOutputBuffer(self: *Self) ?u32 {
        var out_plane = std.mem.zeroes(c.struct_v4l2_plane);
        var dqbuf_out = std.mem.zeroes(c.struct_v4l2_buffer);
        dqbuf_out.type = c.V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        dqbuf_out.memory = c.V4L2_MEMORY_DMABUF;
        dqbuf_out.length = 1;
        dqbuf_out.m.planes = &out_plane;

        if (ioctl(self.fd, c.VIDIOC_DQBUF, @intFromPtr(&dqbuf_out)) == .SUCCESS) {
            return dqbuf_out.index;
        }
        return null;
    }

    /// Force generation of a key frame
    pub fn forceKeyFrame(self: *Self) void {
        setControl(self.fd, c.V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME, 1);
    }

    /// Stop encoding and release resources
    pub fn deinit(self: *Self) void {
        if (self.streaming) {
            var type_out: u32 = c.V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
            _ = ioctl(self.fd, c.VIDIOC_STREAMOFF, @intFromPtr(&type_out));

            var type_cap: u32 = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            _ = ioctl(self.fd, c.VIDIOC_STREAMOFF, @intFromPtr(&type_cap));

            self.streaming = false;
        }

        // Unmap CAPTURE buffers
        for (self.capture_buffers) |buf| {
            _ = std.c.munmap(@ptrCast(@alignCast(buf.ptr)), buf.length);
        }

        self.alloc.free(self.dmabuf_fds);
        self.alloc.free(self.capture_buffers);
        self.alloc.free(self.output_planes);
        self.alloc.free(self.capture_planes);

        posix.close(self.fd);
        log.info("Encoder deinitialized", .{});
    }
};

fn setControl(fd: posix.fd_t, id: u32, value: i32) void {
    var ctrl = c.struct_v4l2_control{
        .id = id,
        .value = value,
    };
    const result = ioctl(fd, c.VIDIOC_S_CTRL, @intFromPtr(&ctrl));
    if (result != .SUCCESS) {
        log.warn("Failed to set control 0x{x} = {}", .{ id, value });
    }
}
