//! The list of the folder open: a search field over the messages, newest
//! first, each with its sender, date, subject and preview; unread ones
//! marked with a dot. Only the rows in view are built; nearing the end
//! fetches the next page.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const k = @import("mail/kinds.zig");
const dates = @import("mail/dates.zig");
const util = @import("view_util.zig");

pub fn view(m: *Model, c: *ui.Context, pane: util.Pane) void {
    const th = c.theme;
    const col = ui.div(c).column().w(pane.w).hFull().bg(th.surface);
    defer col.end();
    if (pane.stacked) {
        const b = ui.div(c).row().wFull().px(8).pt(6);
        defer b.end();
        if (util.back(c, "Mailboxes")) m.screen = .folders;
    }
    header(m, c, pane);
    {
        const s = ui.div(c).row().wFull().px(12).pb(10).gap(6).itemsCenter();
        defer s.end();
        const sid = c.peekId(null);
        if (m.focus_search) {
            c.focus = sid;
            m.focus_search = false;
        }
        const r = ui.textField(c, &m.search, .{ .placeholder = "Search", .width = .fill, .size = 13 });
        if (r.submitted) m.runSearch();
        // Cleared by hand: the whole folder again.
        if (r.changed and m.search.len == 0 and m.query.len > 0) m.runSearch();
        if (m.query.len > 0 and kit.iconButton(c, "xmark.circle.fill", .{ .size = .xs, .tooltip = "Clear search" }).clicked) {
            m.search.clear();
            m.runSearch();
        }
    }
    util.hline(c);
    const n = m.messages.items.len;
    if (n == 0) {
        const e = ui.div(c).column().wFull().grow().center();
        defer e.end();
        if (m.list_loading) {
            kit.spinner(c, .{ .size = 20 });
        } else if (m.query.len > 0) {
            kit.empty(c, .{ .icon = "magnifyingglass", .title = "No results", .description = c.print("Nothing here matches “{s}”.", .{m.query}) });
        } else kit.empty(c, .{ .icon = "tray", .title = "No messages" });
        return;
    }
    var scroll_to: ?f32 = null;
    if (m.reveal) {
        m.reveal = false;
        if (m.selectedIndex()) |i| scroll_to = revealOffset(m, c, i);
    }
    var rows = ui.list(c, .{ .count = n, .row_height = util.row_h, .scroll_to = scroll_to });
    var last: usize = 0;
    while (rows.next()) |i| {
        last = i;
        row(m, c, i, pane);
    }
    rows.end();
    if (last + 6 >= n and n < m.total) m.loadMore();
}

fn header(m: *Model, c: *ui.Context, pane: util.Pane) void {
    const th = c.theme;
    const h = ui.div(c).row().wFull().h(util.toolbar_h).pl(16).pr(8).gap(4).itemsCenter();
    defer h.end();
    {
        const t = ui.div(c).column().grow().gap(1);
        defer t.end();
        const f = m.currentFolder();
        util.line(c, if (f) |x| x.name else "Mail", .{ .size = if (pane.stacked) 24 else 15, .weight = .bold }, pane.w - 16 - 8 - 2 * 32 - 12);
        const sub = if (m.query.len > 0)
            c.print("{d} found", .{m.total})
        else if (f) |x|
            (if (x.unread > 0) c.print("{d} messages, {d} unread", .{ m.total, x.unread }) else c.print("{d} messages", .{m.total}))
        else
            "";
        ui.text(c, sub, .{ .size = 11.5, .color = th.muted });
    }
    if (kit.iconButton(c, "arrow.clockwise", .{ .size = .sm, .tooltip = "Get new mail", .loading = m.list_loading }).clicked) m.refresh();
    if (kit.iconButton(c, "square.and.pencil", .{ .size = .sm, .tooltip = "New message" }).clicked) m.compose(.new);
}

/// Where the list scrolls to show row `i`, or null when it's in view.
fn revealOffset(m: *Model, c: *ui.Context, i: usize) ?f32 {
    _ = m;
    const id = c.peekId(null);
    const view_h = if (c.rects.get(id)) |r| r.h else return null;
    const top = @as(f32, @floatFromInt(i)) * util.row_h;
    const now = c.scroll.get(id) orelse 0;
    if (top < now) return top;
    if (top + util.row_h > now + view_h) return top + util.row_h - view_h;
    return null;
}

