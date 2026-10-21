//! The views through ui.Tester, rendered offscreen: the sync thread is a
//! recorder of jobs, and its answers are events made here. With
//! NANOMAIL_SHOTS=<dir> the tests leave screenshots there.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const k = @import("mail/kinds.zig");
const copy = @import("copy.zig");
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const view = @import("view.zig");
const dates = @import("mail/dates.zig");

const gpa = std.testing.allocator;

pub const Recorder = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    jobs: std.ArrayList(k.Job) = .empty,

    fn submit(ctx: *anyopaque, job: k.Job) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const a = r.arena.allocator();
        r.jobs.append(a, copy.deep(k.Job, a, job) catch return) catch {};
    }

    pub fn backend(r: *Recorder) model_mod.Backend {
        return .{ .ctx = r, .submit = submit };
    }

    pub fn deinit(r: *Recorder) void {
        r.arena.deinit();
    }

    pub fn count(r: *Recorder, tag: std.meta.Tag(k.Job)) usize {
        var n: usize = 0;
        for (r.jobs.items) |j| n += @intFromBool(j == tag);
        return n;
    }

    pub fn last(r: *Recorder, comptime tag: std.meta.Tag(k.Job)) ?@FieldType(k.Job, @tagName(tag)) {
        var i = r.jobs.items.len;
        while (i > 0) {
            i -= 1;
            if (r.jobs.items[i] == tag) return @field(r.jobs.items[i], @tagName(tag));
        }
        return null;
    }
};

/// Gives `m` an event, as the sync thread would: in an arena of its own.
pub fn feed(m: *Model, ev: k.Event) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const e = copy.deep(k.Event, arena.allocator(), ev) catch unreachable;
    m.apply(arena, e);
}

pub const now_s: i64 = 1741273200; // 2025-03-06T15:00:00Z, a Thursday
fn fixedNow() i64 {
    return now_s;
}

pub const folders = [_]k.Folder{
    .{ .id = "inbox", .name = "Inbox", .role = .inbox, .total = 6, .unread = 3 },
    .{ .id = "drafts", .name = "Drafts", .role = .drafts },
    .{ .id = "sent", .name = "Sent", .role = .sent },
    .{ .id = "archive", .name = "Archive", .role = .archive },
    .{ .id = "trash", .name = "Trash", .role = .trash },
    .{ .id = "receipts", .name = "Receipts", .total = 2 },
};

const ada: k.Address = .{ .name = "Ada Lovelace", .email = "ada@example.test" };
const grace: k.Address = .{ .name = "Grace Hopper", .email = "grace@example.test" };
const me: k.Address = .{ .name = "Alice", .email = "alice@example.test" };

pub const messages = [_]k.Message{
    .{ .id = "m1", .thread_id = "t1", .mailbox_ids = &.{"inbox"}, .from = &.{ada}, .to = &.{me}, .cc = &.{grace}, .subject = "The Analytical Engine, notes for Thursday", .preview = "I've gone over the notes on the engine again and added the table of Bernoulli numbers.", .received = now_s - 3600 },
    .{ .id = "m2", .thread_id = "t2", .mailbox_ids = &.{"inbox"}, .flags = .{ .seen = true, .flagged = true }, .from = &.{grace}, .to = &.{me}, .subject = "Compiler meeting moved", .preview = "We're meeting on Friday instead — same room.", .received = now_s - 86400, .has_attachment = true },
    .{ .id = "m3", .thread_id = "t3", .mailbox_ids = &.{"inbox"}, .flags = .{ .seen = true, .answered = true }, .from = &.{.{ .name = "Café Zürich", .email = "hello@cafe.test" }}, .to = &.{me}, .subject = "Your receipt — Café Zürich ☕️", .preview = "Thanks for visiting! Total CHF 12.50", .received = now_s - 3 * 86400 },
    .{ .id = "m4", .thread_id = "t4", .mailbox_ids = &.{"inbox"}, .from = &.{.{ .email = "noreply@very-long-domain-name-for-newsletters.example.test" }}, .to = &.{me}, .subject = "A very long subject line that goes on and on, well past what one row of the list can show", .preview = "Unsubscribe at any time.", .received = now_s - 40 * 86400 },
    .{ .id = "m5", .thread_id = "t5", .mailbox_ids = &.{"inbox"}, .flags = .{ .seen = true }, .from = &.{ada}, .to = &.{me}, .subject = "Re: Poetical science", .preview = "> Can imagination be taught?", .received = now_s - 400 * 86400 },
    .{ .id = "m6", .thread_id = "t6", .mailbox_ids = &.{"inbox"}, .from = &.{grace}, .to = &.{me}, .subject = "Nanoseconds", .preview = "I brought a wire 11.8 inches long.", .received = now_s - 7200 },
};

