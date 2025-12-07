const std = @import("std");
const log = std.log.scoped(.usb);

/// USB HID Gadget for keyboard and mouse emulation
/// Creates TWO separate HID devices for better BIOS compatibility:
/// - /dev/hidg0: Keyboard (Boot Protocol, 8-byte report, no Report ID)
/// - /dev/hidg1: Mouse (Absolute positioning, 6-byte report)
/// Reference: https://github.com/stjeong/rasp_vusb
const GADGET_PATH = "/sys/kernel/config/usb_gadget/mykvm";
const HIDG_KEYBOARD = "/dev/hidg0";
const HIDG_MOUSE = "/dev/hidg1";

// Module-level UDC name storage for state queries
var g_udc_name: [64]u8 = undefined;
var g_udc_name_len: usize = 0;

/// UDC states as defined in Linux kernel
pub const UdcState = enum {
    not_attached,
    attached,
    powered,
    reconnecting,
    unauthenticated,
    default,
    addressed,
    configured,
    suspended,
    unknown,
};

const udc_state_map = std.StaticStringMap(UdcState).initComptime(.{
    .{ "not attached", .not_attached },
    .{ "attached", .attached },
    .{ "powered", .powered },
    .{ "reconnecting", .reconnecting },
    .{ "unauthenticated", .unauthenticated },
    .{ "default", .default },
    .{ "addressed", .addressed },
    .{ "configured", .configured },
    .{ "suspended", .suspended },
});

/// Read current UDC state from /sys/class/udc/<udc>/state
fn readUdcState() UdcState {
    if (g_udc_name_len == 0) return .unknown;

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/udc/{s}/state", .{g_udc_name[0..g_udc_name_len]}) catch return .unknown;

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return .unknown;
    defer file.close();

    var buf: [32]u8 = undefined;
    const len = file.read(&buf) catch return .unknown;
    if (len == 0) return .unknown;

    // Trim trailing newline
    const state_str = std.mem.trimRight(u8, buf[0..len], "\n\r ");
    return udc_state_map.get(state_str) orelse .unknown;
}

// ============================================================================
// HidDevice - Common HID device handling with lifecycle management
// ============================================================================

/// Common HID device structure with lifecycle management
/// Handles open/write/reconnect logic for both keyboard and mouse
pub const HidDevice = struct {
    file: ?std.fs.File = null,
    device_path: []const u8,
    disconnected: bool = false,
    blocked_until_ns: i128 = 0,
    last_error_ns: i128 = 0,

    const BACKOFF_MS: i128 = 100;
    const RECONNECT_INTERVAL_MS: i128 = 1000;

    pub fn init(device_path: []const u8) HidDevice {
        return .{ .device_path = device_path };
    }

    pub fn deinit(self: *HidDevice) void {
        self.close();
    }

    pub fn open(self: *HidDevice) !void {
        const fd = std.posix.open(self.device_path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0) catch |err| {
            log.err("Failed to open {s}: {}", .{ self.device_path, err });
            return err;
        };
        self.file = std.fs.File{ .handle = fd };
        self.disconnected = false;
    }

    pub fn close(self: *HidDevice) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
    }

    /// Write report to HID device with lifecycle handling
    /// Returns true if write succeeded, false otherwise
    pub fn write(self: *HidDevice, report: []const u8) bool {
        const now = std.time.nanoTimestamp();

        // Check backoff first
        if (now < self.blocked_until_ns) return false;

        // Check if USB is actually connected before attempting write
        // This prevents error spam when USB cable is not connected
        const state = readUdcState();
        if (state != .configured) {
            self.blocked_until_ns = now + RECONNECT_INTERVAL_MS * std.time.ns_per_ms;
            return false;
        }

        // If disconnected, try to reconnect
        if (self.disconnected) {
            if (!self.tryReconnect()) {
                self.blocked_until_ns = now + RECONNECT_INTERVAL_MS * std.time.ns_per_ms;
                return false;
            }
        }

        const file = self.file orelse return false;

        _ = file.write(report) catch |err| {
            self.handleWriteError(err, now);
            return false;
        };

        return true;
    }

    fn handleWriteError(self: *HidDevice, err: anyerror, now: i128) void {
        switch (err) {
            error.WouldBlock => {
                // Queue full, apply backoff but stay connected
                self.blocked_until_ns = now + BACKOFF_MS * std.time.ns_per_ms;
            },
            error.NotOpenForWriting, error.InputOutput, error.BrokenPipe => {
                // Transport error - device disconnected
                self.markDisconnected(now);
            },
            else => {
                // Unknown error, treat as disconnect
                if (now - self.last_error_ns >= RECONNECT_INTERVAL_MS * std.time.ns_per_ms) {
                    self.last_error_ns = now;
                    log.err("HID {s} write error: {}, marking disconnected", .{ self.device_path, err });
                }
                self.markDisconnected(now);
            },
        }
    }

    fn markDisconnected(self: *HidDevice, now: i128) void {
        self.close();
        self.disconnected = true;
        self.blocked_until_ns = now + RECONNECT_INTERVAL_MS * std.time.ns_per_ms;
    }

    fn tryReconnect(self: *HidDevice) bool {
        // Check UDC state first
        const state = readUdcState();
        if (state != .configured) {
            return false;
        }

        // Try to reopen the device
        self.open() catch return false;
        log.info("HID {s} reconnected", .{self.device_path});
        return true;
    }
};

