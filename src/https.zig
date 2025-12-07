const std = @import("std");
const tls = @import("tls");
const websocket = @import("websocket");

const HttpServer = @import("./http.zig");
const WsHandler = @import("./ws.zig").Handler;
const Server = @import("./server.zig");

const linux = std.os.linux;
const log = std.log.scoped(.https);

pub fn run(
    alloc: std.mem.Allocator,
    server: *Server,
    addr: []const u8,
    port: u16,
    cert_path: []const u8,
    key_path: []const u8,
) void {
    runImpl(alloc, server, addr, port, cert_path, key_path) catch |err| {
        log.err("Server error: {}", .{err});
    };
}

fn runImpl(
    alloc: std.mem.Allocator,
    server: *Server,
    addr: []const u8,
    port: u16,
    cert_path: []const u8,
    key_path: []const u8,
) !void {
    var auth = try tls.config.CertKeyPair.fromFilePathAbsolute(alloc, cert_path, key_path);
    defer auth.deinit(alloc);

    const address = try std.net.Address.parseIp(addr, port);
    var tcp_server = try address.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    log.info("HTTPS server listening on {s}:{d}", .{ addr, port });

    const http_handler: HttpServer = .init(alloc, port);

    while (true) {
        const tcp = tcp_server.accept() catch |err| {
            log.err("Accept error: {}", .{err});
            continue;
        };

        std.posix.setsockopt(tcp.stream.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        const thread = std.Thread.spawn(.{}, handleConnection, .{ alloc, server, &http_handler, &auth, tcp }) catch |err| {
            log.err("Failed to spawn handler thread: {}", .{err});
            tcp.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(
    alloc: std.mem.Allocator,
    server: *Server,
    http_handler: *const HttpServer,
    auth: *tls.config.CertKeyPair,
    tcp: std.net.Server.Connection,
) void {
    defer tcp.stream.close();

    // Perform TLS handshake
    // Force ChaCha20-Poly1305 only (no AES) for better performance on devices without AES hardware
    var tls_conn = tls.serverFromStream(tcp.stream, .{
        .auth = auth,
        .cipher_suites = &.{.CHACHA20_POLY1305_SHA256},
    }) catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        return;
    };
    defer tls_conn.close() catch {};

    var request_buf: [8192]u8 = undefined;
    const request_len = tls_conn.read(&request_buf) catch |err| {
        log.err("TLS read error: {}", .{err});
        return;
    };

    if (request_len == 0) {
        return;
    }

    const request = request_buf[0..request_len];

    // Check if this is a WebSocket upgrade request
    if (isWebSocketUpgrade(request)) {
        handleWebSocket(alloc, server, &tls_conn, request);
    } else {
        handleHttp(http_handler, &tls_conn, request);
    }
}

fn isWebSocketUpgrade(request: []const u8) bool {
    // Parse headers to check for WebSocket upgrade
    var has_upgrade = false;
    var has_connection_upgrade = false;
    var has_ws_key = false;

    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next(); // Skip request line

    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (std.mem.indexOfScalar(u8, line, ':')) |colon_pos| {
            const name = std.mem.trim(u8, line[0..colon_pos], " \t");
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                if (std.ascii.eqlIgnoreCase(value, "websocket")) {
                    has_upgrade = true;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.indexOfIgnoreCase(value, "upgrade") != null) {
                    has_connection_upgrade = true;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
                if (value.len > 0) {
                    has_ws_key = true;
                }
            }
        }
    }

    return has_upgrade and has_connection_upgrade and has_ws_key;
}

fn handleWebSocket(
    alloc: std.mem.Allocator,
    server: *Server,
    tls_conn: anytype,
    initial_request: []const u8,
) void {
    // Create socketpair for TLS <-> WebSocket library bridge
    var pair: [2]std.posix.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair);
    if (rc != 0) {
        log.err("Failed to create socketpair for WebSocket", .{});
        return;
    }

    const tls_side = std.net.Stream{ .handle = pair[0] };
    const ws_side_fd = pair[1];

    // Write the initial request to socketpair
    tls_side.writeAll(initial_request) catch |err| {
        log.err("Failed to write initial request to socketpair: {}", .{err});
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
        return;
    };

    // Spawn WebSocket handler thread
    const ws_thread = std.Thread.spawn(.{}, wsHandlerThread, .{ alloc, server, ws_side_fd }) catch |err| {
        log.err("Failed to spawn WebSocket handler thread: {}", .{err});
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
        return;
    };

    // Spawn thread to read from socketpair and write to TLS
    const write_thread = std.Thread.spawn(.{}, tlsWriteThread, .{ tls_conn, tls_side }) catch |err| {
        log.err("Failed to spawn TLS write thread: {}", .{err});
        _ = linux.close(pair[0]);
        ws_thread.join();
        return;
    };

    // Read from TLS and write to socketpair (in this thread)
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = tls_conn.read(&buf) catch |err| {
            log.err("TLS read error in WebSocket proxy: {}", .{err});
            break;
        };
        if (n == 0) break;

        tls_side.writeAll(buf[0..n]) catch |err| {
            log.err("Socketpair write error in WebSocket proxy: {}", .{err});
            break;
        };
    }

    _ = linux.shutdown(pair[0], linux.SHUT.WR);
    write_thread.join();
    _ = linux.close(pair[0]);
    ws_thread.join();
}

