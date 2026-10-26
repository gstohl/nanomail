//! The JMAP client: against canned answers always, and against a real
//! server when NANOMAIL_TEST_URL is set (a test account's server, with
//! NANOMAIL_TEST_USER, NANOMAIL_TEST_PASSWORD and NANOMAIL_TEST_TO, an
//! address that takes test mail). The live tests change that account.
const std = @import("std");
const jmap = @import("jmap/client.zig");
const Http = @import("jmap/http.zig").Http;
const k = @import("mail/kinds.zig");

const gpa = std.testing.allocator;

/// A server of canned answers, by URL, recording what it was sent.
const Canned = struct {
    routes: []const struct { url: []const u8, reply: jmap.Reply },
    seen: [16]jmap.Request = undefined,
    count: usize = 0,

    fn send(ctx: *anyopaque, _: std.mem.Allocator, req: jmap.Request) anyerror!jmap.Reply {
        const c: *Canned = @ptrCast(@alignCast(ctx));
        if (c.count < c.seen.len) c.seen[c.count] = req;
        c.count += 1;
        for (c.routes) |r| if (std.mem.eql(u8, r.url, req.url)) return r.reply;
        return error.ConnectionRefused;
    }

    fn transport(c: *Canned) jmap.Transport {
        return .{ .ctx = c, .send = send };
    }
};

const session_json =
    \\{"capabilities":{"urn:ietf:params:jmap:core":{},"urn:ietf:params:jmap:mail":{},"urn:ietf:params:jmap:submission":{}},
    \\"accounts":{"c":{"name":"alice","accountCapabilities":{"urn:ietf:params:jmap:mail":{}}}},
    \\"primaryAccounts":{"urn:ietf:params:jmap:mail":"c"},"username":"alice@example.test",
    \\"apiUrl":"/jmap/","downloadUrl":"/jmap/download/{accountId}/{blobId}/{name}?accept={type}","uploadUrl":"/up","state":"s"}
;

test "a session found through a redirect keeps its credentials on the same host" {
    var canned: Canned = .{ .routes = &.{
        .{ .url = "https://mail.example.test/.well-known/jmap", .reply = .{ .status = 307, .location = "/jmap/session" } },
        .{ .url = "https://mail.example.test/jmap/session", .reply = .{ .status = 200, .body = session_json } },
    } };
    var c = jmap.Client.init(gpa, canned.transport());
    defer c.deinit();
    try c.connect(.{ .username = "alice@mail.example.test", .secret = "pw" });
    try std.testing.expectEqualStrings("https://mail.example.test/jmap/", c.session.?.api_url);
    try std.testing.expectEqualStrings("c", c.session.?.account_id);
    try std.testing.expectEqual(@as(usize, 2), canned.count);
    try std.testing.expectEqualStrings("Basic YWxpY2VAbWFpbC5leGFtcGxlLnRlc3Q6cHc=", canned.seen[1].auth.?);
}

test "credentials don't follow a redirect to another site" {
    var canned: Canned = .{ .routes = &.{
        .{ .url = "https://example.test/.well-known/jmap", .reply = .{ .status = 302, .location = "https://evil.test/jmap/session" } },
        .{ .url = "https://evil.test/jmap/session", .reply = .{ .status = 401 } },
    } };
    var c = jmap.Client.init(gpa, canned.transport());
    defer c.deinit();
    try std.testing.expectError(error.Unauthorized, c.connect(.{ .username = "a@example.test", .secret = "pw", .token = true }));
    try std.testing.expect(canned.seen[1].auth == null);
    try std.testing.expectEqualStrings("The server didn't accept this API token.", c.problem);
}

test "a session from another site, found without credentials, isn't taken" {
    var canned: Canned = .{ .routes = &.{
        .{ .url = "https://example.test/.well-known/jmap", .reply = .{ .status = 302, .location = "https://evil.test/jmap/session" } },
        .{ .url = "https://evil.test/jmap/session", .reply = .{ .status = 200, .body = session_json } },
        .{ .url = "https://evil.test/jmap/", .reply = .{ .status = 200, .body = "{\"methodResponses\":[]}" } },
    } };
    var c = jmap.Client.init(gpa, canned.transport());
    defer c.deinit();
    const connected = if (c.connect(.{ .username = "a@example.test", .secret = "pw" })) true else |_| false;
    if (connected) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        _ = c.identities(arena.allocator()) catch {};
    }
    for (canned.seen[0..@min(canned.count, canned.seen.len)]) |r| {
        if (std.mem.startsWith(u8, r.url, "https://evil.test")) try std.testing.expect(r.auth == null);
    }
    try std.testing.expect(!connected);
    try std.testing.expectEqualStrings("The server sent sign-in on to evil.test: enter its session URL to use it.", c.problem);
}

