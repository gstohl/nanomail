//! nanomail: a JMAP mail client for macOS, drawn by nanoui. The main
//! window shows the model (model.zig); the sync thread (sync.zig) talks to
//! the server; compose windows come and go; the menu bar has Mail's keys.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const Compose = model_mod.Compose;
const Sync = @import("sync.zig").Sync;
const config = @import("config.zig");
const k = @import("mail/kinds.zig");
const builtin = @import("builtin");
const mac = builtin.os.tag == .macos;

/// The app around the model: its windows, the sync thread, the account
/// kept on disk.
const Shell = struct {
    app: *nanoui.App,
    gpa: std.mem.Allocator,
    io: std.Io,
    model: Model,
    sync: *Sync,
    store: config.Store,
    window: ?*nanoui.Window = null,
    downloads: []u8,
    /// NANOMAIL_OPEN_URL_WITH: a command that opens URLs in place of the
    /// browser (headless runs); then nothing is saved either.
    open_with: ?[]const u8 = null,
    ephemeral: bool = false,

    /// An event from the sync thread, on the main thread.
    fn sink(ctx: *anyopaque, arena: std.heap.ArenaAllocator, session: u64, ev: k.Event) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.model.applyFrom(arena, session, ev);
        s.badge();
        s.redraw();
    }

    /// The inbox's unread count on the Dock icon.
    fn badge(s: *Shell) void {
        if (comptime !mac) return;
        const n: u32 = if (s.model.phase == .ready) (if (s.model.folderByRole(.inbox)) |f| f.unread else 0) else 0;
        const objc = nanoui.objc;
        const pool = objc.Pool.push();
        defer pool.pop();
        var buf: [16]u8 = undefined;
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        const tile = objc.msg(objc.Object, nsapp, "dockTile", .{});
        const label: ?objc.Object = if (n > 0) objc.nsString(std.fmt.bufPrint(&buf, "{d}", .{n}) catch "") else null;
        objc.msg(void, tile, "setBadgeLabel:", .{label});
    }

    fn redraw(s: *Shell) void {
        if (s.window) |w| w.redraw();
        for (s.model.composes.items) |c| if (c.window) |w| @as(*nanoui.Window, @ptrCast(@alignCast(w))).redraw();
    }

    fn host(s: *Shell) model_mod.Host {
        return .{
            .ctx = s,
            .open_compose = openCompose,
            .close_compose = closeCompose,
            .save_account = saveAccount,
            .forget_account = forgetAccount,
            .reveal = reveal,
            .open_html = openHtml,
            .open_url = openUrl,
            .sign_in = signIn,
            .update_secret = updateSecret,
            .later = later,
        };
    }

    /// The sign-in page: the browser on the Mac (it comes back to a
    /// loopback address), a sheet on iOS (ios_auth.zig).
    fn signIn(ctx: *anyopaque, url: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (comptime builtin.os.tag == .ios) {
            if (!@import("ios_auth.zig").start(url, s, signedIn)) s.model.notify(.danger, "Couldn't show the sign-in page", "", 5);
            return;
        }
        openUrl(ctx, url);
    }

    fn signedIn(ctx: *anyopaque, url: ?[]const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (url) |u| s.sync.browserReturned(u) else s.model.cancelBrowser();
        s.redraw();
    }

    fn later(ctx: *anyopaque) void {
        nanoui.App.after(0, ctx, reap);
    }

    fn reap(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.model.reapComposes();
        s.redraw();
    }

    /// The sign-in page, in the browser; or, with NANOMAIL_OPEN_URL_WITH
    /// set (headless runs, tests), handed to that command instead.
    fn openUrl(ctx: *anyopaque, url: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (comptime !mac) {
            _ = nanoui.shell.openUrl(url);
            return;
        }
        const cmd = s.open_with orelse {
            _ = nanoui.shell.openUrl(url);
            return;
        };
        const Run = struct {
            fn run(sh: *Shell, argv0: []const u8, u: []u8) void {
                defer sh.gpa.free(u);
                const r = std.process.run(sh.gpa, sh.io, .{ .argv = &.{ argv0, u }, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 16) }) catch return;
                sh.gpa.free(r.stdout);
                sh.gpa.free(r.stderr);
            }
        };
        const owned = s.gpa.dupe(u8, url) catch return;
        const t = std.Thread.spawn(.{}, Run.run, .{ s, cmd, owned }) catch return s.gpa.free(owned);
        t.detach();
    }

    fn updateSecret(ctx: *anyopaque, secret: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.ephemeral) return;
        s.store.updateSecret(secret) catch {};
    }

    fn openCompose(ctx: *anyopaque, c: *Compose) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        const w = s.app.newWindow(.{
            .title = c.title(),
            .width = 760,
            .height = 620,
            .min_width = 480,
            .min_height = 360,
            .title_bar = .hidden,
            .content = .{ .view = .init(c, Compose.view) },
            .on_close = .{ .ctx = s, .func = composeClosed },
        }) catch {
            s.model.composeClosed(c);
            return;
        };
        c.window = w;
        w.focus();
    }

    fn closeCompose(_: *anyopaque, c: *Compose) void {
        const w: *nanoui.Window = @ptrCast(@alignCast(c.window orelse return));
        c.window = null;
        w.close();
    }

    /// A compose window closed by its owner: what was written is kept as
    /// a draft.
    fn composeClosed(ctx: *anyopaque, w: *nanoui.Window) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        for (s.model.composes.items) |c| if (c.window == @as(*anyopaque, w)) {
            c.window = null;
            if (c.dirty() and !c.sending) c.sendNow(true);
            s.model.composeClosed(c);
            break;
        };
        s.redraw();
    }

    /// The main window went; compose windows may stay (the app ends with
    /// the last of them).
    fn mainClosed(ctx: *anyopaque, _: *nanoui.Window) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.window = null;
    }

    fn saveAccount(ctx: *anyopaque, account: k.Account, session_url: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.ephemeral) return;
        s.store.save(account, session_url) catch |e| {
            s.model.toaster.push(.{ .status = .warning, .title = "Couldn't remember this account", .message = @errorName(e), .duration = 5 });
        };
    }

    fn forgetAccount(ctx: *anyopaque) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.ephemeral) return;
        s.store.forget();
    }

    fn reveal(_: *anyopaque, path: []const u8) void {
        nanoui.shell.showInFolder(path);
    }

    fn openHtml(ctx: *anyopaque, id: []const u8, html: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const dir = nanoui.path(a, .temp, "nanomail") catch return;
        var h = std.hash.Wyhash.init(0);
        h.update(id);
        const path = std.fmt.allocPrint(a, "{s}/nanomail-{x}.html", .{ std.mem.trimEnd(u8, dir, "/"), h.final() }) catch return;
        const doc = std.mem.concat(a, u8, &.{ "<meta charset=\"utf-8\">\n", html }) catch return;
        std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = doc }) catch return;
        _ = nanoui.shell.openPath(path);
    }

    /// Every few minutes, in case push isn't there or missed something.
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        const offline = s.model.phase == .offline;
        if (offline) s.model.retry() else s.model.refresh();
        s.redraw();
        // Accounts shared by others may not push their changes: sooner.
        const shared = s.model.accounts.len > 1;
        nanoui.App.after(if (offline) 30 * 1000 else if (shared) 2 * 60 * 1000 else 5 * 60 * 1000, s, tick);
    }

    // The menu bar's actions.

    fn act(s: *Shell) void {
        s.redraw();
    }
    fn newMessage(s: *Shell, _: *nanoui.menu.Item) void {
        if (s.model.phase == .ready) s.model.compose(.new);
        s.act();
    }
    fn reply(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.compose(.reply);
        s.act();
    }
    fn replyAll(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.compose(.reply_all);
        s.act();
    }
    fn forward(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.compose(.forward);
        s.act();
    }
    fn archive(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.archive();
        s.act();
    }
    fn trash(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.trash();
        s.act();
    }
    fn toggleRead(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.toggleSeen();
        s.act();
    }
    fn toggleFlag(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.toggleFlag();
        s.act();
    }
    fn getMail(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.refresh();
        s.act();
    }
    fn find(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.focus_search = true;
        if (s.window) |w| w.focus();
        s.act();
    }
    fn signOut(s: *Shell, _: *nanoui.menu.Item) void {
        s.model.signOut();
        s.badge();
        s.act();
    }
    /// ⌘↩ in the compose window that has the keys.
    fn send(s: *Shell, _: *nanoui.menu.Item) void {
        for (s.model.composes.items) |c| if (c.window) |w| {
            if (@as(*nanoui.Window, @ptrCast(@alignCast(w))).isFocused()) {
                c.sendNow(false);
                break;
            }
        };
        s.act();
    }

    fn installMenu(s: *Shell) !void {
        const of = nanoui.MenuClick.of;
        try s.app.setMenu(&.{
            .{ .label = "nanomail", .submenu = &.{
                .{ .role = .about },
                .separator,
                .{ .label = "Sign Out", .click = of(s, signOut) },
                .separator,
                .{ .role = .hide },
                .{ .role = .hide_others },
                .{ .role = .unhide },
                .separator,
                .{ .role = .quit },
            } },
            .{ .label = "File", .submenu = &.{
                .{ .label = "New Message", .accelerator = "Cmd+N", .click = of(s, newMessage) },
                .separator,
                .{ .role = .close },
            } },
            .{ .role = .edit_menu },
            .{ .label = "Mailbox", .submenu = &.{
                .{ .label = "Get New Mail", .accelerator = "Cmd+Shift+N", .click = of(s, getMail) },
                .{ .label = "Find…", .accelerator = "Cmd+F", .click = of(s, find) },
            } },
            .{ .label = "Message", .submenu = &.{
                .{ .label = "Send", .accelerator = "Cmd+Enter", .click = of(s, send) },
                .separator,
                .{ .label = "Reply", .accelerator = "Cmd+R", .click = of(s, reply) },
                .{ .label = "Reply All", .accelerator = "Cmd+Shift+R", .click = of(s, replyAll) },
                .{ .label = "Forward", .accelerator = "Cmd+Shift+F", .click = of(s, forward) },
                .separator,
                .{ .label = "Archive", .accelerator = "Cmd+Ctrl+A", .click = of(s, archive) },
                .{ .label = "Move to Trash", .accelerator = "Cmd+Backspace", .click = of(s, trash) },
                .separator,
                .{ .label = "Mark as Read / Unread", .accelerator = "Cmd+Shift+U", .click = of(s, toggleRead) },
                .{ .label = "Flag / Unflag", .accelerator = "Cmd+Shift+L", .click = of(s, toggleFlag) },
            } },
            .{ .role = .window_menu },
        });
    }
};

