//! The message open: a toolbar (reply, forward, archive, trash, flag,
//! unread, move), then its subject, who it's from and to, attachments,
//! and its text, quoted lines set apart. The text can be selected and
//! copied.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const k = @import("mail/kinds.zig");
const dates = @import("mail/dates.zig");
const address = @import("mail/address.zig");
const util = @import("view_util.zig");
const bodies = @import("view_body.zig");
const ios = @import("builtin").os.tag == .ios;

pub fn view(m: *Model, c: *ui.Context, pane: util.Pane) void {
    const th = c.theme;
    const col = ui.div(c).column().grow().hFull().bg(th.surface);
    defer col.end();
    const msg = m.selectedMessage();
    if (pane.stacked) stackedBar(m, c, msg) else toolbar(m, c, msg);
    util.hline(c);
    // Stacked, the actions that didn't fit at the top are at the foot.
    defer if (pane.stacked and msg != null) footBar(m, c, msg.?);
    const sel = msg orelse {
        const e = ui.div(c).column().sizeFull().center();
        defer e.end();
        kit.empty(c, .{ .icon = "envelope", .title = "No message selected", .description = if (m.messages.items.len > 0) "Choose one from the list, or use ↑ and ↓." else "" });
        return;
    };
    const d = m.detail(sel.account_id, sel.id) orelse {
        const e = ui.div(c).column().sizeFull().center().gap(10);
        defer e.end();
        if (m.detailError(sel.id)) |why| {
            kit.empty(c, .{ .icon = "exclamationmark.triangle", .title = "Couldn't open this message", .description = why });
            if (kit.button(c, "Try Again", .{}).clicked) m.fetchDetail(sel.account_id, sel.id);
        } else kit.spinner(c, .{ .size = 20 });
        return;
    };
    ui.key(c, sel.id);
    const sc = ui.div(c).column().wFull().grow().scrollY().px(if (pane.stacked) 16 else 32).pt(if (pane.stacked) 16 else 24).pb(40).gap(16);
    defer sc.end();
    head(m, c, d, sel.*, pane.stacked);
    if (d.attachments.len > 0) {
        bodies.attachedPictures(m, c, d);
        attachments(m, c, d);
    }
    if (d.remote_pictures and !m.remoteAllowed(d.message.id)) {
        const note = ui.div(c).row().wFull().gap(8).itemsCenter().px(12).py(8).rounded(8).bg(th.background);
        defer note.end();
        ui.icon(c, "photo", .{ .size = 13, .color = th.muted });
        {
            const t = ui.div(c).grow();
            defer t.end();
            ui.text(c, "Pictures from the web are hidden: loading them tells the sender you read this.", .{ .size = 12.5, .color = th.muted, .wrap = true });
        }
        if (kit.button(c, "Load Pictures", .{ .size = .xs, .variant = .outline }).clicked) m.allowRemote(d.message.id);
    }
    if (d.from_html and d.html != null and !ios) {
        const note = ui.div(c).row().wFull().gap(8).itemsCenter().px(12).py(8).rounded(8).bg(th.background);
        defer note.end();
        ui.icon(c, "doc.richtext", .{ .size = 13, .color = th.muted });
        ui.text(c, "This message was written in HTML and is shown as text.", .{ .size = 12.5, .color = th.muted });
        ui.spacer(c);
        if (kit.button(c, "Open in Browser", .{ .size = .xs, .variant = .outline }).clicked) openHtml(m, d);
    }
    util.hline(c);
    bodies.body(m, c, d);
    // Where the link under the pointer goes, as a browser shows it.
    if (bodies.hover_url) |url| {
        const pill = ui.div(c).fixed().offset(pane.x + 14, c.size.h - 34).layer(5).px(10).py(5).rounded(8).bg(th.text.alpha(0.85));
        defer pill.end();
        util.line(c, url, .{ .size = 12, .color = th.background }, @max(120, pane.w - 60));
    }
}

/// Stacked: back to the list, and what fits beside it.
fn stackedBar(m: *Model, c: *ui.Context, msg: ?*k.Message) void {
    const bar = ui.div(c).row().wFull().h(48).px(8).gap(2).itemsCenter();
    defer bar.end();
    const name = if (m.currentFolder()) |f| f.name else "Back";
    if (util.back(c, util.fit(c, name, .{ .size = 15 }, 140))) m.screen = .list;
    ui.spacer(c);
    const none = msg == null;
    const flagged = if (msg) |x| x.flags.flagged else false;
    if (kit.iconButton(c, if (flagged) "flag.fill" else "flag", .{ .disabled = none, .selected = flagged, .size = .lg }).clicked) m.toggleFlag();
    const seen = if (msg) |x| x.flags.seen else true;
    if (kit.iconButton(c, if (seen) "envelope.badge" else "envelope.open", .{ .disabled = none, .size = .lg }).clicked) m.toggleSeen();
    const mv = kit.iconButton(c, "folder", .{ .disabled = none, .size = .lg });
    if (mv.clicked) m.move_open = !m.move_open;
    m.move_at = mv.rect;
    moveMenu(m, c);
}

