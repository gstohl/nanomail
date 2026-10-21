//! Signing in and out: with a password or an API token, through the
//! browser (OAuth), or with the account kept from last time; and what's
//! dropped when the session changes.
const std = @import("std");
const k = @import("mail/kinds.zig");
const copy = @import("copy.zig");
const Model = @import("model.zig").Model;


/// Signs in with what the form holds.
pub fn signIn(m: *Model) void {
    if (m.form.kind == 2) return signInWithBrowser(m);
    const email = std.mem.trim(u8, m.form.email.text(), " ");
    const secret = m.form.password.text();
    if (email.len == 0 or secret.len == 0) {
        m.login_error = if (m.form.kind == 1) "Enter your address and an API token." else "Enter your address and password.";
        return;
    }
    const server = std.mem.trim(u8, m.form.server.text(), " ");
    if (server.len == 0 and std.mem.indexOfScalar(u8, email, '@') == null) {
        m.login_error = "Enter a server, or an address with a domain.";
        return;
    }
    m.connect(.{ .server = server, .username = email, .secret = secret, .token = m.form.kind == 1 }, true);
}

/// Connects to `account`; `remember` keeps it once the server says yes
/// (else it's the one kept already).
pub fn connect(m: *Model, account: k.Account, remember: bool) void {
    if (m.pending_account) |*a| a.deinit();
    m.pending_account = null;
    m.auto = !remember;
    if (!remember and account.secret.ptr != m.saved.secret.ptr) {
        if (m.saved_arena) |*a| a.deinit();
        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        m.saved = copy.deep(k.Account, arena.allocator(), account) catch .{};
        m.saved_arena = arena;
    }
    if (remember) {
        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        m.pending = copy.deep(k.Account, arena.allocator(), account) catch .{};
        m.pending_account = arena;
    }
    m.login_error = "";
    m.phase = .connecting;
    m.newSession();
    m.submit(.{ .connect = account });
}

/// Tries the kept account again.
pub fn retry(m: *Model) void {
    if (m.saved_arena == null) return;
    m.connect(m.saved, false);
}

/// From the offline screen: the form, for another account.
pub fn useAnother(m: *Model) void {
    if (m.saved_arena) |*a| a.deinit();
    m.saved_arena = null;
    m.saved = .{};
    m.auto = false;
    m.login_error = "";
    m.phase = .signed_out;
}

/// Answers to what was asked before now are no longer wanted.
pub fn newSession(m: *Model) void {
    m.session += 1;
    m.list_gen += 1;
    m.list_loading = false;
    m.refresh_again = false;
    m.submit(.{ .session = m.session });
}

pub fn signOut(m: *Model) void {
    if (m.host) |h| h.forget_account(h.ctx);
    m.newSession();
    m.submit(.sign_out);
    if (m.pending_account) |*a| a.deinit();
    m.pending_account = null;
    if (m.saved_arena) |*a| a.deinit();
    m.saved_arena = null;
    m.saved = .{};
    m.auto = false;
    m.phase = .signed_out;
    m.folders = &.{};
    m.messages = .empty;
    _ = m.folders_arena.reset(.free_all);
    _ = m.list_arena.reset(.free_all);
    for (&m.cache) |*e| if (e.*) |*c| {
        c.arena.deinit();
        e.* = null;
    };
    m.setOwned(&m.mailbox, null);
    m.setOwned(&m.mailbox_account, null);
    m.accounts = &.{};
    m.setOwned(&m.selected, null);
    m.form.password.clear();
}

/// Signs in through the browser: the sync thread finds the server's
/// sign-in page and asks for it to be opened (`Event.browser`).
pub fn signInWithBrowser(m: *Model) void {
    const email = std.mem.trim(u8, m.form.email.text(), " ");
    const server = std.mem.trim(u8, m.form.server.text(), " ");
    if (server.len == 0 and std.mem.indexOfScalar(u8, email, '@') == null) {
        m.login_error = "Enter your address, or the server's.";
        return;
    }
    if (m.pending_account) |*a| a.deinit();
    m.pending_account = null;
    m.auto = false;
    m.login_error = "";
    m.phase = .connecting;
    m.newSession();
    m.submit(.{ .oauth = .{ .server = server, .username = email, .client_id = std.mem.trim(u8, m.form.client_id.text(), " ") } });
}

pub fn openBrowserAgain(m: *Model) void {
    const url = m.browser_url orelse return;
    if (m.host) |h| h.sign_in(h.ctx, url);
}

/// Stops waiting for the browser: back to the form.
pub fn cancelBrowser(m: *Model) void {
    if (m.backend.cancel) |cancel| cancel(m.backend.ctx);
    newSession(m);
    m.setOwned(&m.browser_url, null);
    m.phase = .signed_out;
}