// Boot Protocol Keyboard HID Report Descriptor (no Report ID for BIOS compatibility)
// Report format: [Modifiers, Reserved, Key1, Key2, Key3, Key4, Key5, Key6] = 8 bytes
const KEYBOARD_REPORT_DESC = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x06, // Usage (Keyboard)
    0xa1, 0x01, // Collection (Application)
    0x05, 0x07, //   Usage Page (Key Codes)
    0x19, 0xe0, //   Usage Minimum (224 - Left Control)
    0x29, 0xe7, //   Usage Maximum (231 - Right GUI)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x08, //   Report Count (8)
    0x81, 0x02, //   Input (Data, Variable, Absolute) - Modifier byte
    0x95, 0x01, //   Report Count (1)
    0x75, 0x08, //   Report Size (8)
    0x81, 0x03, //   Input (Constant) - Reserved byte
    0x95, 0x05, //   Report Count (5)
    0x75, 0x01, //   Report Size (1)
    0x05, 0x08, //   Usage Page (LEDs)
    0x19, 0x01, //   Usage Minimum (1)
    0x29, 0x05, //   Usage Maximum (5)
    0x91, 0x02, //   Output (Data, Variable, Absolute) - LED report
    0x95, 0x01, //   Report Count (1)
    0x75, 0x03, //   Report Size (3)
    0x91, 0x03, //   Output (Constant) - LED padding
    0x95, 0x06, //   Report Count (6)
    0x75, 0x08, //   Report Size (8)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x65, //   Logical Maximum (101)
    0x05, 0x07, //   Usage Page (Key Codes)
    0x19, 0x00, //   Usage Minimum (0)
    0x29, 0x65, //   Usage Maximum (101)
    0x81, 0x00, //   Input (Data, Array) - Key array (6 keys)
    0xc0, //       End Collection
};

