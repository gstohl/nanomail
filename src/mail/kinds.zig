//! What the app knows of mail, apart from JMAP's wire format: folders,
//! messages as the list shows them, a message opened, and the jobs the
//! sync thread does and the events it answers with.
const std = @import("std");
const jmap = @import("../jmap/types.zig");
pub const Address = jmap.Address;
pub const Role = jmap.Role;

pub const Flags = packed struct(u8) {
    seen: bool = false,
    flagged: bool = false,
    answered: bool = false,
    draft: bool = false,
    forwarded: bool = false,
    _pad: u3 = 0,

    pub fn of(keywords: jmap.Set) Flags {
        const has = struct {
            fn f(k: jmap.Set, name: []const u8) bool {
                return k.map.get(name) orelse false;
            }
        }.f;
        return .{
            .seen = has(keywords, "$seen"),
            .flagged = has(keywords, "$flagged"),
            .answered = has(keywords, "$answered"),
            .draft = has(keywords, "$draft"),
            .forwarded = has(keywords, "$forwarded"),
        };
    }
};

pub const Keyword = enum {
    seen,
    flagged,
    answered,
    forwarded,

    pub fn name(k: Keyword) []const u8 {
        return switch (k) {
            .seen => "$seen",
            .flagged => "$flagged",
            .answered => "$answered",
            .forwarded => "$forwarded",
        };
    }
};

/// What the user may do with the messages in a folder (its `myRights`):
/// everything, in their own account.
pub const Rights = packed struct(u8) {
    read: bool = true,
    add: bool = true,
    remove: bool = true,
    seen: bool = true,
    keywords: bool = true,
    _pad: u3 = 0,
};

/// An account with mail: the user's own, or one shared with them.
pub const MailAccount = @import("../jmap/session.zig").MailAccount;

pub const Folder = struct {
    /// The account it's in (ids are only unique within one).
    account_id: []const u8 = "",
    id: []const u8,
    name: []const u8,
    parent_id: ?[]const u8 = null,
    role: Role = .other,
    sort_order: u32 = 0,
    total: u32 = 0,
    unread: u32 = 0,
    /// How deep it is in the tree, for the sidebar's indent.
    depth: u8 = 0,
    rights: Rights = .{},
};

pub const Message = struct {
    account_id: []const u8 = "",
    id: []const u8,
    thread_id: []const u8 = "",
    mailbox_ids: []const []const u8 = &.{},
    flags: Flags = .{},
    from: []const Address = &.{},
    to: []const Address = &.{},
    cc: []const Address = &.{},
    subject: []const u8 = "",
    preview: []const u8 = "",
    /// Unix seconds.
    received: i64 = 0,
    has_attachment: bool = false,
    size: u64 = 0,

    pub fn inMailbox(m: Message, id: []const u8) bool {
        for (m.mailbox_ids) |b| if (std.mem.eql(u8, b, id)) return true;
        return false;
    }

    pub fn sender(m: Message) []const u8 {
        return if (m.from.len > 0) m.from[0].display() else "(no sender)";
    }
};

pub const Attachment = struct {
    account_id: []const u8 = "",
    blob_id: []const u8,
    name: []const u8 = "attachment",
    type: []const u8 = "application/octet-stream",
    size: u64 = 0,
};

/// Bytes [start, end) of a message's text go to `url`.
pub const Link = @import("html.zig").Link;

/// A picture in a message: one of its parts (an HTML mail's `cid:`
/// picture, an image attachment), or one on the web.
pub const Picture = struct {
    /// The account a blob is in.
    account_id: []const u8 = "",
    blob_id: ?[]const u8 = null,
    url: ?[]const u8 = null,
    type: []const u8 = "",
    alt: []const u8 = "",
    /// As the HTML sized it, in points.
    width: ?u32 = null,
    height: ?u32 = null,

    /// What it's fetched and kept by.
    pub fn key(p: Picture) []const u8 {
        return p.blob_id orelse p.url orelse "";
    }
};

