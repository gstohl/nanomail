//! A JMAP mail client over some transport (HTTP in the app, canned
//! answers in tests): signing in, then each operation the app needs as
//! one request of batched method calls. Results are the app's own kinds
//! (mail/kinds.zig), made in the caller's arena.
const std = @import("std");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const k = @import("../mail/kinds.zig");
const dates = @import("../mail/dates.zig");
const html = @import("../mail/html.zig");
const oauth = @import("oauth.zig");
const Session = session_mod.Session;

extern "c" fn time(t: ?*i64) i64;

fn wallClock() i64 {
    return time(null);
}

/// Signed in through the browser: what renews the access token.
const OAuthState = struct {
    client_id: []const u8,
    token_endpoint: []const u8,
    refresh_token: []const u8,
    /// Unix seconds when the access token runs out.
    expires_at: i64,
};

pub const Method = enum { GET, POST };

pub const Request = struct {
    method: Method = .POST,
    url: []const u8,
    /// The Authorization header's value.
    auth: ?[]const u8 = null,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    accept: []const u8 = "application/json",
    /// Longer than the transport's own, for big downloads.
    timeout_ms: ?i64 = null,
};

pub const Reply = struct {
    status: u16,
    body: []const u8 = "",
    /// Where a redirect points.
    location: ?[]const u8 = null,
    /// WWW-Authenticate, on a 401.
    challenge: ?[]const u8 = null,
};

