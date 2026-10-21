//! nanomail's state, on the main thread: the account, the folders, the
//! list of the folder open, the message open, and compose windows. It
//! asks the sync thread for work (`Backend`) and takes its answers
//! (`apply`), each in an arena that the state then owns.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const k = @import("mail/kinds.zig");
const copy = @import("copy.zig");
pub const Compose = @import("compose.zig").Compose;

extern "c" fn time(t: ?*i64) i64;

fn wallClock() i64 {
    return time(null);
}

/// Where jobs go: the sync thread, or a test's list.
pub const Backend = struct {
    ctx: *anyopaque,
    submit: *const fn (ctx: *anyopaque, job: k.Job) void,
    /// Stops waiting for the browser's sign-in (it blocks the queue).
    cancel: ?*const fn (ctx: *anyopaque) void = null,
};

/// What the model asks of the app around it: windows, saved settings.
/// Tests leave it null.
pub const Host = struct {
    ctx: *anyopaque,
    open_compose: *const fn (ctx: *anyopaque, c: *Compose) void,
    close_compose: *const fn (ctx: *anyopaque, c: *Compose) void,
    /// Signed in from the form: keep the account (its secret in the keychain).
    save_account: *const fn (ctx: *anyopaque, account: k.Account, session_url: []const u8) void,
    forget_account: *const fn (ctx: *anyopaque) void,
    /// Calls `Model.reapComposes` on the next turn of the main loop.
    later: *const fn (ctx: *anyopaque) void,
    /// Opens a web page (a link) in the browser.
    open_url: *const fn (ctx: *anyopaque, url: []const u8) void,
    /// Shows the sign-in page: the browser on the Mac, a sheet on iOS.
    sign_in: *const fn (ctx: *anyopaque, url: []const u8) void,
    /// A new refresh token for the account kept.
    update_secret: *const fn (ctx: *anyopaque, secret: []const u8) void,
    /// Shows a downloaded file in the Finder.
    reveal: *const fn (ctx: *anyopaque, path: []const u8) void,
    /// Shows a message's HTML in the browser.
    open_html: *const fn (ctx: *anyopaque, id: []const u8, html: []const u8) void,
};

/// `offline`: the account kept from last time couldn't be reached;
/// `browser`: waiting for the sign-in in the browser.
pub const Phase = enum { signed_out, connecting, browser, offline, ready };

/// The sign-in form.
pub const Form = struct {
    email: ui.TextBuffer = .{},
    password: ui.TextBuffer = .{},
    server: ui.TextBuffer = .{},
    /// For a server that doesn't let apps register themselves.
    client_id: ui.TextBuffer = .{},
    /// 0: a password, 1: an API token, 2: through the browser.
    kind: usize = 0,
};

const Cached = struct { arena: std.heap.ArenaAllocator, detail: k.Detail, used: u64 };
const cache_size = 24;