// In the Simulator, entitlements are read from this section of the binary
// (signed ad hoc, a signature can't carry them): the keychain needs them.
comptime {
    if (builtin.os.tag == .ios and builtin.abi == .simulator)
        @export(&simulator_entitlements, .{ .name = "nanomail_simulator_entitlements", .section = "__TEXT,__entitlements" });
}
const simulator_entitlements = if (builtin.os.tag == .ios) @embedFile("simulator.entitlements").* else [0]u8{};

/// The screen's size in points, on iOS.
fn screenSize() ?[2]f64 {
    if (comptime builtin.os.tag != .ios) return null;
    const objc = nanoui.objc;
    const screen = objc.msg(objc.Object, objc.class("UIScreen"), "mainScreen", .{});
    const r = objc.msg(objc.CGRect, screen, "bounds", .{});
    return .{ r.size.width, r.size.height };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try nanoui.App.create(init, .{ .name = "nanomail" });
    const s = try gpa.create(Shell);
    const downloads = nanoui.path(gpa, .downloads, "nanomail") catch try gpa.dupe(u8, "/tmp");
    s.* = .{
        .app = app,
        .gpa = gpa,
        .io = init.io,
        .model = undefined,
        .sync = undefined,
        .store = .init(gpa, init.io),
        .downloads = downloads,
        .open_with = init.environ_map.get("NANOMAIL_OPEN_URL_WITH"),
        .ephemeral = init.environ_map.get("NANOMAIL_OPEN_URL_WITH") != null,
    };
    s.sync = try Sync.create(gpa, init.io, .{ .ctx = s, .func = Shell.sink }, downloads);
    s.model = Model.init(gpa, s.sync.backend());
    s.model.host = s.host();
    try s.installMenu();

    // The account kept from last time (or given by the environment).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    if (s.store.load(arena.allocator(), init.environ_map)) |account| {
        s.model.form.email.set(account.username);
        if (std.mem.indexOf(u8, account.server, "/.well-known/") == null) s.model.form.server.set(account.server);
        s.model.form.kind = if (account.oauth != null) 2 else @intFromBool(account.token);
        s.model.connect(account, false);
    }

    // UIKit sizes iOS windows itself; the screen's size is what headless
    // renders (--nanoui-snapshot) draw at there.
    const size = screenSize() orelse .{ 1240, 800 };
    s.window = try app.newWindow(.{
        .title = "nanomail",
        .width = size[0],
        .height = size[1],
        .min_width = 900,
        .min_height = 520,
        .title_bar = .hidden,
        .content = .{ .view = .init(&s.model, @import("view.zig").view) },
        .on_close = .{ .ctx = s, .func = Shell.mainClosed },
    });
    nanoui.App.after(5 * 60 * 1000, s, Shell.tick);
    try app.run();
    // The threads may be in the middle of a request: the process ends
    // without waiting for them.
    s.sync.stop();
    std.process.exit(0);
}