// Absolute Mouse HID Report Descriptor (no Report ID)
// Report format: [Buttons, X_L, X_H, Y_L, Y_H, Wheel] = 6 bytes
const MOUSE_REPORT_DESC = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x02, // Usage (Mouse)
    0xa1, 0x01, // Collection (Application)
    0x09, 0x01, //   Usage (Pointer)
    0xa1, 0x00, //   Collection (Physical)
    0x05, 0x09, //     Usage Page (Button)
    0x19, 0x01, //     Usage Minimum (Button 1)
    0x29, 0x03, //     Usage Maximum (Button 3)
    0x15, 0x00, //     Logical Minimum (0)
    0x25, 0x01, //     Logical Maximum (1)
    0x95, 0x03, //     Report Count (3)
    0x75, 0x01, //     Report Size (1)
    0x81, 0x02, //     Input (Data, Variable, Absolute) - 3 buttons
    0x95, 0x01, //     Report Count (1)
    0x75, 0x05, //     Report Size (5)
    0x81, 0x03, //     Input (Constant) - 5 bit padding
    0x05, 0x01, //     Usage Page (Generic Desktop)
    0x09, 0x30, //     Usage (X)
    0x09, 0x31, //     Usage (Y)
    0x15, 0x00, //     Logical Minimum (0)
    0x26, 0xff, 0x7f, // Logical Maximum (32767)
    0x75, 0x10, //     Report Size (16)
    0x95, 0x02, //     Report Count (2)
    0x81, 0x02, //     Input (Data, Variable, Absolute) - X and Y absolute
    0x09, 0x38, //     Usage (Wheel)
    0x15, 0x81, //     Logical Minimum (-127)
    0x25, 0x7f, //     Logical Maximum (127)
    0x75, 0x08, //     Report Size (8)
    0x95, 0x01, //     Report Count (1)
    0x81, 0x06, //     Input (Data, Variable, Relative) - Wheel
    0xc0, //         End Collection
    0xc0, //       End Collection
};

// Modifier key bit flags (byte 0 of HID report)
pub const Modifiers = struct {
    pub const LEFT_CTRL: u8 = 0x01;
    pub const LEFT_SHIFT: u8 = 0x02;
    pub const LEFT_ALT: u8 = 0x04;
    pub const LEFT_GUI: u8 = 0x08;
    pub const RIGHT_CTRL: u8 = 0x10;
    pub const RIGHT_SHIFT: u8 = 0x20;
    pub const RIGHT_ALT: u8 = 0x40;
    pub const RIGHT_GUI: u8 = 0x80;
};

// HID keyboard state
pub const HidKeyboard = struct {
    device: HidDevice,
    // Current state: tracks which keys are pressed
    pressed_keys: [6]u8 = [_]u8{0} ** 6,
    modifier_state: u8 = 0,

    pub fn init() HidKeyboard {
        return .{ .device = HidDevice.init(HIDG_KEYBOARD) };
    }

    pub fn deinit(self: *HidKeyboard) void {
        self.device.deinit();
    }

    pub fn open(self: *HidKeyboard) !void {
        try self.device.open();
    }

    pub fn keyDown(self: *HidKeyboard, code: []const u8, modifiers: ModifierFlags) void {
        self.modifier_state = 0;
        if (modifiers.ctrl) self.modifier_state |= Modifiers.LEFT_CTRL;
        if (modifiers.shift) self.modifier_state |= Modifiers.LEFT_SHIFT;
        if (modifiers.alt) self.modifier_state |= Modifiers.LEFT_ALT;
        if (modifiers.meta) self.modifier_state |= Modifiers.LEFT_GUI;

        if (getModifierBit(code)) |mod_bit| {
            self.modifier_state |= mod_bit;
        } else if (getScancode(code)) |scancode| {
            for (&self.pressed_keys) |*slot| {
                if (slot.* == 0) {
                    slot.* = scancode;
                    break;
                } else if (slot.* == scancode) {
                    break;
                }
            }
        }

        self.sendReport();
    }

    pub fn keyUp(self: *HidKeyboard, code: []const u8, modifiers: ModifierFlags) void {
        self.modifier_state = 0;
        if (modifiers.ctrl) self.modifier_state |= Modifiers.LEFT_CTRL;
        if (modifiers.shift) self.modifier_state |= Modifiers.LEFT_SHIFT;
        if (modifiers.alt) self.modifier_state |= Modifiers.LEFT_ALT;
        if (modifiers.meta) self.modifier_state |= Modifiers.LEFT_GUI;

        if (getModifierBit(code)) |mod_bit| {
            self.modifier_state &= ~mod_bit;
        } else if (getScancode(code)) |scancode| {
            for (&self.pressed_keys) |*slot| {
                if (slot.* == scancode) {
                    slot.* = 0;
                    break;
                }
            }
        }

        self.sendReport();
    }

    fn sendReport(self: *HidKeyboard) void {
        var report: [8]u8 = [_]u8{0} ** 8;
        report[0] = self.modifier_state;
        report[1] = 0;
        @memcpy(report[2..8], &self.pressed_keys);
        _ = self.device.write(&report);
    }

    pub fn releaseAll(self: *HidKeyboard) void {
        self.pressed_keys = [_]u8{0} ** 6;
        self.modifier_state = 0;
        self.sendReport();
    }
};

