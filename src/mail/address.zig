//! Addresses as people type them, "Ada <ada@x.org>, bob@y.com", parsed
//! into JMAP's; and lists of them written back as one line.
const std = @import("std");
const Address = @import("../jmap/types.zig").Address;

/// Splits on commas and semicolons outside quotes and angle brackets.
/// Entries without an @ are an error (`error.BadAddress`, with `bad`
/// set to the entry).
pub fn parseList(arena: std.mem.Allocator, s: []const u8, bad: ?*[]const u8) ![]Address {
    var out: std.ArrayList(Address) = .empty;
    var start: usize = 0;
    var quoted = false;
    var angle = false;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        const ch: u8 = if (i < s.len) s[i] else ',';
        switch (ch) {
            '"' => quoted = !quoted,
            '<' => if (!quoted) {
                angle = true;
            },
            '>' => if (!quoted) {
                angle = false;
            },
            ',', ';' => if (!quoted and !angle) {
                const part = std.mem.trim(u8, s[start..i], " \t\r\n");
                start = i + 1;
                if (part.len == 0) continue;
                const a = parseOne(part) orelse {
                    if (bad) |b| b.* = part;
                    return error.BadAddress;
                };
                try out.append(arena, a);
            },
            else => {},
        }
    }
    // An open quote or bracket swallowed the rest: not to be dropped.
    if (quoted or angle) {
        if (bad) |b| b.* = std.mem.trim(u8, s[@min(start, s.len)..], " \t\r\n");
        return error.BadAddress;
    }
    return out.toOwnedSlice(arena);
}

/// As `parseList`, but what isn't an address is kept as written (for a
/// draft, which may be half done).
pub fn parseLenient(arena: std.mem.Allocator, s: []const u8) ![]Address {
    var out: std.ArrayList(Address) = .empty;
    var rest = s;
    while (rest.len > 0) {
        var bad: []const u8 = "";
        const got = parseList(arena, rest, &bad) catch {
            // Keep the good ones before it, the bad one as is, and go on.
            const at = std.mem.indexOf(u8, rest, bad) orelse break;
            const before = try parseList(arena, rest[0..at], null);
            try out.appendSlice(arena, before);
            try out.append(arena, .{ .email = bad });
            rest = rest[at + bad.len ..];
            continue;
        };
        try out.appendSlice(arena, got);
        break;
    }
    return out.toOwnedSlice(arena);
}

/// "Name <a@b>", "<a@b>", "a@b" or "a@b (Name)".
pub fn parseOne(part: []const u8) ?Address {
    if (std.mem.lastIndexOfScalar(u8, part, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, part, lt, '>') orelse return null;
        const email = std.mem.trim(u8, part[lt + 1 .. gt], " ");
        if (!valid(email)) return null;
        const name = std.mem.trim(u8, part[0..lt], " \t\"");
        return .{ .name = if (name.len > 0) name else null, .email = email };
    }
    if (std.mem.indexOfScalar(u8, part, '(')) |p| {
        const email = std.mem.trim(u8, part[0..p], " ");
        if (!valid(email)) return null;
        const name = std.mem.trim(u8, part[p + 1 ..], " )");
        return .{ .name = if (name.len > 0) name else null, .email = email };
    }
    if (!valid(part)) return null;
    return .{ .email = part };
}

fn valid(email: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at == 0 or at == email.len - 1) return false;
    for (email) |ch| if (ch == ' ' or ch == ',' or ch == '<' or ch == '>') return false;
    return true;
}

/// "Ada <ada@x.org>, bob@y.com": names with commas or quotes quoted.
pub fn format(arena: std.mem.Allocator, list: []const Address) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (list, 0..) |a, i| {
        if (i > 0) try w.writeAll(", ");
        const name = if (a.name) |n| std.mem.trim(u8, n, " ") else "";
        if (name.len == 0) {
            try w.writeAll(a.email);
        } else if (std.mem.indexOfAny(u8, name, ",;\"<>@") != null) {
            try w.writeByte('"');
            for (name) |ch| if (ch != '"') try w.writeByte(ch);
            try w.print("\" <{s}>", .{a.email});
        } else try w.print("{s} <{s}>", .{ name, a.email });
    }
    return aw.written();
}

/// Names only, "Ada, bob@y.com", as the reader's header shows them.
pub fn names(arena: std.mem.Allocator, list: []const Address) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (list, 0..) |a, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        try aw.writer.writeAll(a.display());
    }
    return aw.written();
}

/// Whether `email` is one of `mine`, ignoring case.
pub fn isMine(email: []const u8, mine: []const []const u8) bool {
    for (mine) |m| if (std.ascii.eqlIgnoreCase(m, email)) return true;
    return false;
}

test "parse lists" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try parseList(a, "Ada Lovelace <ada@x.org>, bob@y.com; \"Doe, Jane\" <jane@z.net>, carl@w.io (Carl)", null);
    try std.testing.expectEqual(@as(usize, 4), l.len);
    try std.testing.expectEqualStrings("Ada Lovelace", l[0].name.?);
    try std.testing.expectEqualStrings("ada@x.org", l[0].email);
    try std.testing.expectEqualStrings("bob@y.com", l[1].email);
    try std.testing.expect(l[1].name == null);
    try std.testing.expectEqualStrings("Doe, Jane", l[2].name.?);
    try std.testing.expectEqualStrings("Carl", l[3].name.?);
    try std.testing.expectEqual(@as(usize, 0), (try parseList(a, " , ", null)).len);
    var bad: []const u8 = "";
    try std.testing.expectError(error.BadAddress, parseList(a, "ok@x.com, nope", &bad));
    try std.testing.expectEqualStrings("nope", bad);
    try std.testing.expectError(error.BadAddress, parseList(a, "\"Bob <bob@x>, carol@y", &bad));
    try std.testing.expectError(error.BadAddress, parseList(a, "ok@x.com, Ann <ann@x", &bad));
    try std.testing.expectEqualStrings("Ann <ann@x", bad);
}

test "lenient lists keep what isn't an address" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const l = try parseLenient(arena.allocator(), "ok@x.com, bob (half typed, carl@y.org");
    try std.testing.expectEqual(@as(usize, 3), l.len);
    try std.testing.expectEqualStrings("ok@x.com", l[0].email);
    try std.testing.expectEqualStrings("bob (half typed", l[1].email);
    try std.testing.expectEqualStrings("carl@y.org", l[2].email);
}

test "format round trips" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try format(a, &.{ .{ .name = "Doe, Jane", .email = "jane@z.net" }, .{ .email = "bob@y.com" }, .{ .name = "Ada", .email = "ada@x.org" } });
    try std.testing.expectEqualStrings("\"Doe, Jane\" <jane@z.net>, bob@y.com, Ada <ada@x.org>", s);
    const back = try parseList(a, s, null);
    try std.testing.expectEqualStrings("Doe, Jane", back[0].name.?);
    try std.testing.expectEqualStrings("Ada, bob@y.com", try names(a, &.{ .{ .name = "Ada", .email = "a@x" }, .{ .email = "bob@y.com" } }));
}
