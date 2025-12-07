const std = @import("std");
const ws = @import("websocket");
const usb = @import("./usb.zig");
const Server = @import("./server.zig");

const log = std.log.scoped(.ws);

pub const Handler = @This();

server: *Server,
conn: *ws.Conn,

pub fn init(h: *ws.Handshake, conn: *ws.Conn, server: *Server) !@This() {
    _ = h;

    try server.addClient(conn);
    return .{
        .server = server,
        .conn = conn,
    };
}

const ClientMessage = struct { type: []const u8 };

const KeyboardEvent = struct {
    type: []const u8,
    event: []const u8,
    code: []const u8,
    modifiers: struct {
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
        meta: bool = false,
    },
};

const MouseEvent = struct {
    type: []const u8,
    event: []const u8,
    x: u16 = 0, // Absolute position (0-32767)
    y: u16 = 0,
    button: u8 = 0, // 0=left, 1=middle, 2=right
    delta: i32 = 0, // Wheel delta
};

// Handle client messages (keyboard and mouse input from browser)
pub fn clientMessage(self: *@This(), data: []const u8) !void {
    // First, try to determine the event type
    const type_parsed = std.json.parseFromSlice(ClientMessage, self.server.alloc, data, .{ .ignore_unknown_fields = true }) catch |err| {
        log.err("Failed to parse event type: {}", .{err});
        return;
    };
    defer type_parsed.deinit();

    const event = type_parsed.value.type;
    if (std.mem.eql(u8, event, "keyboard")) {
        self.handleKeyboardEvent(data);
    } else if (std.mem.eql(u8, event, "mouse")) {
        self.handleMouseEvent(data);
    } else {
        log.warn("unknown event type: {s}", .{event});
    }
}

fn handleKeyboardEvent(self: *@This(), data: []const u8) void {
    const parsed = std.json.parseFromSlice(KeyboardEvent, self.server.alloc, data, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const event = parsed.value;

    const modifiers = usb.ModifierFlags{
        .ctrl = event.modifiers.ctrl,
        .alt = event.modifiers.alt,
        .shift = event.modifiers.shift,
        .meta = event.modifiers.meta,
    };

    if (std.mem.eql(u8, event.event, "keydown")) {
        self.server.keyboard.keyDown(event.code, modifiers);
    } else if (std.mem.eql(u8, event.event, "keyup")) {
        self.server.keyboard.keyUp(event.code, modifiers);
    }
}

fn handleMouseEvent(self: *@This(), data: []const u8) void {
    const parsed = std.json.parseFromSlice(MouseEvent, self.server.alloc, data, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const event = parsed.value;

    if (std.mem.eql(u8, event.event, "move")) {
        self.server.mouse.move(event.x, event.y);
    } else if (std.mem.eql(u8, event.event, "down")) {
        self.server.mouse.click(event.button, true);
    } else if (std.mem.eql(u8, event.event, "up")) {
        self.server.mouse.click(event.button, false);
    } else if (std.mem.eql(u8, event.event, "wheel")) {
        const delta: i8 = @intCast(std.math.clamp(event.delta, -127, 127));
        self.server.mouse.wheel(delta);
    }
}

pub fn close(self: *@This()) void {
    self.server.removeClient(self.conn);
}
