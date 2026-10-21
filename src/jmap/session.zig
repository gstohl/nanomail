//! Finding the server (RFC 8620 §2.2: `/.well-known/jmap`) and reading
//! the session it describes: the API's URL, the account, what it can do.
const std = @import("std");
const types = @import("types.zig");

/// An account with mail: the user's own, or one shared with them (another
/// person's mailboxes, a group's).
pub const MailAccount = struct {
    id: []const u8,
    name: []const u8 = "",
    personal: bool = true,
    read_only: bool = false,
};

pub const Session = struct {
    api_url: []const u8,
    /// Every account with mail, the primary one first.
    accounts: []const MailAccount = &.{},
    download_url: []const u8 = "",
    upload_url: []const u8 = "",
    event_source_url: ?[]const u8 = null,
    account_id: []const u8,
    username: []const u8 = "",
    state: []const u8 = "",
    can_send: bool = false,
    max_objects_in_get: u32 = 500,
    max_objects_in_set: u32 = 500,
};

const Wire = struct {
    capabilities: std.json.ArrayHashMap(std.json.Value) = .{},
    accounts: std.json.ArrayHashMap(std.json.Value) = .{},
    primaryAccounts: std.json.ArrayHashMap([]const u8) = .{},
    username: []const u8 = "",
    apiUrl: []const u8 = "",
    downloadUrl: []const u8 = "",
    uploadUrl: []const u8 = "",
    eventSourceUrl: ?[]const u8 = null,
    state: []const u8 = "",
};

/// Reads a session object; its URLs resolved against `base` (the URL it
/// came from) where they're relative.
pub fn parse(arena: std.mem.Allocator, json: []const u8, base: []const u8) !Session {
    const w = std.json.parseFromSliceLeaky(Wire, arena, json, .{ .ignore_unknown_fields = true }) catch return error.NotJmap;
    if (w.apiUrl.len == 0) return error.NotJmap;
    // No accounts at all: an anonymous session (the credentials weren't taken).
    if (w.accounts.map.count() == 0) return error.NoMailAccount;
    if (w.capabilities.map.get(types.cap_mail) == null) return error.NoMail;
    const account = w.primaryAccounts.map.get(types.cap_mail) orelse blk: {
        // No primary account for mail: the first that has it.
        var it = w.accounts.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const caps = e.value_ptr.object.get("accountCapabilities") orelse continue;
            if (caps == .object and caps.object.get(types.cap_mail) != null) break :blk e.key_ptr.*;
        }
        return error.NoMailAccount;
    };
    // Every account with mail: the primary, then the rest in the order given.
    var accounts: std.ArrayList(MailAccount) = .empty;
    var it = w.accounts.map.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) continue;
        const o = e.value_ptr.object;
        const caps = o.get("accountCapabilities") orelse continue;
        if (caps != .object or caps.object.get(types.cap_mail) == null) continue;
        const a: MailAccount = .{
            .id = e.key_ptr.*,
            .name = if (o.get("name")) |n| (if (n == .string) n.string else "") else "",
            .personal = if (o.get("isPersonal")) |v| (if (v == .bool) v.bool else true) else true,
            .read_only = if (o.get("isReadOnly")) |v| (if (v == .bool) v.bool else false) else false,
        };
        if (std.mem.eql(u8, a.id, account)) try accounts.insert(arena, 0, a) else try accounts.append(arena, a);
    }
    if (accounts.items.len == 0) try accounts.append(arena, .{ .id = account, .name = w.username });
    var s: Session = .{
        .accounts = accounts.items,
        .api_url = try resolve(arena, base, w.apiUrl),
        .download_url = try resolve(arena, base, w.downloadUrl),
        .upload_url = try resolve(arena, base, w.uploadUrl),
        .event_source_url = if (w.eventSourceUrl) |u| try resolve(arena, base, u) else null,
        .account_id = account,
        .username = w.username,
        .state = w.state,
        .can_send = w.capabilities.map.get(types.cap_submission) != null,
    };
    if (w.capabilities.map.get(types.cap_core)) |core| if (core == .object) {
        if (core.object.get("maxObjectsInGet")) |v| if (v == .integer and v.integer > 0) {
            s.max_objects_in_get = @intCast(@min(v.integer, 10_000));
        };
        if (core.object.get("maxObjectsInSet")) |v| if (v == .integer and v.integer > 0) {
            s.max_objects_in_set = @intCast(@min(v.integer, 10_000));
        };
    };
    return s;
}