test "discovery userinfo redirects never receive credentials or install a session" {
    const target = "https://example.test:443@evil.test/session";
    const uri = try std.Uri.parse(target);
    try std.testing.expectEqualStrings("evil.test", uri.host.?.percent_encoded);
    for ([_]bool{ false, true }) |token| {
        var canned: Canned = .{ .routes = &.{
            .{ .url = "https://example.test/.well-known/jmap", .reply = .{ .status = 302, .location = target } },
            .{ .url = target, .reply = .{ .status = 200, .body = session_json } },
        } };
        var c = jmap.Client.init(gpa, canned.transport());
        defer c.deinit();
        const connected = if (c.connect(.{ .username = "a@example.test", .secret = "fixture", .token = token })) true else |_| false;
        for (canned.seen[0..canned.count]) |req| {
            if (std.mem.eql(u8, req.url, target)) try std.testing.expect(req.auth == null);
        }
        try std.testing.expect(!connected);
        try std.testing.expect(c.session == null);
        try std.testing.expectEqual(@as(usize, 1), canned.count);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try std.testing.expectError(error.NotConnected, c.identities(arena.allocator()));
        try std.testing.expectError(error.NotConnected, c.download(arena.allocator(), "c", "b", "n", "text/plain"));
        try std.testing.expectEqual(@as(usize, 1), canned.count);
    }
}

test "discovery rejects malformed authorities before sending a request" {
    for ([_][]const u8{
        "https://user@example.test/session",        "https://example%2etest/session",
        "https:///example.test",                    "https:/example.test",
        "https:example.test",                       "ftp://example.test/session",
        "HTTPS://example.test/session",             "https://[::1]junk:443/session",
        "https://[::1/session",                     "https://example.test:+443/session",
        "https://example.test\\@evil.test/session",
    }) |target| {
        var canned: Canned = .{ .routes = &.{
            .{ .url = "https://example.test/.well-known/jmap", .reply = .{ .status = 307, .location = target } },
            .{ .url = target, .reply = .{ .status = 200, .body = session_json } },
        } };
        var c = jmap.Client.init(gpa, canned.transport());
        defer c.deinit();
        try std.testing.expectError(error.NotJmap, c.connect(.{ .username = "a@example.test", .secret = "fixture" }));
        try std.testing.expect(c.session == null);
        try std.testing.expectEqual(@as(usize, 1), canned.count);
        canned.count = 0;
        try std.testing.expectError(error.NoServer, c.connect(.{ .server = target, .username = "a@example.test", .secret = "fixture" }));
        try std.testing.expectEqual(@as(usize, 0), canned.count);
    }
}

test "discovery trust stays lost after foreign IPv6 or downgrade hops" {
    for ([_]struct { origin: []const u8, other: []const u8 }{
        .{ .origin = "https://example.test/session", .other = "https://evil.test/session" },
        .{ .origin = "https://example.test/session", .other = "http://example.test/session" },
        .{ .origin = "https://[2001:db8::1]/session", .other = "https://[2001:db8::2]/session" },
    }) |pair| {
        var canned: Canned = .{ .routes = &.{
            .{ .url = pair.origin, .reply = .{ .status = 302, .location = pair.other } },
            .{ .url = pair.other, .reply = .{ .status = 308, .location = "https://example.test/final" } },
            .{ .url = "https://example.test/final", .reply = .{ .status = 200, .body = session_json } },
        } };
        var c = jmap.Client.init(gpa, canned.transport());
        defer c.deinit();
        try std.testing.expectError(error.NotJmap, c.connect(.{ .server = pair.origin, .username = "a", .secret = "fixture", .token = true }));
        try std.testing.expect(c.session == null);
        try std.testing.expectEqual(@as(usize, 3), canned.count);
        try std.testing.expect(canned.seen[1].auth == null and canned.seen[2].auth == null);
    }
}