fn tlsWriteThread(tls_conn: anytype, tls_side: std.net.Stream) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = tls_side.read(&buf) catch |err| {
            log.err("Socketpair read error in TLS write thread: {}", .{err});
            break;
        };
        if (n == 0) break;

        tls_conn.writeAll(buf[0..n]) catch |err| {
            log.err("TLS write error in TLS write thread: {}", .{err});
            break;
        };
    }
}

fn handleHttp(
    http_handler: *const HttpServer,
    tls_conn: anytype,
    request: []const u8,
) void {
    var pair: [2]std.posix.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair);
    if (rc != 0) {
        log.err("Failed to create socketpair", .{});
        return;
    }

    const http_thread = std.Thread.spawn(.{}, httpHandlerThread, .{ http_handler, pair[1] }) catch |err| {
        log.err("Failed to spawn HTTP handler thread: {}", .{err});
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
        return;
    };

    const tls_side = std.net.Stream{ .handle = pair[0] };

    if (request.len > 0) {
        tls_side.writeAll(request) catch |err| {
            log.err("Socketpair write error: {}", .{err});
            _ = linux.close(pair[0]);
            http_thread.join();
            return;
        };
    }

    _ = linux.shutdown(pair[0], linux.SHUT.WR);

    var response_buf: [16384]u8 = undefined;
    while (true) {
        const n = tls_side.read(&response_buf) catch |err| {
            log.err("Response read error: {}", .{err});
            break;
        };
        if (n == 0) break;

        tls_conn.writeAll(response_buf[0..n]) catch |err| {
            log.err("TLS write error: {}", .{err});
            break;
        };
    }

    http_thread.join();
    _ = linux.close(pair[0]);
}

fn wsHandlerThread(alloc: std.mem.Allocator, server: *Server, socket_fd: std.posix.fd_t) void {
    const stream = std.net.Stream{ .handle = socket_fd };
    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

    var state = websocket.server.WorkerState.init(alloc, .{
        .max_message_size = 65536,
    }) catch |err| {
        log.err("Failed to init WebSocket worker state: {}", .{err});
        _ = linux.close(socket_fd);
        return;
    };
    defer state.deinit();

    var worker = websocket.server.Worker(WsHandler).init(alloc, &state) catch |err| {
        log.err("Failed to init WebSocket worker: {}", .{err});
        _ = linux.close(socket_fd);
        return;
    };
    defer worker.deinit();

    const hc = worker.createConn(socket_fd, address, timestamp()) catch |err| {
        log.err("Failed to create WebSocket connection: {}", .{err});
        _ = linux.close(socket_fd);
        return;
    };

    const hs_state = state.handshake_pool.acquire() catch |err| {
        log.err("Failed to acquire handshake state: {}", .{err});
        worker.cleanupConn(hc);
        return;
    };
    defer hs_state.release();

    const n = stream.read(hs_state.buf) catch |err| {
        log.err("WebSocket handshake read error: {}", .{err});
        worker.cleanupConn(hc);
        return;
    };

    if (n == 0) {
        worker.cleanupConn(hc);
        return;
    }
    hs_state.len = n;

    var handshake = websocket.Handshake.parse(hs_state) catch |err| {
        log.err("WebSocket handshake parse error: {}", .{err});
        worker.cleanupConn(hc);
        return;
    } orelse {
        log.err("WebSocket handshake incomplete", .{});
        worker.cleanupConn(hc);
        return;
    };

    var reply_buf: [2048]u8 = undefined;
    const reply = websocket.Handshake.createReply(handshake.key, handshake.res_headers, false, &reply_buf) catch |err| {
        log.err("Failed to create WebSocket reply: {}", .{err});
        worker.cleanupConn(hc);
        return;
    };

    stream.writeAll(reply) catch |err| {
        log.err("WebSocket handshake write error: {}", .{err});
        worker.cleanupConn(hc);
        return;
    };

    hc.handler = WsHandler.init(&handshake, &hc.conn, server) catch |err| {
        log.err("WebSocket handler init error: {}", .{err});
        worker.cleanupConn(hc);
        return;
    };

    worker.worker.readLoop(hc) catch |err| {
        log.err("WebSocket readLoop error: {}", .{err});
    };
}

fn timestamp() u32 {
    const ts = std.posix.clock_gettime(.REALTIME) catch unreachable;
    return @intCast(ts.sec);
}

fn httpHandlerThread(http_handler: *const HttpServer, socket_fd: std.posix.fd_t) void {
    defer _ = linux.close(socket_fd);
    http_handler.handleStream(socket_fd);
}