pub const detail_m1: k.Detail = .{
    .message = messages[0],
    .text = "Hi Alice,\n\nI've gone over the notes on the engine again and added the table of Bernoulli numbers.\nThe engine weaves algebraic patterns as the Jacquard loom weaves flowers.\n\nOn Wednesday, you wrote:\n> Could you send the notes?\n> Thanks!\n\nAda",
    .message_id = "<notes@example.test>",
    .references = &.{"<earlier@example.test>"},
    .attachments = &.{.{ .blob_id = "b1", .name = "notes.pdf", .type = "application/pdf", .size = 48213 }},
    .sent = now_s - 3600,
};

pub const Fixture = struct {
    rec: Recorder = .{},
    m: Model = undefined,

    /// Signed in, folders and the inbox's list in.
    pub fn init(f: *Fixture) void {
        f.* = .{};
        f.m = Model.init(gpa, f.rec.backend());
        f.m.now = fixedNow;
        feed(&f.m, .{ .connected = .{ .username = "alice@example.test", .account_id = "a1", .identities = &.{.{ .id = "i1", .name = "Alice", .email = "alice@example.test" }}, .can_send = true, .session_url = "http://x/jmap/session" } });
        feed(&f.m, .{ .folders = &folders });
        feed(&f.m, .{ .list = .{ .mailbox_id = "inbox", .query = "", .position = 0, .total = messages.len, .messages = &messages, .gen = f.m.list_gen } });
    }

    pub fn deinit(f: *Fixture) void {
        f.m.deinit();
        f.rec.deinit();
    }
};

pub fn shot(t: *ui.Tester, name: []const u8) !void {
    const dir = std.c.getenv("NANOMAIL_SHOTS") orelse return;
    var buf: [512]u8 = undefined;
    try t.screenshot(try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }));
}

test "signing in asks the server, then opens the inbox" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var m = Model.init(gpa, rec.backend());
    defer m.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&m, view.view), .{ .width = 1100, .height = 720 });
    defer t.deinit();
    t.settle(0.3);
    try std.testing.expect(t.hasText("Sign In"));
    try t.clickText("Sign In");
    try std.testing.expect(t.containsText("Enter your address"));
    try std.testing.expectEqual(@as(usize, 0), rec.count(.connect));
    m.form.email.set("alice@example.test");
    m.form.password.set("secret");
    try shot(&t, "login");
    try t.clickText("Sign In");
    const job = rec.last(.connect).?;
    try std.testing.expectEqualStrings("alice@example.test", job.username);
    try std.testing.expectEqualStrings("secret", job.secret);
    try std.testing.expect(!job.token);
    try std.testing.expectEqual(model_mod.Phase.connecting, m.phase);

    feed(&m, .{ .connect_failed = .{ .message = "The server said the password is wrong.", .unauthorized = true } });
    t.settle(0.3);
    try std.testing.expect(t.hasText("The server said the password is wrong."));

    m.signIn();
    feed(&m, .{ .connected = .{ .username = "alice@example.test", .account_id = "a1", .identities = &.{}, .can_send = true, .session_url = "http://x" } });
    try std.testing.expectEqual(model_mod.Phase.ready, m.phase);
    try std.testing.expectEqual(@as(usize, 1), rec.count(.mailboxes));
    feed(&m, .{ .folders = &folders });
    const list = rec.last(.list).?;
    try std.testing.expectEqualStrings("inbox", list.mailbox_id);
    t.settle(0.3);
    try std.testing.expect(t.hasText("Receipts"));
}

