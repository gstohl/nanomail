//! JMAP over HTTP with Apple's NSURLSession (Foundation): the system's
//! trust store, proxies and network stack, on iOS (where std.http finds no
//! CA certificates) and macOS alike. The same contract as http.zig: calls
//! block a thread that isn't the main one, redirects are handed back to the
//! client, and push arrives on a long-lived EventSource stream. Foundation
//! is called through the runtime (nanoui's objc.zig): no headers, no shims.
//!
//!     var apple = AppleHttp.init();
//!     defer apple.deinit();
//!     var client = jmap.Client.init(gpa, apple.transport());
//!
//!     var push = EventStream.init(gpa);
//!     defer push.deinit();
//!     try push.run(url, auth, listener); // blocks; push.cancel() from any thread
//!
//! The stream is in http_apple_stream.zig; the helpers it shares with the
//! transport (sessions, requests, responses, errors) are public here.
const std = @import("std");
const objc = @import("nanoui").objc;
const jmap = @import("client.zig");

pub const EventStream = @import("http_apple_stream.zig").EventStream;
/// What a push stream tells: the same as http.zig's.
pub const Listener = @import("http.zig").Listener;

const Object = objc.Object;
const NSInteger = objc.NSInteger;
const NSUInteger = objc.NSUInteger;
const none: ?Object = null;

extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" var _NSConcreteStackBlock: opaque {};

/// Times NSURLSession called back on the main thread: never (each session
/// has its own delegate queue). The tests check.
pub var on_main: std.atomic.Value(u32) = .init(0);

pub fn noteThread() void {
    if (objc.isMainThread()) _ = on_main.fetchAdd(1, .monotonic);
}

/// Sends requests on one ephemeral session, made once and reused: no
/// cookies, no cache, no saved credentials, redirects never followed.
pub const AppleHttp = struct {
    session: Object,
    /// The whole request's time, unless the request says otherwise.
    timeout_ms: i64 = 45_000,
    /// The largest body taken (attachments included).
    max_body: usize = 64 * 1024 * 1024,

    pub fn init() AppleHttp {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = newSession(transportClass());
        // The session holds its delegate until it's invalidated.
        objc.release(s.delegate);
        return .{ .session = s.session };
    }

    /// Cancels what's in flight (those calls end with error.Canceled).
    pub fn deinit(h: *AppleHttp) void {
        objc.msg(void, h.session, "invalidateAndCancel", .{});
        objc.release(h.session);
    }

    pub fn transport(h: *AppleHttp) jmap.Transport {
        return .{ .ctx = h, .send = send };
    }

    fn send(ctx: *anyopaque, arena: std.mem.Allocator, req: jmap.Request) anyerror!jmap.Reply {
        const h: *AppleHttp = @ptrCast(@alignCast(ctx));
        const pool = objc.Pool.push();
        defer pool.pop();
        const timeout_ms = req.timeout_ms orelse h.timeout_ms;
        const r = try newRequest(req.url, @tagName(req.method), @as(f64, @floatFromInt(timeout_ms)) / 1000);
        defer objc.release(r);
        if (req.auth) |v| setHeader(r, "Authorization", v);
        if (req.body) |b| {
            objc.msg(void, r, "setHTTPBody:", .{objc.msg(Object, objc.class("NSData"), "dataWithBytes:length:", .{ b.ptr, b.len })});
            setHeader(r, "Content-Type", req.content_type);
        }
        setHeader(r, "Accept", req.accept);

        var done: Done = .{ .sem = objc.dispatch_semaphore_create(0) };
        defer objc.dispatch_release(@ptrCast(done.sem));
        defer done.releaseAll();
        var block: DoneBlock = .init(&done);
        const task = objc.msg(Object, h.session, "dataTaskWithRequest:completionHandler:", .{ r, &block });
        objc.msg(void, task, "resume", .{});
        // The whole request against the clock (the request's own interval
        // is only how long it may sit idle).
        if (objc.dispatch_semaphore_wait(done.sem, dispatch_time(0, timeout_ms * std.time.ns_per_ms)) != 0) {
            // A canceled task still calls its handler, whose block points
            // here: wait for it.
            objc.msg(void, task, "cancel", .{});
            _ = objc.dispatch_semaphore_wait(done.sem, objc.DISPATCH_TIME_FOREVER);
            return error.Timeout;
        }
        if (done.err) |e| return mapError(e);
        const response = done.response orelse return error.RequestFailed;
        const status = statusOf(response);
        if (status == 0) return error.RequestFailed;
        const location = try dupeHeader(arena, response, "Location");
        if (status >= 300 and status < 400) return .{ .status = status, .location = location };
        const body = if (done.data) |d| bytesOf(d) else "";
        if (body.len > h.max_body) return error.StreamTooLong;
        return .{
            .status = status,
            .body = try arena.dupe(u8, body),
            .location = location,
            .challenge = try dupeHeader(arena, response, "WWW-Authenticate"),
        };
    }
};

