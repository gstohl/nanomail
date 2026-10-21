//! What's done to messages: opening them, moving through the list,
//! marking, flagging, moving, deleting, downloading. Each changes the
//! model at once and asks the server to follow.
const std = @import("std");
const k = @import("mail/kinds.zig");
const Model = @import("model.zig").Model;


pub fn indexOf(m: *const Model, id: []const u8) ?usize {
    for (m.messages.items, 0..) |msg, i| if (std.mem.eql(u8, msg.id, id)) return i;
    return null;
}

pub fn selectedIndex(m: *const Model) ?usize {
    return if (m.selected) |id| m.indexOf(id) else null;
}

pub fn selectedMessage(m: *Model) ?*k.Message {
    const i = m.selectedIndex() orelse return null;
    return &m.messages.items[i];
}

/// Opens the message at `i`: fetched unless cached, and marked read.
pub fn select(m: *Model, i: usize) void {
    if (i >= m.messages.items.len) return;
    const msg = &m.messages.items[i];
    m.setOwned(&m.selected, msg.id);
    m.reveal = true;
    if (m.detail(msg.account_id, msg.id) == null) m.fetchDetail(msg.account_id, msg.id);
    // A share that won't take $seen stays as it is.
    if (!msg.flags.seen and !msg.flags.draft and m.rights().seen) m.setKeyword(i, .seen, true);
    if (i + 8 >= m.messages.items.len) m.loadMore();
}

/// Fetches a message for the reader (again, after a failure).
pub fn fetchDetail(m: *Model, account: []const u8, id: []const u8) void {
    m.setOwned(&m.detail_error_id, null);
    m.submit(.{ .detail = .{ .account_id = account, .id = id } });
}

/// Why the message `id` couldn't be fetched, if it couldn't.
pub fn detailError(m: *const Model, id: []const u8) ?[]const u8 {
    const e = m.detail_error_id orelse return null;
    return if (std.mem.eql(u8, e, id)) m.detail_error else null;
}

/// The next (1) or previous (-1) message.
pub fn step(m: *Model, dir: i2) void {
    const n = m.messages.items.len;
    if (n == 0) return;
    const i = m.selectedIndex() orelse return m.select(0);
    if (dir > 0 and i + 1 < n) m.select(i + 1);
    if (dir < 0 and i > 0) m.select(i - 1);
}

/// Sets or clears a keyword on the message at `i`, at once here and
/// then on the server.
pub fn setKeyword(m: *Model, i: usize, kw: k.Keyword, on: bool) void {
    const msg = &m.messages.items[i];
    const r = m.rights();
    if ((kw == .seen and !r.seen) or (kw != .seen and !r.keywords)) return readOnly(m);
    switch (kw) {
        .seen => {
            if (msg.flags.seen == on) return;
            msg.flags.seen = on;
            countUnread(m, msg.*, if (on) -1 else 1);
        },
        .flagged => msg.flags.flagged = on,
        .answered => msg.flags.answered = on,
        .forwarded => msg.flags.forwarded = on,
    }
    m.submit(.{ .keyword = .{ .account_id = msg.account_id, .ids = &.{msg.id}, .keyword = kw, .on = on } });
}

/// A shared folder that won't take the change: said so, not tried.
fn readOnly(m: *Model) void {
    m.notify(.warning, "This folder is shared read-only", "Its owner hasn't let you change its messages.", 4);
}

fn countUnread(m: *Model, msg: k.Message, delta: i32) void {
    for (m.folders) |*f| if (std.mem.eql(u8, f.account_id, msg.account_id) and msg.inMailbox(f.id)) {
        const mf: *k.Folder = @constCast(f);
        mf.unread = @intCast(@max(0, @as(i64, mf.unread) + delta));
    };
}

pub fn toggleSeen(m: *Model) void {
    const i = m.selectedIndex() orelse return;
    m.setKeyword(i, .seen, !m.messages.items[i].flags.seen);
}

pub fn toggleFlag(m: *Model) void {
    const i = m.selectedIndex() orelse return;
    m.setKeyword(i, .flagged, !m.messages.items[i].flags.flagged);
}

