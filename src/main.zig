const std = @import("std");
const builtin = @import("builtin");
const key4 = @import("key4.zig");
const login_decrypt = @import("login_decrypt.zig");

var debug_enabled: bool = false;

// Channels exist only so `--channel` can express intent; automatic discovery is
// deliberately name-agnostic (see `isEligible`), so there is no table of "known"
// suffixes to fall out of date as Mozilla adds channels.
const Channel = enum {
    release,
    beta,
    nightly,
    dev,
    esr,

    fn profileSuffix(self: Channel) []const u8 {
        return switch (self) {
            .release => "default-release",
            .beta => "default-beta",
            .nightly => "default-nightly",
            .dev => "dev-edition-default",
            .esr => "default-esr",
        };
    }

    fn fromString(s: []const u8) ?Channel {
        // Enum field names are the canonical channel strings — keep them in sync.
        return std.meta.stringToEnum(Channel, s);
    }
};

const max_profiles = 16;
const max_profile_name = 128;

/// One candidate profile directory, reduced to the facts selection needs.
/// Splitting these facts out of the directory walk is what makes the "which
/// profile wins" policy unit-testable without touching a filesystem.
const ProfileCandidate = struct {
    name: []const u8,
    has_logins: bool,
    has_key4: bool,
    mtime_ns: i128,
};

/// True when a candidate should be considered at all.
///
/// With an explicit `--channel`, stated intent wins outright: the suffix
/// decides even if that profile turns out to be unusable, so the caller can
/// report exactly what it is missing rather than silently using a different
/// one. Without a channel, eligibility is by CAPABILITY rather than by name —
/// ffpw needs both files, and any directory holding them is a real profile
/// whatever its channel or naming scheme.
fn isEligible(c: ProfileCandidate, channel: ?Channel) bool {
    if (channel) |ch| return std.mem.endsWith(u8, c.name, ch.profileSuffix());
    return c.has_logins and c.has_key4;
}

/// Choose which profile directory to use, returning an index into `candidates`.
/// Pure: every filesystem fact arrives via `candidates`.
///
/// Ties go to the most recently modified profile — the one actually being
/// browsed with. Selecting on directory-name suffixes instead is what made
/// ffpw lock onto a stale `…default-nightly` that no longer had a logins.json
/// while Firefox Beta held the real passwords.
fn pickProfile(candidates: []const ProfileCandidate, channel: ?Channel) ?usize {
    var best: ?usize = null;
    for (candidates, 0..) |c, i| {
        if (!isEligible(c, channel)) continue;
        if (best) |b| {
            if (c.mtime_ns > candidates[b].mtime_ns) best = i;
        } else best = i;
    }
    return best;
}

/// How many candidates qualify. Used only to disclose on stderr when ffpw had
/// to choose among several password stores on the user's behalf.
fn countEligible(candidates: []const ProfileCandidate, channel: ?Channel) usize {
    var n: usize = 0;
    for (candidates) |c| {
        if (isEligible(c, channel)) n += 1;
    }
    return n;
}

const max_filters = 16;

const Cli = struct {
    filters: [max_filters][]const u8 = undefined,
    filter_count: usize = 0,
    profile: ?[]const u8 = null,
    channel: ?Channel = null,
    show_help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    run(io, allocator, init.environ_map, args) catch |err| {
        reportError(io, err) catch {};
        std.process.exit(1);
    };
}

fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    if (env.get("FFPW_DEBUG")) |dbg| {
        if (dbg.len > 0) debug_enabled = true;
    }

    var cli = try parseArgs(allocator, args);
    defer cliDeinit(allocator, &cli);

    if (cli.show_help) {
        try printUsage(io);
        return;
    }

    if (cli.filter_count == 0) {
        try printUsage(io);
        return error.MissingFilter;
    }

    // Resolve channel from env var if not set on CLI.
    if (cli.channel == null) {
        if (env.get("FFPW_CHANNEL")) |env_ch| {
            cli.channel = Channel.fromString(env_ch);
        }
    }

    const profile_path = try resolveProfilePath(io, allocator, env, cli.profile, cli.channel);
    defer allocator.free(profile_path);
    debugPrint("Using profile: {s}\n", .{profile_path});

    try ensureProfileFiles(io, profile_path);

    // Open key4.db and extract the master key (verifies master password).
    const key_store = try key4.KeyStore.open(allocator, profile_path, "");
    debugPrint("Master key extracted successfully\n", .{});

    try printMatches(io, allocator, profile_path, cli.filters[0..cli.filter_count], key_store.master_key);
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Cli {
    var cli = Cli{};
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
            if (i >= args.len) return error.MissingFilter;
            if (cli.filter_count >= max_filters) return error.TooManyFilters;
            cli.filters[cli.filter_count] = try allocator.dupe(u8, args[i]);
            cli.filter_count += 1;
        } else if (std.mem.eql(u8, arg, "--channel")) {
            i += 1;
            if (i >= args.len) return error.MissingChannel;
            cli.channel = Channel.fromString(args[i]) orelse return error.InvalidChannel;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArg;
        } else {
            if (cli.filter_count >= max_filters) return error.TooManyFilters;
            cli.filters[cli.filter_count] = try allocator.dupe(u8, args[i]);
            cli.filter_count += 1;
        }
    }

    return cli;
}