/// Sends requests; never follows redirects (the client does, deciding
/// whether credentials go along).
pub const Transport = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, req: Request) anyerror!Reply,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    transport: Transport,
    /// What's kept while signed in: the session and the credentials.
    arena: std.heap.ArenaAllocator,
    auth: []const u8 = "",
    session: ?Session = null,
    session_url: []const u8 = "",
    /// The server's last word on a failure, for the user.
    problem_buf: [400]u8 = undefined,
    problem: []const u8 = "",
    /// A draft `send` saved but couldn't send (in its arena).
    last_draft: ?[]const u8 = null,
    oauth: ?OAuthState = null,
    /// A refresh token the server gave in place of the old, to keep.
    rotated: ?[]const u8 = null,
    /// Counts new access tokens (push takes the newest).
    auth_gen: u32 = 0,
    clock: *const fn () i64 = wallClock,

    pub fn init(gpa: std.mem.Allocator, transport: Transport) Client {
        return .{ .gpa = gpa, .transport = transport, .arena = .init(gpa) };
    }

    pub fn deinit(c: *Client) void {
        c.arena.deinit();
    }

    fn say(c: *Client, comptime fmt: []const u8, args: anytype) void {
        c.problem = std.fmt.bufPrint(&c.problem_buf, fmt, args) catch c.problem_buf[0..0];
    }

    /// Finds the account's session and keeps it.
    pub fn connect(c: *Client, account: k.Account) !void {
        return c.connectWith(account, null);
    }

    /// As `connect`, with tokens just had from the browser's sign-in.
    pub fn connectWith(c: *Client, account: k.Account, tokens: ?oauth.Tokens) !void {
        _ = c.arena.reset(.free_all);
        c.session = null;
        c.problem = "";
        c.oauth = null;
        c.rotated = null;
        const a = c.arena.allocator();
        if (account.oauth) |o| {
            c.oauth = .{ .client_id = try a.dupe(u8, o.client_id), .token_endpoint = try a.dupe(u8, o.token_endpoint), .refresh_token = try a.dupe(u8, account.secret), .expires_at = 0 };
            if (tokens) |t| try c.applyTokens(t) else try c.renew();
        } else c.auth = if (account.token)
            try std.fmt.allocPrint(a, "Bearer {s}", .{account.secret})
        else blk: {
            const plain = try std.fmt.allocPrint(a, "{s}:{s}", .{ account.username, account.secret });
            const enc = std.base64.standard.Encoder;
            const out = try a.alloc(u8, enc.calcSize(plain.len));
            break :blk try std.fmt.allocPrint(a, "Basic {s}", .{enc.encode(out, plain)});
        };
        c.auth_gen +%= 1;
        var url = session_mod.discoveryUrl(a, account.server, account.username) catch {
            c.say("Enter the server's address.", .{});
            return error.NoServer;
        };
        if (session_mod.host(url).len == 0) {
            c.say("Enter an HTTP or HTTPS server URL without user information.", .{});
            return error.NoServer;
        }
        var send_auth = true;
        var hops: u8 = 0;
        while (true) : (hops += 1) {
            if (hops > 5) {
                c.say("The server redirected too many times.", .{});
                return error.TooManyRedirects;
            }
            const reply = c.transport.send(c.transport.ctx, a, .{ .method = .GET, .url = url, .auth = if (send_auth) c.auth else null }) catch |e| {
                c.say("Couldn't reach {s} ({t}).", .{ session_mod.host(url), e });
                return error.Unreachable;
            };
            switch (reply.status) {
                200 => {
                    // Found on another site, which wasn't sent the credentials:
                    // its session would be sent them, so it's the user's to name.
                    if (!send_auth) {
                        c.say("The server sent sign-in on to {s}: enter its session URL to use it.", .{session_mod.host(url)});
                        return error.NotJmap;
                    }
                    const s = session_mod.parse(a, reply.body, url) catch |e| {
                        switch (e) {
                            // An anonymous session: the credentials weren't taken.
                            error.NoMailAccount => c.say("The server didn't accept this address and password.", .{}),
                            error.NoMail => c.say("This server's JMAP has no mail.", .{}),
                            else => c.say("{s} doesn't answer as a JMAP server.", .{session_mod.host(url)}),
                        }
                        return if (e == error.NoMailAccount) error.Unauthorized else error.NotJmap;
                    };
                    c.session = s;
                    // `url` may point into the caller's account, which goes.
                    c.session_url = try a.dupe(u8, url);
                    return;
                },
                301, 302, 303, 307, 308 => {
                    const loc = reply.location orelse return error.NotJmap;
                    const next = session_mod.redirectUrl(a, url, loc) catch |e| {
                        c.say("The server returned an invalid sign-in URL.", .{});
                        return e;
                    };
                    send_auth = send_auth and session_mod.sameSite(url, next);
                    url = next;
                },
                401, 403 => {
                    const bearer_only = if (reply.challenge) |ch| std.ascii.findIgnoreCase(ch, "bearer") != null and std.ascii.findIgnoreCase(ch, "basic") == null else false;
                    if (account.token) {
                        c.say("The server didn't accept this API token.", .{});
                    } else if (bearer_only) {
                        c.say("This server signs in with an API token, not a password: choose API token.", .{});
                    } else c.say("The server didn't accept this address and password.", .{});
                    return error.Unauthorized;
                },
                404 => {
                    c.say("No JMAP server at {s}. Enter the server's session URL.", .{session_mod.host(url)});
                    return error.NotJmap;
                },
                else => {
                    c.say("The server answered {d}.", .{reply.status});
                    return error.NotJmap;
                },
            }
        }
    }

    fn ses(c: *Client) !Session {
        return c.session orelse error.NotConnected;
    }

    /// Takes new tokens: the access token used from now on, and the
    /// refresh token, if it changed, to keep.
    fn applyTokens(c: *Client, t: oauth.Tokens) !void {
        const a = c.arena.allocator();
        const st = &(c.oauth orelse return);
        c.auth = try std.fmt.allocPrint(a, "Bearer {s}", .{t.access_token});
        c.auth_gen +%= 1;
        st.expires_at = if (t.expires_in) |s| c.clock() + @as(i64, @intCast(@min(s, 1 << 40))) else std.math.maxInt(i64);
        if (t.refresh_token) |r| if (!std.mem.eql(u8, r, st.refresh_token)) {
            st.refresh_token = try a.dupe(u8, r);
            c.rotated = st.refresh_token;
        };
    }

    /// A new access token for the refresh token.
    fn renew(c: *Client) !void {
        const st = c.oauth orelse return;
        const t = oauth.refresh(c.arena.allocator(), c.transport, st.token_endpoint, st.client_id, st.refresh_token) catch |e| {
            if (e == error.InvalidGrant or e == error.TokenRefused) {
                c.say("The sign-in has expired: sign in through the browser again.", .{});
                return error.Unauthorized;
            }
            c.say("Couldn't reach the sign-in server ({t}).", .{e});
            return error.Unreachable;
        };
        try c.applyTokens(t);
    }

    /// Before a request: a new access token if this one is about to run out.
    fn fresh(c: *Client) !void {
        const st = c.oauth orelse return;
        if (c.clock() < st.expires_at - 60) return;
        try c.renew();
    }

    /// Sends a request with the account's credentials; a token refused
    /// (it may have been revoked early) is renewed and the request sent again.
    fn authed(c: *Client, arena: std.mem.Allocator, req: Request) anyerror!Reply {
        try c.fresh();
        var r = req;
        r.auth = c.auth;
        const reply = try c.transport.send(c.transport.ctx, arena, r);
        if (reply.status != 401 or c.oauth == null) return reply;
        try c.renew();
        r.auth = c.auth;
        return c.transport.send(c.transport.ctx, arena, r);
    }

    /// Sends a request of method calls; the answer is parsed in `arena`.
    pub fn call(c: *Client, arena: std.mem.Allocator, req: *protocol.Request) !protocol.Response {
        const s = try c.ses();
        const reply = c.authed(arena, .{ .url = s.api_url, .body = try req.body() }) catch |e| {
            if (e == error.Unauthorized) return e;
            c.say("Couldn't reach the server ({t}).", .{e});
            return error.Unreachable;
        };
        if (reply.status == 401) {
            c.say("The server no longer accepts the password.", .{});
            return error.Unauthorized;
        }
        if (reply.status != 200) {
            c.say("The server answered {d}{s}.", .{ reply.status, problem(arena, reply.body) });
            return error.ServerError;
        }
        return protocol.Response.parse(arena, reply.body);
    }

    fn methodFailed(c: *Client, r: *protocol.Response, e: anyerror) anyerror {
        if (r.method_error) |me| c.say("{s}{s}{s}", .{ me.type, if (me.description != null) ": " else "", me.description orelse "" });
        return e;
    }

    /// The identities that may send, in every account that lets the user
    /// send from it (others answer `forbidden`, and are left out).
    pub fn identities(c: *Client, arena: std.mem.Allocator) ![]k.Identity {
        const s = try c.ses();
        if (!s.can_send) return &.{};
        var req = protocol.Request.init(arena, &types.using_submission);
        const ids = try arena.alloc([]const u8, s.accounts.len);
        for (s.accounts, ids) |acc, *id| id.* = try req.call("Identity/get", .{ .accountId = acc.id, .ids = @as(std.json.Value, .null) });
        var r = try c.call(arena, &req);
        var out: std.ArrayList(k.Identity) = .empty;
        for (s.accounts, ids) |acc, id| {
            const got = r.get(types.GetResponse(types.Identity), id) catch continue;
            for (got.list) |x| try out.append(arena, .{ .account_id = acc.id, .id = x.id, .name = x.name, .email = x.email });
        }
        return out.items;
    }

    /// Every folder of every account, in the sidebar's order: the user's
    /// own first, then each shared account's.
    pub fn folders(c: *Client, arena: std.mem.Allocator) ![]k.Folder {
        const s = try c.ses();
        var req = protocol.Request.init(arena, &types.using_mail);
        const ids = try arena.alloc([]const u8, s.accounts.len);
        for (s.accounts, ids) |acc, *id| id.* = try req.call("Mailbox/get", .{
            .accountId = acc.id,
            .ids = @as(std.json.Value, .null),
            .properties = &[_][]const u8{ "id", "name", "parentId", "role", "sortOrder", "totalEmails", "unreadEmails", "myRights" },
        });
        var r = try c.call(arena, &req);
        var out: std.ArrayList(k.Folder) = .empty;
        for (s.accounts, ids, 0..) |acc, id, n| {
            const got = r.get(types.GetResponse(types.Mailbox), id) catch |e| {
                // The user's own must answer; a shared one may not.
                if (n == 0) return c.methodFailed(&r, e);
                continue;
            };
            const mine = try arena.alloc(k.Folder, got.list.len);
            for (got.list, mine) |b, *o| {
                const rights = b.myRights orelse types.Rights{};
                o.* = .{
                    .account_id = acc.id,
                    .id = b.id,
                    .name = b.name,
                    .parent_id = b.parentId,
                    .role = types.Role.of(b.role),
                    .sort_order = clamp32(b.sortOrder),
                    .total = clamp32(b.totalEmails),
                    .unread = clamp32(b.unreadEmails),
                    .rights = .{ .read = rights.mayReadItems, .add = rights.mayAddItems, .remove = rights.mayRemoveItems, .seen = rights.maySetSeen, .keywords = rights.maySetKeywords },
                };
            }
            try out.appendSlice(arena, try k.sortFolders(arena, mine));
        }
        return out.items;
    }

    pub const Page = struct { total: u32, messages: []k.Message };

    /// A page of the folder's messages, newest first; those matching
    /// `query` when it isn't empty.
    pub fn list(c: *Client, arena: std.mem.Allocator, account_id: []const u8, mailbox_id: []const u8, query: []const u8, position: u32, limit: u32) !Page {
        const s = try c.ses();
        var req = protocol.Request.init(arena, &types.using_mail);
        const q = try req.call("Email/query", .{
            .accountId = account_id,
            .filter = .{ .inMailbox = mailbox_id, .text = if (query.len > 0) query else null },
            .sort = &[_]struct { property: []const u8, isAscending: bool }{.{ .property = "receivedAt", .isAscending = false }},
            .collapseThreads = false,
            .position = position,
            .limit = @min(limit, s.max_objects_in_get),
            .calculateTotal = true,
        });
        const g = try req.call("Email/get", .{
            .accountId = account_id,
            .@"#ids" = protocol.ResultRef{ .resultOf = q, .name = "Email/query", .path = "/ids" },
            .properties = &types.summary_properties,
        });
        var r = try c.call(arena, &req);
        const qr = r.get(types.QueryResponse, q) catch |e| return c.methodFailed(&r, e);
        const got = r.get(types.GetResponse(types.EmailSummary), g) catch |e| return c.methodFailed(&r, e);
        // In the query's order (a get answers in any).
        var out: std.ArrayList(k.Message) = .empty;
        for (qr.ids) |want| for (got.list) |e| if (std.mem.eql(u8, e.id, want)) {
            try out.append(arena, try message(arena, account_id, e));
            break;
        };
        return .{ .total = if (qr.total) |t| clamp32(t) else @intCast(position + out.items.len), .messages = out.items };
    }

    /// One message, whole.
    pub fn detail(c: *Client, arena: std.mem.Allocator, account_id: []const u8, id: []const u8) !k.Detail {
        _ = try c.ses();
        var req = protocol.Request.init(arena, &types.using_mail);
        const g = try req.call("Email/get", .{
            .accountId = account_id,
            .ids = &[_][]const u8{id},
            .properties = &types.full_properties,
            .fetchTextBodyValues = true,
            .fetchHTMLBodyValues = true,
            .maxBodyValueBytes = @as(u32, 4_000_000),
        });
        var r = try c.call(arena, &req);
        const got = r.get(types.GetResponse(types.EmailFull), g) catch |e| return c.methodFailed(&r, e);
        if (got.list.len == 0) {
            c.say("The message is gone.", .{});
            return error.NotFound;
        }
        return full(arena, account_id, got.list[0]);
    }

    /// Sets (or clears) a keyword on messages.
    pub fn setKeyword(c: *Client, arena: std.mem.Allocator, account_id: []const u8, ids: []const []const u8, keyword: k.Keyword, on: bool) !void {
        var patches: std.json.ObjectMap = .empty;
        for (ids) |id| {
            var patch: std.json.ObjectMap = .empty;
            try patch.put(arena, try std.fmt.allocPrint(arena, "keywords/{s}", .{keyword.name()}), if (on) .{ .bool = true } else .null);
            try patches.put(arena, id, .{ .object = patch });
        }
        try c.update(arena, account_id, patches);
    }

    /// Moves messages from one folder to another (out of `from` only:
    /// other folders they're in keep them).
    pub fn move(c: *Client, arena: std.mem.Allocator, account_id: []const u8, ids: []const []const u8, from: ?[]const u8, to: []const u8) !void {
        var patches: std.json.ObjectMap = .empty;
        for (ids) |id| {
            var patch: std.json.ObjectMap = .empty;
            if (from) |f| {
                try patch.put(arena, try std.fmt.allocPrint(arena, "mailboxIds/{s}", .{f}), .null);
                try patch.put(arena, try std.fmt.allocPrint(arena, "mailboxIds/{s}", .{to}), .{ .bool = true });
            } else try patch.put(arena, "mailboxIds", try protocol.idSet(arena, &.{to}));
            try patches.put(arena, id, .{ .object = patch });
        }
        try c.update(arena, account_id, patches);
    }

    fn update(c: *Client, arena: std.mem.Allocator, account_id: []const u8, patches: std.json.ObjectMap) !void {
        _ = try c.ses();
        var req = protocol.Request.init(arena, &types.using_mail);
        const id = try req.call("Email/set", .{ .accountId = account_id, .update = std.json.Value{ .object = patches } });
        var r = try c.call(arena, &req);
        const got = r.get(types.SetResponse, id) catch |e| return c.methodFailed(&r, e);
        if (got.firstError()) |e| {
            c.say("{s}", .{e.description orelse e.type});
            return error.NotUpdated;
        }
    }

    pub fn destroy(c: *Client, arena: std.mem.Allocator, account_id: []const u8, ids: []const []const u8) !void {
        _ = try c.ses();
        var req = protocol.Request.init(arena, &types.using_mail);
        const id = try req.call("Email/set", .{ .accountId = account_id, .destroy = ids });
        var r = try c.call(arena, &req);
        const got = r.get(types.SetResponse, id) catch |e| return c.methodFailed(&r, e);
        if (got.firstError()) |e| {
            c.say("{s}", .{e.description orelse e.type});
            return error.NotDestroyed;
        }
    }

    pub const send = @import("send.zig").send;

    /// A blob's bytes (an attachment).
    pub fn download(c: *Client, arena: std.mem.Allocator, account_id: []const u8, blob_id: []const u8, name: []const u8, mime: []const u8) ![]const u8 {
        const s = try c.ses();
        const url = try session_mod.downloadUrl(arena, s.download_url, account_id, blob_id, name, mime);
        const reply = c.authed(arena, .{ .method = .GET, .url = url, .accept = "*/*", .timeout_ms = 10 * 60 * 1000 }) catch |e| {
            c.say("Couldn't download it ({t}).", .{e});
            return error.Unreachable;
        };
        if (reply.status != 200) {
            c.say("The server answered {d}.", .{reply.status});
            return error.ServerError;
        }
        return reply.body;
    }
};

