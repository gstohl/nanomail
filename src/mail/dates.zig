//! Dates: JMAP's RFC 3339 strings to Unix time, and Unix time to what a
//! mail list shows (a time today, "Yesterday", a weekday this week, else
//! a date), in the local time zone (libc's localtime_r).
const std = @import("std");
const builtin = @import("builtin");

/// Seconds since 1970 from "2024-05-01T12:34:56Z" or "…+02:00"
/// (fractions of a second ignored); null when it isn't one.
pub fn parse(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const num = struct {
        fn f(t: []const u8) ?i64 {
            return std.fmt.parseInt(i64, t, 10) catch null;
        }
    }.f;
    const y = num(s[0..4]) orelse return null;
    const mo = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    const h = num(s[11..13]) orelse return null;
    const mi = num(s[14..16]) orelse return null;
    const se = num(s[17..19]) orelse return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    var offset: i64 = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        if (s.len < i + 6) return null;
        const oh = num(s[i + 1 .. i + 3]) orelse return null;
        const om = num(s[i + 4 .. i + 6]) orelse return null;
        offset = (oh * 60 + om) * 60;
        if (s[i] == '-') offset = -offset;
    }
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset;
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's).
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// A broken-down local time.
pub const Local = struct {
    year: i32,
    month: u8, // 1-12
    day: u8,
    hour: u8,
    minute: u8,
    weekday: u8, // 0 = Sunday
    /// Days since 1970 in local time, to compare days.
    day_number: i64,
};

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

/// `t` in the local time zone; UTC where libc can't say, and in tests
/// when `utc` is set, so they don't depend on the machine's zone.
pub fn local(t: i64, utc: bool) Local {
    var offset: i64 = 0;
    if (!utc and comptime builtin.os.tag != .windows) {
        var tm: Tm = undefined;
        if (localtime_r(&t, &tm) != null) offset = tm.tm_gmtoff;
    }
    const lt = t + offset;
    const days = @divFloor(lt, 86400);
    const secs = lt - days * 86400;
    // Civil from days (Hinnant).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{
        .year = @intCast(y),
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(secs, 3600)),
        .minute = @intCast(@divFloor(@mod(secs, 3600), 60)),
        .weekday = @intCast(@mod(days + 4, 7)),
        .day_number = days,
    };
}

pub const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
pub const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// As a mail list shows `t` at `now`: "14:05", "Yesterday", "Tuesday",
/// "Mar 4", or "Mar 4, 2023" in another year.
pub fn short(buf: []u8, t: i64, now: i64, utc: bool) []const u8 {
    const a = local(t, utc);
    const b = local(now, utc);
    const ago = b.day_number - a.day_number;
    if (ago == 0) return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ a.hour, a.minute }) catch "";
    if (ago == 1) return "Yesterday";
    if (ago > 1 and ago < 7) return weekday_names[a.weekday];
    if (a.year == b.year) return std.fmt.bufPrint(buf, "{s} {d}", .{ month_names[a.month - 1], a.day }) catch "";
    return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ month_names[a.month - 1], a.day, a.year }) catch "";
}

/// "Tuesday, Mar 4, 2025 at 14:05", for the reader and quoted replies.
pub fn long(buf: []u8, t: i64, utc: bool) []const u8 {
    const a = local(t, utc);
    return std.fmt.bufPrint(buf, "{s}, {s} {d}, {d} at {d:0>2}:{d:0>2}", .{ weekday_names[a.weekday], month_names[a.month - 1], a.day, a.year, a.hour, a.minute }) catch "";
}

/// RFC 3339 in UTC, for JMAP: "2025-03-04T14:05:00Z".
pub fn rfc3339(buf: []u8, t: i64) []const u8 {
    const a = local(t, true);
    const sec: u8 = @intCast(@mod(t, 60));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u32, @intCast(a.year)), a.month, a.day, a.hour, a.minute, sec }) catch "";
}

test "parse" {
    try std.testing.expectEqual(@as(?i64, 0), parse("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1714566896), parse("2024-05-01T12:34:56Z"));
    try std.testing.expectEqual(@as(?i64, 1714566896), parse("2024-05-01T14:34:56+02:00"));
    try std.testing.expectEqual(@as(?i64, 1714566896), parse("2024-05-01T12:34:56.789Z"));
    try std.testing.expectEqual(@as(?i64, null), parse("yesterday"));
}

test "short dates" {
    var buf: [32]u8 = undefined;
    const now = parse("2025-03-06T15:00:00Z").?; // a Thursday
    try std.testing.expectEqualStrings("09:07", short(&buf, parse("2025-03-06T09:07:00Z").?, now, true));
    try std.testing.expectEqualStrings("Yesterday", short(&buf, parse("2025-03-05T23:59:00Z").?, now, true));
    try std.testing.expectEqualStrings("Monday", short(&buf, parse("2025-03-03T08:00:00Z").?, now, true));
    try std.testing.expectEqualStrings("Feb 12", short(&buf, parse("2025-02-12T08:00:00Z").?, now, true));
    try std.testing.expectEqualStrings("Dec 31, 2024", short(&buf, parse("2024-12-31T08:00:00Z").?, now, true));
}

test "long dates and back to RFC 3339" {
    var buf: [64]u8 = undefined;
    const t = parse("2025-03-04T14:05:09Z").?;
    try std.testing.expectEqualStrings("Tuesday, Mar 4, 2025 at 14:05", long(&buf, t, true));
    try std.testing.expectEqualStrings("2025-03-04T14:05:09Z", rfc3339(&buf, t));
}
