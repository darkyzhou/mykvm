//! E-Paper Display Driver for EPD 2in13 V4
//!
//! IMPORTANT WARNINGS:
//!
//! 1. PARTIAL REFRESH LIMITATION
//!    This screen supports partial refresh, but you CANNOT use partial refresh
//!    continuously. After several partial refreshes, you MUST perform a full
//!    refresh to clear the screen. Otherwise, display artifacts will occur.
//!
//! 2. POWER MANAGEMENT (CRITICAL)
//!    The screen MUST NOT remain powered on for extended periods. When not
//!    refreshing, always put the screen into sleep mode or power it off.
//!    Prolonged high voltage will PERMANENTLY DAMAGE the display film and
//!    cannot be repaired.
//!
//! 3. REFRESH INTERVAL
//!    Recommended minimum refresh interval is 180 seconds. The screen should
//!    be refreshed at least once every 24 hours. For long-term storage,
//!    clear the screen to white before storing. (Refer to datasheet for
//!    specific storage requirements)
//!
//! 4. SLEEP MODE BEHAVIOR
//!    After entering sleep mode, the screen will ignore any image data sent
//!    to it. You must re-initialize the display before refreshing again.

const std = @import("std");

const c = @cImport({
    @cDefine("RPI", "1");
    @cDefine("USE_DEV_LIB", "1");
    @cInclude("DEV_Config.h");
    @cInclude("EPD_2in13_V4.h");
    @cInclude("GUI_Paint.h");
});

const EPD_WIDTH = c.EPD_2in13_V4_WIDTH;
const EPD_HEIGHT = c.EPD_2in13_V4_HEIGHT;

// Font dimensions
const FONT_WIDTH = 11; // Font16 width
const FONT_HEIGHT = 16; // Font16 height
const LINE_SPACING = 4;
const LINE_HEIGHT = FONT_HEIGHT + LINE_SPACING;
const MARGIN_X = 4;
const MARGIN_Y = 4;

// Line Y positions (no empty line to fit 5 status lines)
const LINE_0_Y = MARGIN_Y; // "MyKVM v0.1"
const LINE_1_Y = MARGIN_Y + LINE_HEIGHT; // "Setting up EDID..."
const LINE_2_Y = MARGIN_Y + LINE_HEIGHT * 2; // "Setting up HDMI..."
const LINE_3_Y = MARGIN_Y + LINE_HEIGHT * 3; // "Setting up HID..."
const LINE_4_Y = MARGIN_Y + LINE_HEIGHT * 4; // "Setting up server..."