test "the list shows the inbox; a click opens a message and marks it read" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 1180, .height = 720 });
    defer t.deinit();
    t.settle(0.3);
    try std.testing.expect(t.hasText("Inbox"));
    try std.testing.expect(t.hasText("Ada Lovelace"));
    try std.testing.expect(t.hasText("Compiler meeting moved"));
    try std.testing.expect(t.hasText("No message selected"));
    try std.testing.expect(t.hasText("Yesterday"));
    // Too long for its row: cut with an ellipsis.
    try std.testing.expect(t.containsText("…"));
    try t.clickText("Compiler meeting moved");
    try std.testing.expectEqualStrings("m2", f.m.selected.?);
    try std.testing.expectEqualStrings("m2", f.rec.last(.detail).?.id);
    // Already read: nothing to mark.
    try std.testing.expectEqual(@as(usize, 0), f.rec.count(.keyword));

    try t.clickText("The Analytical Engine, notes for Thursday");
    const kw = f.rec.last(.keyword).?;
    try std.testing.expectEqual(k.Keyword.seen, kw.keyword);
    try std.testing.expect(kw.on);
    try std.testing.expectEqualStrings("m1", kw.ids[0]);
    try std.testing.expectEqual(@as(u32, 2), f.m.folder("", "inbox").?.unread);
    feed(&f.m, .{ .detail = detail_m1 });
    t.settle(0.3);
    try std.testing.expect(t.containsText("Jacquard loom"));
    try std.testing.expect(t.hasText("notes.pdf"));
    try std.testing.expect(t.containsText("Could you send the notes?"));
    try shot(&t, "reader");
    try t.clickText("notes.pdf");
    try std.testing.expectEqualStrings("b1", f.rec.last(.download).?.blob_id);
}

test "keys move through the list, archive and flag" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 1180, .height = 720 });
    defer t.deinit();
    t.settle(0.2);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try std.testing.expectEqualStrings("m1", f.m.selected.?);
    t.typeText("j");
    try std.testing.expectEqualStrings("m2", f.m.selected.?);
    t.typeText("s");
    try std.testing.expect(!f.m.messages.items[1].flags.flagged);
    try std.testing.expect(!f.rec.last(.keyword).?.on);
    t.typeText("e");
    const mv = f.rec.last(.move).?;
    try std.testing.expectEqualStrings("m2", mv.ids[0]);
    try std.testing.expectEqualStrings("archive", mv.to);
    try std.testing.expectEqualStrings("inbox", mv.from.?);
    try std.testing.expectEqual(@as(usize, 5), f.m.messages.items.len);
    // The next message opens in its place.
    try std.testing.expectEqualStrings("m3", f.m.selected.?);
    t.key(.backspace);
    try std.testing.expectEqualStrings("trash", f.rec.last(.move).?.to);
    try std.testing.expectEqual(@as(usize, 4), f.m.messages.items.len);
    t.typeText("k");
    try std.testing.expectEqualStrings("m1", f.m.selected.?);
}

test "searching asks for the folder's matches" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 1180, .height = 720 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("Search");
    t.typeText("engine");
    t.key(.enter);
    const l = f.rec.last(.list).?;
    try std.testing.expectEqualStrings("engine", l.query);
    try std.testing.expectEqualStrings("inbox", l.mailbox_id);
    feed(&f.m, .{ .list = .{ .mailbox_id = "inbox", .query = "engine", .position = 0, .total = 1, .messages = messages[0..1], .gen = f.m.list_gen } });
    t.settle(0.2);
    try std.testing.expect(t.hasText("1 found"));
    try std.testing.expect(!t.hasText("Compiler meeting moved"));
}