/// A message opened in the reader.
pub const Detail = struct {
    message: Message,
    bcc: []const Address = &.{},
    reply_to: []const Address = &.{},
    /// Sent, by the sender's clock (unix seconds); 0 when not given.
    sent: i64 = 0,
    /// The body as text (HTML read as text where there's no plain part).
    text: []const u8 = "",
    /// The HTML body as sent, when there is one (to open in a browser).
    html: ?[]const u8 = null,
    /// The body was HTML only.
    from_html: bool = false,
    attachments: []const Attachment = &.{},
    message_id: ?[]const u8 = null,
    in_reply_to: ?[]const u8 = null,
    references: []const []const u8 = &.{},
    /// What in `text` can be clicked.
    links: []const Link = &.{},
    /// The n-th U+FFFC line of `text` shows `pictures[n]`.
    pictures: []const Picture = &.{},
    /// Some pictures are on the web (shown only when asked: they tell the
    /// sender the mail was read).
    remote_pictures: bool = false,
};

pub const Identity = struct {
    /// The account it sends from (its Drafts and Sent are there).
    account_id: []const u8 = "",
    id: []const u8,
    name: []const u8 = "",
    email: []const u8 = "",
};

/// Signed in through the browser: whom to ask for new access tokens.
pub const OAuth = struct {
    client_id: []const u8,
    token_endpoint: []const u8,
};

/// Where to sign in, and with what.
pub const Account = struct {
    /// A session URL, a host, or empty (from the address's domain).
    server: []const u8 = "",
    username: []const u8 = "",
    secret: []const u8 = "",
    /// The secret is an API token (Authorization: Bearer), not a password.
    token: bool = false,
    /// Signed in through the browser: the secret is a refresh token.
    oauth: ?OAuth = null,
};

/// A message to send.
pub const Outgoing = struct {
    /// Which compose window it came from, for its answer.
    compose: u64 = 0,
    /// The account it's made and sent in: the identity's.
    account_id: []const u8 = "",
    identity_id: []const u8,
    from: Address,
    to: []const Address = &.{},
    cc: []const Address = &.{},
    bcc: []const Address = &.{},
    subject: []const u8 = "",
    body: []const u8 = "",
    in_reply_to: ?[]const u8 = null,
    references: []const []const u8 = &.{},
    /// Forwarded attachments, by their blobs on the server.
    attachments: []const Attachment = &.{},
    drafts_id: ?[]const u8 = null,
    sent_id: ?[]const u8 = null,
    /// The message this answers (in its account), and the keyword it then gets.
    original_account_id: ?[]const u8 = null,
    original_id: ?[]const u8 = null,
    original_keyword: ?Keyword = null,
    /// Saved, not sent (stays in Drafts).
    draft_only: bool = false,
    /// The draft this one replaces (in its account), deleted once it's saved.
    replaces_account_id: ?[]const u8 = null,
    replaces: ?[]const u8 = null,
};

pub const Job = union(enum) {
    /// A new session (signing in or out): events made from here on carry
    /// this number, and the model ignores those of earlier sessions.
    session: u64,
    connect: Account,
    /// Sign in through the browser (OAuth): find the server's sign-in,
    /// open it, wait for the browser to come back.
    oauth: struct { server: []const u8 = "", username: []const u8 = "", client_id: []const u8 = "" },
    /// Forget the account: no more requests, no more push.
    sign_out,
    mailboxes,
    list: struct { account_id: []const u8 = "", mailbox_id: []const u8, query: []const u8 = "", position: u32 = 0, limit: u32 = 100, gen: u64 = 0 },
    detail: struct { account_id: []const u8 = "", id: []const u8 },
    keyword: struct { account_id: []const u8 = "", ids: []const []const u8, keyword: Keyword, on: bool },
    move: struct { account_id: []const u8 = "", ids: []const []const u8, from: ?[]const u8, to: []const u8 },
    destroy: struct { account_id: []const u8 = "", ids: []const []const u8 },
    send: Outgoing,
    download: struct { account_id: []const u8 = "", blob_id: []const u8, name: []const u8, type: []const u8 },
    /// A picture's bytes, for the reader.
    picture: struct { key: []const u8, account_id: []const u8 = "", blob_id: ?[]const u8 = null, url: ?[]const u8 = null, type: []const u8 = "" },
};

