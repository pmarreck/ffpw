const std = @import("std");
const table = @import("table");

const maximum_timestamp_ms: i64 = 253_402_300_799_999;
const maximum_table_width: usize = 10_000;
const column_count: usize = 5;
const headers: [column_count][]const u8 = .{ "Site", "Username", "Password", "Set", "Last Used" };

pub const Login = struct {
    hostname: []const u8,
    username: []const u8,
    password: []const u8,
    time_password_changed_ms: ?i64,
    time_last_used_ms: ?i64,
};

pub const RenderOptions = struct {
    terminal_width: usize,
    color: bool,
    ascii: bool,
};

fn formatTimestamp(allocator: std.mem.Allocator, timestamp_ms: ?i64) ![]u8 {
    const milliseconds = normalizeFirefoxTimestamp(timestamp_ms) orelse return allocator.dupe(u8, "unknown");

    const epoch_seconds = std.time.epoch.EpochSeconds{
        .secs = @intCast(@divTrunc(milliseconds, std.time.ms_per_s)),
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            @as(u10, @intCast(@mod(milliseconds, std.time.ms_per_s))),
        },
    );
}

pub fn normalizeFirefoxTimestamp(timestamp_ms: ?i64) ?i64 {
    const milliseconds = timestamp_ms orelse return null;
    return if (milliseconds > 0 and milliseconds <= maximum_timestamp_ms) milliseconds else null;
}

pub fn renderLogins(
    allocator: std.mem.Allocator,
    options: RenderOptions,
    logins: []const Login,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const rows = try scratch.alloc(table.Row, logins.len + 1);
    rows[0] = &headers;

    for (logins, rows[1..]) |login, *row| {
        const cells = try scratch.alloc([]const u8, column_count);
        cells[0] = login.hostname;
        cells[1] = login.username;
        cells[2] = login.password;
        cells[3] = try formatTimestamp(scratch, login.time_password_changed_ms);
        cells[4] = try formatTimestamp(scratch, login.time_last_used_ms);
        row.* = cells;
    }

    const content_width = try requiredWidth(rows);
    if (content_width > maximum_table_width) return error.TableTooWide;
    const terminal_width = @min(maximum_table_width, @max(options.terminal_width, content_width));
    return table.renderTable(allocator, .{
        .terminal = terminal_width,
        .color = if (options.color) .always else .never,
        .ascii = options.ascii,
    }, rows);
}

fn requiredWidth(rows: []const table.Row) !usize {
    var widths = [_]usize{0} ** column_count;
    for (rows) |row| {
        for (row, 0..) |cell, index| widths[index] = @max(widths[index], cell.len);
    }
    var total = 3 * column_count + 1;
    for (widths) |width| total = std.math.add(usize, total, width) catch return error.TableTooWide;
    return total;
}

test "Firefox millisecond timestamps render as deterministic UTC" {
    const allocator = std.testing.allocator;
    const rendered = try formatTimestamp(allocator, 1_704_067_200_123);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("2024-01-01 00:00:00.123Z", rendered);
}

test "missing and invalid Firefox timestamps render as unknown" {
    const allocator = std.testing.allocator;
    for ([_]?i64{ null, -1, 0, 253_402_300_800_000 }) |value| {
        const rendered = try formatTimestamp(allocator, value);
        defer allocator.free(rendered);
        try std.testing.expectEqualStrings("unknown", rendered);
    }
}

test "credential table preserves a password wider than the terminal" {
    const allocator = std.testing.allocator;
    var password: [200]u8 = undefined;
    @memset(&password, 'p');
    const rendered = try renderLogins(allocator, .{
        .terminal_width = 80,
        .color = false,
        .ascii = false,
    }, &.{.{
        .hostname = "https://example.com",
        .username = "someone@example.com",
        .password = &password,
        .time_password_changed_ms = 1_704_067_200_123,
        .time_last_used_ms = 1_735_689_599_999,
    }});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, &password) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2024-01-01 00:00:00.123Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2024-12-31 23:59:59.999Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "…") == null);
}

test "approved credential table layout is stable below its lossless content width" {
    const allocator = std.testing.allocator;
    const logins = [_]Login{
        .{
            .hostname = "https://example.com",
            .username = "alice",
            .password = "correct horse battery staple",
            .time_password_changed_ms = 1_704_067_200_123,
            .time_last_used_ms = 1_735_689_599_999,
        },
        .{
            .hostname = "https://mail.test",
            .username = "bob@example.com",
            .password = "s3cret",
            .time_password_changed_ms = null,
            .time_last_used_ms = 1_704_067_200_123,
        },
    };
    const expected =
        \\┌─────────────────────┬─────────────────┬──────────────────────────────┬──────────────────────────┬──────────────────────────┐
        \\│ Site                │ Username        │ Password                     │ Set                      │ Last Used                │
        \\├─────────────────────┼─────────────────┼──────────────────────────────┼──────────────────────────┼──────────────────────────┤
        \\│ https://example.com │ alice           │ correct horse battery staple │ 2024-01-01 00:00:00.123Z │ 2024-12-31 23:59:59.999Z │
        \\│ https://mail.test   │ bob@example.com │ s3cret                       │ unknown                  │ 2024-01-01 00:00:00.123Z │
        \\└─────────────────────┴─────────────────┴──────────────────────────────┴──────────────────────────┴──────────────────────────┘
        \\
    ;

    for ([_]usize{ 40, 80 }) |terminal_width| {
        const rendered = try renderLogins(allocator, .{
            .terminal_width = terminal_width,
            .color = false,
            .ascii = false,
        }, &logins);
        defer allocator.free(rendered);
        try std.testing.expectEqualStrings(expected, rendered);
    }

    const colored = try renderLogins(allocator, .{
        .terminal_width = 80,
        .color = true,
        .ascii = false,
    }, &logins);
    defer allocator.free(colored);
    try std.testing.expectEqual(@as(usize, column_count), std.mem.count(u8, colored, "\x1b[1;36m"));
    try std.testing.expectEqual(@as(usize, column_count), std.mem.count(u8, colored, "\x1b[0m"));
    try std.testing.expect(std.mem.indexOf(u8, colored, "correct horse battery staple") != null);
}

test "credential table sanitizes terminal controls and renders unknown timestamps" {
    const allocator = std.testing.allocator;
    const rendered = try renderLogins(allocator, .{
        .terminal_width = 40,
        .color = false,
        .ascii = true,
    }, &.{.{
        .hostname = "https://example.com",
        .username = "alice",
        .password = "safe\x1b[31m\x07",
        .time_password_changed_ms = null,
        .time_last_used_ms = 0,
    }});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "safe�[31m�") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "unknown"));
    try std.testing.expect(std.mem.startsWith(u8, rendered, "+"));
}

test "credential table refuses content above its lossless width limit" {
    const allocator = std.testing.allocator;
    var password: [maximum_table_width]u8 = undefined;
    @memset(&password, 'p');
    try std.testing.expectError(error.TableTooWide, renderLogins(allocator, .{
        .terminal_width = 80,
        .color = false,
        .ascii = false,
    }, &.{.{
        .hostname = "h",
        .username = "u",
        .password = &password,
        .time_password_changed_ms = null,
        .time_last_used_ms = null,
    }}));
}
