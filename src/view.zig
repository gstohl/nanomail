//! The main window: the sign-in form until there's an account, then the
//! folders, the list of the folder open and the message open, side by
//! side as Mail's are. Keys without ⌘ are taken here (↑ ↓, ⌫, e, …);
//! those with ⌘ are the menu bar's (main.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const util = @import("view_util.zig");

pub fn view(m: *Model, c: *ui.Context) void {
    switch (m.phase) {
        .connecting => if (m.auto) splash(m, c) else login(m, c),
        .browser => browser(m, c),
        .offline => splash(m, c),
        .signed_out => login(m, c),
        .ready => mail(m, c),
    }
    m.toaster.view(c);
}

fn mail(m: *Model, c: *ui.Context) void {
    // The toolbar band moves the window, as a title bar does.
    c.title_bar_height = util.toolbar_h;
    // The question takes the keys while it's asked.
    if (!m.confirm_destroy) keys(m, c);
    {
        const root = ui.div(c).row().sizeFull().bg(c.theme.background);
        defer root.end();
        const w = c.size.w;
        if (w < util.stack_below) {
            // One pane at a time, as a phone's Mail shows them.
            if (m.screen == .message and m.selectedMessage() == null) m.screen = .list;
            const pane: util.Pane = .{ .w = w, .stacked = true };
            switch (m.screen) {
                .folders => @import("view_sidebar.zig").view(m, c, pane),
                .list => @import("view_list.zig").view(m, c, pane),
                .message => @import("view_reader.zig").view(m, c, pane),
            }
        } else {
            @import("view_sidebar.zig").view(m, c, .{ .w = util.sidebar_w });
            util.vline(c);
            @import("view_list.zig").view(m, c, .{ .w = util.list_w, .x = util.sidebar_w + 1 });
            util.vline(c);
            @import("view_reader.zig").view(m, c, .{ .w = w - util.sidebar_w - util.list_w - 2, .x = util.sidebar_w + util.list_w + 2 });
        }
    }
    if (kit.dialog(c, "destroy", &m.confirm_destroy, .{ .title = "Delete this message forever?", .description = "It's in the Trash: deleting it here can't be undone.", .ok = "Delete", .ok_variant = .danger })) |d| {
        if (d.end() == .ok) m.destroySelected();
    }
}

/// Keys for the list, when no field has them.
fn keys(m: *Model, c: *ui.Context) void {
    if (c.shortcut(.{ .key = ui.Shortcut.down })) return m.step(1);
    if (c.shortcut(.{ .key = ui.Shortcut.up })) return m.step(-1);
    if (c.focus != 0) return;
    if (c.input.key) |key| switch (key) {
        .down, .up => {
            m.step(if (key == .down) 1 else -1);
            c.changed = true;
        },
        .backspace, .delete => {
            m.trash();
            c.changed = true;
        },
        .enter => if (m.selectedIndex() == null) {
            m.step(1);
            c.changed = true;
        },
        else => {},
    };
    if (c.input.chars.len != 1) return;
    const handled = switch (c.input.chars[0]) {
        'j' => blk: {
            m.step(1);
            break :blk true;
        },
        'k' => blk: {
            m.step(-1);
            break :blk true;
        },
        'e', 'y' => blk: {
            m.archive();
            break :blk true;
        },
        '#' => blk: {
            m.trash();
            break :blk true;
        },
        'u' => blk: {
            m.toggleSeen();
            break :blk true;
        },
        's' => blk: {
            m.toggleFlag();
            break :blk true;
        },
        'r' => blk: {
            m.compose(.reply);
            break :blk true;
        },
        'a' => blk: {
            m.compose(.reply_all);
            break :blk true;
        },
        'f' => blk: {
            m.compose(.forward);
            break :blk true;
        },
        'c' => blk: {
            m.compose(.new);
            break :blk true;
        },
        '/' => blk: {
            m.focus_search = true;
            break :blk true;
        },
        else => false,
    };
    if (handled) c.changed = true;
}

/// Connecting to the account kept from last time, or failing to.
fn splash(m: *Model, c: *ui.Context) void {
    const th = c.theme;
    c.title_bar_height = 40;
    const root = ui.div(c).column().sizeFull().center().bg(th.background).gap(14);
    defer root.end();
    {
        const mark = ui.div(c).size(64, 64).center().rounded(16).bg(if (m.phase == .offline) th.muted else th.accent);
        defer mark.end();
        ui.icon(c, if (m.phase == .offline) "wifi.exclamationmark" else "envelope.fill", .{ .size = 28, .color = th.accent_text });
    }
    if (m.phase != .offline) {
        ui.text(c, c.print("Connecting to {s}…", .{m.saved.username}), .{ .size = 15, .weight = .semibold });
        kit.spinner(c, .{ .size = 18 });
        return;
    }
    ui.text(c, "Can't reach your mail", .{ .size = 17, .weight = .semibold });
    const why = ui.div(c).maxW(460);
    ui.text(c, m.login_error, .{ .size = 13, .color = th.muted, .wrap = true });
    why.end();
    const row = ui.div(c).row().gap(8).pt(6);
    defer row.end();
    if (kit.button(c, "Use Another Account", .{ .variant = .ghost }).clicked) m.useAnother();
    if (kit.button(c, "Try Again", .{ .variant = .primary }).clicked) m.retry();
}