fn cliDeinit(allocator: std.mem.Allocator, cli: *Cli) void {
    for (cli.filters[0..cli.filter_count]) |f| {
        allocator.free(f);
    }
    if (cli.profile) |profile| {
        allocator.free(profile);
    }
}

fn printUsage(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.writeAll(
        "Usage: ffpw <filter> [<filter> ...] [--channel <ch>] [--profile <path>]\n" ++
        "\n" ++
        "Filters are substring-matched against hostname and username (AND'd).\n" ++
        "\n" ++
        "Options:\n" ++
        "  --host <filter>          Alias for a positional filter\n" ++
        "  --channel <ch>           Firefox channel: release, beta, nightly, dev, esr\n" ++
        "  --profile <path>         Firefox profile directory (overrides --channel)\n" ++
        "  -h, --help               Show this help\n" ++
        "\n" ++
        "Environment:\n" ++
        "  FFPW_CHANNEL             Default channel (e.g. nightly, release)\n" ++
        "\n" ++
        "Examples:\n" ++
        "  ffpw google              All logins with 'google' in hostname or username\n" ++
        "  ffpw google admin        Logins matching both 'google' AND 'admin'\n" ++
        "  ffpw github --channel nightly\n",
    );
    try out.interface.flush();
}

fn resolveProfilePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    override: ?[]const u8,
    channel: ?Channel,
) ![]u8 {
    if (override) |path| {
        return allocator.dupe(u8, path);
    }

    const home = env.get("HOME") orelse return error.MissingHome;

    const base = switch (builtin.os.tag) {
        .macos => "Library/Application Support/Firefox/Profiles",
        .linux => ".mozilla/firefox",
        else => return error.UnsupportedOs,
    };

    const base_path = try std.fs.path.join(allocator, &.{ home, base });
    defer allocator.free(base_path);

    var dir = std.Io.Dir.openDirAbsolute(io, base_path, .{ .iterate = true }) catch
        return error.ProfileNotFound;
    defer dir.close(io);

    // Gather every subdirectory as a candidate, then let the pure `pickProfile`
    // policy decide. `entry.name` is only valid until the next iteration, so
    // names are copied into a fixed backing store.
    var name_store: [max_profiles][max_profile_name]u8 = undefined;
    var candidates: [max_profiles]ProfileCandidate = undefined;
    var count: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (count == max_profiles) break;
        if (entry.kind != .directory) continue;
        if (entry.name.len > max_profile_name) continue;

        @memcpy(name_store[count][0..entry.name.len], entry.name);
        const name = name_store[count][0..entry.name.len];

        // Nothing here degrades an error into a value. A profile we cannot open
        // or stat is REPORTED and skipped, never admitted with a placeholder
        // mtime: substituting 0 would make it merely look ancient — identical
        // to a genuinely old profile — which is precisely how a stale profile
        // silently outranked the live one and left no trace to debug.
        var sub = dir.openDir(io, name, .{}) catch |err| {
            try warnSkippedProfile(io, name, @errorName(err));
            continue;
        };
        defer sub.close(io);

        const st = sub.stat(io) catch |err| {
            try warnSkippedProfile(io, name, @errorName(err));
            continue;
        };

        candidates[count] = .{
            .name = name,
            .has_logins = try fileExistsIn(io, sub, "logins.json"),
            .has_key4 = try fileExistsIn(io, sub, "key4.db"),
            .mtime_ns = st.mtime.nanoseconds,
        };
        count += 1;
    }

    const winner = pickProfile(candidates[0..count], channel) orelse return error.ProfileNotFound;

    // Picking among several password stores on the user's behalf is worth
    // disclosing; it goes to stderr so stdout stays pipeable.
    const eligible = countEligible(candidates[0..count], channel);
    if (eligible > 1) {
        var buffer: [1024]u8 = undefined;
        var err_writer = std.Io.File.stderr().writer(io, &buffer);
        try err_writer.interface.print(
            "Note: {d} usable Firefox profiles found; using the most recently updated ({s}). Override with --profile or --channel.\n",
            .{ eligible, candidates[winner].name },
        );
        try err_writer.interface.flush();
    }

    return std.fs.path.join(allocator, &.{ base_path, candidates[winner].name });
}