/// What a data task's completion handler gave, kept (retained) until the
/// waiting thread has read it.
const Done = struct {
    sem: objc.dispatch_semaphore_t,
    data: ?Object = null,
    response: ?Object = null,
    err: ?Object = null,

    fn finished(d: *Done, data: ?Object, response: ?Object, err: ?Object) void {
        noteThread();
        d.data = if (data) |o| objc.retain(o) else null;
        d.response = if (response) |o| objc.retain(o) else null;
        d.err = if (err) |o| objc.retain(o) else null;
        _ = objc.dispatch_semaphore_signal(d.sem);
    }

    fn releaseAll(d: *Done) void {
        for ([_]?Object{ d.data, d.response, d.err }) |o| if (o) |x| objc.release(x);
    }
};

/// `^(NSData *, NSURLResponse *, NSError *)`: objc.Block's layout with
/// three arguments. Built on the stack; the session copies it.
const DoneBlock = extern struct {
    isa: *anyopaque,
    flags: i32 = 0,
    reserved: i32 = 0,
    invoke: *const fn (*const DoneBlock, ?Object, ?Object, ?Object) callconv(.c) void,
    descriptor: *const Descriptor,
    ctx: *Done,

    const Descriptor = extern struct { reserved: usize = 0, size: usize };
    const descriptor_value: Descriptor = .{ .size = @sizeOf(DoneBlock) };

    fn init(ctx: *Done) DoneBlock {
        return .{ .isa = @ptrCast(&_NSConcreteStackBlock), .invoke = &call, .descriptor = &descriptor_value, .ctx = ctx };
    }

    fn call(b: *const DoneBlock, data: ?Object, response: ?Object, err: ?Object) callconv(.c) void {
        b.ctx.finished(data, response, err);
    }
};

/// Calls a block the system handed over (a delegate's completion handler)
/// with its one argument.
pub fn callBlock(block: Object, comptime A: type, arg: A) void {
    const Head = extern struct { isa: *anyopaque, flags: i32, reserved: i32, invoke: *const fn (Object, A) callconv(.c) void };
    const b: *const Head = @ptrCast(@alignCast(block));
    b.invoke(block, arg);
}

/// NSURLErrorDomain's codes, named as std.http's errors are.
pub fn mapError(err: Object) anyerror {
    const domain = objc.fromNSString(objc.msg(?Object, err, "domain", .{}));
    if (!std.mem.eql(u8, domain, "NSURLErrorDomain")) return error.RequestFailed;
    return switch (objc.msg(NSInteger, err, "code", .{})) {
        -999 => error.Canceled,
        -1000 => error.InvalidUrl,
        -1001 => error.Timeout,
        -1002 => error.UnsupportedUriScheme,
        -1003, -1006 => error.UnknownHostName,
        -1004 => error.ConnectionRefused,
        -1005 => error.ConnectionResetByPeer,
        -1009, -1018, -1020 => error.NetworkDown,
        // App Transport Security: plain http:// to a host it covers.
        -1022 => error.InsecureConnectionRefused,
        -1206...-1200 => error.TlsInitializationFailed,
        else => error.RequestFailed,
    };
}

