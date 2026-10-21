//! Sending (RFC 8621 §7): the message made in Drafts, then submitted,
//! which on success moves it to Sent and clears $draft; the message it
//! answers marked $answered or $forwarded, all in one request. A draft
//! alone is the first step only.
const std = @import("std");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const k = @import("../mail/kinds.zig");
const Client = @import("client.zig").Client;

const Part = struct { partId: []const u8, type: []const u8 };
const BodyValue = struct { value: []const u8 };
const Attached = struct { blobId: []const u8, type: []const u8, name: []const u8, disposition: []const u8 = "attachment" };

/// Sends `out` (or saves it as a draft). The draft is made first; only
/// once the server has it does what it replaces go, and does the message
/// it answers get its keyword. When the draft was saved but not sent,
/// `c.last_draft` names it, for the next try to replace.
pub fn send(c: *Client, arena: std.mem.Allocator, out: k.Outgoing) !void {
    _ = c.session orelse return error.NotConnected;
    c.last_draft = null;
    const home = out.drafts_id orelse out.sent_id orelse {
        c.problem = "This account has no Drafts or Sent folder to keep the message in.";
        return error.NoFolder;
    };
    var bodies: std.json.ObjectMap = .empty;
    try bodies.put(arena, "body", .{ .object = blk: {
        var v: std.json.ObjectMap = .empty;
        try v.put(arena, "value", .{ .string = try validUtf8(arena, out.body) });
        break :blk v;
    } });
    var keywords: std.json.ObjectMap = .empty;
    try keywords.put(arena, "$draft", .{ .bool = true });
    try keywords.put(arena, "$seen", .{ .bool = true });
    const attachments = try arena.alloc(Attached, out.attachments.len);
    for (out.attachments, attachments) |a, *o| o.* = .{ .blobId = a.blob_id, .type = a.type, .name = a.name };

    const email = .{
        .mailboxIds = try protocol.idSet(arena, &.{home}),
        .keywords = std.json.Value{ .object = keywords },
        .from = &[_]types.Address{out.from},
        .to = if (out.to.len > 0) try clean(arena, out.to) else null,
        .cc = if (out.cc.len > 0) try clean(arena, out.cc) else null,
        .bcc = if (out.bcc.len > 0) try clean(arena, out.bcc) else null,
        .subject = try validUtf8(arena, out.subject),
        .inReplyTo = if (out.in_reply_to) |m| try arena.dupe([]const u8, &.{m}) else null,
        .references = if (out.references.len > 0) out.references else null,
        .bodyValues = std.json.Value{ .object = bodies },
        .textBody = &[_]Part{.{ .partId = "body", .type = "text/plain" }},
        .attachments = if (attachments.len > 0) attachments else null,
    };
    var create: std.json.ObjectMap = .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(email, .{ .emit_null_optional_fields = false }, &aw.writer);
    try create.put(arena, "draft", try std.json.parseFromSliceLeaky(std.json.Value, arena, aw.written(), .{}));

    var req = protocol.Request.init(arena, if (out.draft_only) &types.using_mail else &types.using_submission);
    const set_id = try req.call("Email/set", .{ .accountId = out.account_id, .create = std.json.Value{ .object = create } });
    var sub_id: ?[]const u8 = null;
    if (!out.draft_only) {
        // Once submitted: out of Drafts, into Sent, no longer a draft.
        var after: std.json.ObjectMap = .empty;
        if (out.drafts_id) |d| if (out.sent_id) |sent| {
            try after.put(arena, try std.fmt.allocPrint(arena, "mailboxIds/{s}", .{d}), .null);
            try after.put(arena, try std.fmt.allocPrint(arena, "mailboxIds/{s}", .{sent}), .{ .bool = true });
        };
        try after.put(arena, "keywords/$draft", .null);
        var on_success: std.json.ObjectMap = .empty;
        try on_success.put(arena, "#send", .{ .object = after });
        var subs: std.json.ObjectMap = .empty;
        var sub: std.json.ObjectMap = .empty;
        try sub.put(arena, "identityId", .{ .string = out.identity_id });
        try sub.put(arena, "emailId", .{ .string = "#draft" });
        try subs.put(arena, "send", .{ .object = sub });
        sub_id = try req.call("EmailSubmission/set", .{
            .accountId = out.account_id,
            .create = std.json.Value{ .object = subs },
            .onSuccessUpdateEmail = std.json.Value{ .object = on_success },
        });
    }
    var r = try c.call(arena, &req);
    const made = r.get(types.SetResponse, set_id) catch |e| return failed(c, &r, e);
    if (made.firstError()) |e| return say(c, "Couldn't save the message: {s}", e);
    const draft_id = createdId(made, "draft");

    var sent = true;
    if (sub_id) |id| {
        const subd = r.get(types.SetResponse, id) catch |e| return failed(c, &r, e);
        if (subd.firstError()) |e| {
            say(c, "The server didn't send it: {s}", e) catch {};
            sent = false;
        }
    }
    // The new draft holds the text now: the one it replaces can go, and
    // the message answered gets its keyword (only if it was sent).
    try followUp(c, arena, out, sent and !out.draft_only);
    if (!sent) {
        c.last_draft = draft_id;
        return error.NotSent;
    }
}

