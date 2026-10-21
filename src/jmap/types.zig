//! JMAP's objects as the server sends them (RFC 8620, RFC 8621): what
//! the client asks for, parsed with unknown fields ignored. Strings point
//! into the arena the response was parsed in.
const std = @import("std");

pub const using_mail = [_][]const u8{ "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail" };
pub const using_submission = [_][]const u8{ "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission" };

pub const cap_core = "urn:ietf:params:jmap:core";
pub const cap_mail = "urn:ietf:params:jmap:mail";
pub const cap_submission = "urn:ietf:params:jmap:submission";

/// A set of ids or keywords: JMAP's `{"id": true}`.
pub const Set = std.json.ArrayHashMap(bool);

pub const Address = struct {
    name: ?[]const u8 = null,
    email: []const u8 = "",

    /// The name if it has one, else the address.
    pub fn display(a: Address) []const u8 {
        if (a.name) |n| if (std.mem.trim(u8, n, " \"'").len > 0) return std.mem.trim(u8, n, " \"'");
        return a.email;
    }
};

/// What the user may do in a mailbox (RFC 8621 §2): all, in their own.
pub const Rights = struct {
    mayReadItems: bool = true,
    mayAddItems: bool = true,
    mayRemoveItems: bool = true,
    maySetSeen: bool = true,
    maySetKeywords: bool = true,
};

pub const Mailbox = struct {
    id: []const u8,
    name: []const u8 = "",
    parentId: ?[]const u8 = null,
    role: ?[]const u8 = null,
    sortOrder: u64 = 0,
    totalEmails: u64 = 0,
    unreadEmails: u64 = 0,
    myRights: ?Rights = null,
};

pub const Identity = struct {
    id: []const u8,
    name: []const u8 = "",
    email: []const u8 = "",
    replyTo: ?[]const Address = null,
    textSignature: ?[]const u8 = null,
};

/// A message as the list shows it.
pub const EmailSummary = struct {
    id: []const u8,
    threadId: []const u8 = "",
    mailboxIds: Set = .{},
    keywords: Set = .{},
    from: ?[]const Address = null,
    to: ?[]const Address = null,
    cc: ?[]const Address = null,
    subject: ?[]const u8 = null,
    receivedAt: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    hasAttachment: bool = false,
    size: u64 = 0,
};

pub const summary_properties = [_][]const u8{ "id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "subject", "receivedAt", "preview", "hasAttachment", "size" };

pub const BodyPart = struct {
    partId: ?[]const u8 = null,
    blobId: ?[]const u8 = null,
    size: u64 = 0,
    name: ?[]const u8 = null,
    type: []const u8 = "",
    charset: ?[]const u8 = null,
    disposition: ?[]const u8 = null,
    cid: ?[]const u8 = null,
};

pub const BodyValue = struct {
    value: []const u8 = "",
    isEncodingProblem: bool = false,
    isTruncated: bool = false,
};

/// A message as the reader shows it.
pub const EmailFull = struct {
    id: []const u8,
    threadId: []const u8 = "",
    mailboxIds: Set = .{},
    keywords: Set = .{},
    from: ?[]const Address = null,
    to: ?[]const Address = null,
    cc: ?[]const Address = null,
    bcc: ?[]const Address = null,
    replyTo: ?[]const Address = null,
    subject: ?[]const u8 = null,
    receivedAt: ?[]const u8 = null,
    sentAt: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    hasAttachment: bool = false,
    size: u64 = 0,
    messageId: ?[]const []const u8 = null,
    inReplyTo: ?[]const []const u8 = null,
    references: ?[]const []const u8 = null,
    textBody: []const BodyPart = &.{},
    htmlBody: []const BodyPart = &.{},
    attachments: []const BodyPart = &.{},
    bodyValues: std.json.ArrayHashMap(BodyValue) = .{},
};

pub const full_properties = summary_properties ++ [_][]const u8{ "bcc", "replyTo", "sentAt", "messageId", "inReplyTo", "references", "textBody", "htmlBody", "attachments", "bodyValues" };

pub fn GetResponse(comptime T: type) type {
    return struct {
        accountId: []const u8 = "",
        state: []const u8 = "",
        list: []const T = &.{},
        notFound: ?[]const []const u8 = null,
    };
}

pub const QueryResponse = struct {
    accountId: []const u8 = "",
    queryState: []const u8 = "",
    position: u64 = 0,
    total: ?u64 = null,
    ids: []const []const u8 = &.{},
};

pub const SetError = struct {
    type: []const u8 = "",
    description: ?[]const u8 = null,
};

pub const SetResponse = struct {
    accountId: []const u8 = "",
    newState: ?[]const u8 = null,
    created: ?std.json.ArrayHashMap(std.json.Value) = null,
    updated: ?std.json.ArrayHashMap(?std.json.Value) = null,
    destroyed: ?[]const []const u8 = null,
    notCreated: ?std.json.ArrayHashMap(SetError) = null,
    notUpdated: ?std.json.ArrayHashMap(SetError) = null,
    notDestroyed: ?std.json.ArrayHashMap(SetError) = null,

    /// The first failure, if any, as a readable line.
    pub fn firstError(r: SetResponse) ?SetError {
        inline for (.{ r.notCreated, r.notUpdated, r.notDestroyed }) |m| {
            if (m) |map| {
                var it = map.map.iterator();
                if (it.next()) |e| return e.value_ptr.*;
            }
        }
        return null;
    }
};

/// The well-known roles, in the order the sidebar lists them.
pub const Role = enum {
    inbox,
    drafts,
    sent,
    archive,
    junk,
    trash,
    other,

    pub fn of(role: ?[]const u8) Role {
        const r = role orelse return .other;
        inline for (@typeInfo(Role).@"enum".field_names, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(r, name)) return @enumFromInt(i);
        }
        return .other;
    }

    pub fn icon(r: Role) []const u8 {
        return switch (r) {
            .inbox => "tray",
            .drafts => "doc",
            .sent => "paperplane",
            .archive => "archivebox",
            .junk => "xmark.bin",
            .trash => "trash",
            .other => "folder",
        };
    }
};

test "address display" {
    try std.testing.expectEqualStrings("Ada", (Address{ .name = "Ada", .email = "a@x" }).display());
    try std.testing.expectEqualStrings("a@x", (Address{ .name = "", .email = "a@x" }).display());
    try std.testing.expectEqualStrings("a@x", (Address{ .email = "a@x" }).display());
}

test "roles" {
    try std.testing.expectEqual(Role.inbox, Role.of("inbox"));
    try std.testing.expectEqual(Role.trash, Role.of("Trash"));
    try std.testing.expectEqual(Role.other, Role.of("important"));
    try std.testing.expectEqual(Role.other, Role.of(null));
}