test "discovery trusts named servers and same-host or subdomain locations" {
    for ([_][]const u8{ "/session", "session", "//mail.example.test/session", "https://mail.example.test/session" }) |location| {
        var canned: Canned = .{ .routes = &.{
            .{ .url = "https://example.test/start", .reply = .{ .status = 301, .location = location } },
            .{ .url = "https://example.test/session", .reply = .{ .status = 200, .body = session_json } },
            .{ .url = "https://mail.example.test/session", .reply = .{ .status = 200, .body = session_json } },
        } };
        var c = jmap.Client.init(gpa, canned.transport());
        defer c.deinit();
        try c.connect(.{ .server = "https://example.test/start", .username = "a@elsewhere.test", .secret = "fixture", .token = true });
        try std.testing.expectEqual(@as(usize, 2), canned.count);
        try std.testing.expectEqualStrings("Bearer fixture", canned.seen[1].auth.?);
    }
}

test "Fastmail's session, its downloads on another site, connects" {
    var canned: Canned = .{ .routes = &.{
        .{ .url = "https://api.fastmail.com/jmap/session", .reply = .{ .status = 200, .body =
        \\{"capabilities":{"urn:ietf:params:jmap:core":{},"urn:ietf:params:jmap:mail":{}},
        \\"accounts":{"u1":{"name":"a","accountCapabilities":{"urn:ietf:params:jmap:mail":{}}}},
        \\"primaryAccounts":{"urn:ietf:params:jmap:mail":"u1"},"username":"a@fastmail.com",
        \\"apiUrl":"https://api.fastmail.com/jmap/api/","uploadUrl":"https://api.fastmail.com/jmap/upload/{accountId}/",
        \\"downloadUrl":"https://www.fastmailusercontent.com/jmap/download/{accountId}/{blobId}/{name}?type={type}",
        \\"eventSourceUrl":"https://api.fastmail.com/jmap/event/","state":"s"}
        } },
        .{ .url = "https://www.fastmailusercontent.com/jmap/download/u1/b/attachment?type=text%2Fplain", .reply = .{ .status = 200, .body = "fixture bytes" } },
    } };
    var c = jmap.Client.init(gpa, canned.transport());
    defer c.deinit();
    try c.connect(.{ .server = "fastmail.com", .username = "a@fastmail.com", .secret = "tok", .token = true });
    try std.testing.expect(std.mem.startsWith(u8, c.session.?.download_url, "https://www.fastmailusercontent.com/"));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("fixture bytes", try c.download(arena.allocator(), "u1", "b", "attachment", "text/plain"));
    try std.testing.expectEqualStrings("Bearer tok", canned.seen[1].auth.?);
}

test "an anonymous session means the password was wrong; no server, a clear word" {
    var canned: Canned = .{ .routes = &.{
        .{ .url = "http://127.0.0.1:9/jmap/session", .reply = .{ .status = 200, .body =
        \\{"capabilities":{"urn:ietf:params:jmap:mail":{}},"accounts":{},"primaryAccounts":{},"username":"","apiUrl":"/jmap/"}
        } },
    } };
    var c = jmap.Client.init(gpa, canned.transport());
    defer c.deinit();
    try std.testing.expectError(error.Unauthorized, c.connect(.{ .server = "http://127.0.0.1:9/jmap/session", .username = "a", .secret = "x" }));
    try std.testing.expectError(error.Unreachable, c.connect(.{ .server = "nowhere.test", .username = "a", .secret = "x" }));
    try std.testing.expect(std.mem.startsWith(u8, c.problem, "Couldn't reach nowhere.test"));
}

