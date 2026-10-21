//! Web and mail addresses in plain text, to click: http(s)://…, www.…,
//! mailto:…, cut where the text around them takes over (a closing
//! bracket, a full stop).
const std = @import("std");
const Link = @import("html.zig").Link;

/// Adds the addresses in `text` not inside `links` already.
pub fn detect(arena: std.mem.Allocator, text: []const u8, links: *std.ArrayList(Link)) !void {
    const known = links.items.len;
    var i: usize = 0;
    while (i < text.len) {
        const rest = text[i..];
        const prefix: ?[]const u8 = for ([_][]const u8{ "https://", "http://", "mailto:", "www." }) |p| {
            if (std.ascii.startsWithIgnoreCase(rest, p)) break p;
        } else null;
        // Only at a word's start ("xhttp://" isn't one).
        if (prefix == null or (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '@' or text[i - 1] == '/'))) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '<' and text[end] != '>' and text[end] != '"' and text[end] != '`') end += 1;
        end = trimEnd(text[i..end]) + i;
        if (end - i <= prefix.?.len) {
            i += 1;
            continue;
        }
        const covered = for (links.items[0..known]) |l| {
            if (i < l.end and end > l.start) break true;
        } else false;
        if (!covered) {
            const raw = text[i..end];
            const url = if (std.ascii.eqlIgnoreCase(prefix.?, "www.")) try std.mem.concat(arena, u8, &.{ "https://", raw }) else raw;
            try links.append(arena, .{ .start = @intCast(i), .end = @intCast(end), .url = url });
        }
        i = end;
    }
}

/// The length of `s` without the punctuation that ends a sentence around
/// it, nor a closing bracket it didn't open.
fn trimEnd(s: []const u8) usize {
    var n = s.len;
    while (n > 0) {
        const ch = s[n - 1];
        if (std.mem.indexOfScalar(u8, ".,;:!?'*", ch) != null) {
            n -= 1;
        } else if (ch == ')' or ch == ']') {
            const open: u8 = if (ch == ')') '(' else '[';
            if (std.mem.count(u8, s[0..n], &.{open}) >= std.mem.count(u8, s[0..n], &.{ch})) break;
            n -= 1;
        } else break;
    }
    return n;
}

test "addresses in text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "See https://x.test/a_(b) and (www.y.test/z). Mail mailto:ada@x.test, not xhttp://no.";
    var links: std.ArrayList(Link) = .empty;
    try detect(a, text, &links);
    try std.testing.expectEqual(@as(usize, 3), links.items.len);
    try std.testing.expectEqualStrings("https://x.test/a_(b)", text[links.items[0].start..links.items[0].end]);
    try std.testing.expectEqualStrings("www.y.test/z", text[links.items[1].start..links.items[1].end]);
    try std.testing.expectEqualStrings("https://www.y.test/z", links.items[1].url);
    try std.testing.expectEqualStrings("mailto:ada@x.test", links.items[2].url);
    // Already a link (from the HTML): not twice.
    var l2: std.ArrayList(Link) = .empty;
    try l2.append(a, .{ .start = 4, .end = 24, .url = "https://elsewhere.test" });
    try detect(a, text, &l2);
    try std.testing.expectEqual(@as(usize, 3), l2.items.len);
    try std.testing.expectEqualStrings("https://elsewhere.test", l2.items[0].url);
}