pub const Event = union(enum) {
    connected: struct {
        username: []const u8,
        account_id: []const u8,
        /// Every account with mail, the user's own first.
        accounts: []const MailAccount = &.{},
        identities: []const Identity,
        can_send: bool,
        /// The session's URL, saved for next time.
        session_url: []const u8,
        /// Signed in through the browser: the account to keep (its secret
        /// the refresh token), if the server gave one.
        save: ?Account = null,
    },
    /// Open this in the browser to sign in.
    browser: struct { url: []const u8 },
    /// The server replaced the refresh token: keep the new one.
    tokens: struct { refresh_token: []const u8 },
    /// `unauthorized`: the server said no (else it couldn't be reached).
    connect_failed: struct { message: []const u8, unauthorized: bool },
    folders: []const Folder,
    list: struct { mailbox_id: []const u8, query: []const u8, position: u32, total: u32, messages: []const Message, gen: u64 },
    list_failed: struct { gen: u64, message: []const u8 },
    detail: Detail,
    detail_failed: struct { id: []const u8, message: []const u8 },
    sent: struct { compose: u64, draft_only: bool },
    /// `draft`: the draft that was saved all the same, for the next try.
    send_failed: struct { compose: u64, message: []const u8, draft: ?[]const u8 = null },
    /// Something failed: what, and why. After a change that failed, the
    /// list is fetched again to show what the server has.
    failed: struct { what: []const u8, message: []const u8, refresh: bool = true },
    /// The server's state moved on (push, or a change of ours landed).
    changed,
    downloaded: struct { path: []const u8 },
    /// A picture's bytes (null: it couldn't be had).
    picture: struct { key: []const u8, bytes: ?[]const u8 },
};

/// Folders in the sidebar's order: the roles first, then the rest by
/// sort order and name, each followed by its children.
pub fn sortFolders(arena: std.mem.Allocator, in: []const Folder) ![]Folder {
    const Ctx = struct {
        fn lt(_: void, a: Folder, b: Folder) bool {
            if (a.role != b.role) return @intFromEnum(a.role) < @intFromEnum(b.role);
            if (a.sort_order != b.sort_order) return a.sort_order < b.sort_order;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    };
    const sorted = try arena.dupe(Folder, in);
    std.mem.sort(Folder, sorted, {}, Ctx.lt);
    var out: std.ArrayList(Folder) = .empty;
    const walk = struct {
        fn f(a: std.mem.Allocator, all: []const Folder, o: *std.ArrayList(Folder), parent: ?[]const u8, depth: u8) !void {
            for (all) |fo| {
                const same = if (parent) |p| (fo.parent_id != null and std.mem.eql(u8, fo.parent_id.?, p)) else fo.parent_id == null;
                if (!same) continue;
                var copy = fo;
                copy.depth = depth;
                try o.append(a, copy);
                if (depth < 8) try f(a, all, o, fo.id, depth + 1);
            }
        }
    }.f;
    try walk(arena, sorted, &out, null, 0);
    // Folders whose parent is missing still show, at the top level.
    for (sorted) |fo| {
        var found = false;
        for (out.items) |o| if (std.mem.eql(u8, o.id, fo.id)) {
            found = true;
            break;
        };
        if (!found) try out.append(arena, fo);
    }
    return out.toOwnedSlice(arena);
}

test "folders sort by role, then nest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try sortFolders(arena.allocator(), &.{
        .{ .id = "z", .name = "Zeta" },
        .{ .id = "t", .name = "Trash", .role = .trash },
        .{ .id = "r", .name = "Receipts", .parent_id = "z" },
        .{ .id = "i", .name = "Inbox", .role = .inbox },
        .{ .id = "a", .name = "Alpha" },
        .{ .id = "o", .name = "Orphan", .parent_id = "gone" },
    });
    const want = [_][]const u8{ "i", "t", "a", "z", "r", "o" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g.id);
    try std.testing.expectEqual(@as(u8, 1), got[4].depth);
}