pub fn statusOf(response: Object) u16 {
    if (!objc.msg(objc.BOOL, response, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")})) return 0;
    return std.math.cast(u16, objc.msg(NSInteger, response, "statusCode", .{})) orelse 0;
}

/// A header's value (names match in any case), valid in the current pool.
pub fn header(response: Object, name: []const u8) ?[]const u8 {
    const v = objc.msg(?Object, response, "valueForHTTPHeaderField:", .{objc.nsString(name)}) orelse return null;
    return objc.fromNSString(v);
}

fn dupeHeader(arena: std.mem.Allocator, response: Object, name: []const u8) !?[]const u8 {
    return if (header(response, name)) |v| try arena.dupe(u8, v) else null;
}

pub fn bytesOf(data: Object) []const u8 {
    const n = objc.msg(NSUInteger, data, "length", .{});
    if (n == 0) return "";
    const p = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return "";
    return p[0..n];
}

/// A request (retained: release it) with no cache in the way.
pub fn newRequest(url: []const u8, method: []const u8, idle_s: f64) !Object {
    const nsurl = objc.msg(?Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return error.InvalidUrl;
    // NSURLRequestReloadIgnoringLocalCacheData
    const r = objc.msg(Object, objc.alloc("NSMutableURLRequest"), "initWithURL:cachePolicy:timeoutInterval:", .{ nsurl, @as(NSUInteger, 1), idle_s });
    objc.msg(void, r, "setHTTPMethod:", .{objc.nsString(method)});
    return r;
}

pub fn setHeader(r: Object, name: []const u8, value: []const u8) void {
    objc.msg(void, r, "setValue:forHTTPHeaderField:", .{ objc.nsString(value), objc.nsString(name) });
}

/// An ephemeral session that keeps nothing, with a new delegate of `cls`;
/// both retained. Callbacks come on the session's own serial queue.
pub fn newSession(cls: objc.Class) struct { session: Object, delegate: Object } {
    const cfg = objc.msg(Object, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
    objc.msg(void, cfg, "setHTTPCookieAcceptPolicy:", .{@as(NSUInteger, 1)}); // never
    objc.msg(void, cfg, "setHTTPShouldSetCookies:", .{objc.NO});
    objc.msg(void, cfg, "setHTTPCookieStorage:", .{none});
    objc.msg(void, cfg, "setURLCache:", .{none});
    objc.msg(void, cfg, "setURLCredentialStorage:", .{none});
    objc.msg(void, cfg, "setRequestCachePolicy:", .{@as(NSUInteger, 1)});
    // Requests set their own idle time; this would cap it.
    objc.msg(void, cfg, "setTimeoutIntervalForRequest:", .{@as(f64, 7 * 24 * 3600)});
    const delegate = objc.msg(Object, cls, "new", .{});
    const session = objc.msg(Object, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ cfg, delegate, none });
    return .{ .session = objc.retain(session), .delegate = delegate };
}

pub const redirect_sel = "URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:";

fn transportClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanomailURLSessionDelegate",
        .protocols = &.{"NSURLSessionTaskDelegate"},
        .methods = &.{.{ .name = redirect_sel, .imp = &noRedirect, .types = "v@:@@@@@?" }},
    });
}

/// Never follows: the handler gets nil and the task's answer is the 3xx.
pub fn noRedirect(_: Object, _: objc.SEL, _: Object, _: Object, _: Object, _: Object, handler: Object) callconv(.c) void {
    noteThread();
    callBlock(handler, ?Object, null);
}

// Tests: against nothing listening and a listener that never answers; with
// NANOMAIL_TEST_URL, against that JMAP server (and Fastmail's, for TLS).

const testing = std.testing;
const session_mod = @import("session.zig");
const k = @import("../mail/kinds.zig");

