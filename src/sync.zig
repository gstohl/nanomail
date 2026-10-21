//! The sync thread: it owns the JMAP client and does the model's jobs in
//! order, answering each with an event that runs on the main thread
//! (`App.onMain`). A second thread listens for push (EventSource) and says
//! when the server changed, a few at a time.
const std = @import("std");
const Io = std.Io;
const nanoui = @import("nanoui");
const k = @import("mail/kinds.zig");
const copy = @import("copy.zig");
const jmap = @import("jmap/client.zig");
const Http = @import("jmap/http.zig").Http;
const eventStream = @import("jmap/http.zig").eventStream;
const apple = @import("jmap/http_apple.zig");

/// How HTTP is done: std.http on the Mac; NSURLSession on iOS, where
/// std.http has no certificates to trust.
pub const Net = if (ios_target) apple.AppleHttp else Http;
const ios_target = @import("builtin").os.tag == .ios;

pub fn newNet(gpa: std.mem.Allocator, io: Io) Net {
    return if (ios_target) apple.AppleHttp.init() else Http.init(gpa, io);
}
const session_mod = @import("jmap/session.zig");
const oauth = @import("jmap/oauth.zig");
const Loopback = @import("jmap/loopback.zig").Loopback;
const pictures = @import("sync_pictures.zig");
const ios = @import("builtin").os.tag == .ios;
const ios_auth = @import("ios_auth.zig");

/// Where events go, on the main thread: the model, then a redraw. Each
/// carries the session it was made in (`Job.session`).
pub const Sink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, arena: std.heap.ArenaAllocator, session: u64, ev: k.Event) void,
};

const Queued = struct { arena: std.heap.ArenaAllocator, job: k.Job };

