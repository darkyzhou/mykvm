const std = @import("std");
const utils = @import("./utils.zig");
const posix = std.posix;
const log = std.log.scoped(.dma);

const ioctl = utils.ioctl;

const c = @cImport({
    @cInclude("linux/dma-heap.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("linux/fcntl.h");
});

pub const DmaBuffer = struct {
    fd: posix.fd_t,
    size: usize,

    const Self = @This();

    pub fn syncStart(self: *const Self, flags: u64) void {
        var sync = c.struct_dma_buf_sync{ .flags = flags | c.DMA_BUF_SYNC_START };
        _ = ioctl(self.fd, c.DMA_BUF_IOCTL_SYNC, @intFromPtr(&sync));
    }

    pub fn syncEnd(self: *const Self, flags: u64) void {
        var sync = c.struct_dma_buf_sync{ .flags = flags | c.DMA_BUF_SYNC_END };
        _ = ioctl(self.fd, c.DMA_BUF_IOCTL_SYNC, @intFromPtr(&sync));
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.fd);
    }
};

/// DMA Heap allocator
pub const DmaHeap = struct {
    fd: posix.fd_t,

    const Self = @This();

    pub fn init() !Self {
        const fd = posix.open("/dev/dma_heap/linux,cma", .{ .ACCMODE = .RDWR }, 0) catch |err| {
            log.err("Failed to open /dev/dma_heap/linux,cma: {}", .{err});
            return err;
        };
        log.info("Opened /dev/dma_heap/linux,cma", .{});
        return Self{ .fd = fd };
    }

    pub fn alloc(self: *const Self, size: usize) !DmaBuffer {
        var alloc_data = c.struct_dma_heap_allocation_data{
            .len = size,
            .fd = 0,
            .fd_flags = c.O_CLOEXEC | c.O_RDWR,
            .heap_flags = 0,
        };

        if (ioctl(self.fd, c.DMA_HEAP_IOCTL_ALLOC, @intFromPtr(&alloc_data)) != .SUCCESS) {
            log.err("Failed to allocate {} bytes", .{size});
            return error.AllocFailed;
        }

        return DmaBuffer{
            .fd = @intCast(alloc_data.fd),
            .size = size,
        };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.fd);
    }
};
