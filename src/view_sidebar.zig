//! The sidebar: the account's folders, roles first, with their unread
//! counts; the account at the foot.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const util = @import("view_util.zig");

pub fn view(m: *Model, c: *ui.Context, pane: util.Pane) void {
    const th = c.theme;
    const side = ui.div(c).column().w(pane.w).hFull().bg(if (pane.stacked) th.background else util.sidebarColor(th)).pt(if (pane.stacked) 10 else util.top_inset).pb(10).px(10).gap(1);
    defer side.end();
    if (pane.stacked) {
        const head = ui.div(c).row().wFull().itemsCenter().px(6).pb(8);
        defer head.end();
        ui.text(c, "Mailboxes", .{ .size = 26, .weight = .bold });
        ui.spacer(c);
        if (kit.iconButton(c, "square.and.pencil", .{ .size = .md }).clicked) m.compose(.new);
    } else ui.text(c, "Mailboxes", .{ .size = 11, .weight = .semibold, .color = th.muted });
    _ = c.leaf(.{ .height = .{ .px = 4 } }, .none, null);
    {
        const list = ui.div(c).column().wFull().grow().scrollY().gap(1);
        defer list.end();
        const primary = m.primary();
        var account: []const u8 = primary;
        for (m.folders) |f| {
            // A section for each account shared with the user, named after it.
            if (!std.mem.eql(u8, f.account_id, account)) {
                account = f.account_id;
                ui.key(c, c.print("acct-{s}", .{account}));
                const head = ui.div(c).row().wFull().gap(6).itemsCenter().pt(14).pb(4).px(4);
                defer head.end();
                ui.icon(c, "person.2", .{ .size = 11, .color = th.muted });
                util.line(c, m.accountName(account), .{ .size = 11, .weight = .semibold, .color = th.muted }, pane.w - 50);
            }
            ui.key(c, c.print("{s}/{s}", .{ f.account_id, f.id }));
            const selected = m.isOpen(f.account_id, f.id);
            // Stacked: rows a finger can hit, none shown as chosen.
            const chosen = selected and !pane.stacked;
            var row = ui.div(c).row().wFull().h(if (pane.stacked) 46 else 30).pl(8 + 14 * @as(f32, @floatFromInt(f.depth))).pr(8).gap(8).itemsCenter().rounded(if (pane.stacked) 10 else 7);
            row = if (chosen) row.bg(util.selectedColor(th, false)) else row.hover(th.surface_hover.alpha(0.7));
            defer row.end();
            if (row.clicked()) {
                m.openMailbox(f.account_id, f.id);
                m.screen = .list;
            }
            ui.icon(c, f.role.icon(), .{ .size = 14, .frame = 18, .color = th.accent });
            const count_w: f32 = if (f.unread > 0) c.text.width(c.print("{d}", .{f.unread}), .{ .size = 12 }) + 8 else 0;
            const name_w = pane.w - 20 - 16 - 14 * @as(f32, @floatFromInt(f.depth)) - 26 - count_w - @as(f32, if (pane.stacked) 20 else 0);
            util.line(c, f.name, .{ .size = if (pane.stacked) 16 else 13, .weight = if (chosen) .semibold else .regular }, name_w);
            ui.spacer(c);
            // Read-only: a lock, as Mail marks folders it can't change.
            if (!f.rights.remove and !f.rights.keywords) ui.icon(c, "lock", .{ .size = 10, .color = th.muted });
            if (f.unread > 0) ui.text(c, c.print("{d}", .{f.unread}), .{ .size = if (pane.stacked) 15 else 12, .weight = .medium, .color = th.muted });
            if (pane.stacked) ui.icon(c, "chevron.right", .{ .size = 12, .color = th.muted });
        }
    }
    util.hline(c);
    _ = c.leaf(.{ .height = .{ .px = 8 } }, .none, null);
    const foot = ui.div(c).row().wFull().gap(8).itemsCenter().px(4);
    defer foot.end();
    kit.avatar(c, .{ .name = m.username, .size = 26 });
    {
        const who = ui.div(c).column().grow().gap(1);
        defer who.end();
        util.line(c, m.username, .{ .size = 12, .weight = .medium }, pane.w - 20 - 8 - 26 - 16 - 30);
        ui.text(c, if (m.list_loading) "Updating…" else "Connected", .{ .size = 11, .color = th.muted });
    }
    if (kit.iconButton(c, "rectangle.portrait.and.arrow.right", .{ .size = .xs, .tooltip = "Sign out" }).clicked) m.signOut();
}