/// After the message is safe: the draft it replaces deleted, the message
/// it answers marked. Failing here loses nothing, so it isn't an error.
fn followUp(c: *Client, arena: std.mem.Allocator, out: k.Outgoing, mark: bool) !void {
    _ = c.session orelse return;
    var req = protocol.Request.init(arena, &types.using_mail);
    if (out.replaces) |old| _ = try req.call("Email/set", .{ .accountId = out.replaces_account_id orelse out.account_id, .destroy = &[_][]const u8{old} });
    if (mark) if (out.original_id) |orig| if (out.original_keyword) |kw| {
        var patch: std.json.ObjectMap = .empty;
        try patch.put(arena, try std.fmt.allocPrint(arena, "keywords/{s}", .{kw.name()}), .{ .bool = true });
        var update: std.json.ObjectMap = .empty;
        try update.put(arena, orig, .{ .object = patch });
        _ = try req.call("Email/set", .{ .accountId = out.original_account_id orelse out.account_id, .update = std.json.Value{ .object = update } });
    };
    if (req.count == 0) return;
    const saved = c.problem;
    _ = c.call(arena, &req) catch {};
    c.problem = saved;
}

/// The server's id for what was created as `key`.
fn createdId(r: types.SetResponse, key: []const u8) ?[]const u8 {
    const created = r.created orelse return null;
    const v = created.map.get(key) orelse return null;
    if (v != .object) return null;
    const id = v.object.get("id") orelse return null;
    return if (id == .string) id.string else null;
}

/// Addresses with valid UTF-8 names, and none without an address.
fn clean(arena: std.mem.Allocator, list: []const types.Address) ![]const types.Address {
    var out: std.ArrayList(types.Address) = .empty;
    for (list) |a| {
        if (std.mem.trim(u8, a.email, " ").len == 0) continue;
        try out.append(arena, .{ .name = if (a.name) |n| try validUtf8(arena, n) else null, .email = a.email });
    }
    return out.items;
}

/// `s` with any byte that isn't valid UTF-8 made U+FFFD: JSON strings must
/// be UTF-8 (std.json writes anything else as an array of numbers).
pub fn validUtf8(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n > 0 and i + n <= s.len and (if (std.unicode.utf8Decode(s[i .. i + n])) |_| true else |_| false)) {
            try out.appendSlice(arena, s[i .. i + n]);
            i += n;
        } else {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

fn say(c: *Client, comptime fmt: []const u8, e: types.SetError) error{NotSent} {
    c.problem = std.fmt.bufPrint(&c.problem_buf, fmt, .{e.description orelse e.type}) catch "";
    return error.NotSent;
}

fn failed(c: *Client, r: *protocol.Response, e: anyerror) anyerror {
    if (r.method_error) |me| c.problem = std.fmt.bufPrint(&c.problem_buf, "{s}: {s}", .{ me.type, me.description orelse "" }) catch "";
    return e;
}

test "invalid UTF-8 is mended" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("voil\u{FFFD} ok", try validUtf8(arena.allocator(), "voil\xc3 ok"));
    try std.testing.expectEqualStrings("Zürich", try validUtf8(arena.allocator(), "Zürich"));
}
