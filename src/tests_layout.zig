//! Layouts and accounts through ui.Tester: the panes stacked on a phone,
//! a narrow compose window, and accounts shared with the user.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const k = @import("mail/kinds.zig");
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const view = @import("view.zig");
const tv = @import("tests_views.zig");
const Recorder = tv.Recorder;
const Fixture = tv.Fixture;
const feed = tv.feed;
const shot = tv.shot;
const messages = tv.messages;
const gpa = std.testing.allocator;
const now_s = tv.now_s;
fn fixedNow() i64 {
    return now_s;
}

test "on a phone: mailboxes, then the list, then the message, and back" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 390, .height = 844 });
    defer t.deinit();
    t.settle(0.3);
    // The list first, with a way back to the mailboxes.
    try std.testing.expect(t.hasText("Mailboxes"));
    try std.testing.expect(t.hasText("Ada Lovelace"));
    try std.testing.expect(!t.hasText("No message selected"));
    try shot(&t, "phone-list");
    try t.clickText("Compiler meeting moved");
    try std.testing.expectEqual(@as(@TypeOf(f.m.screen), .message), f.m.screen);
    feed(&f.m, .{ .detail = .{ .message = messages[1], .text = "We're meeting on Friday instead, same room.\n\nGrace" } });
    t.settle(0.3);
    try std.testing.expect(t.containsText("same room"));
    try shot(&t, "phone-message");
    try t.clickText("Inbox");
    try std.testing.expectEqual(@as(@TypeOf(f.m.screen), .list), f.m.screen);
    t.settle(0.3);
    try t.clickText("Mailboxes");
    t.settle(0.3);
    try std.testing.expectEqual(@as(@TypeOf(f.m.screen), .folders), f.m.screen);
    try shot(&t, "phone-mailboxes");
    try t.clickText("Receipts");
    try std.testing.expectEqualStrings("receipts", f.rec.last(.list).?.mailbox_id);
    try std.testing.expectEqual(@as(@TypeOf(f.m.screen), .list), f.m.screen);
}

test "a narrow compose window has Cancel, which keeps the draft" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.m.compose(.new);
    const cm = f.m.composes.items[0];
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(cm, @import("compose.zig").Compose.view), .{ .width = 390, .height = 700 });
    defer t.deinit();
    t.settle(0.2);
    cm.subject.set("Half a thought");
    try t.clickText("Cancel");
    // Not under the frame that drew it: on the next turn.
    try std.testing.expect(cm.dismissed);
    try std.testing.expectEqual(@as(usize, 1), f.m.composes.items.len);
    f.m.reapComposes();
    try std.testing.expect(f.rec.last(.send).?.draft_only);
    try std.testing.expectEqual(@as(usize, 0), f.m.composes.items.len);
}

test "shared accounts: a section each, read-only folders locked" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var m = Model.init(gpa, rec.backend());
    defer m.deinit();
    m.now = fixedNow;
    feed(&m, .{ .connected = .{ .username = "alice@example.test", .account_id = "c", .accounts = &.{
        .{ .id = "c", .name = "alice@example.test" },
        .{ .id = "d", .name = "bob@example.test", .personal = false },
        .{ .id = "e", .name = "support@example.test", .personal = false },
    }, .identities = &.{
        .{ .account_id = "c", .id = "i1", .name = "Alice", .email = "alice@example.test" },
        .{ .account_id = "e", .id = "i9", .name = "Support Team", .email = "support@example.test" },
    }, .can_send = true, .session_url = "x" } });
    const ro: k.Rights = .{ .add = false, .remove = false, .seen = false, .keywords = false };
    feed(&m, .{ .folders = &.{
        .{ .account_id = "c", .id = "a", .name = "Inbox", .role = .inbox },
        .{ .account_id = "c", .id = "h", .name = "Archive", .role = .archive },
        .{ .account_id = "d", .id = "h", .name = "Team Updates", .rights = ro, .unread = 2 },
        .{ .account_id = "d", .id = "i", .name = "Shared Inbox Triage" },
        .{ .account_id = "e", .id = "a", .name = "Inbox", .role = .inbox, .unread = 1 },
    } });
    // The user's own inbox opens, not the group's.
    try std.testing.expectEqualStrings("c", rec.last(.list).?.account_id);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&m, view.view), .{ .width = 1180, .height = 720 });
    defer t.deinit();
    t.settle(0.3);
    try std.testing.expect(t.hasText("bob@example.test"));
    try std.testing.expect(t.hasText("support@example.test"));
    try t.clickText("Team Updates");
    const l = rec.last(.list).?;
    try std.testing.expectEqualStrings("d", l.account_id);
    try std.testing.expectEqualStrings("h", l.mailbox_id);
    feed(&m, .{ .list = .{ .mailbox_id = "h", .query = "", .position = 0, .total = 1, .gen = m.list_gen, .messages = &.{
        .{ .account_id = "d", .id = "x1", .mailbox_ids = &.{"h"}, .from = &.{.{ .name = "Bob", .email = "bob@example.test" }}, .subject = "Sprint notes", .received = now_s - 60 },
    } } });
    t.settle(0.2);
    try shot(&t, "shared");
    try t.clickText("Sprint notes");
    // Opened in its account; not marked read where $seen can't be set.
    try std.testing.expectEqualStrings("d", rec.last(.detail).?.account_id);
    try std.testing.expectEqual(@as(usize, 0), rec.count(.keyword));
    const moves = rec.count(.move);
    m.toggleFlag();
    m.archive();
    try std.testing.expectEqual(@as(usize, 0), rec.count(.keyword));
    try std.testing.expectEqual(moves, rec.count(.move));
    // A reply from the group's inbox goes out as the group.
    m.openMailbox("e", "a");
    feed(&m, .{ .list = .{ .mailbox_id = "a", .query = "", .position = 0, .total = 1, .gen = m.list_gen, .messages = &.{
        .{ .account_id = "e", .id = "t1", .mailbox_ids = &.{"a"}, .from = &.{.{ .email = "customer@x.test" }}, .subject = "Help", .received = now_s },
    } } });
    m.select(0);
    feed(&m, .{ .detail = .{ .message = .{ .account_id = "e", .id = "t1", .from = &.{.{ .email = "customer@x.test" }}, .subject = "Help" }, .text = "Please help." } });
    m.compose(.reply);
    const cm = m.composes.items[m.composes.items.len - 1];
    try std.testing.expectEqual(@as(?usize, 1), cm.identity);
    cm.sendNow(false);
    const s = rec.last(.send).?;
    try std.testing.expectEqualStrings("e", s.account_id);
    try std.testing.expectEqualStrings("e", s.original_account_id.?);
}