/// Waiting while the user signs in in the browser.
fn browser(m: *Model, c: *ui.Context) void {
    const th = c.theme;
    c.title_bar_height = 40;
    const root = ui.div(c).column().sizeFull().center().bg(th.background).gap(14);
    defer root.end();
    {
        const mark = ui.div(c).size(64, 64).center().rounded(16).bg(th.accent);
        defer mark.end();
        ui.icon(c, "safari", .{ .size = 30, .color = th.accent_text });
    }
    ui.text(c, "Continue in your browser", .{ .size = 17, .weight = .semibold });
    {
        const why = ui.div(c).maxW(440);
        defer why.end();
        ui.text(c, "nanomail opened your server's sign-in page. Once you've signed in there, you'll come back here.", .{ .size = 13, .color = th.muted, .wrap = true });
    }
    kit.spinner(c, .{ .size = 16 });
    const row = ui.div(c).row().gap(8).pt(6);
    defer row.end();
    if (kit.button(c, "Cancel", .{ .variant = .ghost }).clicked) m.cancelBrowser();
    if (kit.button(c, "Open the Page Again", .{ .variant = .primary }).clicked) m.openBrowserAgain();
}

fn login(m: *Model, c: *ui.Context) void {
    const th = c.theme;
    c.title_bar_height = 40;
    const root = ui.div(c).column().sizeFull().center().bg(th.background).gap(18);
    defer root.end();
    {
        const mark = ui.div(c).size(72, 72).center().rounded(18).bg(th.accent);
        defer mark.end();
        ui.icon(c, "envelope.fill", .{ .size = 34, .color = th.accent_text });
    }
    {
        const words = ui.div(c).column().itemsCenter().gap(4);
        defer words.end();
        ui.text(c, "nanomail", .{ .size = 26, .weight = .bold });
        ui.text(c, "Mail over JMAP: Fastmail, Stalwart, Cyrus and others.", .{ .size = 13, .color = th.muted });
    }
    const connecting = m.phase == .connecting;
    // The card's width less its padding.
    const card_w = @min(400, c.size.w - 24);
    const field_w: ui.Length = .{ .px = card_w - 48 };
    const card = ui.div(c).column().w(card_w).p(24).gap(14).rounded(14).bg(th.surface).border(th.border.alpha(0.6)).shadowMd();
    defer card.end();
    var submit = false;
    {
        const f = kit.field(c, "Email", .{});
        defer f.end();
        const email_id = c.peekId(null);
        if (c.frame <= 2 and c.focus == 0) c.focus = email_id;
        submit = ui.textField(c, &m.form.email, .{ .placeholder = "you@example.com", .width = field_w }).submitted or submit;
    }
    _ = kit.tabs(c, &.{ "Password", "API token", "Browser" }, &m.form.kind, .{ .variant = .segmented, .size = .sm });
    const browser_kind = m.form.kind == 2;
    if (!browser_kind) {
        const f = kit.field(c, if (m.form.kind == 1) "API token" else "Password", .{ .hint = if (m.form.kind == 1) "Fastmail: Settings → Privacy & Security → API tokens." else "" });
        defer f.end();
        submit = ui.textField(c, &m.form.password, .{ .placeholder = if (m.form.kind == 1) "fmu1-…" else "Password or app password", .width = field_w, .password = true }).submitted or submit;
    } else {
        _ = kit.alert(c, .{ .status = .info, .description = "You'll sign in on your server's page in the browser (OAuth or OpenID Connect), and come back here." });
    }
    {
        const f = kit.field(c, "Server", .{ .hint = "Leave empty to find it from your address." });
        defer f.end();
        submit = ui.textField(c, &m.form.server, .{ .placeholder = "https://mail.example.com", .width = field_w }).submitted or submit;
    }
    if (browser_kind) {
        const f = kit.field(c, "Client ID", .{ .hint = "Only for a server that doesn't let apps register themselves." });
        defer f.end();
        submit = ui.textField(c, &m.form.client_id, .{ .placeholder = "Optional", .width = field_w }).submitted or submit;
    }
    if (m.login_error.len > 0) _ = kit.alert(c, .{ .status = .danger, .title = "Couldn't sign in", .description = m.login_error });
    const label = if (connecting) (if (browser_kind) "Finding the sign-in page…" else "Signing in…") else if (browser_kind) "Continue in Browser" else "Sign In";
    if (kit.button(c, label, .{ .variant = .primary, .full_width = true, .loading = connecting, .size = .lg, .icon = if (browser_kind and !connecting) "safari" else "" }).clicked) submit = true;
    if (submit and !connecting) m.signIn();
}