/// Modifier flags from browser event
pub const ModifierFlags = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
};

// Mouse button bit flags
pub const MouseButtons = struct {
    pub const LEFT: u8 = 0x01;
    pub const RIGHT: u8 = 0x02;
    pub const MIDDLE: u8 = 0x04;
};

/// HID Mouse state for absolute positioning
pub const HidMouse = struct {
    device: HidDevice,
    button_state: u8 = 0,
    last_x: u16 = 0,
    last_y: u16 = 0,

    pub fn init() HidMouse {
        return .{ .device = HidDevice.init(HIDG_MOUSE) };
    }

    pub fn deinit(self: *HidMouse) void {
        self.device.deinit();
    }

    pub fn open(self: *HidMouse) !void {
        try self.device.open();
    }

    pub fn move(self: *HidMouse, x: u16, y: u16) void {
        self.last_x = x;
        self.last_y = y;
        self.sendReport();
    }

    pub fn click(self: *HidMouse, button: u8, pressed: bool) void {
        const bit: u8 = switch (button) {
            0 => MouseButtons.LEFT,
            1 => MouseButtons.MIDDLE,
            2 => MouseButtons.RIGHT,
            else => return,
        };

        if (pressed) {
            self.button_state |= bit;
        } else {
            self.button_state &= ~bit;
        }
        self.sendReport();
    }

    pub fn wheel(self: *HidMouse, delta: i8) void {
        self.sendWheelReport(delta);
    }

    fn sendReport(self: *HidMouse) void {
        var report: [6]u8 = undefined;
        report[0] = self.button_state;
        report[1] = @truncate(self.last_x & 0xFF);
        report[2] = @truncate((self.last_x >> 8) & 0xFF);
        report[3] = @truncate(self.last_y & 0xFF);
        report[4] = @truncate((self.last_y >> 8) & 0xFF);
        report[5] = 0;
        _ = self.device.write(&report);
    }

    fn sendWheelReport(self: *HidMouse, wheel_delta: i8) void {
        var report: [6]u8 = undefined;
        report[0] = self.button_state;
        report[1] = @truncate(self.last_x & 0xFF);
        report[2] = @truncate((self.last_x >> 8) & 0xFF);
        report[3] = @truncate(self.last_y & 0xFF);
        report[4] = @truncate((self.last_y >> 8) & 0xFF);
        report[5] = @bitCast(wheel_delta);
        _ = self.device.write(&report);
    }

    pub fn releaseAll(self: *HidMouse) void {
        self.button_state = 0;
        self.sendReport();
    }
};

/// Get modifier bit for modifier keys (ControlLeft, ShiftRight, etc.)
fn getModifierBit(code: []const u8) ?u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "ControlLeft", Modifiers.LEFT_CTRL },
        .{ "ControlRight", Modifiers.RIGHT_CTRL },
        .{ "ShiftLeft", Modifiers.LEFT_SHIFT },
        .{ "ShiftRight", Modifiers.RIGHT_SHIFT },
        .{ "AltLeft", Modifiers.LEFT_ALT },
        .{ "AltRight", Modifiers.RIGHT_ALT },
        .{ "MetaLeft", Modifiers.LEFT_GUI },
        .{ "MetaRight", Modifiers.RIGHT_GUI },
    });
    return map.get(code);
}