/// Where to look for the session, from what the user typed: a session
/// URL as is, a server's address with the well-known path, or the
/// domain of their email address.
pub fn discoveryUrl(arena: std.mem.Allocator, server_in: []const u8, username: []const u8) ![]const u8 {
    var server = std.mem.trim(u8, server_in, " ");
    if (server.len == 0) {
        const at = std.mem.lastIndexOfScalar(u8, username, '@') orelse return error.NoServer;
        server = username[at + 1 ..];
        if (server.len == 0) return error.NoServer;
    }
    // Fastmail's session isn't under its web address.
    for ([_][]const u8{ "fastmail.com", "www.fastmail.com", "api.fastmail.com", "https://fastmail.com", "https://www.fastmail.com", "https://api.fastmail.com", "fastmail.fm", "messagingengine.com" }) |f| {
        if (std.ascii.eqlIgnoreCase(server, f)) return "https://api.fastmail.com/jmap/session";
    }
    const has_scheme = std.mem.indexOf(u8, server, "://") != null;
    const full = if (has_scheme) server else try std.fmt.allocPrint(arena, "https://{s}", .{server});
    const after_scheme = std.mem.indexOf(u8, full, "://").? + 3;
    // A path is kept as typed ("…/jmap/"); a bare "/" is no path.
    if (std.mem.indexOfScalarPos(u8, full, after_scheme, '/')) |slash| {
        if (slash + 1 < full.len) return full;
        return std.fmt.allocPrint(arena, "{s}/.well-known/jmap", .{full[0..slash]});
    }
    return std.fmt.allocPrint(arena, "{s}/.well-known/jmap", .{full});
}

/// `ref` against `base`: absolute as is, "/path" on base's origin.
pub fn resolve(arena: std.mem.Allocator, base: []const u8, ref: []const u8) ![]const u8 {
    if (ref.len == 0 or std.mem.indexOf(u8, ref, "://") != null) return ref;
    const o = origin(base);
    if (ref[0] == '/') return std.mem.concat(arena, u8, &.{ o, ref });
    const dir_end = std.mem.lastIndexOfScalar(u8, base, '/') orelse base.len;
    return std.mem.concat(arena, u8, &.{ base[0 .. @max(dir_end, o.len) + 1], ref });
}

/// "https://host:port" of a URL.
pub fn origin(url: []const u8) []const u8 {
    const s = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    const end = std.mem.indexOfScalarPos(u8, url, s, '/') orelse url.len;
    return url[0..end];
}

/// The host of a URL, without its port.
pub fn host(url: []const u8) []const u8 {
    const o = origin(url);
    const s = if (std.mem.indexOf(u8, o, "://")) |i| i + 3 else 0;
    const h = o[s..];
    return h[0 .. std.mem.lastIndexOfScalar(u8, h, ':') orelse h.len];
}

/// Whether credentials may follow a redirect from `a` to `b`: to the
/// same host, or into a subdomain of it (example.com to
/// mail.example.com), never between addresses or from https to http.
pub fn sameSite(a: []const u8, b: []const u8) bool {
    if (std.mem.startsWith(u8, a, "https:") and !std.mem.startsWith(u8, b, "https:")) return false;
    const ha = host(a);
    const hb = host(b);
    if (std.ascii.eqlIgnoreCase(ha, hb)) return true;
    if (isAddress(ha) or isAddress(hb)) return false;
    return hb.len > ha.len + 1 and std.ascii.endsWithIgnoreCase(hb, ha) and hb[hb.len - ha.len - 1] == '.';
}

/// An IP address rather than a name.
fn isAddress(h: []const u8) bool {
    if (std.mem.indexOfScalar(u8, h, ':') != null or (h.len > 0 and h[0] == '[')) return true;
    for (h) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return false;
    return true;
}