/// Stacked: archive, trash, reply, forward, a new message.
fn footBar(m: *Model, c: *ui.Context, msg: *k.Message) void {
    util.hline(c);
    const bar = ui.div(c).row().wFull().h(50).px(12).itemsCenter().justifyBetween();
    defer bar.end();
    const loaded = m.detail(msg.account_id, msg.id) != null;
    const r = m.rights();
    if (msg.flags.draft) {
        if (kit.button(c, "Edit Draft", .{ .icon = "square.and.pencil", .disabled = !loaded }).clicked) m.compose(.draft);
        return;
    }
    if (kit.iconButton(c, "archivebox", .{ .size = .lg, .disabled = !r.remove or m.folderByRoleIn(msg.account_id, .archive) == null }).clicked) m.archive();
    if (kit.iconButton(c, "trash", .{ .size = .lg, .disabled = !r.remove }).clicked) m.trash();
    if (kit.iconButton(c, "arrowshape.turn.up.left", .{ .size = .lg, .disabled = !loaded }).clicked) m.compose(.reply);
    if (kit.iconButton(c, "arrowshape.turn.up.left.2", .{ .size = .lg, .disabled = !loaded }).clicked) m.compose(.reply_all);
    if (kit.iconButton(c, "arrowshape.turn.up.right", .{ .size = .lg, .disabled = !loaded }).clicked) m.compose(.forward);
    if (kit.iconButton(c, "square.and.pencil", .{ .size = .lg }).clicked) m.compose(.new);
}

fn toolbar(m: *Model, c: *ui.Context, msg: ?*k.Message) void {
    const bar = ui.div(c).row().wFull().h(util.toolbar_h).px(12).gap(2).itemsCenter();
    defer bar.end();
    const none = msg == null;
    const loaded = if (msg) |x| m.detail(x.account_id, x.id) != null else false;
    const r = m.rights();
    if (msg != null and msg.?.flags.draft) {
        if (kit.button(c, "Edit Draft", .{ .icon = "square.and.pencil", .size = .sm, .disabled = !loaded }).clicked) m.compose(.draft);
    } else {
        if (kit.iconButton(c, "arrowshape.turn.up.left", .{ .tooltip = "Reply (r)", .disabled = !loaded }).clicked) m.compose(.reply);
        if (kit.iconButton(c, "arrowshape.turn.up.left.2", .{ .tooltip = "Reply All (a)", .disabled = !loaded }).clicked) m.compose(.reply_all);
        if (kit.iconButton(c, "arrowshape.turn.up.right", .{ .tooltip = "Forward (f)", .disabled = !loaded }).clicked) m.compose(.forward);
    }
    ui.spacer(c);
    const no_archive = if (msg) |x| m.folderByRoleIn(x.account_id, .archive) == null else true;
    if (kit.iconButton(c, "archivebox", .{ .tooltip = "Archive (e)", .disabled = none or !r.remove or no_archive }).clicked) m.archive();
    if (kit.iconButton(c, "trash", .{ .tooltip = "Delete (⌫)", .disabled = none or !r.remove }).clicked) m.trash();
    const flagged = if (msg) |x| x.flags.flagged else false;
    if (kit.iconButton(c, if (flagged) "flag.fill" else "flag", .{ .tooltip = if (flagged) "Unflag (s)" else "Flag (s)", .disabled = none or !r.keywords, .selected = flagged }).clicked) m.toggleFlag();
    const seen = if (msg) |x| x.flags.seen else true;
    if (kit.iconButton(c, if (seen) "envelope.badge" else "envelope.open", .{ .tooltip = if (seen) "Mark as Unread (u)" else "Mark as Read (u)", .disabled = none or !r.seen }).clicked) m.toggleSeen();
    const mv = kit.iconButton(c, "folder", .{ .tooltip = "Move to…", .disabled = none or !r.remove });
    if (mv.clicked) m.move_open = !m.move_open;
    m.move_at = mv.rect;
    moveMenu(m, c);
}

fn moveMenu(m: *Model, c: *ui.Context) void {
    var items: std.ArrayList(kit.MenuItem) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    // Moving stays within the account (between accounts it's a copy).
    const account = m.mailbox_account orelse "";
    for (m.folders) |f| {
        if (!std.mem.eql(u8, f.account_id, account) or !f.rights.add) continue;
        if (m.mailbox) |cur| if (std.mem.eql(u8, cur, f.id)) continue;
        items.append(c.alloc(), .{ .label = f.name, .icon = f.role.icon() }) catch return;
        ids.append(c.alloc(), f.id) catch return;
    }
    if (kit.menu(c, "move", &m.move_open, m.move_at, items.items, .{ .placement = .bottom_end, .width = 220 })) |i| m.moveSelected(ids.items[i]);
}

