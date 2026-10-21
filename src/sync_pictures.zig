//! The sync thread's picture queue: pictures in mail fetched on a thread
//! of their own, so a slow one on the web never holds up the list. A
//! message's own pictures come from the server's download URL with the
//! account's credentials; those on the web, without any.
const std = @import("std");
const Io = std.Io;
const k = @import("mail/kinds.zig");
const copy = @import("copy.zig");
const sync_mod = @import("sync.zig");
const jmap = @import("jmap/client.zig");
const session_mod = @import("jmap/session.zig");
const Sync = @import("sync.zig").Sync;

pub const Job = @FieldType(k.Job, "picture");
const Queued = struct { arena: std.heap.ArenaAllocator, job: Job };

/// The pictures' share of `Sync` (under its mutex).
pub const Queue = struct {
    items: std.ArrayList(Queued) = .empty,
    cond: Io.Condition = .init,
    thread: ?std.Thread = null,
    /// Where a blob is downloaded, and with what (copies, gpa's).
    template: ?[]u8 = null,
    account: ?[]u8 = null,
    auth: ?[]u8 = null,
};

/// From the main thread: a picture to fetch.
pub fn submit(s: *Sync, job: Job) void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    const owned = copy.deep(Job, arena.allocator(), job) catch return arena.deinit();
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    s.pics.items.append(s.gpa, .{ .arena = arena, .job = owned }) catch return arena.deinit();
    if (s.pics.thread == null) s.pics.thread = std.Thread.spawn(.{}, loop, .{s}) catch null;
    s.pics.cond.signal(s.io);
}

/// After signing in, or new credentials: where and how to download.
pub fn setMedia(s: *Sync, template: []const u8, account: []const u8, auth: []const u8) void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    inline for (.{ "template", "account", "auth" }, .{ template, account, auth }) |field, v| {
        if (@field(s.pics, field)) |old| s.gpa.free(old);
        @field(s.pics, field) = s.gpa.dupe(u8, v) catch null;
    }
}

fn loop(s: *Sync) void {
    var http = sync_mod.newNet(s.gpa, s.io);
    http.timeout_ms = 30_000;
    http.max_body = 25 * 1024 * 1024;
    while (true) {
        s.mutex.lockUncancelable(s.io);
        while (s.pics.items.items.len == 0 and !s.stopping) s.pics.cond.waitUncancelable(s.io, &s.mutex);
        if (s.stopping) return s.mutex.unlock(s.io);
        var q = s.pics.items.orderedRemove(0);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        const a = arena.allocator();
        const template = if (s.pics.template) |t| a.dupe(u8, t) catch null else null;
        const account = if (s.pics.account) |t| a.dupe(u8, t) catch null else null;
        const auth = if (s.pics.auth) |t| a.dupe(u8, t) catch null else null;
        s.mutex.unlock(s.io);
        defer q.arena.deinit();
        const j = q.job;
        const bytes = if (j.blob_id) |blob| blk: {
            const acc = if (j.account_id.len > 0) j.account_id else account orelse break :blk null;
            const url = session_mod.downloadUrl(a, template orelse break :blk null, acc, blob, "picture", if (j.type.len > 0) j.type else "application/octet-stream") catch break :blk null;
            break :blk get(a, http.transport(), url, auth, 0);
        } else if (j.url) |url| get(a, http.transport(), url, null, 4) else null;
        const key = a.dupe(u8, j.key) catch "";
        s.post(arena, .{ .picture = .{ .key = key, .bytes = bytes } });
    }
}

/// The body at `url`, following up to `hops` redirects (on the web only:
/// credentials never follow one).
fn get(a: std.mem.Allocator, t: jmap.Transport, url_in: []const u8, auth: ?[]const u8, hops: u8) ?[]const u8 {
    var url = url_in;
    var left = hops;
    while (true) {
        const r = t.send(t.ctx, a, .{ .method = .GET, .url = url, .auth = auth, .accept = "image/*" }) catch return null;
        if (r.status == 200) return if (r.body.len > 0) r.body else null;
        if (r.status >= 300 and r.status < 400 and left > 0 and auth == null) {
            const next = session_mod.resolve(a, url, r.location orelse return null) catch return null;
            if (!std.ascii.startsWithIgnoreCase(next, "http://") and !std.ascii.startsWithIgnoreCase(next, "https://")) return null;
            url = next;
            left -= 1;
            continue;
        }
        return null;
    }
}
