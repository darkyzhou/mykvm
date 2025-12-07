const std = @import("std");
const ws = @import("websocket");

const usb = @import("./usb.zig");
const log = std.log.scoped(.server);

alloc: std.mem.Allocator,
clients: std.ArrayList(*ws.Conn),
mutex: std.Thread.Mutex,
keyboard: *usb.HidKeyboard,
mouse: *usb.HidMouse,

pub fn init(alloc: std.mem.Allocator, keyboard: *usb.HidKeyboard, mouse: *usb.HidMouse) @This() {
    return .{
        .alloc = alloc,
        .clients = std.ArrayList(*ws.Conn).empty,
        .mutex = .{},
        .keyboard = keyboard,
        .mouse = mouse,
    };
}

pub fn deinit(self: *@This()) void {
    self.clients.deinit(self.alloc);
}

pub fn addClient(self: *@This(), conn: *ws.Conn) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.clients.append(self.alloc, conn);
    log.info("Client connected. Total clients: {}", .{self.clients.items.len});
}

pub fn removeClient(self: *@This(), conn: *ws.Conn) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.clients.items, 0..) |client, i| {
        if (client == conn) {
            _ = self.clients.swapRemove(i);
            log.info("Client disconnected. Total clients: {}", .{self.clients.items.len});
            break;
        }
    }
}

pub fn broadcast(self: *@This(), data: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var failed_clients = std.ArrayList(usize).empty;
    defer failed_clients.deinit(self.alloc);

    for (self.clients.items, 0..) |client, i| {
        client.writeBin(data) catch {
            try failed_clients.append(self.alloc, i);
            continue;
        };
    }

    var j: usize = failed_clients.items.len;
    while (j > 0) {
        j -= 1;
        _ = self.clients.swapRemove(failed_clients.items[j]);
    }

    if (failed_clients.items.len > 0) {
        log.info("Removed {} disconnected clients", .{failed_clients.items.len});
    }
}