/// A download URL from the session's template (RFC 8620 §6.2).
pub fn downloadUrl(arena: std.mem.Allocator, template: []const u8, account: []const u8, blob: []const u8, name: []const u8, mime: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') if (std.mem.indexOfScalarPos(u8, template, i, '}')) |end| {
            const key = template[i + 1 .. end];
            const value: ?[]const u8 = if (std.mem.eql(u8, key, "accountId")) account else if (std.mem.eql(u8, key, "blobId")) blob else if (std.mem.eql(u8, key, "name")) name else if (std.mem.eql(u8, key, "type")) mime else null;
            if (value) |v| {
                try percentEncode(&aw.writer, v);
                i = end + 1;
                continue;
            }
        };
        try aw.writer.writeByte(template[i]);
        i += 1;
    }
    return aw.written();
}

fn percentEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else try w.print("%{X:0>2}", .{ch});
    }
}

test "discovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://example.org/.well-known/jmap", try discoveryUrl(a, "", "me@example.org"));
    try std.testing.expectEqualStrings("https://mail.example.org/.well-known/jmap", try discoveryUrl(a, "mail.example.org", "me"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/.well-known/jmap", try discoveryUrl(a, "http://127.0.0.1:8080/", "me"));
    try std.testing.expectEqualStrings("https://h/jmap/session", try discoveryUrl(a, "https://h/jmap/session", "me"));
    try std.testing.expectEqualStrings("https://h/jmap/", try discoveryUrl(a, " https://h/jmap/ ", "me"));
    try std.testing.expectEqualStrings("https://api.fastmail.com/jmap/session", try discoveryUrl(a, "", "me@fastmail.com"));
    try std.testing.expectError(error.NoServer, discoveryUrl(a, "", "me"));
}

test "urls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("http://h:8/jmap/", try resolve(a, "http://h:8/.well-known/jmap", "/jmap/"));
    try std.testing.expectEqualStrings("https://x/api", try resolve(a, "http://h:8/a", "https://x/api"));
    try std.testing.expectEqualStrings("h", host("https://h:443/x"));
    try std.testing.expect(sameSite("https://fastmail.com/.well-known/jmap", "https://api.fastmail.com/jmap/session"));
    try std.testing.expect(!sameSite("https://a.com/x", "http://a.com/y"));
    try std.testing.expect(!sameSite("https://a.com/x", "https://evil.com/y"));
    try std.testing.expect(sameSite("https://example.com/.well-known/jmap", "https://mail.example.com/jmap"));
    try std.testing.expect(!sameSite("https://mail.example.co.uk/x", "https://attacker.co.uk/y"));
    try std.testing.expect(!sameSite("https://alice.github.io/x", "https://mallory.github.io/y"));
    try std.testing.expect(!sameSite("http://10.0.0.1/x", "http://192.168.0.1/y"));
    try std.testing.expect(!sameSite("https://xexample.com/x", "https://example.com/y"));
    try std.testing.expectEqualStrings(
        "http://h/download/u1/B%2F1/my%20file.pdf?accept=application%2Fpdf",
        try downloadUrl(a, "http://h/download/{accountId}/{blobId}/{name}?accept={type}", "u1", "B/1", "my file.pdf", "application/pdf"),
    );
}

test "session objects" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(),
        \\{"capabilities":{"urn:ietf:params:jmap:core":{"maxObjectsInGet":250,"maxSizeUpload":1},"urn:ietf:params:jmap:mail":{},"urn:ietf:params:jmap:submission":{}},
        \\"accounts":{"u1":{"name":"alice","accountCapabilities":{"urn:ietf:params:jmap:mail":{}}}},
        \\"primaryAccounts":{"urn:ietf:params:jmap:mail":"u1"},"username":"alice@example.test",
        \\"apiUrl":"/jmap/","downloadUrl":"/jmap/download/{accountId}/{blobId}/{name}?accept={type}",
        \\"uploadUrl":"/jmap/upload/{accountId}/","eventSourceUrl":"/jmap/eventsource/?types={types}&closeafter={closeafter}&ping={ping}","state":"s1"}
    , "http://127.0.0.1:8080/.well-known/jmap");
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/jmap/", s.api_url);
    try std.testing.expectEqualStrings("u1", s.account_id);
    try std.testing.expect(s.can_send);
    try std.testing.expectEqual(@as(u32, 250), s.max_objects_in_get);
    try std.testing.expectError(error.NotJmap, parse(arena.allocator(), "<html>", "x"));
}
