//! A message being written, in a window of its own: new, or a reply or a
//! forward filled in from the message it answers (who to, the subject,
//! the quoted text, the threading headers, forwarded attachments).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const k = @import("mail/kinds.zig");
const address = @import("mail/address.zig");
const dates = @import("mail/dates.zig");
const copy = @import("copy.zig");
const Model = @import("model.zig").Model;

pub const Compose = struct {
    model: *Model,
    gpa: std.mem.Allocator,
    id: u64,
    kind: Kind,
    /// What the answer refers to, and forwarded attachments.
    arena: std.heap.ArenaAllocator,
    in_reply_to: ?[]const u8 = null,
    references: []const []const u8 = &.{},
    attachments: []const k.Attachment = &.{},
    original_id: ?[]const u8 = null,
    /// The account the message answered (or the draft replaced) is in.
    original_account: []const u8 = "",
    /// A draft opened again: it's replaced when this is saved or sent.
    replaces: ?[]const u8 = null,

    to: ui.TextBuffer = .{},
    cc: ui.TextBuffer = .{},
    bcc: ui.TextBuffer = .{},
    subject: ui.TextBuffer = .{},
    body: ui.TextBuffer = .{},
    show_cc: bool = false,
    identity: ?usize = 0,
    sending: bool = false,
    error_buf: [320]u8 = undefined,
    error_len: usize = 0,
    /// The window showing it (main.zig's), and whether its first frame
    /// put the caret in a field yet.
    window: ?*anyopaque = null,
    focused_once: bool = false,
    /// Asked to close with something written: the "discard?" question.
    confirm_close: bool = false,
    /// What the fields held when it opened, to tell if anything was written.
    initial: u64 = 0,
    /// Cancel was pressed: it goes on the next turn (Model.reapComposes).
    dismissed: bool = false,
    /// A word on what was filled in (shortened, formatting dropped).
    notice: []const u8 = "",

    pub const Kind = enum { new, reply, reply_all, forward, draft };

    pub fn create(m: *Model, kind: Kind, original: ?*const k.Detail) !*Compose {
        const c = try m.gpa.create(Compose);
        c.* = .{ .model = m, .gpa = m.gpa, .id = m.next_compose, .kind = kind, .arena = .init(m.gpa) };
        m.next_compose += 1;
        errdefer c.destroy();
        if (original) |o| try c.fill(o.*);
        c.initial = c.contentHash();
        return c;
    }

    pub fn destroy(c: *Compose) void {
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    /// Fills To and the subject (a mailto: link's), percent-escapes
    /// read; still counts as nothing written.
    pub fn prefill(c: *Compose, to: []const u8, subject: []const u8) void {
        var buf: [1024]u8 = undefined;
        c.to.set(unescape(&buf, to));
        c.subject.set(unescape(&buf, subject));
        c.initial = c.contentHash();
    }

    pub fn errorText(c: *const Compose) []const u8 {
        return c.error_buf[0..c.error_len];
    }

    pub fn failed(c: *Compose, msg: []const u8) void {
        c.sending = false;
        const n = @min(msg.len, c.error_buf.len);
        @memcpy(c.error_buf[0..n], msg[0..n]);
        c.error_len = n;
    }

    pub fn title(c: *const Compose) []const u8 {
        const s = std.mem.trim(u8, c.subject.text(), " ");
        if (s.len > 0) return s;
        return switch (c.kind) {
            .new, .draft => "New Message",
            .reply, .reply_all => "Reply",
            .forward => "Forward",
        };
    }

    fn contentHash(c: *const Compose) u64 {
        var h = std.hash.Wyhash.init(0);
        for ([_]*const ui.TextBuffer{ &c.to, &c.cc, &c.bcc, &c.subject, &c.body }) |b| {
            h.update(b.text());
            h.update("\x00");
        }
        return h.final();
    }

    /// Whether closing would lose something written.
    pub fn dirty(c: *const Compose) bool {
        return c.contentHash() != c.initial;
    }

    /// The addresses that are the user's own, left out of a reply to all.
    fn mine(c: *Compose, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (c.model.identities) |id| try out.append(a, id.email);
        try out.append(a, c.model.username);
        return out.toOwnedSlice(a);
    }

    fn fill(c: *Compose, o: k.Detail) !void {
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const a = c.arena.allocator();
        const msg = o.message;
        c.original_id = try a.dupe(u8, msg.id);
        c.original_account = try a.dupe(u8, msg.account_id);
        // From the account it came to, when the user may send from there
        // (a group's mail, answered as the group).
        for (c.model.identities, 0..) |id, i| if (std.mem.eql(u8, id.account_id, msg.account_id)) {
            c.identity = i;
            break;
        };
        var datebuf: [64]u8 = undefined;
        const when = dates.long(&datebuf, if (o.sent != 0) o.sent else msg.received, false);
        switch (c.kind) {
            .new => {},
            .draft => {
                c.original_id = null;
                c.replaces = try a.dupe(u8, msg.id);
                c.to.set(try address.format(s, msg.to));
                c.cc.set(try address.format(s, msg.cc));
                c.bcc.set(try address.format(s, o.bcc));
                c.show_cc = msg.cc.len + o.bcc.len > 0;
                c.subject.set(msg.subject);
                c.body.set(o.text);
                c.body.want_caret = 0;
                if (c.body.len < o.text.len) {
                    // Too long to edit here: the original stays.
                    c.replaces = null;
                    c.notice = "This draft is longer than nanomail can edit, so only its start is here. The original draft is kept.";
                } else if (o.html != null) c.notice = "This draft was written with formatting; here it's plain text, and it will be saved that way.";
                if (o.in_reply_to) |r| c.in_reply_to = try a.dupe(u8, r);
                var refs: std.ArrayList([]const u8) = .empty;
                for (o.references) |r| try refs.append(a, try a.dupe(u8, r));
                c.references = refs.items;
                c.attachments = try copy.deep([]const k.Attachment, a, o.attachments);
            },
            .reply, .reply_all => {
                const me = try c.mine(s);
                const reply_to = if (o.reply_to.len > 0) o.reply_to else msg.from;
                var to: std.ArrayList(k.Address) = .empty;
                for (reply_to) |x| if (x.email.len > 0) try to.append(s, x);
                var cc: std.ArrayList(k.Address) = .empty;
                if (c.kind == .reply_all) {
                    for (msg.to) |x| if (x.email.len > 0 and !address.isMine(x.email, me) and !contains(to.items, x.email)) try to.append(s, x);
                    for (msg.cc) |x| if (x.email.len > 0 and !address.isMine(x.email, me) and !contains(to.items, x.email) and !contains(cc.items, x.email)) try cc.append(s, x);
                }
                // Replying to one's own message: to whom it went.
                if (to.items.len > 0 and address.isMine(to.items[0].email, me) and msg.to.len > 0) {
                    to.clearRetainingCapacity();
                    for (msg.to) |x| try to.append(s, x);
                }
                c.to.set(try address.format(s, to.items));
                if (cc.items.len > 0) {
                    c.cc.set(try address.format(s, cc.items));
                    c.show_cc = true;
                }
                c.subject.set(try prefixed(s, "Re: ", msg.subject));
                const head = try std.fmt.allocPrint(s, "\n\nOn {s}, {s} wrote:\n", .{ when, msg.sender() });
                const text = try std.mem.concat(s, u8, &.{ head, try quote(s, o.text) });
                c.body.set(text);
                c.body.want_caret = 0;
                if (c.body.len < text.len) c.notice = "The quoted message was too long and has been shortened.";
                if (o.message_id) |mid| {
                    c.in_reply_to = try a.dupe(u8, mid);
                    // The parent's references, or else what it replied to
                    // (RFC 5322 §3.6.4), then the parent.
                    var refs: std.ArrayList([]const u8) = .empty;
                    for (o.references) |r| try refs.append(a, try a.dupe(u8, r));
                    if (o.references.len == 0) if (o.in_reply_to) |r| try refs.append(a, try a.dupe(u8, r));
                    try refs.append(a, c.in_reply_to.?);
                    c.references = try refs.toOwnedSlice(a);
                }
            },
            .forward => {
                c.subject.set(try prefixed(s, "Fwd: ", msg.subject));
                const head = try std.fmt.allocPrint(s, "\n\n---------- Forwarded message ----------\nFrom: {s}\nDate: {s}\nSubject: {s}\nTo: {s}\n\n", .{
                    try address.format(s, msg.from), when, msg.subject, try address.format(s, msg.to),
                });
                const text = try std.mem.concat(s, u8, &.{ head, o.text });
                c.body.set(text);
                c.body.want_caret = 0;
                if (c.body.len < text.len) c.notice = "The forwarded message was too long and has been shortened.";
                c.attachments = try copy.deep([]const k.Attachment, a, o.attachments);
                if (o.message_id) |mid| c.references = try a.dupe([]const u8, &.{try a.dupe(u8, mid)});
            },
        }
    }

    /// Checks what was written and makes it a message to send.
    pub fn outgoing(c: *Compose, arena: std.mem.Allocator, draft_only: bool) !k.Outgoing {
        const m = c.model;
        const ident = if (c.identity) |i| (if (i < m.identities.len) m.identities[i] else null) else null;
        const from: k.Identity = ident orelse if (m.identities.len > 0) m.identities[0] else {
            c.failed("This account has no identity to send from.");
            return error.Invalid;
        };
        var bad: []const u8 = "";
        // A draft keeps what's written, addresses or not.
        const parse = struct {
            fn f(a: std.mem.Allocator, s: []const u8, lenient: bool, b: *[]const u8) ![]k.Address {
                return if (lenient) address.parseLenient(a, s) else address.parseList(a, s, b);
            }
        }.f;
        const to = parse(arena, c.to.text(), draft_only, &bad) catch return c.invalid("“{s}” isn't an address.", .{bad});
        const cc = parse(arena, c.cc.text(), draft_only, &bad) catch return c.invalid("“{s}” isn't an address.", .{bad});
        const bcc = parse(arena, c.bcc.text(), draft_only, &bad) catch return c.invalid("“{s}” isn't an address.", .{bad});
        if (!draft_only and to.len + cc.len + bcc.len == 0) return c.invalid("Add someone to send it to.", .{});
        // Made and kept in the account it's sent from.
        const drafts = m.folderByRoleIn(from.account_id, .drafts);
        const sent = m.folderByRoleIn(from.account_id, .sent);
        return .{
            .compose = c.id,
            .identity_id = from.id,
            .from = .{ .name = if (from.name.len > 0) from.name else null, .email = from.email },
            .to = to,
            .cc = cc,
            .bcc = bcc,
            .subject = std.mem.trim(u8, c.subject.text(), " "),
            .body = c.body.text(),
            .in_reply_to = c.in_reply_to,
            .references = c.references,
            .attachments = c.attachments,
            .drafts_id = if (drafts) |d| d.id else null,
            .sent_id = if (sent) |x| x.id else null,
            .account_id = from.account_id,
            .original_account_id = c.original_account,
            .replaces_account_id = c.original_account,
            .original_id = if (draft_only) null else c.original_id,
            .original_keyword = if (draft_only) null else switch (c.kind) {
                .new, .draft => null,
                .reply, .reply_all => .answered,
                .forward => .forwarded,
            },
            .draft_only = draft_only,
            .replaces = c.replaces,
        };
    }

    fn invalid(c: *Compose, comptime fmt: []const u8, args: anytype) error{Invalid} {
        const s = std.fmt.bufPrint(&c.error_buf, fmt, args) catch "";
        c.error_len = s.len;
        return error.Invalid;
    }

    /// Sends it (or saves it as a draft); the model closes the window
    /// once the server has it.
    pub fn view(c: *Compose, cx: *ui.Context) void {
        @import("view_compose.zig").view(c, cx);
    }

    pub fn sendNow(c: *Compose, draft_only: bool) void {
        if (c.sending) return;
        c.error_len = 0;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const out = c.outgoing(arena.allocator(), draft_only) catch return;
        c.sending = true;
        c.model.send(out);
    }
};

/// "%20" as " ", into `buf` (cut to fit).
fn unescape(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) {
        if (s[i] == '%' and i + 3 <= s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                buf[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[n] = s[i];
        i += 1;
    }
    return buf[0..n];
}

fn contains(list: []const k.Address, email: []const u8) bool {
    for (list) |a| if (std.ascii.eqlIgnoreCase(a.email, email)) return true;
    return false;
}

/// "Re: " before a subject that hasn't one already.
fn prefixed(a: std.mem.Allocator, prefix: []const u8, subject: []const u8) ![]const u8 {
    const s = std.mem.trim(u8, subject, " ");
    if (s.len >= prefix.len - 1 and std.ascii.eqlIgnoreCase(s[0 .. prefix.len - 1], prefix[0 .. prefix.len - 1])) return s;
    if (std.mem.eql(u8, prefix, "Fwd: ") and s.len >= 3 and std.ascii.eqlIgnoreCase(s[0..3], "Fw:")) return s;
    return std.mem.concat(a, u8, &.{ prefix, s });
}

/// Each line of `text` quoted with "> ".
pub fn quote(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n "), '\n');
    while (lines.next()) |line| {
        try out.appendSlice(a, if (line.len > 0 and line[0] == '>') ">" else if (line.len == 0) ">" else "> ");
        try out.appendSlice(a, std.mem.trimEnd(u8, line, "\r"));
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

test "subjects get one prefix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Re: Lunch", try prefixed(a, "Re: ", "Lunch"));
    try std.testing.expectEqualStrings("RE: Lunch", try prefixed(a, "Re: ", "RE: Lunch"));
    try std.testing.expectEqualStrings("Fwd: Lunch", try prefixed(a, "Fwd: ", "Lunch"));
    try std.testing.expectEqualStrings("Fw: Lunch", try prefixed(a, "Fwd: ", "Fw: Lunch"));
    try std.testing.expectEqualStrings("> Hi\n>\n>> Earlier\n", try quote(a, "Hi\n\n> Earlier\n"));
}
