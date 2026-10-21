//! Signing in through the browser on iOS: a loopback address can't be
//! listened on while Safari has the screen, so the sign-in page shows in
//! an ASWebAuthenticationSession sheet, which hands back the redirect to
//! nanomail's own scheme (RFC 8252 §7.1) when the server sends it there.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

/// The private-use scheme the server sends the browser back to.
pub const scheme = "dev.nanomail.app";
pub const redirect_uri = scheme ++ ":/oauth/callback";

/// What the sheet ended with: the redirect's URL, or null (closed, failed).
pub const Done = *const fn (ctx: *anyopaque, url: ?[]const u8) void;

const Pending = struct {
    ctx: *anyopaque,
    done: Done,
    session: ?objc.Object = null,
    anchor: ?objc.Object = null,
};

var anchor_class: ?objc.Class = null;

/// The window the sheet shows over.
fn presentationAnchor(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) ?objc.Object {
    const app = nanoui.App.shared() orelse return null;
    return app.uiwindow;
}

fn finished(p: *Pending, url: ?objc.Object, err: ?objc.Object) void {
    _ = err;
    const s: ?[]const u8 = if (url) |u| objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{})) else null;
    p.done(p.ctx, s);
    if (p.session) |x| objc.release(x);
    if (p.anchor) |x| objc.release(x);
    std.heap.page_allocator.destroy(p);
}

/// Shows `url` in the sheet; `done` is called on the main thread when it
/// ends. False when it couldn't start.
pub fn start(url: []const u8, ctx: *anyopaque, done: Done) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = anchor_class orelse blk: {
        const c = objc.defineClass(.{
            .name = "NanomailAuthAnchor",
            .protocols = &.{"ASWebAuthenticationPresentationContextProviding"},
            .methods = &.{.{ .name = "presentationAnchorForWebAuthenticationSession:", .imp = &presentationAnchor, .types = "@@:@" }},
        });
        anchor_class = c;
        break :blk c;
    };
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return false;
    const p = std.heap.page_allocator.create(Pending) catch return false;
    p.* = .{ .ctx = ctx, .done = done };
    const Block = objc.Block(Pending, &.{ ?objc.Object, ?objc.Object });
    var block = Block.init(p, finished);
    const session = objc.msg(?objc.Object, objc.alloc("ASWebAuthenticationSession"), "initWithURL:callbackURLScheme:completionHandler:", .{ nsurl, objc.nsString(scheme), &block }) orelse {
        std.heap.page_allocator.destroy(p);
        return false;
    };
    p.session = session;
    p.anchor = objc.msg(objc.Object, cls, "new", .{});
    objc.msg(void, session, "setPresentationContextProvider:", .{p.anchor.?});
    // The browser's own sign-ins (a password manager's, an SSO session) help.
    objc.msg(void, session, "setPrefersEphemeralWebBrowserSession:", .{objc.NO});
    if (!objc.msg(objc.BOOL, session, "start", .{})) {
        objc.release(session);
        objc.release(p.anchor.?);
        std.heap.page_allocator.destroy(p);
        return false;
    }
    return true;
}