/// Moves the selection to the folder `to`; the next message opens.
pub fn moveSelected(m: *Model, to: []const u8) void {
    const i = m.selectedIndex() orelse return;
    const msg = m.messages.items[i];
    if (msg.inMailbox(to)) return;
    if (!m.rights().remove) return readOnly(m);
    const from = m.mailbox;
    m.submit(.{ .move = .{ .account_id = msg.account_id, .ids = &.{msg.id}, .from = from, .to = to } });
    if (!msg.flags.seen) countUnread(m, msg, -1);
    removeAt(m, i);
    if (m.folder(msg.account_id, to)) |f| if (!msg.flags.seen) {
        @constCast(f).unread += 1;
    };
}

pub fn archive(m: *Model) void {
    const msg = m.selectedMessage() orelse return;
    const f = m.folderByRoleIn(msg.account_id, .archive) orelse {
        m.toaster.push(.{ .status = .warning, .title = "No Archive folder", .message = "This account has no folder with the archive role.", .duration = 4 });
        return;
    };
    m.moveSelected(f.id);
}

/// To the trash; in the trash, asks, then deletes for good.
pub fn trash(m: *Model) void {
    const msg = m.selectedMessage() orelse return;
    if (!m.rights().remove) return readOnly(m);
    // The trash of the message's own account (a share may have none: then
    // it's deleted, after asking).
    const t = m.folderByRoleIn(msg.account_id, .trash);
    const in_trash = if (t) |f| m.isOpen(f.account_id, f.id) else true;
    if (in_trash) {
        m.setOwned(&m.destroy_id, m.selected);
        m.confirm_destroy = true;
        return;
    }
    m.moveSelected(t.?.id);
}

/// Deletes for good the message the question was about.
pub fn destroySelected(m: *Model) void {
    const id = m.destroy_id orelse return;
    defer m.setOwned(&m.destroy_id, null);
    const i = m.indexOf(id) orelse return;
    const msg = m.messages.items[i];
    // Filed in another folder too: out of the trash, kept there.
    for (msg.mailbox_ids) |b| if (m.mailbox == null or !std.mem.eql(u8, b, m.mailbox.?)) {
        m.submit(.{ .move = .{ .account_id = msg.account_id, .ids = &.{msg.id}, .from = m.mailbox, .to = b } });
        return removeAt(m, i);
    };
    m.submit(.{ .destroy = .{ .account_id = msg.account_id, .ids = &.{msg.id} } });
    removeAt(m, i);
}

fn removeAt(m: *Model, i: usize) void {
    _ = m.messages.orderedRemove(i);
    m.total -|= 1;
    m.setOwned(&m.selected, null);
    if (m.messages.items.len > 0) m.select(@min(i, m.messages.items.len - 1));
}

/// A link in a message: an address opens a new message to it, the rest
/// the browser.
pub fn openLink(m: *Model, url: []const u8) void {
    if (std.ascii.startsWithIgnoreCase(url, "mailto:")) {
        const rest = url["mailto:".len..];
        const q = std.mem.indexOfScalar(u8, rest, '?') orelse rest.len;
        var subject: []const u8 = "";
        if (q < rest.len) {
            var params = std.mem.splitScalar(u8, rest[q + 1 ..], '&');
            while (params.next()) |kv| if (std.ascii.startsWithIgnoreCase(kv, "subject=")) {
                subject = kv["subject=".len..];
            };
        }
        m.compose(.new);
        if (m.composes.items.len > 0) m.composes.items[m.composes.items.len - 1].prefill(rest[0..q], subject);
        return;
    }
    if (m.host) |h| h.open_url(h.ctx, url);
}

pub fn download(m: *Model, a: k.Attachment) void {
    m.submit(.{ .download = .{ .account_id = a.account_id, .blob_id = a.blob_id, .name = a.name, .type = a.type } });
    m.toaster.push(.{ .title = "Downloading", .message = a.name, .duration = 2 });
}