fn clamp32(v: u64) u32 {
    return @intCast(@min(v, std.math.maxInt(u32)));
}

/// ": notRequest", from a problem details body (RFC 7807), or nothing.
fn problem(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const P = struct { type: []const u8 = "" };
    const p = std.json.parseFromSliceLeaky(P, arena, body, .{ .ignore_unknown_fields = true }) catch return "";
    if (p.type.len == 0) return "";
    const short = p.type[(std.mem.lastIndexOfScalar(u8, p.type, ':') orelse return "") + 1 ..];
    return std.fmt.allocPrint(arena, " ({s})", .{short}) catch "";
}

fn list_of(v: ?[]const types.Address) []const k.Address {
    return v orelse &.{};
}

/// A message as the list keeps it.
pub fn message(arena: std.mem.Allocator, account_id: []const u8, e: anytype) !k.Message {
    var boxes: std.ArrayList([]const u8) = .empty;
    var it = e.mailboxIds.map.iterator();
    while (it.next()) |b| if (b.value_ptr.*) try boxes.append(arena, b.key_ptr.*);
    return .{
        .account_id = account_id,
        .id = e.id,
        .thread_id = e.threadId,
        .mailbox_ids = boxes.items,
        .flags = k.Flags.of(e.keywords),
        .from = list_of(e.from),
        .to = list_of(e.to),
        .cc = list_of(e.cc),
        .subject = e.subject orelse "",
        .preview = std.mem.trim(u8, e.preview orelse "", " \r\n\t"),
        .received = dates.parse(e.receivedAt orelse "") orelse 0,
        .has_attachment = e.hasAttachment,
        .size = e.size,
    };
}