pub const Display = struct {
    image_buffer: []u8,
    alloc: std.mem.Allocator,
    partial_refresh_count: u8,
    enabled: bool,

    const Self = @This();

    /// Initialize the e-paper display and show initial boot screen
    /// If disabled is true, creates a no-op display that accepts all operations silently
    pub fn init(alloc: std.mem.Allocator, disabled: bool) !Self {
        if (disabled) {
            return Self{
                .image_buffer = &.{},
                .alloc = alloc,
                .partial_refresh_count = 0,
                .enabled = false,
            };
        }

        // Initialize device module
        if (c.DEV_Module_Init() != 0) {
            return error.DeviceInitFailed;
        }

        // Initialize EPD
        c.EPD_2in13_V4_Init();

        // Clear the display
        c.EPD_2in13_V4_Clear();

        // Calculate image buffer size
        const width_bytes: usize = if (EPD_WIDTH % 8 == 0) EPD_WIDTH / 8 else EPD_WIDTH / 8 + 1;
        const image_size: usize = width_bytes * EPD_HEIGHT;

        // Allocate image buffer
        const image_buffer = try alloc.alloc(u8, image_size);

        // Create new image (rotate 270 degrees for landscape mode, origin at top-left)
        c.Paint_NewImage(image_buffer.ptr, EPD_WIDTH, EPD_HEIGHT, 270, c.WHITE);
        c.Paint_SelectImage(image_buffer.ptr);
        c.Paint_Clear(c.WHITE);

        // Draw initial content - all status lines at once to minimize partial refreshes
        c.Paint_DrawString_EN(MARGIN_X, LINE_0_Y, "MyKVM v0.1", &c.Font16, c.BLACK, c.WHITE);
        c.Paint_DrawString_EN(MARGIN_X, LINE_1_Y, "Setting up EDID...", &c.Font16, c.WHITE, c.BLACK);
        c.Paint_DrawString_EN(MARGIN_X, LINE_2_Y, "Setting up HDMI...", &c.Font16, c.WHITE, c.BLACK);
        c.Paint_DrawString_EN(MARGIN_X, LINE_3_Y, "Setting up HID...", &c.Font16, c.WHITE, c.BLACK);
        c.Paint_DrawString_EN(MARGIN_X, LINE_4_Y, "Setting up server...", &c.Font16, c.WHITE, c.BLACK);

        // Display base image (full refresh) - required before partial refresh
        c.EPD_2in13_V4_Display_Base(image_buffer.ptr);

        return Self{
            .image_buffer = image_buffer,
            .alloc = alloc,
            .partial_refresh_count = 0,
            .enabled = true,
        };
    }

    /// Update EDID status line with OK or ERR (partial refresh)
    pub fn updateEdidStatus(self: *Self, success: bool) void {
        if (!self.enabled) return;
        const status = if (success) "OK" else "ERR";
        // "Setting up EDID..." is 18 chars, add status after it
        const x_pos = MARGIN_X + FONT_WIDTH * 18;
        c.Paint_DrawString_EN(x_pos, LINE_1_Y, status, &c.Font16, c.WHITE, c.BLACK);
        self.partialRefresh();
    }

    /// Update HDMI status line with OK or ERR (partial refresh)
    pub fn updateHdmiStatus(self: *Self, success: bool) void {
        if (!self.enabled) return;
        const status = if (success) "OK" else "ERR";
        // "Setting up HDMI..." is 18 chars
        const x_pos = MARGIN_X + FONT_WIDTH * 18;
        c.Paint_DrawString_EN(x_pos, LINE_2_Y, status, &c.Font16, c.WHITE, c.BLACK);
        self.partialRefresh();
    }

    /// Update HID status line with OK or ERR (partial refresh)
    pub fn updateHidStatus(self: *Self, success: bool) void {
        if (!self.enabled) return;
        const status = if (success) "OK" else "ERR";
        // "Setting up HID..." is 17 chars
        const x_pos = MARGIN_X + FONT_WIDTH * 17;
        c.Paint_DrawString_EN(x_pos, LINE_3_Y, status, &c.Font16, c.WHITE, c.BLACK);
        self.partialRefresh();
    }

    /// Show final status screen with IP and port (full refresh)
    pub fn showStatus(self: *Self, ip: []const u8, port: u16) void {
        if (!self.enabled) return;

        // Re-initialize display (might be in sleep mode)
        c.EPD_2in13_V4_Init();

        // Clear and redraw
        c.Paint_Clear(c.WHITE);

        // Draw title
        c.Paint_DrawString_EN(MARGIN_X, LINE_0_Y, "MyKVM v0.1", &c.Font16, c.BLACK, c.WHITE);

        // Format and draw IP:port
        var buf: [64]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&buf, "{s}:{d}", .{ ip, port }) catch "???";
        // Null-terminate for C function
        buf[addr_str.len] = 0;
        c.Paint_DrawString_EN(MARGIN_X, LINE_1_Y, &buf, &c.Font16, c.WHITE, c.BLACK);

        // Full refresh
        c.EPD_2in13_V4_Display_Base(self.image_buffer.ptr);
    }

    /// Perform partial refresh
    fn partialRefresh(self: *Self) void {
        c.EPD_2in13_V4_Display_Partial(self.image_buffer.ptr);
        self.partial_refresh_count += 1;
    }

    /// Put display to sleep (MUST be called when not refreshing)
    pub fn sleep(self: *Self) void {
        if (!self.enabled) return;
        c.EPD_2in13_V4_Sleep();
    }

    /// Hardware shutdown - clear display and release hardware (no memory free)
    /// Use this for signal handlers where we're about to exit anyway
    pub fn shutdown(self: *Self) void {
        if (!self.enabled) return;
        // Re-initialize since display might be in sleep mode
        c.EPD_2in13_V4_Init();
        c.EPD_2in13_V4_Clear();
        c.EPD_2in13_V4_Sleep();
        // Important: wait at least 2s before DEV_Module_Exit
        c.DEV_Delay_ms(2000);
        c.DEV_Module_Exit();
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (!self.enabled) return;
        self.shutdown();
        self.alloc.free(self.image_buffer);
    }
};