/// Get USB HID scancode for a KeyboardEvent.code value
fn getScancode(code: []const u8) ?u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        // Letters
        .{ "KeyA", 0x04 },
        .{ "KeyB", 0x05 },
        .{ "KeyC", 0x06 },
        .{ "KeyD", 0x07 },
        .{ "KeyE", 0x08 },
        .{ "KeyF", 0x09 },
        .{ "KeyG", 0x0a },
        .{ "KeyH", 0x0b },
        .{ "KeyI", 0x0c },
        .{ "KeyJ", 0x0d },
        .{ "KeyK", 0x0e },
        .{ "KeyL", 0x0f },
        .{ "KeyM", 0x10 },
        .{ "KeyN", 0x11 },
        .{ "KeyO", 0x12 },
        .{ "KeyP", 0x13 },
        .{ "KeyQ", 0x14 },
        .{ "KeyR", 0x15 },
        .{ "KeyS", 0x16 },
        .{ "KeyT", 0x17 },
        .{ "KeyU", 0x18 },
        .{ "KeyV", 0x19 },
        .{ "KeyW", 0x1a },
        .{ "KeyX", 0x1b },
        .{ "KeyY", 0x1c },
        .{ "KeyZ", 0x1d },

        // Numbers
        .{ "Digit1", 0x1e },
        .{ "Digit2", 0x1f },
        .{ "Digit3", 0x20 },
        .{ "Digit4", 0x21 },
        .{ "Digit5", 0x22 },
        .{ "Digit6", 0x23 },
        .{ "Digit7", 0x24 },
        .{ "Digit8", 0x25 },
        .{ "Digit9", 0x26 },
        .{ "Digit0", 0x27 },

        // Control keys
        .{ "Enter", 0x28 },
        .{ "Escape", 0x29 },
        .{ "Backspace", 0x2a },
        .{ "Tab", 0x2b },
        .{ "Space", 0x2c },

        // Symbols
        .{ "Minus", 0x2d },
        .{ "Equal", 0x2e },
        .{ "BracketLeft", 0x2f },
        .{ "BracketRight", 0x30 },
        .{ "Backslash", 0x31 },
        .{ "Semicolon", 0x33 },
        .{ "Quote", 0x34 },
        .{ "Backquote", 0x35 },
        .{ "Comma", 0x36 },
        .{ "Period", 0x37 },
        .{ "Slash", 0x38 },

        // Function keys
        .{ "CapsLock", 0x39 },
        .{ "F1", 0x3a },
        .{ "F2", 0x3b },
        .{ "F3", 0x3c },
        .{ "F4", 0x3d },
        .{ "F5", 0x3e },
        .{ "F6", 0x3f },
        .{ "F7", 0x40 },
        .{ "F8", 0x41 },
        .{ "F9", 0x42 },
        .{ "F10", 0x43 },
        .{ "F11", 0x44 },
        .{ "F12", 0x45 },

        // Navigation
        .{ "PrintScreen", 0x46 },
        .{ "ScrollLock", 0x47 },
        .{ "Pause", 0x48 },
        .{ "Insert", 0x49 },
        .{ "Home", 0x4a },
        .{ "PageUp", 0x4b },
        .{ "Delete", 0x4c },
        .{ "End", 0x4d },
        .{ "PageDown", 0x4e },
        .{ "ArrowRight", 0x4f },
        .{ "ArrowLeft", 0x50 },
        .{ "ArrowDown", 0x51 },
        .{ "ArrowUp", 0x52 },

        // Numpad
        .{ "NumLock", 0x53 },
        .{ "NumpadDivide", 0x54 },
        .{ "NumpadMultiply", 0x55 },
        .{ "NumpadSubtract", 0x56 },
        .{ "NumpadAdd", 0x57 },
        .{ "NumpadEnter", 0x58 },
        .{ "Numpad1", 0x59 },
        .{ "Numpad2", 0x5a },
        .{ "Numpad3", 0x5b },
        .{ "Numpad4", 0x5c },
        .{ "Numpad5", 0x5d },
        .{ "Numpad6", 0x5e },
        .{ "Numpad7", 0x5f },
        .{ "Numpad8", 0x60 },
        .{ "Numpad9", 0x61 },
        .{ "Numpad0", 0x62 },
        .{ "NumpadDecimal", 0x63 },

        // Additional keys
        .{ "IntlBackslash", 0x64 },
        .{ "ContextMenu", 0x65 },
    });
    return map.get(code);
}

// ============================================================================
// ConfigFS Gadget Setup
// ============================================================================

pub const SetupError = error{
    CreateDirFailed,
    WriteFailed,
    SymlinkFailed,
    NoUdcFound,
    GadgetAlreadyExists,
};