/// The part a `cid:` picture names, among the message's.
fn byCid(e: types.EmailFull, src: []const u8) ?types.BodyPart {
    const cid = std.mem.trim(u8, src["cid:".len..], "<> ");
    for (e.attachments) |p| if (p.cid) |pc| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, pc, "<> "), cid)) return p;
    };
    return null;
}

/// A message as the reader shows it: its text from the plain parts, or
/// from the HTML where there are none, with its links and pictures.
pub fn full(arena: std.mem.Allocator, account_id: []const u8, e: types.EmailFull) !k.Detail {
    var text: std.ArrayList(u8) = .empty;
    var links: std.ArrayList(k.Link) = .empty;
    var pictures: std.ArrayList(k.Picture) = .empty;
    var remote = false;
    var plain = false;
    var had_html = false;
    for (e.textBody) |p| {
        const pid = p.partId orelse continue;
        const v = e.bodyValues.map.get(pid) orelse continue;
        if (text.items.len > 0) try text.appendSlice(arena, "\n\n");
        const base: u32 = @intCast(text.items.len);
        if (std.ascii.eqlIgnoreCase(p.type, "text/html")) {
            had_html = true;
            const conv = try html.convert(arena, v.value);
            try text.appendSlice(arena, conv.text);
            for (conv.links) |l| try links.append(arena, .{ .start = base + l.start, .end = base + l.end, .url = l.url });
            for (conv.images) |img| {
                var pic: k.Picture = .{ .alt = img.alt, .width = img.width, .height = img.height };
                if (std.ascii.startsWithIgnoreCase(img.src, "cid:")) {
                    if (byCid(e, img.src)) |part| {
                        pic.account_id = account_id;
                        pic.blob_id = part.blobId;
                        pic.type = part.type;
                    }
                } else if (std.ascii.startsWithIgnoreCase(img.src, "https://") or std.ascii.startsWithIgnoreCase(img.src, "http://")) {
                    pic.url = img.src;
                    remote = true;
                }
                // One for each mark, shown or not.
                try pictures.append(arena, pic);
            }
        } else if (std.mem.startsWith(u8, p.type, "text/")) {
            plain = true;
            // A plain text's own U+FFFC isn't a picture of ours.
            const t = try std.mem.replaceOwned(u8, arena, std.mem.trimEnd(u8, v.value, " \r\n"), html.image_mark, "\u{FFFD}");
            try text.appendSlice(arena, t);
        }
    }
    try @import("../mail/links.zig").detect(arena, text.items, &links);
    var html_src: std.ArrayList(u8) = .empty;
    for (e.htmlBody) |p| {
        if (!std.ascii.eqlIgnoreCase(p.type, "text/html")) continue;
        const v = e.bodyValues.map.get(p.partId orelse continue) orelse continue;
        try html_src.appendSlice(arena, v.value);
    }
    var atts: std.ArrayList(k.Attachment) = .empty;
    for (e.attachments) |p| {
        const blob = p.blobId orelse continue;
        // Pictures inside HTML aren't attachments to a reader of text.
        const inline_image = p.cid != null and std.mem.startsWith(u8, p.type, "image/") and (p.disposition == null or std.ascii.eqlIgnoreCase(p.disposition.?, "inline"));
        if (inline_image and p.name == null) continue;
        try atts.append(arena, .{ .account_id = account_id, .blob_id = blob, .name = p.name orelse "attachment", .type = if (p.type.len > 0) p.type else "application/octet-stream", .size = p.size });
    }
    const msg = try message(arena, account_id, e);
    return .{
        .message = msg,
        .bcc = list_of(e.bcc),
        .reply_to = list_of(e.replyTo),
        .sent = dates.parse(e.sentAt orelse "") orelse 0,
        .text = text.items,
        .html = if (html_src.items.len > 0) html_src.items else null,
        .from_html = had_html and !plain,
        .attachments = atts.items,
        .links = links.items,
        .pictures = pictures.items,
        .remote_pictures = remote,
        .message_id = if (e.messageId) |ids| (if (ids.len > 0) ids[0] else null) else null,
        .in_reply_to = if (e.inReplyTo) |ids| (if (ids.len > 0) ids[0] else null) else null,
        .references = e.references orelse &.{},
    };
}