test "a reply is addressed, quoted and threaded" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.m.select(0);
    feed(&f.m, .{ .detail = detail_m1 });
    f.m.compose(.reply_all);
    try std.testing.expectEqual(@as(usize, 1), f.m.composes.items.len);
    const cm = f.m.composes.items[0];
    try std.testing.expectEqualStrings("Ada Lovelace <ada@example.test>", cm.to.text());
    try std.testing.expectEqualStrings("Grace Hopper <grace@example.test>", cm.cc.text());
    try std.testing.expectEqualStrings("Re: The Analytical Engine, notes for Thursday", cm.subject.text());
    try std.testing.expect(std.mem.indexOf(u8, cm.body.text(), "Ada Lovelace wrote:\n> Hi Alice,") != null);
    try std.testing.expect(std.mem.indexOf(u8, cm.body.text(), ">> Could you send the notes?") != null);
    try std.testing.expectEqualStrings("<notes@example.test>", cm.in_reply_to.?);
    try std.testing.expectEqual(@as(usize, 2), cm.references.len);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(cm, @import("compose.zig").Compose.view), .{ .width = 720, .height = 560 });
    defer t.deinit();
    t.settle(0.3);
    try std.testing.expect(t.hasText("Send"));
    // The caret starts in the text; Return makes a new line there.
    t.typeText("Splendid.");
    t.key(.enter);
    try std.testing.expect(std.mem.startsWith(u8, cm.body.text(), "Splendid.\n"));
    try shot(&t, "compose");
    try t.clickText("Send");
    const s = f.rec.last(.send).?;
    try std.testing.expectEqualStrings("i1", s.identity_id);
    try std.testing.expectEqualStrings("ada@example.test", s.to[0].email);
    try std.testing.expectEqualStrings("grace@example.test", s.cc[0].email);
    try std.testing.expectEqual(k.Keyword.answered, s.original_keyword.?);
    try std.testing.expectEqualStrings("m1", s.original_id.?);
    try std.testing.expectEqualStrings("drafts", s.drafts_id.?);
    try std.testing.expectEqualStrings("sent", s.sent_id.?);
    try std.testing.expect(cm.sending);
    feed(&f.m, .{ .sent = .{ .compose = cm.id, .draft_only = false } });
    try std.testing.expectEqual(@as(usize, 0), f.m.composes.items.len);
}

test "a message with no one to send to isn't sent" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.m.compose(.new);
    const cm = f.m.composes.items[0];
    cm.to.set("not an address");
    cm.sendNow(false);
    try std.testing.expectEqual(@as(usize, 0), f.rec.count(.send));
    try std.testing.expect(std.mem.indexOf(u8, cm.errorText(), "isn't an address") != null);
    cm.to.set("");
    cm.sendNow(false);
    try std.testing.expectEqualStrings("Add someone to send it to.", cm.errorText());
    // A draft needs no one.
    cm.sendNow(true);
    try std.testing.expect(f.rec.last(.send).?.draft_only);
}

test "dark appearance" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.m.select(0);
    feed(&f.m, .{ .detail = detail_m1 });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 1180, .height = 720, .dark = true });
    defer t.deinit();
    t.settle(0.3);
    try shot(&t, "dark");
}

test "the kept account, unreachable: an offline screen that tries again" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var m = Model.init(gpa, rec.backend());
    defer m.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&m, view.view), .{ .width = 1100, .height = 720 });
    defer t.deinit();
    m.connect(.{ .server = "https://mail.example.test", .username = "alice@example.test", .secret = "kept" }, false);
    t.settle(0.2);
    try std.testing.expect(t.hasText("Connecting to alice@example.test…"));
    feed(&m, .{ .connect_failed = .{ .message = "Couldn't reach mail.example.test (ConnectionRefused).", .unauthorized = false } });
    t.settle(0.2);
    try std.testing.expectEqual(model_mod.Phase.offline, m.phase);
    try std.testing.expect(t.hasText("Can't reach your mail"));
    try shot(&t, "offline");
    try t.clickText("Try Again");
    try std.testing.expectEqual(@as(usize, 2), rec.count(.connect));
    try std.testing.expectEqualStrings("kept", rec.last(.connect).?.secret);
    // A password the server refuses goes back to the form.
    feed(&m, .{ .connect_failed = .{ .message = "The server didn't accept this address and password.", .unauthorized = true } });
    try std.testing.expectEqual(model_mod.Phase.signed_out, m.phase);
    m.retry();
    feed(&m, .{ .connect_failed = .{ .message = "down", .unauthorized = false } });
    t.settle(0.2);
    try t.clickText("Use Another Account");
    try std.testing.expectEqual(model_mod.Phase.signed_out, m.phase);
    try std.testing.expect(t.hasText("Sign In"));
}

