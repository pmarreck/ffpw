const std = @import("std");
const builtin = @import("builtin");
const key4 = @import("key4.zig");
const login_decrypt = @import("login_decrypt.zig");

var debug_enabled: bool = false;

const Cli = struct {
    host: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    show_help: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    run(allocator) catch |err| {
        try reportError(err);
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator) !void {
    debug_enabled = std.process.hasNonEmptyEnvVar(allocator, "FFPW_DEBUG") catch false;

    var cli = try parseArgs(allocator);
    defer cliDeinit(allocator, &cli);

    if (cli.show_help) {
        try printUsage();
        return;
    }

    if (cli.host == null) {
        try printUsage();
        return error.MissingHost;
    }

    const profile_path = try resolveProfilePath(allocator, cli.profile);
    defer allocator.free(profile_path);
    debugPrint("Using profile: {s}\n", .{profile_path});

    try ensureProfileFiles(profile_path);

    // Open key4.db and extract the master key (verifies master password).
    const key_store = try key4.KeyStore.open(allocator, profile_path, "");
    debugPrint("Master key extracted successfully\n", .{});

    try printMatches(allocator, profile_path, cli.host.?, key_store.master_key);
}

fn parseArgs(allocator: std.mem.Allocator) !Cli {
    var cli = Cli{};
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cli.show_help = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingProfilePath;
            cli.profile = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            cli.host = try allocator.dupe(u8, args[i]);
        } else {
            return error.UnknownArg;
        }
    }

    return cli;
}

fn cliDeinit(allocator: std.mem.Allocator, cli: *Cli) void {
    if (cli.host) |host| {
        allocator.free(host);
    }
    if (cli.profile) |profile| {
        allocator.free(profile);
    }
}

fn printUsage() !void {
    var buffer: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buffer);
    try out.interface.writeAll(
        "Usage: ffpw --host <hostname> [--profile <path>]\n" ++
        "\n" ++
        "Options:\n" ++
        "  --host <hostname>   Substring match for login hostname\n" ++
        "  --profile <path>    Firefox profile directory (defaults to Nightly)\n" ++
        "  -h, --help          Show this help\n",
    );
    try out.interface.flush();
}

fn resolveProfilePath(allocator: std.mem.Allocator, override: ?[]const u8) ![]u8 {
    if (override) |path| {
        return allocator.dupe(u8, path);
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.MissingHome;
    defer allocator.free(home);

    const base = switch (builtin.os.tag) {
        .macos => "Library/Application Support/Firefox/Profiles",
        .linux => ".mozilla/firefox",
        else => return error.UnsupportedOs,
    };

    const base_path = try std.fs.path.join(allocator, &.{ home, base });
    defer allocator.free(base_path);

    var dir = try std.fs.openDirAbsolute(base_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.indexOf(u8, entry.name, "default-nightly") == null) continue;
        return std.fs.path.join(allocator, &.{ base_path, entry.name });
    }

    return error.NightlyProfileNotFound;
}

fn ensureProfileFiles(profile_path: []const u8) !void {
    const logins = try std.fs.path.join(std.heap.page_allocator, &.{ profile_path, "logins.json" });
    defer std.heap.page_allocator.free(logins);

    const key4_path = try std.fs.path.join(std.heap.page_allocator, &.{ profile_path, "key4.db" });
    defer std.heap.page_allocator.free(key4_path);

    if (!fileExists(logins)) return error.MissingLogins;
    if (!fileExists(key4_path)) return error.MissingKey4;
}

