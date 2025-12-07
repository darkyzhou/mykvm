const std = @import("std");
const log = std.log.scoped(.args);

pub const Config = struct {
    port: u16,
    listen: []const u8,
    device: []const u8,
    encoder: []const u8,
    bitrate: u32,
    no_epaper: bool,
    tls_cert_path: []const u8,
    tls_key_path: []const u8,

    pub fn deinit(self: *const Config, alloc: std.mem.Allocator) void {
        alloc.free(self.tls_cert_path);
        alloc.free(self.tls_key_path);
    }
};

pub fn parse(alloc: std.mem.Allocator, args: []const []const u8) !Config {
    var port: u16 = 8443;
    var listen: []const u8 = "0.0.0.0";
    var device: []const u8 = "/dev/video0";
    var encoder: []const u8 = "/dev/video11";
    var bitrate: u32 = 1_000_000;
    var no_epaper: bool = false;
    var tls_cert_path: ?[]const u8 = null;
    var tls_key_path: ?[]const u8 = null;

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) {
                log.err("Error: {s} requires a port number argument", .{arg});
                return error.MissingArgument;
            }
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--listen") or std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i >= args.len) {
                log.err("Error: {s} requires an address argument", .{arg});
                return error.MissingArgument;
            }
            listen = args[i];
        } else if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) {
                log.err("Error: {s} requires a device path argument", .{arg});
                return error.MissingArgument;
            }
            device = args[i];
        } else if (std.mem.eql(u8, arg, "--encoder") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) {
                log.err("Error: {s} requires an encoder device path argument", .{arg});
                return error.MissingArgument;
            }
            encoder = args[i];
        } else if (std.mem.eql(u8, arg, "--bitrate") or std.mem.eql(u8, arg, "-r")) {
            i += 1;
            if (i >= args.len) {
                log.err("Error: {s} requires a bitrate argument", .{arg});
                return error.MissingArgument;
            }
            bitrate = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--cert") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                log.err("Error: {s} requires a certificate path argument", .{arg});
                return error.MissingArgument;
            }
            tls_cert_path = try std.fs.cwd().realpathAlloc(alloc, args[i]);
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "-k")) {
            i += 1;
            if (i >= args.len) {
                log.err("Error: {s} requires a key path argument", .{arg});
                return error.MissingArgument;
            }
            tls_key_path = try std.fs.cwd().realpathAlloc(alloc, args[i]);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--no-epaper")) {
            no_epaper = true;
        } else {
            log.err("Unknown argument: {s}", .{arg});
            printUsage();
            return error.UnknownArgument;
        }
    }

    if (tls_cert_path == null or tls_key_path == null) {
        log.err("Error: --cert and --key are required", .{});
        printUsage();
        return error.MissingArgument;
    }

    return Config{
        .port = port,
        .listen = listen,
        .device = device,
        .encoder = encoder,
        .bitrate = bitrate,
        .no_epaper = no_epaper,
        .tls_cert_path = tls_cert_path.?,
        .tls_key_path = tls_key_path.?,
    };
}

pub fn printUsage() void {
    log.info(
        \\Usage: mykvm --cert <path> --key <path> [options]
        \\
        \\Required:
        \\  -c, --cert <path>         TLS certificate path
        \\  -k, --key <path>          TLS private key path
        \\
        \\Options:
        \\  -p, --port <port>         HTTPS server port (default: 8443)
        \\  -l, --listen <address>    Listen address (default: 0.0.0.0)
        \\  -d, --device <path>       Capture device path (default: /dev/video0)
        \\  -e, --encoder <path>      Encoder device path (default: /dev/video11)
        \\  -r, --bitrate <bps>       Encoder bitrate (default: 1000000)
        \\  --no-epaper               Disable e-Paper display
        \\  -h, --help                Show help information
        \\
        \\Examples:
        \\  mykvm --cert cert.pem --key key.pem
        \\  mykvm --cert cert.pem --key key.pem --port 443
        \\  mykvm --cert cert.pem --key key.pem --listen 0.0.0.0
    , .{});
}
