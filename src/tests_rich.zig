//! The reader's rich text through ui.Tester: links that open (and say
//! where they go), pictures in the text and attached, pictures from the
//! web held back until asked for.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const k = @import("mail/kinds.zig");
const model_mod = @import("model.zig");
const view = @import("view.zig");
const tv = @import("tests_views.zig");

const gpa = std.testing.allocator;
const png = @embedFile("testdata/sunrise.png");

const text = "Hi Alice,\n\nThe notes are at https://notes.example.test/engine now.\nOr ask me.\n\n\u{FFFC}\n\n\u{FFFC}\n\nAda";

fn detail() k.Detail {
    return .{
        .message = tv.messages[0],
        .text = text,
        .links = &.{
            .{ .start = 28, .end = 61, .url = "https://notes.example.test/engine" },
            .{ .start = 70, .end = 76, .url = "mailto:ada@example.test?subject=Notes" },
        },
        .pictures = &.{
            .{ .blob_id = "inline-1", .type = "image/png", .alt = "The engine" },
            .{ .url = "https://tracker.example.test/banner.png", .alt = "Banner" },
        },
        .remote_pictures = true,
        .attachments = &.{.{ .blob_id = "att-1", .name = "sunrise.png", .type = "image/png", .size = png.len }},
    };
}

/// The rectangle of the first text drawn that contains `s`, and that text.
fn textWith(t: *ui.Tester, s: []const u8) ?struct { rect: ui.Rect, str: []const u8 } {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.indexOf(u8, tx.str, s) != null) return .{ .rect = n.rect, .str = tx.str },
        else => {},
    };
    return null;
}

const Opened = struct {
    var url: [256]u8 = undefined;
    var len: usize = 0;
    fn open(_: *anyopaque, u: []const u8) void {
        len = @min(u.len, url.len);
        @memcpy(url[0..len], u[0..len]);
    }
    fn none(_: *anyopaque) void {}
    fn compose(_: *anyopaque, _: *model_mod.Compose) void {}
    fn save(_: *anyopaque, _: k.Account, _: []const u8) void {}
    fn html(_: *anyopaque, _: []const u8, _: []const u8) void {}
};

test "links open, pictures show, and the web's wait until asked" {
    var f: tv.Fixture = undefined;
    f.init();
    defer f.deinit();
    f.m.host = .{ .ctx = &f, .open_compose = Opened.compose, .close_compose = Opened.compose, .save_account = Opened.save, .forget_account = Opened.none, .reveal = Opened.open, .open_html = Opened.html, .open_url = Opened.open, .sign_in = Opened.open, .update_secret = Opened.open, .later = Opened.none };
    f.m.select(0);
    tv.feed(&f.m, .{ .detail = detail() });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&f.m, view.view), .{ .width = 1180, .height = 820 });
    defer t.deinit();
    t.settle(0.3);
    // The message's own pictures are asked for; the one on the web isn't.
    try std.testing.expectEqual(@as(usize, 2), f.rec.count(.picture));
    try std.testing.expect(t.hasText("Load Pictures"));
    tv.feed(&f.m, .{ .picture = .{ .key = "inline-1", .bytes = png } });
    tv.feed(&f.m, .{ .picture = .{ .key = "att-1", .bytes = png } });
    t.settle(0.3);
    var images: usize = 0;
    for (t.ctx.nodes.items) |n| images += @intFromBool(n.content == .image);
    try std.testing.expectEqual(@as(usize, 2), images);

    // A click on the link opens it.
    const para = textWith(&t, "The notes are at").?;
    const style: ui.TextStyle = .{ .size = 14, .wrap = true, .leading = 1.35 };
    const before = t.ctx.text.width("The notes are at https://notes", style);
    t.moveTo(para.rect.x + before, para.rect.y + 6);
    t.settle(0.1);
    try std.testing.expect(t.hasText("https://notes.example.test/engine"));
    try tv.shot(&t, "rich");
    t.click(para.rect.x + before, para.rect.y + 6);
    try std.testing.expectEqualStrings("https://notes.example.test/engine", Opened.url[0..Opened.len]);
    // Plain words beside it aren't a link.
    Opened.len = 0;
    t.click(para.rect.x + 8, para.rect.y + 6);
    try std.testing.expectEqual(@as(usize, 0), Opened.len);

    // A mail address opens a message to it.
    const ask = textWith(&t, "Or ask me.").?;
    const lh = t.ctx.text.lineHeight(style);
    t.click(ask.rect.x + t.ctx.text.width("Or ", style) + 4, ask.rect.y + lh * 1.5);
    try std.testing.expectEqual(@as(usize, 1), f.m.composes.items.len);
    try std.testing.expectEqualStrings("ada@example.test", f.m.composes.items[0].to.text());
    try std.testing.expectEqualStrings("Notes", f.m.composes.items[0].subject.text());
    try std.testing.expect(!f.m.composes.items[0].dirty());

    // Asked for: the picture from the web loads.
    try t.clickText("Load Pictures");
    t.settle(0.2);
    try std.testing.expectEqualStrings("https://tracker.example.test/banner.png", f.rec.last(.picture).?.url.?);
    try std.testing.expect(!t.hasText("Load Pictures"));
}