fn env(name: [:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(testing.io).toMilliseconds();
}

fn get(t: jmap.Transport, a: std.mem.Allocator, url: []const u8, auth: ?[]const u8) anyerror!jmap.Reply {
    return t.send(t.ctx, a, .{ .method = .GET, .url = url, .auth = auth });
}

test "apple http: refused, and a server that never answers times out" {
    var h = AppleHttp.init();
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = h.transport();
    try testing.expectError(error.ConnectionRefused, get(t, a, "http://127.0.0.1:1/", null));
    // Taken by the kernel, never read: only the clock ends it.
    var addr: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try addr.listen(testing.io, .{});
    defer server.deinit(testing.io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const started = nowMs();
    try testing.expectError(error.Timeout, t.send(t.ctx, a, .{ .method = .GET, .url = url, .timeout_ms = 300 }));
    const took = nowMs() - started;
    try testing.expect(took >= 250 and took < 3000);
    try testing.expectEqual(0, on_main.load(.monotonic));
}

const mailbox_get =
    \\{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],
    \\"methodCalls":[["Mailbox/get",{"accountId":"
;

test "apple http live: redirect handed back, session, API call, challenge" {
    const base = std.mem.trimEnd(u8, env("NANOMAIL_TEST_URL") orelse return error.SkipZigTest, "/");
    var h = AppleHttp.init();
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = h.transport();
    const plain = try std.fmt.allocPrint(a, "{s}:{s}", .{ env("NANOMAIL_TEST_USER") orelse "", env("NANOMAIL_TEST_PASSWORD") orelse "" });
    const enc = std.base64.standard.Encoder;
    const auth = try std.fmt.allocPrint(a, "Basic {s}", .{enc.encode(try a.alloc(u8, enc.calcSize(plain.len)), plain)});

    // Discovery: the redirect comes back, not followed.
    const wk = try get(t, a, try std.fmt.allocPrint(a, "{s}/.well-known/jmap", .{base}), null);
    try testing.expect(wk.status >= 300 and wk.status < 400);
    const loc = wk.location.?;
    const session_url = if (std.mem.startsWith(u8, loc, "/")) try std.fmt.allocPrint(a, "{s}{s}", .{ base, loc }) else loc;

    const ses = try get(t, a, session_url, auth);
    try testing.expectEqual(200, ses.status);
    try testing.expect(std.mem.indexOf(u8, ses.body, "\"apiUrl\"") != null);
    const s = try session_mod.parse(a, ses.body, session_url);

    const body = try std.fmt.allocPrint(a, "{s}{s}\",\"ids\":null}},\"0\"]]}}", .{ mailbox_get, s.account_id });
    const mb = try t.send(t.ctx, a, .{ .url = s.api_url, .auth = auth, .body = body });
    try testing.expectEqual(200, mb.status);
    try testing.expect(std.mem.indexOf(u8, mb.body, "\"Mailbox/get\"") != null);

    // Without credentials: 401, and how to sign in.
    const no = try t.send(t.ctx, a, .{ .url = s.api_url, .body = body });
    try testing.expectEqual(401, no.status);
    try testing.expect(std.mem.indexOf(u8, no.challenge.?, "Bearer") != null);
    try testing.expectEqual(0, on_main.load(.monotonic));
}

test "apple http live: system trust, unknown hosts" {
    _ = env("NANOMAIL_TEST_URL") orelse return error.SkipZigTest;
    var h = AppleHttp.init();
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = h.transport();
    // TLS with the system's roots: Fastmail answers (401 without credentials).
    const fm = try get(t, a, "https://api.fastmail.com/jmap/session", null);
    try testing.expectEqual(401, fm.status);
    try testing.expectError(error.UnknownHostName, get(t, a, "http://nanomail-test.invalid/", null));
}

test "apple http live: the client signs in and lists folders" {
    const url = env("NANOMAIL_TEST_URL") orelse return error.SkipZigTest;
    var h = AppleHttp.init();
    defer h.deinit();
    var c = jmap.Client.init(testing.allocator, h.transport());
    defer c.deinit();
    c.connect(.{ .server = url, .username = env("NANOMAIL_TEST_USER") orelse "", .secret = env("NANOMAIL_TEST_PASSWORD") orelse "" }) catch |e| {
        std.debug.print("connect: {s}\n", .{c.problem});
        return e;
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const folders = try c.folders(arena.allocator());
    for (folders) |f| {
        if (f.role == .inbox) break;
    } else return error.NoInbox;
    try testing.expectEqual(0, on_main.load(.monotonic));
}