test "signing out stops the sync thread's account" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.m.signOut();
    try std.testing.expectEqual(@as(usize, 1), f.rec.count(.sign_out));
    try std.testing.expectEqual(model_mod.Phase.signed_out, f.m.phase);
    try std.testing.expectEqual(@as(usize, 0), f.m.messages.items.len);
}

test "a draft opens again for editing, and replaces itself when sent" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var draft = messages[0];
    draft.id = "d1";
    draft.flags = .{ .draft = true, .seen = true };
    draft.subject = "Half written";
    feed(&f.m, .{ .list = .{ .mailbox_id = "inbox", .query = "", .position = 0, .total = 1, .messages = &.{draft}, .gen = f.m.list_gen } });
    f.m.select(0);
    feed(&f.m, .{ .detail = .{ .message = draft, .text = "Dear Ada,\n\nso far", .in_reply_to = "<orig@x>" } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 1180, .height = 720 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("Edit Draft");
    const cm = f.m.composes.items[0];
    try std.testing.expectEqualStrings("Half written", cm.subject.text());
    try std.testing.expectEqualStrings("Dear Ada,\n\nso far", cm.body.text());
    try std.testing.expectEqualStrings("Alice <alice@example.test>", cm.to.text());
    try std.testing.expect(cm.show_cc);
    cm.sendNow(false);
    const s = f.rec.last(.send).?;
    try std.testing.expectEqualStrings("d1", s.replaces.?);
    try std.testing.expectEqualStrings("<orig@x>", s.in_reply_to.?);
    try std.testing.expect(s.original_keyword == null);
}

test "answers from before signing out are dropped" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const old = f.m.session;
    f.m.signOut();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const ev = copy.deep(k.Event, arena.allocator(), .{ .connected = .{ .username = "late@example.test", .account_id = "a", .identities = &.{}, .can_send = true, .session_url = "x" } }) catch unreachable;
    f.m.applyFrom(arena, old, ev);
    try std.testing.expectEqual(model_mod.Phase.signed_out, f.m.phase);
    var arena2: std.heap.ArenaAllocator = .init(gpa);
    const folders_ev = copy.deep(k.Event, arena2.allocator(), .{ .folders = &folders }) catch unreachable;
    f.m.applyFrom(arena2, old, folders_ev);
    try std.testing.expectEqual(@as(usize, 0), f.m.folders.len);
    try std.testing.expect(f.rec.last(.session).? == f.m.session);
}