test "a page of the list comes in the query's order, with flags and dates" {
    var canned: Canned = .{ .routes = &.{
        .{ .url = "https://h/s", .reply = .{ .status = 200, .body = session_json } },
        .{ .url = "https://h/jmap/", .reply = .{ .status = 200, .body =
        \\{"methodResponses":[["Email/query",{"ids":["e2","e1"],"position":0,"total":7,"queryState":"q"},"c0"],
        \\["Email/get",{"state":"s","list":[
        \\{"id":"e1","threadId":"t","mailboxIds":{"a":true},"keywords":{"$seen":true},"from":[{"name":"Ada","email":"ada@x"}],"subject":"One","receivedAt":"2025-03-06T09:07:00Z","preview":"hi\nthere","hasAttachment":false,"size":10},
        \\{"id":"e2","threadId":"t","mailboxIds":{"a":true,"i":true},"keywords":{"$flagged":true,"$answered":true},"from":null,"subject":null,"receivedAt":"2025-03-06T10:00:00Z","preview":"","hasAttachment":true,"size":99}
        \\],"notFound":[]},"c1"]]}
        } },
    } };
    var c = jmap.Client.init(gpa, canned.transport());
    defer c.deinit();
    try c.connect(.{ .server = "https://h/s", .username = "a", .secret = "x" });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const page = try c.list(arena.allocator(), "c", "a", "", 0, 50);
    try std.testing.expectEqual(@as(u32, 7), page.total);
    try std.testing.expectEqualStrings("e2", page.messages[0].id);
    try std.testing.expect(page.messages[0].flags.flagged and page.messages[0].flags.answered and !page.messages[0].flags.seen);
    try std.testing.expectEqual(@as(usize, 2), page.messages[0].mailbox_ids.len);
    try std.testing.expect(page.messages[0].has_attachment);
    try std.testing.expectEqualStrings("One", page.messages[1].subject);
    try std.testing.expect(page.messages[1].flags.seen);
    try std.testing.expectEqual(@as(i64, 1741252020), page.messages[1].received);
    const body = canned.seen[1].body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"filter\":{\"inMailbox\":\"a\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"#ids\":{\"resultOf\":\"c0\"") != null);
}

test "an HTML-only message reads as text, its inline pictures aren't attachments" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try std.json.parseFromSliceLeaky(@import("jmap/types.zig").EmailFull, a,
        \\{"id":"e","textBody":[{"partId":"1","type":"text/html"}],"htmlBody":[{"partId":"1","type":"text/html"}],
        \\"attachments":[{"partId":"2","blobId":"b2","type":"image/png","cid":"logo","disposition":"inline","size":5},
        \\{"partId":"3","blobId":"b3","type":"application/pdf","name":"bill.pdf","disposition":"attachment","size":900}],
        \\"bodyValues":{"1":{"value":"<p>Hello&nbsp;<b>there</b></p><p>Bye</p>"}},"messageId":["<m@x>"]}
    , .{ .ignore_unknown_fields = true });
    const d = try jmap.full(a, "c", e);
    try std.testing.expectEqualStrings("Hello there\n\nBye", d.text);
    try std.testing.expect(d.from_html);
    try std.testing.expect(d.html != null);
    try std.testing.expectEqual(@as(usize, 1), d.attachments.len);
    try std.testing.expectEqualStrings("bill.pdf", d.attachments[0].name);
    try std.testing.expectEqualStrings("<m@x>", d.message_id.?);
}

// Against a real server.