/// Existence check that keeps "absent" and "broken" distinct. FileNotFound is a
/// legitimate answer — the profile simply lacks the file — but any other error
/// (permissions, I/O) is a real failure and propagates rather than quietly
/// reading as "absent", which would silently disqualify a usable profile.
fn fileExistsIn(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !bool {
    _ = dir.statFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// A profile directory we cannot inspect is announced, never silently dropped —
/// a skipped candidate that leaves no trace is indistinguishable from one that
/// was never there.
fn warnSkippedProfile(io: std.Io, name: []const u8, reason: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &buffer);
    try err_writer.interface.print(
        "Warning: skipping profile '{s}': {s}\n",
        .{ name, reason },
    );
    try err_writer.interface.flush();
}

fn ensureProfileFiles(io: std.Io, profile_path: []const u8) !void {
    const logins = try std.fs.path.join(std.heap.page_allocator, &.{ profile_path, "logins.json" });
    defer std.heap.page_allocator.free(logins);

    const key4_path = try std.fs.path.join(std.heap.page_allocator, &.{ profile_path, "key4.db" });
    defer std.heap.page_allocator.free(key4_path);

    if (!fileExists(io, logins)) return error.MissingLogins;
    if (!fileExists(io, key4_path)) return error.MissingKey4;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn printMatches(
    io: std.Io,
    allocator: std.mem.Allocator,
    profile_path: []const u8,
    filters: []const []const u8,
    master_key: [32]u8,
) !void {
    const logins_path = try std.fs.path.join(allocator, &.{ profile_path, "logins.json" });
    defer allocator.free(logins_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, logins_path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    var matched: usize = 0;
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

        // Decrypt username (needed for filter matching).
        const username = login_decrypt.decryptLoginField(allocator, encrypted_username, master_key) catch |err| {
            debugPrint("Decrypt username failed for {s}: {s}\n", .{ hostname, @errorName(err) });
            decrypt_failures += 1;
            continue;
        };
        defer allocator.free(username);

        if (!entryMatches(hostname, username, filters)) continue;
        matched += 1;

        const password = login_decrypt.decryptLoginField(allocator, encrypted_password, master_key) catch |err| {
            debugPrint("Decrypt password failed for {s}: {s}\n", .{ hostname, @errorName(err) });
            decrypt_failures += 1;
            continue;
        };
        defer allocator.free(password);

        try out.interface.print("{s}\n\tusername: {s}\n\tpassword: {s}\n\n", .{ hostname, username, password });
    }

    if (matched == 0) {
        try out.interface.writeAll("No matching logins found.\n");
    }
    debugPrint("Matched: {d}, decrypt failures: {d}\n", .{ matched, decrypt_failures });
    try out.interface.flush();
}

/// Returns true if every filter term appears as a substring in either hostname or username.
fn entryMatches(hostname: []const u8, username: []const u8, filters: []const []const u8) bool {
    for (filters) |needle| {
        const in_host = std.mem.indexOf(u8, hostname, needle) != null;
        const in_user = std.mem.indexOf(u8, username, needle) != null;
        if (!in_host and !in_user) return false;
    }
    return true;
}

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    std.debug.print(fmt, args);
}

fn reportError(io: std.Io, err: anyerror) !void {
    var buffer: [4096]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &buffer);
    switch (err) {
        error.MissingFilter => try err_writer.interface.writeAll("No search filter provided. See --help.\n"),
        error.TooManyFilters => try err_writer.interface.writeAll("Too many filter terms.\n"),
        error.MissingProfilePath => try err_writer.interface.writeAll("Missing path after --profile.\n"),
        error.UnknownArg => try err_writer.interface.writeAll("Unknown argument. Use --help for usage.\n"),
        error.MissingLogins => try err_writer.interface.writeAll("Missing logins.json in profile directory.\n"),
        error.MissingLoginsArray => try err_writer.interface.writeAll("logins.json missing logins array.\n"),
        error.InvalidLoginsJson => try err_writer.interface.writeAll("logins.json is not a JSON object.\n"),
        error.InvalidLoginsArray => try err_writer.interface.writeAll("logins.json logins is not an array.\n"),
        error.MissingKey4 => try err_writer.interface.writeAll("Missing key4.db in profile directory.\n"),
        error.MissingField => try err_writer.interface.writeAll("logins.json missing expected fields.\n"),
        error.ProfileNotFound => try err_writer.interface.writeAll("No Firefox profile found. Use --profile <path>.\n"),
        error.MissingChannel => try err_writer.interface.writeAll("Missing value after --channel.\n"),
        error.InvalidChannel => try err_writer.interface.writeAll("Invalid channel. Use: release, beta, nightly, dev, esr.\n"),
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

// Force the test runner to also run tests from imported modules. Every source
// file MUST be listed here — `addTest` only includes tests from files explicitly
// referenced this way, so an omission silently drops that file's whole suite.
comptime {
    _ = @import("crypto.zig");
    _ = @import("der.zig");
    _ = @import("key4.zig");
    _ = @import("login_decrypt.zig");
}

// ── Profile-selection tests ──────────────────────────────────────────────
//
// Regression guard for the 2026-07-27 report: `ffpw amazon.com` died with
// "Missing logins.json in profile directory." on a box whose live profile was
// Firefox Beta. Selection matched directory-name SUFFIXES in a fixed order
// (release, nightly, dev, esr, then legacy "default"), so it locked onto a
// stale `…default-nightly` — which still had a key4.db but no logins.json —
// and never considered the profile actually in use.
//
// These pin the policy as a classifier over SETS of candidates, not a single
// happy example: a name-based selector passes any one-profile case, so only
// competing candidates can tell a correct policy from a broken one.

const testing = std.testing;

fn cand(name: []const u8, has_logins: bool, has_key4: bool, mtime_ns: i128) ProfileCandidate {
    return .{ .name = name, .has_logins = has_logins, .has_key4 = has_key4, .mtime_ns = mtime_ns };
}

test "pickProfile skips a profile that lacks logins.json, even if it is newer" {
    // Peter's box, with the recency signal deliberately inverted so this pins
    // capability-beats-recency rather than accidentally passing on mtime.
    const candidates = [_]ProfileCandidate{
        cand("rbbm52p1.default-nightly", false, true, 900),
        cand("b5y7l11v.default", true, true, 100),
    };
    try testing.expectEqual(@as(?usize, 1), pickProfile(&candidates, null));
}

test "pickProfile picks the most recently used among several usable profiles" {
    const candidates = [_]ProfileCandidate{
        cand("a.default", true, true, 100),
        cand("b.default-release", true, true, 900),
        cand("c.default-nightly", true, true, 500),
    };
    try testing.expectEqual(@as(?usize, 1), pickProfile(&candidates, null));
}

test "pickProfile is channel-agnostic: unrecognized profile names still qualify" {
    // Beta, a custom `-P` profile, a Flatpak/Snap dir: none end in a suffix the
    // old matcher knew, so all of them were invisible to auto-detection.
    const candidates = [_]ProfileCandidate{
        cand("xyz.default-beta", true, true, 400),
        cand("work-profile", true, true, 800),
    };
    try testing.expectEqual(@as(?usize, 1), pickProfile(&candidates, null));
}

test "pickProfile requires BOTH logins.json and key4.db" {
    const candidates = [_]ProfileCandidate{
        cand("a.default", true, false, 100),
        cand("b.default-nightly", false, true, 200),
    };
    try testing.expectEqual(@as(?usize, null), pickProfile(&candidates, null));
}

test "pickProfile honors an explicit --channel over recency and capability" {
    const candidates = [_]ProfileCandidate{
        cand("a.default", true, true, 900),
        cand("b.default-nightly", false, true, 100),
    };
    // Stated intent wins: the user asked for nightly, so report precisely why
    // nightly is unusable rather than silently decrypting a different profile.
    try testing.expectEqual(@as(?usize, 1), pickProfile(&candidates, .nightly));
}

test "Channel.fromString accepts every advertised channel and rejects junk" {
    for ([_][]const u8{ "release", "beta", "nightly", "dev", "esr" }) |name| {
        try testing.expect(Channel.fromString(name) != null);
    }
    try testing.expect(Channel.fromString("bogus") == null);
}