test "delete forever deletes the message it asked about" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.m.openMailbox("", "trash");
    var trashed = messages[0..3].*;
    for (&trashed) |*t_| t_.mailbox_ids = &.{"trash"};
    // Also filed under Receipts: deleting it here only takes it out of the trash.
    trashed[2].mailbox_ids = &.{ "trash", "receipts" };
    feed(&f.m, .{ .list = .{ .mailbox_id = "trash", .query = "", .position = 0, .total = 3, .messages = &trashed, .gen = f.m.list_gen } });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 1180, .height = 720 });
    defer t.deinit();
    f.m.select(0);
    t.key(.backspace);
    try std.testing.expect(f.m.confirm_destroy);
    // Keys don't move the selection under the question.
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.typeText("j");
    try std.testing.expectEqualStrings("m1", f.m.selected.?);
    f.m.step(1);
    t.settle(0.3);
    try t.clickText("Delete");
    try std.testing.expectEqualStrings("m1", f.rec.last(.destroy).?.ids[0]);
    try std.testing.expect(f.m.indexOf("m1") == null);
    try std.testing.expect(f.m.indexOf("m2") != null);
    f.m.select(f.m.indexOf("m3").?);
    f.m.trash();
    f.m.destroySelected();
    const mv = f.rec.last(.move).?;
    try std.testing.expectEqualStrings("m3", mv.ids[0]);
    try std.testing.expectEqualStrings("trash", mv.from.?);
    try std.testing.expectEqualStrings("receipts", mv.to);
    try std.testing.expectEqual(@as(usize, 1), f.rec.count(.destroy));
}

test "signing in through the browser: the page opens, then a wait that can be called off" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var cancels: u32 = 0;
    const Cancel = struct {
        fn f(ctx: *anyopaque) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    var m = Model.init(gpa, rec.backend());
    defer m.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&m, view.view), .{ .width = 1100, .height = 760 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("Browser");
    try std.testing.expect(t.hasText("Continue in Browser"));
    try std.testing.expect(!t.hasText("Password or app password"));
    m.form.email.set("alice@example.test");
    try shot(&t, "login-browser");
    try t.clickText("Continue in Browser");
    const job = rec.last(.oauth).?;
    try std.testing.expectEqualStrings("alice@example.test", job.username);
    try std.testing.expectEqualStrings("", job.client_id);
    feed(&m, .{ .browser = .{ .url = "http://127.0.0.1:8080/login?client_id=x" } });
    t.settle(0.2);
    try std.testing.expectEqual(model_mod.Phase.browser, m.phase);
    try std.testing.expect(t.hasText("Continue in your browser"));
    try shot(&t, "browser-wait");
    // Called off: the sync thread is told, and the form is back.
    m.backend = .{ .ctx = &cancels, .submit = struct {
        fn f(_: *anyopaque, _: k.Job) void {}
    }.f, .cancel = Cancel.f };
    try t.clickText("Cancel");
    try std.testing.expectEqual(@as(u32, 1), cancels);
    try std.testing.expectEqual(model_mod.Phase.signed_out, m.phase);
    try std.testing.expect(m.browser_url == null);
}

test "through the browser and back: the account is kept with its refresh token" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var saved: ?[]const u8 = null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const H = struct {
        var out: *?[]const u8 = undefined;
        var a: std.mem.Allocator = undefined;
        fn save(_: *anyopaque, acc: k.Account, _: []const u8) void {
            out.* = a.dupe(u8, acc.secret) catch null;
        }
        fn none(_: *anyopaque) void {}
        fn compose(_: *anyopaque, _: *model_mod.Compose) void {}
        fn path(_: *anyopaque, _: []const u8) void {}
        fn html(_: *anyopaque, _: []const u8, _: []const u8) void {}
    };
    H.out = &saved;
    H.a = arena.allocator();
    var m = Model.init(gpa, rec.backend());
    defer m.deinit();
    m.host = .{ .ctx = &m, .open_compose = H.compose, .close_compose = H.compose, .save_account = H.save, .forget_account = H.none, .reveal = H.path, .open_html = H.html, .open_url = H.path, .sign_in = H.path, .update_secret = H.path, .later = H.none };
    m.form.kind = 2;
    m.form.email.set("alice@example.test");
    m.signIn();
    feed(&m, .{ .connected = .{ .username = "alice@example.test", .account_id = "c", .identities = &.{}, .can_send = true, .session_url = "http://x/jmap/session", .save = .{ .username = "alice@example.test", .secret = "refresh-1", .token = true, .oauth = .{ .client_id = "cid", .token_endpoint = "http://x/auth/token" } } } });
    try std.testing.expectEqual(model_mod.Phase.ready, m.phase);
    try std.testing.expectEqualStrings("refresh-1", saved.?);
}