pub const Sync = struct {
    gpa: std.mem.Allocator,
    io: Io,
    sink: Sink,
    /// Where attachments are saved.
    downloads: []const u8,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(Queued) = .empty,
    stopping: bool = false,
    worker: ?std.Thread = null,

    // The worker's own.
    http: Net,
    client: jmap.Client,
    /// The session the worker is in (set by the worker, read by push).
    session: std.atomic.Value(u64) = .init(0),

    // Push: what to listen to (under `mutex`), changed when signing in or
    // out (`push_gen`, with `push_cond` broadcast).
    push_url: ?[]u8 = null,
    push_auth: ?[]u8 = null,
    push_gen: u64 = 0,
    push_cond: Io.Condition = .init,
    pusher: ?std.Thread = null,
    /// A stream is open: the server tells of changes, ours included.
    push_alive: std.atomic.Value(bool) = .init(false),
    /// The access token push last took (the client renews them).
    push_auth_gen: u32 = 0,

    /// Pictures in mail: their own queue and thread (sync_pictures.zig).
    pics: pictures.Queue = .{},

    /// Signing in through the browser: given up on (under `mutex`).
    browser_cancel: bool = false,
    browser_cond: Io.Condition = .init,
    /// iOS: the redirect the sign-in sheet handed back (gpa's).
    browser_result: ?[]u8 = null,
    changed_pending: std.atomic.Value(bool) = .init(false),

    pub fn create(gpa: std.mem.Allocator, io: Io, sink: Sink, downloads: []const u8) !*Sync {
        const s = try gpa.create(Sync);
        s.* = .{ .gpa = gpa, .io = io, .sink = sink, .downloads = downloads, .http = newNet(gpa, io), .client = undefined };
        s.client = .init(gpa, s.http.transport());
        s.worker = try std.Thread.spawn(.{}, run, .{s});
        return s;
    }

    /// Asks the threads to stop; they finish what they're doing. The app
    /// is ending: what they hold goes with the process.
    pub fn stop(s: *Sync) void {
        s.mutex.lockUncancelable(s.io);
        s.stopping = true;
        s.cond.broadcast(s.io);
        s.push_cond.broadcast(s.io);
        s.browser_cond.broadcast(s.io);
        s.pics.cond.broadcast(s.io);
        s.mutex.unlock(s.io);
    }

    pub fn backend(s: *Sync) @import("model.zig").Backend {
        return .{ .ctx = s, .submit = submit, .cancel = cancelBrowser };
    }

    /// From the main thread (iOS): the sign-in sheet came back with `url`.
    pub fn browserReturned(s: *Sync, url: []const u8) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.browser_result) |old| s.gpa.free(old);
        s.browser_result = s.gpa.dupe(u8, url) catch null;
        s.browser_cond.broadcast(s.io);
    }

    /// From the main thread: stop waiting for the browser.
    fn cancelBrowser(ctx: *anyopaque) void {
        const s: *Sync = @ptrCast(@alignCast(ctx));
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.browser_cancel = true;
        s.browser_cond.broadcast(s.io);
    }

    /// From the main thread: queues a copy of `job`. A newer list or
    /// message replaces one still waiting: only the latest matters.
    fn submit(ctx: *anyopaque, job: k.Job) void {
        const s: *Sync = @ptrCast(@alignCast(ctx));
        if (job == .picture) return pictures.submit(s, job.picture);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        const owned = copy.deep(k.Job, arena.allocator(), job) catch {
            arena.deinit();
            return;
        };
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var i: usize = 0;
        while (i < s.queue.items.len) {
            const q = s.queue.items[i].job;
            const stale = switch (owned) {
                .detail => q == .detail,
                .list => |l| q == .list and l.position == 0,
                .mailboxes => q == .mailboxes,
                else => false,
            };
            if (stale) {
                var old = s.queue.orderedRemove(i);
                old.arena.deinit();
            } else i += 1;
        }
        s.queue.append(s.gpa, .{ .arena = arena, .job = owned }) catch {
            arena.deinit();
            return;
        };
        s.cond.signal(s.io);
    }

    fn run(s: *Sync) void {
        while (true) {
            s.mutex.lockUncancelable(s.io);
            while (s.queue.items.len == 0 and !s.stopping) s.cond.waitUncancelable(s.io, &s.mutex);
            if (s.stopping) {
                s.mutex.unlock(s.io);
                return;
            }
            var q = s.queue.orderedRemove(0);
            s.mutex.unlock(s.io);
            s.work(q.job);
            q.arena.deinit();
        }
    }

    /// Sends `ev` (made in `arena`, which goes with it) to the main thread.
    pub fn post(s: *Sync, arena: std.heap.ArenaAllocator, ev: k.Event) void {
        const Envelope = struct {
            s: *Sync,
            arena: std.heap.ArenaAllocator,
            session: u64,
            ev: k.Event,
            fn deliver(ctx: ?*anyopaque) callconv(.c) void {
                const e: *@This() = @ptrCast(@alignCast(ctx));
                const sync = e.s;
                const a = e.arena;
                const session = e.session;
                const ev_ = e.ev;
                sync.gpa.destroy(e);
                sync.sink.func(sync.sink.ctx, a, session, ev_);
            }
        };
        const e = s.gpa.create(Envelope) catch {
            var a = arena;
            a.deinit();
            return;
        };
        e.* = .{ .s = s, .arena = arena, .session = s.session.load(.acquire), .ev = ev };
        nanoui.App.onMain(e, Envelope.deliver);
    }

    /// The client's account of what went wrong, in `a`.
    fn why(s: *Sync, a: std.mem.Allocator, e: anyerror) []const u8 {
        if (s.client.problem.len > 0) return a.dupe(u8, s.client.problem) catch "";
        return std.fmt.allocPrint(a, "{t}", .{e}) catch "";
    }

    fn work(s: *Sync, job: k.Job) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        const a = arena.allocator();
        s.client.problem = "";
        const ev: k.Event = switch (job) {
            .connect => |acc| blk: {
                s.client.connect(acc) catch |e| break :blk .{ .connect_failed = .{ .message = s.why(a, e), .unauthorized = e == error.Unauthorized } };
                break :blk s.connected(a, acc.username, null);
            },
            .oauth => |o| s.browserSignIn(a, o.server, o.username, o.client_id),
            .session => |n| {
                s.session.store(n, .release);
                arena.deinit();
                return;
            },
            .picture => unreachable, // the picture queue's (submit)
            .sign_out => {
                s.client.session = null;
                s.setPush(null, null);
                arena.deinit();
                return;
            },
            .mailboxes => blk: {
                const f = s.client.folders(a) catch |e| break :blk .{ .failed = .{ .what = "Couldn't load the folders", .message = s.why(a, e), .refresh = false } };
                break :blk .{ .folders = f };
            },
            .list => |l| blk: {
                // What the messages keep must be the event's (the job's goes).
                const acct = a.dupe(u8, l.account_id) catch "";
                const page = s.client.list(a, acct, l.mailbox_id, l.query, l.position, l.limit) catch |e| break :blk .{ .list_failed = .{ .gen = l.gen, .message = s.why(a, e) } };
                break :blk .{ .list = .{
                    .mailbox_id = a.dupe(u8, l.mailbox_id) catch "",
                    .query = a.dupe(u8, l.query) catch "",
                    .position = l.position,
                    .total = page.total,
                    .messages = page.messages,
                    .gen = l.gen,
                } };
            },
            .detail => |d| blk: {
                const acct = a.dupe(u8, d.account_id) catch "";
                const got = s.client.detail(a, acct, d.id) catch |e| break :blk .{ .detail_failed = .{ .id = a.dupe(u8, d.id) catch "", .message = s.why(a, e) } };
                break :blk .{ .detail = got };
            },
            .keyword => |kw| blk: {
                s.client.setKeyword(a, kw.account_id, kw.ids, kw.keyword, kw.on) catch |e| break :blk .{ .failed = .{ .what = "Couldn't change the message", .message = s.why(a, e) } };
                break :blk .changed;
            },
            .move => |mv| blk: {
                s.client.move(a, mv.account_id, mv.ids, mv.from, mv.to) catch |e| break :blk .{ .failed = .{ .what = "Couldn't move the message", .message = s.why(a, e) } };
                break :blk .changed;
            },
            .destroy => |d| blk: {
                s.client.destroy(a, d.account_id, d.ids) catch |e| break :blk .{ .failed = .{ .what = "Couldn't delete the message", .message = s.why(a, e) } };
                break :blk .changed;
            },
            .send => |out| blk: {
                s.client.send(a, out) catch |e| break :blk .{ .send_failed = .{ .compose = out.compose, .message = s.why(a, e), .draft = s.client.last_draft } };
                break :blk .{ .sent = .{ .compose = out.compose, .draft_only = out.draft_only } };
            },
            .download => |d| blk: {
                const bytes = s.client.download(a, d.account_id, d.blob_id, d.name, d.type) catch |e| break :blk .{ .failed = .{ .what = "Couldn't download it", .message = s.why(a, e), .refresh = false } };
                const path = s.save(a, d.name, bytes) catch |e| break :blk .{ .failed = .{ .what = "Couldn't save it", .message = s.why(a, e), .refresh = false } };
                break :blk .{ .downloaded = .{ .path = path } };
            },
        };
        s.tokensChanged();
        // Our own changes come back by push, while there is push.
        if (ev == .changed and s.push_alive.load(.acquire)) {
            arena.deinit();
            return;
        }
        s.post(arena, ev);
    }

    /// Signed in: who, with what identities, and push started.
    fn connected(s: *Sync, a: std.mem.Allocator, username: []const u8, keep: ?k.Account) k.Event {
        const ses = s.client.session.?;
        const ids = s.client.identities(a) catch &.{};
        s.listen(ses);
        pictures.setMedia(s, ses.download_url, ses.account_id, s.client.auth);
        return .{ .connected = .{
            .username = a.dupe(u8, if (ses.username.len > 0) ses.username else username) catch "",
            .account_id = a.dupe(u8, ses.account_id) catch "",
            .accounts = copy.deep([]const k.MailAccount, a, ses.accounts) catch &.{},
            .identities = ids,
            .can_send = ses.can_send and ids.len > 0,
            .session_url = a.dupe(u8, s.client.session_url) catch "",
            .save = keep,
        } };
    }

    /// The client renewed its access token: push takes it; and a new
    /// refresh token goes to the keychain.
    fn tokensChanged(s: *Sync) void {
        if (s.client.auth_gen != s.push_auth_gen) {
            s.push_auth_gen = s.client.auth_gen;
            if (s.gpa.dupe(u8, s.client.auth)) |auth| {
                s.mutex.lockUncancelable(s.io);
                defer s.mutex.unlock(s.io);
                if (s.push_auth) |old| s.gpa.free(old);
                // The stream open keeps going; the next one uses this.
                s.push_auth = auth;
            } else |_| {}
            if (s.client.session) |ses| pictures.setMedia(s, ses.download_url, ses.account_id, s.client.auth);
        }
        const r = s.client.rotated orelse return;
        s.client.rotated = null;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        const token = arena.allocator().dupe(u8, r) catch return arena.deinit();
        s.post(arena, .{ .tokens = .{ .refresh_token = token } });
    }

    /// Signs in through the browser: finds the server's sign-in, has the
    /// main thread open it, waits for the browser to come back to a
    /// loopback address, trades the code for tokens, and connects.
    fn browserSignIn(s: *Sync, a: std.mem.Allocator, server: []const u8, username: []const u8, client_id_in: []const u8) k.Event {
        const t = s.http.transport();
        const fail = struct {
            fn f(al: std.mem.Allocator, comptime fmt: []const u8, args: anytype) k.Event {
                return .{ .connect_failed = .{ .message = std.fmt.allocPrint(al, fmt, args) catch "", .unauthorized = true } };
            }
        }.f;
        oauth.problem = "";
        const start = session_mod.discoveryUrl(a, server, username) catch return fail(a, "Enter the server's address, or an email address with a domain.", .{});
        const session_url = oauth.findSession(a, t, start) catch |e| return fail(a, "Couldn't reach {s} ({t}).", .{ session_mod.host(start), e });
        const md = oauth.discover(a, t, session_url) catch return fail(a, "{s} doesn't offer signing in through the browser. Use a password or an API token.", .{session_mod.host(session_url)});
        // The Mac's browser comes back to a loopback address; iOS's sheet
        // to nanomail's own scheme.
        var lb: ?Loopback = if (ios) null else Loopback.open(s.io) catch |e| return fail(a, "Couldn't listen for the browser ({t}).", .{e});
        defer if (lb) |*l| l.close(s.io);
        const redirect = if (lb) |*l| l.redirectUri(a) catch return fail(a, "Out of memory.", .{}) else ios_auth.redirect_uri;
        const client_id = if (client_id_in.len > 0) client_id_in else if (md.registration_endpoint) |ep|
            oauth.register(a, t, ep, redirect) catch return fail(a, "The server wouldn't register nanomail. Enter a client ID for it.", .{})
        else
            return fail(a, "This server needs a client ID for nanomail: it doesn't let apps register themselves.", .{});
        const p = oauth.Pkce.make(s.io);
        const scope = oauth.scopes(a, md) catch "";
        const url = oauth.authorizationUrl(a, md, client_id, redirect, &p, scope, username) catch return fail(a, "Out of memory.", .{});
        {
            var arena: std.heap.ArenaAllocator = .init(s.gpa);
            const owned = arena.allocator().dupe(u8, url) catch "";
            s.post(arena, .{ .browser = .{ .url = owned } });
        }
        const target = s.waitBrowser(if (lb) |*l| l else null, a) catch |e| return switch (e) {
            error.Timeout => fail(a, "The browser didn't come back in time. Try again.", .{}),
            else => fail(a, "Signing in was stopped.", .{}),
        };
        const cb = oauth.parseCallback(a, target) catch return fail(a, "The browser's answer couldn't be read.", .{});
        const code = oauth.checkCallback(cb, &p, md) catch |e| return switch (e) {
            error.AccessDenied, error.AuthorizationFailed => fail(a, "{s}", .{oauth.problem}),
            else => fail(a, "The browser's answer wasn't for this sign-in ({t}).", .{e}),
        };
        const tok = oauth.exchange(a, t, md, client_id, code, redirect, &p) catch |e|
            return fail(a, "The server didn't hand out a token: {s}", .{if (oauth.problem.len > 0) oauth.problem else @errorName(e)});
        const account: k.Account = .{
            .server = session_url,
            .username = username,
            .secret = tok.refresh_token orelse "",
            .token = true,
            .oauth = .{ .client_id = client_id, .token_endpoint = md.token_endpoint },
        };
        s.client.connectWith(account, tok) catch |e| return .{ .connect_failed = .{ .message = s.why(a, e), .unauthorized = true } };
        // Without a refresh token there's nothing to keep: next time, the
        // browser again.
        return s.connected(a, username, if (tok.refresh_token != null) account else null);
    }

    /// The browser's request to the loopback address; given up on when
    /// canceled, or after ten minutes.
    fn waitBrowser(s: *Sync, lb_in: ?*Loopback, a: std.mem.Allocator) ![]const u8 {
        s.mutex.lockUncancelable(s.io);
        s.browser_cancel = false;
        if (s.browser_result) |old| s.gpa.free(old);
        s.browser_result = null;
        s.mutex.unlock(s.io);
        const lb = lb_in orelse return s.waitResult(a, 600);
        const U = union(enum) { got: anyerror![]const u8, stop: Io.Cancelable!Wake };
        var buf: [2]U = undefined;
        var sel: Io.Select(U) = .init(s.io, &buf);
        defer sel.cancelDiscard();
        try sel.concurrent(.got, Loopback.wait, .{ lb, s.io, a });
        try sel.concurrent(.stop, waitCancel, .{ s, 600 });
        return switch (try sel.await()) {
            .got => |r| r,
            .stop => |w| if ((w catch .changed) == .timeout) error.Timeout else error.Canceled,
        };
    }

    /// iOS: the redirect the sheet hands back (`browserReturned`).
    fn waitResult(s: *Sync, a: std.mem.Allocator, seconds: i64) ![]const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } }).toDeadline(s.io);
        while (s.browser_result == null and !s.browser_cancel and !s.stopping) {
            s.browser_cond.waitTimeout(s.io, &s.mutex, deadline) catch |e| switch (e) {
                error.Timeout => return error.Timeout,
                error.Canceled => return error.Canceled,
            };
        }
        const r = s.browser_result orelse return error.Canceled;
        defer {
            s.gpa.free(r);
            s.browser_result = null;
        }
        return a.dupe(u8, r);
    }

    fn waitCancel(s: *Sync, seconds: i64) Io.Cancelable!Wake {
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } }).toDeadline(s.io);
        while (!s.browser_cancel and !s.stopping) {
            s.browser_cond.waitTimeout(s.io, &s.mutex, deadline) catch |e| switch (e) {
                error.Timeout => return .timeout,
                error.Canceled => |c| return c,
            };
        }
        return .changed;
    }

    /// Writes an attachment to the downloads folder under a name not
    /// taken yet ("notes.pdf", "notes 2.pdf", …).
    fn save(s: *Sync, a: std.mem.Allocator, name_in: []const u8, bytes: []const u8) ![]const u8 {
        var name = std.fs.path.basename(name_in);
        if (name.len == 0 or name[0] == '.') name = "attachment";
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
        var n: u32 = 1;
        while (n < 1000) : (n += 1) {
            const file = if (n == 1) name else try std.fmt.allocPrint(a, "{s} {d}{s}", .{ name[0..dot], n, name[dot..] });
            const path = try std.fs.path.join(a, &.{ s.downloads, file });
            Io.Dir.cwd().access(s.io, path, .{}) catch {
                try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = bytes });
                return path;
            };
        }
        return error.PathAlreadyExists;
    }

    // Push.

    /// What the push thread listens to (null: nothing); the stream it has
    /// open, if any, is dropped at once.
    fn setPush(s: *Sync, url: ?[]u8, auth: ?[]u8) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.push_url) |old| s.gpa.free(old);
        if (s.push_auth) |old| s.gpa.free(old);
        s.push_url = url;
        s.push_auth = auth;
        s.push_gen += 1;
        s.push_cond.broadcast(s.io);
    }

    /// Listens to the session's event source, if it has one.
    fn listen(s: *Sync, ses: session_mod.Session) void {
        const tmpl = ses.event_source_url orelse return s.setPush(null, null);
        const url = fill(s.gpa, tmpl) catch return;
        const auth = s.gpa.dupe(u8, s.client.auth) catch {
            s.gpa.free(url);
            return;
        };
        s.push_auth_gen = s.client.auth_gen;
        s.setPush(url, auth);
        if (s.pusher == null) s.pusher = std.Thread.spawn(.{}, pushLoop, .{s}) catch null;
    }

    /// The event source's URL for every type, kept open, pinged.
    fn fill(gpa: std.mem.Allocator, tmpl: []const u8) ![]u8 {
        const a = try std.mem.replaceOwned(u8, gpa, tmpl, "{types}", "*");
        defer gpa.free(a);
        const b = try std.mem.replaceOwned(u8, gpa, a, "{closeafter}", "no");
        defer gpa.free(b);
        return std.mem.replaceOwned(u8, gpa, b, "{ping}", "60");
    }

    const Wake = enum { changed, timeout };

    /// Waits until what to listen to changes, or `seconds` pass.
    fn waitChange(s: *Sync, gen: u64, seconds: i64) Io.Cancelable!Wake {
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } }).toDeadline(s.io);
        while (s.push_gen == gen and !s.stopping) {
            s.push_cond.waitTimeout(s.io, &s.mutex, deadline) catch |e| switch (e) {
                error.Timeout => return .timeout,
                error.Canceled => |c| return c,
            };
        }
        return .changed;
    }

    fn pushLoop(s: *Sync) void {
        var client: std.http.Client = .{ .allocator = s.gpa, .io = s.io };
        // iOS: NSURLSession's stream, stopped with its own cancel.
        var stream = apple.EventStream.init(s.gpa);
        var backoff: i64 = 2;
        while (true) {
            s.mutex.lockUncancelable(s.io);
            const stopping = s.stopping;
            const gen = s.push_gen;
            const url = if (s.push_url) |u| s.gpa.dupe(u8, u) catch null else null;
            const auth = if (s.push_auth) |u| s.gpa.dupe(u8, u) catch null else null;
            s.mutex.unlock(s.io);
            if (stopping) return;
            defer if (url) |u| s.gpa.free(u);
            defer if (auth) |u| s.gpa.free(u);
            if (url == null or auth == null) {
                _ = s.waitChange(gen, 3600) catch {};
                continue;
            }
            // A stream can die without a word: a new one every few minutes,
            // catching up on what may have been missed. A change of account
            // drops it at once.
            const U = union(enum) { stream: anyerror!void, wake: Io.Cancelable!Wake };
            var buf: [2]U = undefined;
            var sel: Io.Select(U) = .init(s.io, &buf);
            const started = Io.Clock.awake.now(s.io);
            const listener: @import("jmap/http.zig").Listener = .{ .ctx = s, .open = opened, .state = changed };
            const first: ?U = blk: {
                if (ios_target) {
                    sel.concurrent(.stream, apple.EventStream.run, .{ &stream, url.?, auth.?, listener }) catch break :blk null;
                } else sel.concurrent(.stream, eventStream, .{ &client, url.?, auth.?, listener }) catch break :blk null;
                sel.concurrent(.wake, waitChange, .{ s, gen, 240 }) catch break :blk null;
                break :blk sel.await() catch null;
            };
            // NSURLSession's stream isn't stopped by Io's cancel: by its own
            // (only while it runs: a cancel stops the next run otherwise).
            if (ios_target) if (first == null or first.? != .stream) stream.cancel();
            sel.cancelDiscard();
            s.push_alive.store(false, .release);
            client.now = null;
            const lasted = started.durationTo(Io.Clock.awake.now(s.io)).toSeconds();
            if (first) |f| if (f == .wake) {
                const w = f.wake catch .changed;
                if (w == .timeout) changed(s);
                backoff = 2;
                continue;
            };
            // The stream ended. One that ran a while is opened again at
            // once; one that keeps failing, less and less often.
            if (lasted > 30) {
                backoff = 2;
                changed(s);
                continue;
            }
            _ = s.waitChange(gen, backoff) catch {};
            backoff = @min(backoff * 2, 300);
        }
    }

    fn opened(ctx: *anyopaque) void {
        const s: *Sync = @ptrCast(@alignCast(ctx));
        s.push_alive.store(true, .release);
    }

    /// From the push thread: the server changed. Changes in a burst are
    /// told once, shortly after the first.
    fn changed(ctx: *anyopaque) void {
        const s: *Sync = @ptrCast(@alignCast(ctx));
        if (s.changed_pending.swap(true, .acq_rel)) return;
        nanoui.App.after(300, s, fireChanged);
    }

    fn fireChanged(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Sync = @ptrCast(@alignCast(ctx));
        s.changed_pending.store(false, .release);
        s.sink.func(s.sink.ctx, .init(s.gpa), s.session.load(.acquire), .changed);
    }
};
