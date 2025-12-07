const std = @import("std");

const web_dist_tar = @embedFile("web_dist_tar");
const log = std.log.scoped(.http);

alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator, port: u16) @This() {
    _ = port;
    return .{
        .alloc = alloc,
    };
}

/// Handle HTTP request from a socket stream (used by HTTPS server via socketpair)
pub fn handleStream(self: *const @This(), socket_fd: std.posix.fd_t) void {
    const stream = std.net.Stream{ .handle = socket_fd };
    self.handleStreamImpl(stream);
}

fn handleStreamImpl(self: *const @This(), stream: std.net.Stream) void {
    var buffer: [4096]u8 = undefined;
    const bytes_read = stream.read(&buffer) catch |err| {
        log.err("Failed to read HTTP request: {}", .{err});
        return;
    };

    if (bytes_read == 0) {
        return;
    }

    // Parse request path from HTTP request line (e.g., "GET /path HTTP/1.1")
    const request = buffer[0..bytes_read];
    var request_path: []const u8 = "/";

    if (std.mem.indexOf(u8, request, " ")) |first_space| {
        const after_method = request[first_space + 1 ..];
        if (std.mem.indexOf(u8, after_method, " ")) |second_space| {
            request_path = after_method[0..second_space];
        }
    }

    // Default to index.html for root path
    const file_path: []const u8 = if (std.mem.eql(u8, request_path, "/")) "index.html" else request_path[1..]; // Strip leading /

    // Find and serve file from embedded tar
    var file_name_buffer: [std.fs.max_name_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var tar_reader = std.Io.Reader.fixed(web_dist_tar);
    var tar_iter = std.tar.Iterator.init(&tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    while (tar_iter.next() catch null) |file_entry| {
        // Handle paths that might start with "./"
        var entry_name = file_entry.name;
        if (std.mem.startsWith(u8, entry_name, "./")) {
            entry_name = entry_name[2..];
        }

        if (std.mem.eql(u8, entry_name, file_path)) {
            // Read file content from tar - use unread_file_bytes from iterator
            const content = self.alloc.alloc(u8, @intCast(file_entry.size)) catch {
                sendErrorResponse(stream, "500 Internal Server Error");
                return;
            };
            defer self.alloc.free(content);

            // Read file content directly from the tar reader
            tar_reader.readSliceAll(content) catch {
                sendErrorResponse(stream, "500 Internal Server Error");
                return;
            };
            tar_iter.unread_file_bytes = 0;

            // Determine Content-Type
            const content_type = getContentType(file_path);

            self.sendResponse(stream, "200 OK", content_type, content);
            return;
        }
    }

    // File not found
    sendErrorResponse(stream, "404 Not Found");
}

fn sendResponse(self: *const @This(), stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    const header = std.fmt.allocPrint(
        self.alloc,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return;
    defer self.alloc.free(header);

    _ = stream.writeAll(header) catch return;
    _ = stream.writeAll(body) catch return;
}

fn getContentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".woff")) return "font/woff";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    return "application/octet-stream";
}

fn sendErrorResponse(stream: std.net.Stream, comptime status: []const u8) void {
    const response = "HTTP/1.1 " ++ status ++ "\r\nContent-Type: text/plain\r\nContent-Length: " ++ std.fmt.comptimePrint("{d}", .{status.len}) ++ "\r\nConnection: close\r\n\r\n" ++ status;
    _ = stream.writeAll(response) catch {};
}
