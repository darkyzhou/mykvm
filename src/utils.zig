//! Common utility functions

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Wrapper for ioctl syscall with EINTR retry
pub fn ioctl(fd: posix.fd_t, request: u32, arg: usize) posix.E {
    while (true) {
        const rc = linux.syscall3(.ioctl, @bitCast(@as(isize, fd)), request, arg);
        const signed: isize = @bitCast(rc);
        if (signed != -@as(isize, @intCast(@intFromEnum(linux.E.INTR)))) {
            if (signed < 0) {
                return @enumFromInt(@as(u16, @intCast(-signed)));
            }
            return .SUCCESS;
        }
    }
}

/// Get local IP address by creating a UDP socket and checking the source address
pub fn getLocalIp() ?[]const u8 {
    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch return null;
    defer posix.close(sock);

    // Connect to external IP (doesn't actually send anything for UDP)
    const dest = std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53);
    posix.connect(sock, &dest.any, dest.getOsSockLen()) catch return null;

    // Get local address
    var local_addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    posix.getsockname(sock, &local_addr, &addr_len) catch return null;

    const addr = std.net.Address{ .any = local_addr };
    const ip_u32 = addr.in.sa.addr;

    // Format IP address - use static buffer
    const Static = struct {
        var buf: [16]u8 = undefined;
    };
    const ip_str = std.fmt.bufPrint(&Static.buf, "{}.{}.{}.{}", .{
        @as(u8, @truncate(ip_u32)),
        @as(u8, @truncate(ip_u32 >> 8)),
        @as(u8, @truncate(ip_u32 >> 16)),
        @as(u8, @truncate(ip_u32 >> 24)),
    }) catch return null;
    return ip_str;
}

/// Convert V4L2 FourCC format code to string
pub fn fourccToString(fourcc: u32) [4]u8 {
    return .{
        @truncate(fourcc & 0xFF),
        @truncate((fourcc >> 8) & 0xFF),
        @truncate((fourcc >> 16) & 0xFF),
        @truncate((fourcc >> 24) & 0xFF),
    };
}