fn fileExists(path: []const u8) bool {
    _ = std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn printMatches(
    allocator: std.mem.Allocator,
    profile_path: []const u8,
    host: []const u8,
    master_key: [32]u8,
) !void {
    const logins_path = try std.fs.path.join(allocator, &.{ profile_path, "logins.json" });
    defer allocator.free(logins_path);

    var file = try std.fs.openFileAbsolute(logins_path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    var buffer: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buffer);
    var matched: usize = 0;
    var decrypted: usize = 0;
    var decrypt_failures: usize = 0;

    const root = parsed.value;
    const logins_value = switch (root) {
        .object => |obj| obj.get("logins") orelse return error.MissingLoginsArray,
        else => return error.InvalidLoginsJson,
    };

    const logins_array = switch (logins_value) {
        .array => |arr| arr.items,
        else => return error.InvalidLoginsArray,
    };

    debugPrint("Logins entries: {d}\n", .{logins_array.len});

    for (logins_array) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };

        const hostname_value = obj.get("hostname") orelse continue;
        const hostname = switch (hostname_value) {
            .string => |value| value,
            else => continue,
        };

        const username_value = obj.get("encryptedUsername") orelse continue;
        const encrypted_username = switch (username_value) {
            .string => |value| value,
            else => continue,
        };

        const password_value = obj.get("encryptedPassword") orelse continue;
        const encrypted_password = switch (password_value) {
            .string => |value| value,
            else => continue,
        };

        if (!hostnameMatches(hostname, host)) continue;
        matched += 1;
        const username = login_decrypt.decryptLoginField(allocator, encrypted_username, master_key) catch |err| {
            decrypt_failures += 1;
            debugPrint("Decrypt username failed for {s}: {s}\n", .{ hostname, @errorName(err) });
            continue;
        };
        defer allocator.free(username);
        const password = login_decrypt.decryptLoginField(allocator, encrypted_password, master_key) catch |err| {
            decrypt_failures += 1;
            debugPrint("Decrypt password failed for {s}: {s}\n", .{ hostname, @errorName(err) });
            continue;
        };
        defer allocator.free(password);

        decrypted += 1;
        try out.interface.print("{s}\n\tusername: {s}\n\tpassword: {s}\n\n", .{ hostname, username, password });
    }

    if (matched == 0) {
        try out.interface.print("No matches for host substring: {s}\n", .{host});
    } else if (decrypted == 0 and decrypt_failures > 0) {
        return error.DecryptFailed;
    }
    debugPrint("Matched: {d}, decrypted: {d}, failures: {d}\n", .{ matched, decrypted, decrypt_failures });
    try out.interface.flush();
}

fn hostnameMatches(hostname: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hostname, needle) != null;
}

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    std.debug.print(fmt, args);
}

fn reportError(err: anyerror) !void {
    var buffer: [4096]u8 = undefined;
    var err_writer = std.fs.File.stderr().writer(&buffer);
    switch (err) {
        error.MissingHost => try err_writer.interface.writeAll("Missing required --host argument.\n"),
        error.MissingProfilePath => try err_writer.interface.writeAll("Missing path after --profile.\n"),
        error.UnknownArg => try err_writer.interface.writeAll("Unknown argument. Use --help for usage.\n"),
        error.MissingLogins => try err_writer.interface.writeAll("Missing logins.json in profile directory.\n"),
        error.MissingLoginsArray => try err_writer.interface.writeAll("logins.json missing logins array.\n"),
        error.InvalidLoginsJson => try err_writer.interface.writeAll("logins.json is not a JSON object.\n"),
        error.InvalidLoginsArray => try err_writer.interface.writeAll("logins.json logins is not an array.\n"),
        error.MissingKey4 => try err_writer.interface.writeAll("Missing key4.db in profile directory.\n"),
        error.MissingField => try err_writer.interface.writeAll("logins.json missing expected fields.\n"),
        error.NightlyProfileNotFound => try err_writer.interface.writeAll("Nightly profile not found. Use --profile.\n"),
        error.MissingHome => try err_writer.interface.writeAll("HOME is not set.\n"),
        error.UnsupportedOs => try err_writer.interface.writeAll("Unsupported OS for automatic profile discovery.\n"),
        error.Key4OpenFailed => try err_writer.interface.writeAll("Failed to open key4.db.\n"),
        error.MissingPasswordEntry => try err_writer.interface.writeAll("key4.db missing password entry in metadata.\n"),
        error.WrongMasterPassword => try err_writer.interface.writeAll("Master password verification failed.\n"),
        error.MissingPrivateKey => try err_writer.interface.writeAll("key4.db missing private key entry.\n"),
        error.InvalidMasterKey => try err_writer.interface.writeAll("Failed to extract master key from key4.db.\n"),
        error.DecryptFailed => try err_writer.interface.writeAll("Failed to decrypt login entry.\n"),
        else => try err_writer.interface.print("Unexpected error: {s}\n", .{@errorName(err)}),
    }
    try err_writer.interface.flush();
}

// Force the test runner to also run tests from imported modules.
comptime {
    _ = @import("crypto.zig");
    _ = @import("der.zig");
}