fn row(m: *Model, c: *ui.Context, i: usize, pane: util.Pane) void {
    const th = c.theme;
    const msg = m.messages.items[i];
    const selected = if (m.selected) |id| std.mem.eql(u8, id, msg.id) else false;
    const unread = !msg.flags.seen;
    var r = ui.div(c).row().wFull().h(util.row_h).pl(6).pr(14).py(10).gap(4);
    r = if (selected) r.bg(util.selectedColor(th, true)) else r.hover(th.surface_hover.alpha(0.6));
    defer r.end();
    if (r.clicked()) {
        m.select(i);
        m.screen = .message;
    }
    const fg = if (selected) th.accent_text else th.text;
    const muted = if (selected) th.accent_text.alpha(0.8) else th.muted;
    {
        // The unread dot, or the replied arrow.
        const g = ui.div(c).w(16).pt(4).itemsCenter();
        defer g.end();
        if (unread) {
            _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = if (selected) th.accent_text else th.accent }, .none, null);
        } else if (msg.flags.answered) {
            ui.icon(c, "arrowshape.turn.up.left.fill", .{ .size = 9, .color = muted });
        } else if (msg.flags.forwarded) ui.icon(c, "arrowshape.turn.up.right.fill", .{ .size = 9, .color = muted });
    }
    const inner_w = pane.w - 6 - 14 - 16 - 4;
    const body = ui.div(c).column().grow().gap(2);
    defer body.end();
    var datebuf: [32]u8 = undefined;
    const date = c.print("{s}", .{dates.short(&datebuf, msg.received, m.now(), false)});
    const date_style: ui.TextStyle = .{ .size = 11.5, .color = muted };
    {
        const top = ui.div(c).row().wFull().itemsCenter().gap(6);
        defer top.end();
        const who = if (msg.flags.draft) "Draft" else if (inSent(m)) recipients(c, msg) else msg.sender();
        const name_style: ui.TextStyle = .{ .size = 13.5, .weight = if (unread) .bold else .semibold, .color = if (msg.flags.draft and !selected) th.danger else fg };
        util.line(c, who, name_style, inner_w - c.text.width(date, date_style) - 6);
        ui.spacer(c);
        ui.text(c, date, date_style);
    }
    {
        const mid = ui.div(c).row().wFull().itemsCenter().gap(4);
        defer mid.end();
        var icons_w: f32 = 0;
        if (msg.flags.flagged) icons_w += 18;
        if (msg.has_attachment) icons_w += 18;
        const subject = if (msg.subject.len > 0) util.flat(c, msg.subject) else "(no subject)";
        util.line(c, subject, .{ .size = 13, .weight = if (unread) .medium else .regular, .color = fg }, inner_w - icons_w);
        ui.spacer(c);
        if (msg.has_attachment) ui.icon(c, "paperclip", .{ .size = 11, .frame = 14, .color = muted });
        if (msg.flags.flagged) ui.icon(c, "flag.fill", .{ .size = 11, .frame = 14, .color = if (selected) th.accent_text else ui.Color.hex(0xff9500) });
    }
    util.line(c, util.flat(c, msg.preview), .{ .size = 12.5, .color = muted }, inner_w);
    // The hairline between rows.
    if (!selected) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 22 - 6, .y = util.row_h - 10 - 1 }, .width = .{ .px = pane.w - 22 }, .height = .{ .px = 1 }, .background = th.border.alpha(0.45) }, .none, null);
}

fn inSent(m: *Model) bool {
    const f = m.currentFolder() orelse return false;
    return f.role == .sent or f.role == .drafts;
}

/// "To: Ada, Bob", for the sent folder.
fn recipients(c: *ui.Context, msg: k.Message) []const u8 {
    if (msg.to.len == 0) return "(no recipients)";
    var aw: std.Io.Writer.Allocating = .init(c.alloc());
    aw.writer.writeAll("To: ") catch {};
    for (msg.to, 0..) |a, i| {
        if (i > 0) aw.writer.writeAll(", ") catch {};
        aw.writer.writeAll(a.display()) catch {};
    }
    return aw.written();
}