/// Setup USB HID Gadget through ConfigFS
/// Requires root privileges
pub fn setupGadget() !void {
    log.info("Setting up USB HID Gadget (keyboard + mouse)...", .{});

    // Check if gadget already exists
    std.fs.accessAbsolute(GADGET_PATH, .{}) catch {
        // Gadget doesn't exist, create it
        try createGadget();
        return;
    };

    // Gadget exists, check if both hidg devices exist
    std.fs.accessAbsolute(HIDG_KEYBOARD, .{}) catch {
        log.info("Gadget directory exists but {s} not found", .{HIDG_KEYBOARD});
        log.info("Trying to activate gadget...", .{});
        try activateGadget();
        return;
    };
    std.fs.accessAbsolute(HIDG_MOUSE, .{}) catch {
        log.info("Gadget directory exists but {s} not found", .{HIDG_MOUSE});
        log.info("Trying to activate gadget...", .{});
        try activateGadget();
        return;
    };

    log.info("USB HID Gadget already configured, reusing existing setup", .{});
}

fn createGadget() !void {
    // Create gadget directory
    std.fs.makeDirAbsolute(GADGET_PATH) catch |err| {
        log.err("Failed to create gadget directory: {}", .{err});
        return SetupError.CreateDirFailed;
    };

    // Write USB descriptor values
    try writeFile(GADGET_PATH ++ "/idVendor", "0x1d6b"); // Linux Foundation
    try writeFile(GADGET_PATH ++ "/idProduct", "0x0104"); // Multifunction Composite Gadget
    try writeFile(GADGET_PATH ++ "/bcdDevice", "0x0100"); // v1.0.0
    try writeFile(GADGET_PATH ++ "/bcdUSB", "0x0200"); // USB 2.0

    // Create strings directory (English - 0x409)
    const strings_path = GADGET_PATH ++ "/strings/0x409";
    try makeDirRecursive(strings_path);
    try writeFile(strings_path ++ "/serialnumber", "mykvm001");
    try writeFile(strings_path ++ "/manufacturer", "MYKVM");
    try writeFile(strings_path ++ "/product", "MYKVM USB HID");

    // Create configuration
    const config_path = GADGET_PATH ++ "/configs/c.1";
    const config_strings_path = config_path ++ "/strings/0x409";
    try makeDirRecursive(config_strings_path);
    try writeFile(config_strings_path ++ "/configuration", "Config 1: HID Keyboard+Mouse");
    try writeFile(config_path ++ "/MaxPower", "250");

    // ============ Create Keyboard HID function (hid.usb0) ============
    // Boot Protocol keyboard for BIOS compatibility
    const kbd_path = GADGET_PATH ++ "/functions/hid.usb0";
    try makeDirRecursive(kbd_path);
    try writeFile(kbd_path ++ "/protocol", "1"); // 1 = Keyboard
    try writeFile(kbd_path ++ "/subclass", "1"); // 1 = Boot Interface Subclass
    try writeFile(kbd_path ++ "/report_length", "8"); // Boot keyboard report size
    try writeFileBytes(kbd_path ++ "/report_desc", &KEYBOARD_REPORT_DESC);

    // Create symlink for keyboard
    std.posix.symlink(kbd_path, config_path ++ "/hid.usb0") catch |err| {
        log.err("Failed to create keyboard symlink: {}", .{err});
        return SetupError.SymlinkFailed;
    };

    // ============ Create Mouse HID function (hid.usb1) ============
    const mouse_path = GADGET_PATH ++ "/functions/hid.usb1";
    try makeDirRecursive(mouse_path);
    try writeFile(mouse_path ++ "/protocol", "2"); // 2 = Mouse
    try writeFile(mouse_path ++ "/subclass", "1"); // 1 = Boot Interface Subclass
    try writeFile(mouse_path ++ "/report_length", "6"); // Our absolute mouse report size
    try writeFileBytes(mouse_path ++ "/report_desc", &MOUSE_REPORT_DESC);

    // Create symlink for mouse
    std.posix.symlink(mouse_path, config_path ++ "/hid.usb1") catch |err| {
        log.err("Failed to create mouse symlink: {}", .{err});
        return SetupError.SymlinkFailed;
    };

    // Activate gadget
    try activateGadget();

    log.info("USB HID Gadget setup complete! (keyboard={s}, mouse={s})", .{ HIDG_KEYBOARD, HIDG_MOUSE });
}

