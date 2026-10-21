//! A compose window: To, Cc and Bcc, the subject, who it's from (when
//! there's a choice), and the text; Send in the toolbar. Return makes a
//! new line in the text, Tab goes to the next field.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Compose = @import("compose.zig").Compose;
const util = @import("view_util.zig");

pub fn view(cm: *Compose, c: *ui.Context) void {
    const th = c.theme;
    c.title_bar_height = util.toolbar_h;
    const root = ui.div(c).column().sizeFull().bg(th.surface);
    defer root.end();
    toolbar(cm, c);
    util.hline(c);
    if (cm.error_len > 0) {
        const e = ui.div(c).wFull().px(16).pt(10);
        defer e.end();
        if (kit.alert(c, .{ .status = .danger, .title = "Not sent", .description = cm.errorText(), .closable = true })) cm.error_len = 0;
    }
    if (cm.notice.len > 0) {
        const e = ui.div(c).wFull().px(16).pt(10);
        defer e.end();
        if (kit.alert(c, .{ .status = .warning, .description = cm.notice, .closable = true })) cm.notice = "";
    }
    // The fields' ids, for Tab and the first focus.
    var ids: [6]u64 = undefined;
    var count: usize = 0;
    ids[count] = field(cm, c, "To:", &cm.to, true);
    count += 1;
    if (cm.show_cc) {
        ids[count] = field(cm, c, "Cc:", &cm.cc, false);
        count += 1;
        ids[count] = field(cm, c, "Bcc:", &cm.bcc, false);
        count += 1;
    }
    ids[count] = field(cm, c, "Subject:", &cm.subject, false);
    count += 1;
    if (cm.model.identities.len > 1) from(cm, c);
    {
        const b = ui.div(c).column().wFull().grow().px(16).py(12).clip();
        defer b.end();
        ids[count] = c.peekId(null);
        count += 1;
        const lines: u16 = @intFromFloat(@max(4, (c.size.h - 200) / 19));
        const r = ui.textField(c, &cm.body, .{ .multiline = true, .bare = true, .width = .fill, .max_lines = lines, .size = 14 });
        // Return is a new line in a letter, not "send".
        if (r.submitted) {
            const at = @min(r.caret, cm.body.len);
            const n = cm.body.insert(at, "\n");
            cm.body.want_caret = at + n;
        }
    }
    if (cm.attachments.len > 0) {
        util.hline(c);
        const a = ui.div(c).row().wFull().px(16).py(10).gap(8).itemsCenter();
        defer a.end();
        ui.icon(c, "paperclip", .{ .size = 12, .color = th.muted });
        for (cm.attachments, 0..) |att, i| {
            ui.key(c, c.print("fwd-{d}", .{i}));
            kit.tag(c, att.name, .{});
        }
    }
    // The caret starts in To, or in the text of a reply.
    if (!cm.focused_once) {
        cm.focused_once = true;
        c.focus = if (cm.kind == .reply or cm.kind == .reply_all) ids[count - 1] else ids[0];
    }
    if (c.shortcut(.{ .key = ui.Shortcut.tab })) moveFocus(c, ids[0..count], 1);
    if (c.shortcut(.{ .key = ui.Shortcut.tab, .shift = true })) moveFocus(c, ids[0..count], -1);
    if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) cm.sendNow(false);
}

fn moveFocus(c: *ui.Context, ids: []const u64, dir: i2) void {
    var at: usize = 0;
    for (ids, 0..) |id, i| if (id == c.focus) {
        at = i;
        break;
    };
    const n = ids.len;
    c.focus = ids[if (dir > 0) (at + 1) % n else (at + n - 1) % n];
}

fn toolbar(cm: *Compose, c: *ui.Context) void {
    const th = c.theme;
    // Without a window's close button (iOS, a narrow window): Cancel.
    const cancel = util.ios or c.size.w < 600;
    const bar = ui.div(c).row().wFull().h(util.toolbar_h).pl(if (util.ios) 12 else 84).pr(14).gap(8).itemsCenter();
    defer bar.end();
    if (cancel and kit.button(c, "Cancel", .{ .variant = .ghost, .size = .sm }).clicked) cm.model.dismissCompose(cm);
    util.line(c, cm.title(), .{ .size = 13, .weight = .semibold, .color = th.muted }, @max(0, c.size.w - 84 - 14 - 220 - @as(f32, if (cancel) 80 else 0)));
    ui.spacer(c);
    if (kit.button(c, "Save Draft", .{ .variant = .ghost, .size = .sm, .disabled = cm.sending }).clicked) cm.sendNow(true);
    if (kit.button(c, if (cm.sending) "Sending…" else "Send", .{ .variant = .primary, .size = .sm, .icon = "paperplane.fill", .loading = cm.sending, .tooltip = "Send (⌘↩)" }).clicked) cm.sendNow(false);
}

/// A labelled one-line field; returns its text field's id.
fn field(cm: *Compose, c: *ui.Context, label: []const u8, buf: *ui.TextBuffer, cc_toggle: bool) u64 {
    const th = c.theme;
    var id: u64 = 0;
    {
        const r = ui.div(c).row().wFull().h(40).px(16).gap(8).itemsCenter();
        defer r.end();
        ui.text(c, label, .{ .size = 13, .color = th.muted });
        id = c.peekId(null);
        _ = ui.textField(c, buf, .{ .bare = true, .width = .fill, .size = 13.5 });
        if (cc_toggle and !cm.show_cc and kit.button(c, "Cc/Bcc", .{ .variant = .link, .size = .xs }).clicked) cm.show_cc = true;
    }
    util.hline(c);
    return id;
}

fn from(cm: *Compose, c: *ui.Context) void {
    const th = c.theme;
    {
        const r = ui.div(c).row().wFull().h(40).px(16).gap(8).itemsCenter();
        defer r.end();
        ui.text(c, "From:", .{ .size = 13, .color = th.muted });
        var names: std.ArrayList([]const u8) = .empty;
        for (cm.model.identities) |id| {
            const s = if (id.name.len > 0) c.print("{s} <{s}>", .{ id.name, id.email }) else id.email;
            names.append(c.alloc(), s) catch return;
        }
        _ = kit.select(c, "from", names.items, &cm.identity, .{ .width = 320 });
    }
    util.hline(c);
}