pub const Model = struct {
    gpa: std.mem.Allocator,
    backend: Backend,
    host: ?Host = null,
    now: *const fn () i64 = wallClock,
    phase: Phase = .signed_out,
    /// Which sign-in this is: answers from the sync thread made for an
    /// earlier one are dropped (`applyFrom`).
    session: u64 = 0,
    form: Form = .{},
    /// Why signing in failed, in `notice_buf`.
    login_error: []const u8 = "",
    notice_buf: [512]u8 = undefined,
    /// The account being signed in to, kept once the server says yes.
    pending_account: ?std.heap.ArenaAllocator = null,
    pending: k.Account = .{},
    /// The account kept from last time, to try again when it can't be
    /// reached; and whether it's being connected to now (a splash, not
    /// the form).
    saved_arena: ?std.heap.ArenaAllocator = null,
    saved: k.Account = .{},
    auto: bool = false,
    /// The sign-in page the browser was sent to (gpa's), to open again.
    browser_url: ?[]u8 = null,

    account_arena: std.heap.ArenaAllocator,
    username: []const u8 = "",
    /// Every account with mail (the user's own first) and who may send.
    accounts: []const k.MailAccount = &.{},
    identities: []const k.Identity = &.{},
    can_send: bool = false,

    folders_arena: std.heap.ArenaAllocator,
    folders: []const k.Folder = &.{},
    /// The folder open, and its account (gpa's).
    mailbox: ?[]u8 = null,
    mailbox_account: ?[]u8 = null,

    list_arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(k.Message) = .empty,
    total: u32 = 0,
    list_gen: u64 = 0,
    list_loading: bool = false,
    /// A refresh came while the list was loading: one more after it.
    refresh_again: bool = false,
    search: ui.TextBuffer = .{},
    /// What the list was asked for (the search), gpa's.
    query: []u8 = &.{},
    selected: ?[]u8 = null,
    /// The list scrolls to the selection in the next frame.
    reveal: bool = false,

    cache: [cache_size]?Cached = @splat(null),
    /// Pictures in mail, by blob id or URL (model_pictures.zig), and the
    /// messages whose pictures on the web may load (gpa's keys).
    pictures: std.StringArrayHashMapUnmanaged(pics.State) = .empty,
    remote_ok: std.StringHashMapUnmanaged(void) = .empty,
    /// The message that couldn't be fetched, and why (in `detail_error_buf`).
    detail_error_id: ?[]u8 = null,
    detail_error: []const u8 = "",
    detail_error_buf: [256]u8 = undefined,
    cache_clock: u64 = 0,

    composes: std.ArrayList(*Compose) = .empty,
    next_compose: u64 = 1,
    toaster: kit.Toaster,
    /// ⌘F: the search field takes the keys in the next frame.
    focus_search: bool = false,
    /// The trash's "Delete forever?" question, and the message it's about.
    confirm_destroy: bool = false,
    destroy_id: ?[]u8 = null,
    /// Stacked panes (a phone): the one shown.
    screen: enum { folders, list, message } = .list,
    /// The move menu.
    move_open: bool = false,
    move_at: ?ui.Rect = null,

    pub fn init(gpa: std.mem.Allocator, backend: Backend) Model {
        return .{
            .gpa = gpa,
            .backend = backend,
            .account_arena = .init(gpa),
            .folders_arena = .init(gpa),
            .list_arena = .init(gpa),
            .toaster = .{ .gpa = gpa },
        };
    }

    pub fn deinit(m: *Model) void {
        for (m.composes.items) |c| c.destroy();
        m.composes.deinit(m.gpa);
        for (&m.cache) |*e| if (e.*) |*c| c.arena.deinit();
        m.account_arena.deinit();
        m.folders_arena.deinit();
        m.list_arena.deinit();
        if (m.pending_account) |*a| a.deinit();
        if (m.saved_arena) |*a| a.deinit();
        if (m.mailbox) |b| m.gpa.free(b);
        if (m.mailbox_account) |b| m.gpa.free(b);
        if (m.selected) |s| m.gpa.free(s);
        if (m.detail_error_id) |s| m.gpa.free(s);
        if (m.destroy_id) |s| m.gpa.free(s);
        if (m.browser_url) |s| m.gpa.free(s);
        pics.deinit(m);
        m.gpa.free(m.query);
        m.toaster.deinit();
    }

    pub fn submit(m: *Model, job: k.Job) void {
        m.backend.submit(m.backend.ctx, job);
    }

    pub fn setOwned(m: *Model, slot: *?[]u8, v: ?[]const u8) void {
        if (slot.*) |old| m.gpa.free(old);
        slot.* = if (v) |s| m.gpa.dupe(u8, s) catch null else null;
    }

    fn notice(m: *Model, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(&m.notice_buf, fmt, args) catch m.notice_buf[0..0];
    }

    // Signing in: model_account.zig.
    const signing = @import("model_account.zig");
    pub const signIn = signing.signIn;
    pub const connect = signing.connect;
    pub const retry = signing.retry;
    pub const useAnother = signing.useAnother;
    pub const signOut = signing.signOut;
    pub const newSession = signing.newSession;
    pub const signInWithBrowser = signing.signInWithBrowser;
    pub const openBrowserAgain = signing.openBrowserAgain;
    pub const cancelBrowser = signing.cancelBrowser;

    // What the sync thread says.

    /// An event made in sign-in `session`: dropped if that has passed.
    pub fn applyFrom(m: *Model, arena: std.heap.ArenaAllocator, session: u64, ev: k.Event) void {
        if (session != m.session) {
            var a = arena;
            a.deinit();
            return;
        }
        m.apply(arena, ev);
    }

    /// Takes an event and the arena its data lives in.
    pub fn apply(m: *Model, arena_in: std.heap.ArenaAllocator, ev: k.Event) void {
        var arena = arena_in;
        var keep = false;
        defer if (!keep) arena.deinit();
        switch (ev) {
            .connected => |c| {
                m.account_arena.deinit();
                m.account_arena = arena;
                keep = true;
                m.username = c.username;
                m.accounts = c.accounts;
                m.identities = c.identities;
                m.can_send = c.can_send;
                m.phase = .ready;
                if (m.pending_account) |*a| {
                    if (m.host) |h| h.save_account(h.ctx, m.pending, c.session_url);
                    a.deinit();
                    m.pending_account = null;
                }
                // Through the browser: the account and its refresh token.
                if (c.save) |acc| if (m.host) |h| h.save_account(h.ctx, acc, c.session_url);
                m.setOwned(&m.browser_url, null);
                m.form.password.clear();
                m.submit(.mailboxes);
            },
            .browser => |b| {
                m.setOwned(&m.browser_url, b.url);
                m.phase = .browser;
                if (m.host) |h| h.sign_in(h.ctx, b.url);
            },
            .tokens => |t| if (m.host) |h| h.update_secret(h.ctx, t.refresh_token),
            .connect_failed => |f| {
                m.setOwned(&m.browser_url, null);
                const kept = m.auto and m.saved_arena != null;
                m.phase = if (kept and !f.unauthorized) .offline else .signed_out;
                m.auto = false;
                m.login_error = m.notice("{s}", .{f.message});
            },
            .folders => |f| {
                m.folders_arena.deinit();
                m.folders_arena = arena;
                keep = true;
                m.folders = f;
                const still = m.currentFolder() != null;
                if (!still) {
                    const first = m.folderByRole(.inbox) orelse if (f.len > 0) &f[0] else null;
                    if (first) |fo| m.openMailbox(fo.account_id, fo.id);
                }
            },
            .list => |l| {
                if (l.gen != m.list_gen) return;
                m.list_loading = false;
                m.total = l.total;
                if (l.position == 0) {
                    m.list_arena.deinit();
                    m.list_arena = arena;
                    keep = true;
                    m.messages = .empty;
                    m.messages.appendSlice(m.list_arena.allocator(), l.messages) catch {};
                } else if (l.position == m.messages.items.len) {
                    const a = m.list_arena.allocator();
                    for (l.messages) |msg| m.messages.append(a, copy.deep(k.Message, a, msg) catch continue) catch {};
                }
                if (m.refresh_again) {
                    m.refresh_again = false;
                    m.refresh();
                }
            },
            .list_failed => |l| {
                if (l.gen != m.list_gen) return;
                m.list_loading = false;
                m.refresh_again = false;
                m.notify(.danger, "Couldn't load the list", l.message, 6);
            },
            .detail => |d| {
                m.cachePut(arena, d);
                keep = true;
            },
            .detail_failed => |d| {
                m.setOwned(&m.detail_error_id, d.id);
                const n = @min(d.message.len, m.detail_error_buf.len);
                @memcpy(m.detail_error_buf[0..n], d.message[0..n]);
                m.detail_error = m.detail_error_buf[0..n];
            },
            .sent => |s| {
                for (m.composes.items, 0..) |c, i| if (c.id == s.compose) {
                    _ = m.composes.orderedRemove(i);
                    if (m.host) |h| h.close_compose(h.ctx, c);
                    c.destroy();
                    break;
                };
                m.toaster.push(.{ .status = .success, .title = if (s.draft_only) "Draft saved" else "Message sent", .duration = 3 });
                m.refresh();
            },
            .send_failed => |s| {
                for (m.composes.items) |c| if (c.id == s.compose) {
                    // The draft it saved is the one to replace next time.
                    if (s.draft) |d| c.replaces = c.arena.allocator().dupe(u8, d) catch c.replaces;
                    return c.failed(s.message);
                };
                // Its window is gone: say so here.
                m.notify(.danger, "A message wasn't saved or sent", s.message, 0);
            },
            .failed => |f| {
                m.notify(.danger, f.what, f.message, 6);
                if (f.refresh) m.refresh();
            },
            .changed => m.refresh(),
            .picture => |p| {
                keep = pics.received(m, arena, p.key, p.bytes);
            },
            .downloaded => |d| {
                const where = if (@import("builtin").os.tag == .ios) "In Files, On My iPhone › nanomail" else std.fs.path.basename(d.path);
                m.toaster.push(.{ .status = .success, .title = "Downloaded", .message = where, .duration = 3 });
                if (m.host) |h| h.reveal(h.ctx, d.path);
            },
        }
    }

    /// Shows a toast, unless the same one is showing (a server that's
    /// down fails every request the same way).
    pub fn notify(m: *Model, status: kit.Status, title: []const u8, message: []const u8, duration: f32) void {
        for (m.toaster.items.items) |e| {
            if (!e.leaving and std.mem.eql(u8, e.toast.title, title) and std.mem.eql(u8, e.toast.message, message)) return;
        }
        m.toaster.push(.{ .status = status, .title = title, .message = message, .duration = duration });
    }

    /// Fetches the folders and the list shown again (the server changed).
    pub fn refresh(m: *Model) void {
        if (m.phase != .ready) return;
        if (m.list_loading) {
            m.refresh_again = true;
            return;
        }
        m.submit(.mailboxes);
        const id = m.mailbox orelse return;
        m.list_gen += 1;
        m.list_loading = true;
        const limit: u32 = @intCast(@min(500, @max(100, m.messages.items.len)));
        m.submit(.{ .list = .{ .account_id = m.mailbox_account orelse "", .mailbox_id = id, .query = m.query, .limit = limit, .gen = m.list_gen } });
    }

    // Folders.

    /// The user's own account (its folders come first).
    pub fn primary(m: *const Model) []const u8 {
        return if (m.accounts.len > 0) m.accounts[0].id else if (m.folders.len > 0) m.folders[0].account_id else "";
    }

    pub fn accountName(m: *const Model, id: []const u8) []const u8 {
        for (m.accounts) |a| if (std.mem.eql(u8, a.id, id)) return if (a.name.len > 0) a.name else a.id;
        return id;
    }

    pub fn folder(m: *const Model, account: []const u8, id: []const u8) ?*const k.Folder {
        for (m.folders) |*f| if (std.mem.eql(u8, f.id, id) and std.mem.eql(u8, f.account_id, account)) return f;
        return null;
    }

    /// The folder with `role` in the user's own account.
    pub fn folderByRole(m: *const Model, role: k.Role) ?*const k.Folder {
        return m.folderByRoleIn(m.primary(), role);
    }

    /// The folder with `role` in `account` (each has its own roles).
    pub fn folderByRoleIn(m: *const Model, account: []const u8, role: k.Role) ?*const k.Folder {
        for (m.folders) |*f| if (f.role == role and std.mem.eql(u8, f.account_id, account)) return f;
        return null;
    }

    pub fn currentFolder(m: *const Model) ?*const k.Folder {
        return if (m.mailbox) |id| m.folder(m.mailbox_account orelse "", id) else null;
    }

    /// What may be done in the folder open (everything, when unknown).
    pub fn rights(m: *const Model) k.Rights {
        return if (m.currentFolder()) |f| f.rights else .{};
    }

    pub fn isOpen(m: *const Model, account: []const u8, id: []const u8) bool {
        const cur = m.mailbox orelse return false;
        return std.mem.eql(u8, cur, id) and std.mem.eql(u8, m.mailbox_account orelse "", account);
    }

    pub fn openMailbox(m: *Model, account: []const u8, id: []const u8) void {
        if (m.isOpen(account, id) and m.query.len == 0) return;
        m.setOwned(&m.mailbox_account, account);
        m.setOwned(&m.mailbox, id);
        m.setOwned(&m.selected, null);
        m.search.clear();
        m.gpa.free(m.query);
        m.query = &.{};
        m.loadList();
    }

    /// Searches the folder open for what the search field holds.
    pub fn runSearch(m: *Model) void {
        const q = std.mem.trim(u8, m.search.text(), " ");
        if (std.mem.eql(u8, q, m.query)) return;
        m.gpa.free(m.query);
        m.query = m.gpa.dupe(u8, q) catch &.{};
        m.setOwned(&m.selected, null);
        m.loadList();
    }

    fn loadList(m: *Model) void {
        const id = m.mailbox orelse return;
        m.list_gen += 1;
        m.list_loading = true;
        m.refresh_again = false;
        m.messages = .empty;
        _ = m.list_arena.reset(.retain_capacity);
        m.total = 0;
        m.submit(.{ .list = .{ .account_id = m.mailbox_account orelse "", .mailbox_id = id, .query = m.query, .gen = m.list_gen } });
    }

    /// The next page, when the list nears its end.
    pub fn loadMore(m: *Model) void {
        if (m.list_loading or m.messages.items.len >= m.total) return;
        const id = m.mailbox orelse return;
        m.list_loading = true;
        m.submit(.{ .list = .{ .account_id = m.mailbox_account orelse "", .mailbox_id = id, .query = m.query, .position = @intCast(m.messages.items.len), .gen = m.list_gen } });
    }

    // Pictures: model_pictures.zig.
    const pics = @import("model_pictures.zig");
    pub const picture = pics.picture;
    pub const pictureLoading = pics.pictureLoading;
    pub const pictureFailed = pics.pictureFailed;
    pub const allowRemote = pics.allowRemote;
    pub const remoteAllowed = pics.remoteAllowed;

    // Messages: model_actions.zig.
    const actions = @import("model_actions.zig");
    pub const indexOf = actions.indexOf;
    pub const selectedIndex = actions.selectedIndex;
    pub const selectedMessage = actions.selectedMessage;
    pub const select = actions.select;
    pub const fetchDetail = actions.fetchDetail;
    pub const detailError = actions.detailError;
    pub const step = actions.step;
    pub const setKeyword = actions.setKeyword;
    pub const toggleSeen = actions.toggleSeen;
    pub const toggleFlag = actions.toggleFlag;
    pub const moveSelected = actions.moveSelected;
    pub const archive = actions.archive;
    pub const trash = actions.trash;
    pub const destroySelected = actions.destroySelected;
    pub const download = actions.download;
    pub const openLink = actions.openLink;

    // Opened messages, kept for a while.

    pub fn detail(m: *Model, account: []const u8, id: []const u8) ?*const k.Detail {
        for (&m.cache) |*e| if (e.*) |*c| if (std.mem.eql(u8, c.detail.message.id, id) and std.mem.eql(u8, c.detail.message.account_id, account)) {
            m.cache_clock += 1;
            c.used = m.cache_clock;
            return &c.detail;
        };
        return null;
    }

    fn cachePut(m: *Model, arena: std.heap.ArenaAllocator, d: k.Detail) void {
        var slot: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&m.cache, 0..) |*e, i| {
            if (e.*) |c| {
                if (std.mem.eql(u8, c.detail.message.id, d.message.id) and std.mem.eql(u8, c.detail.message.account_id, d.message.account_id)) {
                    slot = i;
                    break;
                }
                if (c.used < oldest) {
                    oldest = c.used;
                    slot = i;
                }
            } else {
                slot = i;
                oldest = 0;
            }
        }
        if (m.cache[slot]) |*old| old.arena.deinit();
        m.cache_clock += 1;
        m.cache[slot] = .{ .arena = arena, .detail = d, .used = m.cache_clock };
    }

    // Composing.

    pub fn compose(m: *Model, kind: Compose.Kind) void {
        if (!m.can_send and m.phase == .ready) {
            m.toaster.push(.{ .status = .warning, .title = "Sending isn't available", .message = "The server doesn't offer JMAP submission for this account.", .duration = 5 });
            return;
        }
        const original: ?*const k.Detail = if (kind == .new) null else blk: {
            const msg = m.selectedMessage() orelse return;
            break :blk m.detail(msg.account_id, msg.id) orelse return;
        };
        const c = Compose.create(m, kind, original) catch return;
        m.composes.append(m.gpa, c) catch {
            c.destroy();
            return;
        };
        if (m.host) |h| h.open_compose(h.ctx, c);
    }

    /// The compose window's own Cancel, from inside its view: it goes on
    /// the next turn (`reapComposes`), not under the frame drawing it.
    pub fn dismissCompose(m: *Model, c: *Compose) void {
        c.dismissed = true;
        if (m.host) |h| h.later(h.ctx);
    }

    /// Closes the compose windows dismissed, keeping what was written in
    /// them as drafts. Outside any frame.
    pub fn reapComposes(m: *Model) void {
        var i: usize = 0;
        while (i < m.composes.items.len) {
            const c = m.composes.items[i];
            if (!c.dismissed) {
                i += 1;
                continue;
            }
            if (c.dirty() and !c.sending) c.sendNow(true);
            _ = m.composes.orderedRemove(i);
            if (m.host) |h| h.close_compose(h.ctx, c);
            c.destroy();
        }
    }

    /// A compose window closed without sending.
    pub fn composeClosed(m: *Model, c: *Compose) void {
        for (m.composes.items, 0..) |x, i| if (x == c) {
            _ = m.composes.orderedRemove(i);
            c.destroy();
            return;
        };
    }

    pub fn send(m: *Model, out: k.Outgoing) void {
        m.submit(.{ .send = out });
    }
};