fn activateGadget() !void {
    // Find UDC (USB Device Controller)
    var udc_dir = std.fs.openDirAbsolute("/sys/class/udc", .{ .iterate = true }) catch |err| {
        log.err("Failed to open /sys/class/udc: {}", .{err});
        return SetupError.NoUdcFound;
    };
    defer udc_dir.close();

    var iter = udc_dir.iterate();
    const udc_name = while (try iter.next()) |entry| {
        if (entry.kind == .directory or entry.kind == .sym_link) {
            break entry.name;
        }
    } else {
        log.err("No UDC found in /sys/class/udc", .{});
        return SetupError.NoUdcFound;
    };

    // Save UDC name for later state queries
    if (udc_name.len <= g_udc_name.len) {
        @memcpy(g_udc_name[0..udc_name.len], udc_name);
        g_udc_name_len = udc_name.len;
    }

    // Write UDC name to activate gadget
    try writeFile(GADGET_PATH ++ "/UDC", udc_name);
    log.info("Activated gadget with UDC: {s}", .{udc_name});
}

/// Cleanup/remove the USB gadget
pub fn cleanupGadget() void {
    log.info("Cleaning up USB HID Gadget...", .{});

    // 1. Disable the gadget (write empty string to UDC)
    writeFile(GADGET_PATH ++ "/UDC", "") catch {};

    // 2. Remove functions from configurations (symlinks)
    std.fs.deleteFileAbsolute(GADGET_PATH ++ "/configs/c.1/hid.usb0") catch {};
    std.fs.deleteFileAbsolute(GADGET_PATH ++ "/configs/c.1/hid.usb1") catch {};

    // 3. Remove strings directories in configurations
    std.fs.deleteDirAbsolute(GADGET_PATH ++ "/configs/c.1/strings/0x409") catch {};

    // 4. Remove the configurations
    std.fs.deleteDirAbsolute(GADGET_PATH ++ "/configs/c.1") catch {};

    // 5. Remove functions
    std.fs.deleteDirAbsolute(GADGET_PATH ++ "/functions/hid.usb0") catch {};
    std.fs.deleteDirAbsolute(GADGET_PATH ++ "/functions/hid.usb1") catch {};

    // 6. Remove strings directories in the gadget
    std.fs.deleteDirAbsolute(GADGET_PATH ++ "/strings/0x409") catch {};

    // 7. Remove the gadget
    std.fs.deleteDirAbsolute(GADGET_PATH) catch {};

    log.info("USB HID Gadget cleaned up", .{});
}

// Helper functions

fn writeFile(path: []const u8, content: []const u8) !void {
    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| {
        log.err("Failed to open {s} for writing: {}", .{ path, err });
        return SetupError.WriteFailed;
    };
    defer file.close();
    _ = file.write(content) catch |err| {
        log.err("Failed to write to {s}: {}", .{ path, err });
        return SetupError.WriteFailed;
    };
}

fn writeFileBytes(path: []const u8, content: []const u8) !void {
    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| {
        log.err("Failed to open {s} for writing: {}", .{ path, err });
        return SetupError.WriteFailed;
    };
    defer file.close();
    _ = file.write(content) catch |err| {
        log.err("Failed to write to {s}: {}", .{ path, err });
        return SetupError.WriteFailed;
    };
}

fn makeDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        // Try creating parent directories
        if (std.mem.lastIndexOf(u8, path, "/")) |last_sep| {
            try makeDirRecursive(path[0..last_sep]);
            std.fs.makeDirAbsolute(path) catch |e| {
                if (e != error.PathAlreadyExists) {
                    log.err("Failed to create directory {s}: {}", .{ path, e });
                    return SetupError.CreateDirFailed;
                }
            };
        } else {
            log.err("Failed to create directory {s}: {}", .{ path, err });
            return SetupError.CreateDirFailed;
        }
    };
}