fn head(m: *Model, c: *ui.Context, d: *const k.Detail, msg: k.Message, narrow: bool) void {
    const th = c.theme;
    const a = c.alloc();
    ui.text(c, if (msg.subject.len > 0) msg.subject else "(no subject)", .{ .size = 21, .weight = .bold, .wrap = true });
    const r = ui.div(c).row().wFull().gap(12).itemsStart();
    defer r.end();
    const from: k.Address = if (msg.from.len > 0) msg.from[0] else .{ .email = "" };
    kit.avatar(c, .{ .name = from.display(), .size = 40 });
    {
        const who = ui.div(c).column().grow().gap(3);
        defer who.end();
        if (narrow) {
            // One thing a line: there's no room beside each other.
            ui.text(c, from.display(), .{ .size = 15, .weight = .semibold, .wrap = true });
            if (from.name != null and from.email.len > 0) ui.text(c, from.email, .{ .size = 12.5, .color = th.muted, .wrap = true });
        } else {
            const line = ui.div(c).row().gap(6).itemsCenter();
            defer line.end();
            ui.text(c, from.display(), .{ .size = 14, .weight = .semibold });
            if (from.name != null and from.email.len > 0) ui.text(c, c.print("<{s}>", .{from.email}), .{ .size = 12.5, .color = th.muted });
        }
        if (msg.to.len > 0) ui.text(c, c.print("To: {s}", .{address.names(a, msg.to) catch ""}), .{ .size = 12.5, .color = th.muted, .wrap = true });
        if (msg.cc.len > 0) ui.text(c, c.print("Cc: {s}", .{address.names(a, msg.cc) catch ""}), .{ .size = 12.5, .color = th.muted, .wrap = true });
        if (d.bcc.len > 0) ui.text(c, c.print("Bcc: {s}", .{address.names(a, d.bcc) catch ""}), .{ .size = 12.5, .color = th.muted, .wrap = true });
        if (d.reply_to.len > 0 and !(d.reply_to.len == 1 and std.ascii.eqlIgnoreCase(d.reply_to[0].email, from.email)))
            ui.text(c, c.print("Reply-To: {s}", .{address.format(a, d.reply_to) catch ""}), .{ .size = 12.5, .color = th.muted, .wrap = true });
        if (narrow) {
            var nbuf: [64]u8 = undefined;
            ui.text(c, c.print("{s}", .{dates.long(&nbuf, msg.received, false)}), .{ .size = 12, .color = th.muted });
        }
    }
    if (narrow) return;
    var buf: [64]u8 = undefined;
    ui.text(c, c.print("{s}", .{dates.long(&buf, msg.received, false)}), .{ .size = 12, .color = th.muted });
    _ = m;
}

fn attachments(m: *Model, c: *ui.Context, d: *const k.Detail) void {
    const th = c.theme;
    const col = ui.div(c).column().wFull().gap(6);
    defer col.end();
    for (d.attachments, 0..) |att, i| {
        ui.key(c, c.print("att-{d}", .{i}));
        const chip = ui.div(c).row().gap(8).itemsCenter().px(10).py(7).rounded(8).border(th.border).hover(th.surface_hover).control();
        defer chip.end();
        if (chip.clicked()) m.download(att);
        ui.icon(c, iconFor(att.type), .{ .size = 14, .color = th.accent });
        ui.text(c, att.name, .{ .size = 12.5, .weight = .medium });
        ui.text(c, util.size(c, att.size), .{ .size = 12, .color = th.muted });
        ui.icon(c, "arrow.down.circle", .{ .size = 13, .color = th.muted });
    }
}

fn iconFor(mime: []const u8) []const u8 {
    if (std.mem.startsWith(u8, mime, "image/")) return "photo";
    if (std.mem.eql(u8, mime, "application/pdf")) return "doc.richtext";
    if (std.mem.startsWith(u8, mime, "text/")) return "doc.text";
    if (std.mem.indexOf(u8, mime, "zip") != null) return "doc.zipper";
    if (std.mem.startsWith(u8, mime, "audio/")) return "waveform";
    if (std.mem.startsWith(u8, mime, "video/")) return "film";
    return "paperclip";
}

/// Opens the HTML as sent in the browser (the host writes the file).
fn openHtml(m: *Model, d: *const k.Detail) void {
    const h = m.host orelse return;
    h.open_html(h.ctx, d.message.id, d.html orelse return);
}