fn env(name: [:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

test "live: sign in, read, flag, move, send, download" {
    const url = env("NANOMAIL_TEST_URL") orelse return error.SkipZigTest;
    var http: Http = .init(gpa, std.testing.io);
    defer http.deinit();
    var c = jmap.Client.init(gpa, http.transport());
    defer c.deinit();
    c.connect(.{ .server = url, .username = env("NANOMAIL_TEST_USER") orelse "", .secret = env("NANOMAIL_TEST_PASSWORD") orelse "" }) catch |e| {
        std.debug.print("connect: {s}\n", .{c.problem});
        return e;
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const folders = try c.folders(a);
    const acc = c.session.?.account_id;
    // The user's own (shared accounts have their own roles).
    const find = struct {
        var own: []const u8 = "";
        fn f(fs: []const k.Folder, role: k.Role) ?k.Folder {
            for (fs) |x| if (x.role == role and std.mem.eql(u8, x.account_id, own)) return x;
            return null;
        }
    };
    find.own = acc;
    const inbox = find.f(folders, .inbox).?;
    const archive = find.f(folders, .archive) orelse find.f(folders, .trash).?;
    const ids = try c.identities(a);
    try std.testing.expect(ids.len > 0);

    // Send one to the test address, kept in Sent.
    var subject_buf: [64]u8 = undefined;
    const subject = try std.fmt.bufPrint(&subject_buf, "nanomail live test {d}", .{std.Io.Clock.real.now(std.testing.io).toSeconds()});
    try c.send(a, .{
        .account_id = ids[0].account_id,
        .identity_id = ids[0].id,
        .from = .{ .name = ids[0].name, .email = ids[0].email },
        .to = &.{.{ .email = env("NANOMAIL_TEST_TO") orelse ids[0].email }},
        .subject = subject,
        .body = "Sent by nanomail's tests.\n\nŁódź, Zürich, 東京 ✓",
        .drafts_id = if (find.f(folders, .drafts)) |d| d.id else null,
        .sent_id = if (find.f(folders, .sent)) |s| s.id else null,
    });
    if (find.f(folders, .sent)) |sent| {
        const p = try c.list(a, acc, sent.id, subject, 0, 5);
        try std.testing.expectEqual(@as(usize, 1), p.messages.len);
        try std.testing.expect(!p.messages[0].flags.draft);
    }

    const page = try c.list(a, acc, inbox.id, "", 0, 20);
    try std.testing.expect(page.messages.len > 0);
    const first = page.messages[0];
    const d = try c.detail(a, acc, first.id);
    try std.testing.expectEqualStrings(first.id, d.message.id);

    // Flag and unflag; out to the archive and back.
    try c.setKeyword(a, acc, &.{first.id}, .flagged, !first.flags.flagged);
    try std.testing.expectEqual(!first.flags.flagged, (try c.detail(a, acc, first.id)).message.flags.flagged);
    try c.setKeyword(a, acc, &.{first.id}, .flagged, first.flags.flagged);
    try c.move(a, acc, &.{first.id}, inbox.id, archive.id);
    const moved = try c.detail(a, acc, first.id);
    try std.testing.expect(moved.message.inMailbox(archive.id) and !moved.message.inMailbox(inbox.id));
    try c.move(a, acc, &.{first.id}, archive.id, inbox.id);

    // The first attachment in the inbox, whole.
    for ((try c.list(a, acc, inbox.id, "", 0, 50)).messages) |m| if (m.has_attachment) {
        const full = try c.detail(a, acc, m.id);
        if (full.attachments.len == 0) continue;
        const bytes = try c.download(a, acc, full.attachments[0].blob_id, full.attachments[0].name, full.attachments[0].type);
        try std.testing.expect(bytes.len > 0);
        break;
    };
}

/// A server whose answers come in order, recording each request's body.
const Script = struct {
    replies: []const jmap.Reply,
    /// Each request's body, kept here (the client's arenas go).
    store: [8][4096]u8 = undefined,
    lens: [8]usize = @splat(0),
    n: usize = 0,

    fn send(ctx: *anyopaque, _: std.mem.Allocator, req: jmap.Request) anyerror!jmap.Reply {
        const s: *Script = @ptrCast(@alignCast(ctx));
        if (s.n >= s.replies.len) return error.ConnectionRefused;
        const sent = req.body orelse "";
        const len = @min(sent.len, s.store[s.n].len);
        @memcpy(s.store[s.n][0..len], sent[0..len]);
        s.lens[s.n] = len;
        s.n += 1;
        return s.replies[s.n - 1];
    }

    fn body(s: *const Script, i: usize) []const u8 {
        return s.store[i][0..s.lens[i]];
    }
};

fn sendWith(replies: []const jmap.Reply, out: k.Outgoing) !struct { err: ?anyerror, script: Script, last_draft: ?[]const u8 } {
    var script: Script = .{ .replies = replies };
    var c = jmap.Client.init(gpa, .{ .ctx = &script, .send = Script.send });
    defer c.deinit();
    try c.connect(.{ .server = "https://h/s", .username = "a", .secret = "x" });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const err: ?anyerror = if (c.send(arena.allocator(), out)) |_| null else |e| e;
    return .{ .err = err, .script = script, .last_draft = if (c.last_draft) |d| if (std.mem.eql(u8, d, "new1")) "new1" else "?" else null };
}

const outgoing: k.Outgoing = .{
    .account_id = "c",
    .identity_id = "b",
    .from = .{ .email = "alice@example.test" },
    .to = &.{.{ .email = "bob@example.test" }},
    .subject = "Re: hi",
    .body = "text",
    .drafts_id = "d",
    .sent_id = "s",
    .original_id = "orig",
    .original_keyword = .answered,
    .replaces = "old",
};

test "a draft that fails to save leaves the one it replaces alone" {
    const r = try sendWith(&.{
        .{ .status = 200, .body = session_json },
        .{ .status = 200, .body =
        \\{"methodResponses":[["Email/set",{"notCreated":{"draft":{"type":"invalidProperties","description":"Missing body value"}}},"c0"],
        \\["EmailSubmission/set",{"notCreated":{"send":{"type":"invalidProperties"}}},"c1"]]}
        },
    }, outgoing);
    try std.testing.expectEqual(@as(?anyerror, error.NotSent), r.err);
    // The session, then one request: no second one destroying "old".
    try std.testing.expectEqual(@as(usize, 2), r.script.n);
    try std.testing.expect(std.mem.indexOf(u8, r.script.body(1), "\"destroy\"") == null);
}

test "a draft saved but not sent replaces the old one, and is the next to replace" {
    const r = try sendWith(&.{
        .{ .status = 200, .body = session_json },
        .{ .status = 200, .body =
        \\{"methodResponses":[["Email/set",{"created":{"draft":{"id":"new1"}}},"c0"],
        \\["EmailSubmission/set",{"notCreated":{"send":{"type":"forbiddenFrom","description":"not yours"}}},"c1"]]}
        },
        .{ .status = 200, .body =
        \\{"methodResponses":[["Email/set",{"destroyed":["old"]},"c0"]]}
        },
    }, outgoing);
    try std.testing.expectEqual(@as(?anyerror, error.NotSent), r.err);
    try std.testing.expectEqualStrings("new1", r.last_draft.?);
    try std.testing.expectEqual(@as(usize, 3), r.script.n);
    const follow = r.script.body(2);
    try std.testing.expect(std.mem.indexOf(u8, follow, "\"destroy\":[\"old\"]") != null);
    // Not sent: the original isn't marked answered.
    try std.testing.expect(std.mem.indexOf(u8, follow, "$answered") == null);
}

test "sent: the old draft goes and the original is marked answered" {
    const r = try sendWith(&.{
        .{ .status = 200, .body = session_json },
        .{ .status = 200, .body =
        \\{"methodResponses":[["Email/set",{"created":{"draft":{"id":"new1"}}},"c0"],
        \\["EmailSubmission/set",{"created":{"send":{"id":"sub1"}}},"c1"]]}
        },
        .{ .status = 200, .body =
        \\{"methodResponses":[["Email/set",{"destroyed":["old"]},"c0"],["Email/set",{"updated":{"orig":null}},"c1"]]}
        },
    }, outgoing);
    try std.testing.expectEqual(@as(?anyerror, null), r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.script.body(2), "\"keywords/$answered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.script.body(1), "\"emailId\":\"#draft\"") != null);
}

var fake_now: i64 = 1_000_000;
fn fakeClock() i64 {
    return fake_now;
}

test "signed in through the browser: tokens renewed before they run out, and when refused" {
    var script: Script = .{
        .replies = &.{
            // Launch: the refresh token kept buys an access token, then the session.
            .{ .status = 200, .body = "{\"access_token\":\"A1\",\"token_type\":\"Bearer\",\"expires_in\":3600}" },
            .{ .status = 200, .body = session_json },
            // An hour on: renewed first; the server also replaces the refresh token.
            .{ .status = 200, .body = "{\"access_token\":\"A2\",\"expires_in\":3600,\"refresh_token\":\"R2\"}" },
            .{ .status = 200, .body = "{\"methodResponses\":[[\"Mailbox/get\",{\"list\":[]},\"c0\"]]}" },
            // Refused early (revoked): renewed, sent again.
            .{ .status = 401 },
            .{ .status = 200, .body = "{\"access_token\":\"A3\",\"expires_in\":3600}" },
            .{ .status = 200, .body = "{\"methodResponses\":[[\"Mailbox/get\",{\"list\":[]},\"c0\"]]}" },
        },
    };
    var c = jmap.Client.init(gpa, .{ .ctx = &script, .send = Script.send });
    defer c.deinit();
    c.clock = fakeClock;
    try c.connect(.{ .server = "https://h/s", .username = "a", .secret = "R1", .token = true, .oauth = .{ .client_id = "cid", .token_endpoint = "https://h/token" } });
    try std.testing.expectEqualStrings("grant_type=refresh_token&refresh_token=R1&client_id=cid", script.body(0));
    try std.testing.expectEqualStrings("Bearer A1", c.auth);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    fake_now += 3600;
    _ = try c.folders(arena.allocator());
    try std.testing.expectEqualStrings("Bearer A2", c.auth);
    try std.testing.expectEqualStrings("R2", c.rotated.?);
    try std.testing.expect(std.mem.indexOf(u8, script.body(2), "refresh_token=R1") != null);
    _ = try c.folders(arena.allocator());
    try std.testing.expectEqualStrings("Bearer A3", c.auth);
    // The newest refresh token renewed it.
    try std.testing.expect(std.mem.indexOf(u8, script.body(5), "refresh_token=R2") != null);
    try std.testing.expectEqual(@as(usize, 7), script.n);
}

test "a refresh token the server no longer takes asks for the browser again" {
    var script: Script = .{ .replies = &.{
        .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Token expired\"}" },
    } };
    var c = jmap.Client.init(gpa, .{ .ctx = &script, .send = Script.send });
    defer c.deinit();
    try std.testing.expectError(error.Unauthorized, c.connect(.{ .server = "https://h/s", .username = "a", .secret = "R1", .token = true, .oauth = .{ .client_id = "cid", .token_endpoint = "https://h/token" } }));
    try std.testing.expectEqualStrings("The sign-in has expired: sign in through the browser again.", c.problem);
}

test "discovery: the resource names its authorization server" {
    var canned: Canned = .{ .routes = &.{
        .{ .url = "https://mail.example.test/.well-known/oauth-protected-resource", .reply = .{ .status = 200, .body = "{\"resource\":\"https://mail.example.test\",\"authorization_servers\":[\"https://id.example.test/realms/mail\"]}" } },
        .{ .url = "https://id.example.test/.well-known/oauth-authorization-server/realms/mail", .reply = .{ .status = 404 } },
        .{ .url = "https://id.example.test/realms/mail/.well-known/openid-configuration", .reply = .{ .status = 200, .body = "{\"issuer\":\"https://id.example.test/realms/mail\",\"authorization_endpoint\":\"https://id.example.test/auth\",\"token_endpoint\":\"https://id.example.test/token\"}" } },
    } };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const oauth = @import("jmap/oauth.zig");
    const md = try oauth.discover(arena.allocator(), canned.transport(), "https://mail.example.test/jmap/session");
    try std.testing.expectEqualStrings("https://id.example.test/token", md.token_endpoint);
    try std.testing.expect(md.registration_endpoint == null);
    // No scopes listed: the usual OpenID ones.
    try std.testing.expectEqualStrings("openid email offline_access", try oauth.scopes(arena.allocator(), md));
}

test "live: shared mailboxes come as accounts of their own" {
    _ = env("NANOMAIL_TEST_URL") orelse return error.SkipZigTest;
    if (env("NANOMAIL_TEST_SHARED") == null) return error.SkipZigTest;
    var http: Http = .init(gpa, std.testing.io);
    defer http.deinit();
    var c = jmap.Client.init(gpa, http.transport());
    defer c.deinit();
    try c.connect(.{ .server = env("NANOMAIL_TEST_URL").?, .username = env("NANOMAIL_TEST_USER") orelse "", .secret = env("NANOMAIL_TEST_PASSWORD") orelse "" });
    try std.testing.expect(c.session.?.accounts.len >= 2);
    try std.testing.expect(c.session.?.accounts[0].personal);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const folders = try c.folders(a);
    var read_only: ?k.Folder = null;
    for (folders) |f| if (!std.mem.eql(u8, f.account_id, c.session.?.account_id) and !f.rights.keywords) {
        read_only = f;
    };
    const share = read_only orelse return error.NoReadOnlyShare;
    const page = try c.list(a, share.account_id, share.id, "", 0, 10);
    try std.testing.expect(page.messages.len > 0);
    try std.testing.expectEqualStrings(share.account_id, page.messages[0].account_id);
    // The server says no to changing it (the app doesn't try).
    try std.testing.expectError(error.NotUpdated, c.setKeyword(a, share.account_id, &.{page.messages[0].id}, .flagged, true));
    // Who may send: the user's own and the group's, not another person's.
    const ids = try c.identities(a);
    var accounts_with_identities: usize = 0;
    var last: []const u8 = "";
    for (ids) |id| if (!std.mem.eql(u8, id.account_id, last)) {
        accounts_with_identities += 1;
        last = id.account_id;
    };
    try std.testing.expect(accounts_with_identities >= 1);
}
