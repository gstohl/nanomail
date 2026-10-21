//! JMAP push (EventSource, RFC 8620 §7.3) over NSURLSession: the stream's
//! session delegate hands what arrives to the thread reading it, which cuts
//! it into lines and tells the listener. http_apple.zig is the transport.
const std = @import("std");
const objc = @import("nanoui").objc;
const apple = @import("http_apple.zig");
const Listener = apple.Listener;

const Object = objc.Object;
const NSInteger = objc.NSInteger;
const newRequest = apple.newRequest;
const setHeader = apple.setHeader;
const noteThread = apple.noteThread;

fn streamClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanomailEventStreamDelegate",
        .protocols = &.{ "NSURLSessionTaskDelegate", "NSURLSessionDataDelegate" },
        .methods = &.{
            .{ .name = apple.redirect_sel, .imp = &apple.noRedirect, .types = "v@:@@@@@?" },
            .{ .name = "URLSession:dataTask:didReceiveResponse:completionHandler:", .imp = &gotResponse, .types = "v@:@@@@?" },
            .{ .name = "URLSession:dataTask:didReceiveData:", .imp = &gotData, .types = "v@:@@@" },
            .{ .name = "URLSession:task:didCompleteWithError:", .imp = &completed, .types = "v@:@@@" },
        },
    });
}

/// os_unfair_lock: for the few fields the delegate queue and the reading
/// thread share.
const Lock = struct {
    word: u32 = 0,
    extern "c" fn os_unfair_lock_lock(l: *u32) void;
    extern "c" fn os_unfair_lock_unlock(l: *u32) void;
    fn lock(l: *Lock) void {
        os_unfair_lock_lock(&l.word);
    }
    fn unlock(l: *Lock) void {
        os_unfair_lock_unlock(&l.word);
    }
};

/// A JMAP push stream (EventSource, RFC 8620 §7.3) on its own session.
/// `run` blocks the calling thread until the server ends the stream, it
/// fails, or `cancel` (from any thread) stops it; the listener is called on
/// the thread in `run`. A `cancel` with no stream running stops the next
/// `run` at once. Keep the struct in place while it runs.
///
/// NSURLSession holds a response back until its first body bytes arrive,
/// so `open` comes with the server's first event or ping, not its headers
/// (http.zig's comes with the headers).
pub const EventStream = struct {
    gpa: std.mem.Allocator,
    lock: Lock = .{},
    // Under the lock: the running task, and what its delegate has seen.
    task: ?Object = null,
    sem: ?objc.dispatch_semaphore_t = null,
    canceled: bool = false,
    opened: bool = false,
    refused: ?anyerror = null,
    failure: ?anyerror = null,
    finished: bool = false,
    /// Bytes read and not yet taken by `run`.
    inbox: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) EventStream {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *EventStream) void {
        s.inbox.deinit(s.gpa);
    }

    /// Stops the running stream: `run` returns error.Canceled.
    pub fn cancel(s: *EventStream) void {
        s.lock.lock();
        s.canceled = true;
        const task = if (s.task) |t| objc.retain(t) else null;
        s.lock.unlock();
        if (task) |t| {
            objc.msg(void, t, "cancel", .{});
            objc.release(t);
        }
    }

    /// Reads the stream at `url` with Authorization `auth`: `listener.open`
    /// once it answers 200 as text/event-stream, then `listener.state` for
    /// each state event. Returns when the server closes it; errors are
    /// PushRefused (not 200, a redirect included), NotEventStream,
    /// LineTooLong, Canceled, or the transport's.
    pub fn run(s: *EventStream, url: []const u8, auth: []const u8, listener: Listener) anyerror!void {
        const pool = objc.Pool.push();
        defer pool.pop();
        // No idle limit: pings are minutes apart, and the caller cancels.
        const r = try newRequest(url, "GET", 7 * 24 * 3600);
        defer objc.release(r);
        setHeader(r, "Authorization", auth);
        setHeader(r, "Accept", "text/event-stream");
        setHeader(r, "Cache-Control", "no-cache");
        setHeader(r, "Accept-Encoding", "identity");
        const ns = apple.newSession(streamClass());
        objc.setZig(ns.delegate, s);
        defer {
            objc.setZig(ns.delegate, null);
            objc.msg(void, ns.session, "invalidateAndCancel", .{});
            objc.release(ns.session);
            objc.release(ns.delegate);
        }
        const task = objc.msg(Object, ns.session, "dataTaskWithRequest:", .{r});
        const sem = objc.dispatch_semaphore_create(0);
        defer objc.dispatch_release(@ptrCast(sem));
        {
            s.lock.lock();
            defer s.lock.unlock();
            if (s.canceled) {
                s.canceled = false;
                return error.Canceled;
            }
            s.task = objc.retain(task);
            s.sem = sem;
            s.opened = false;
            s.refused = null;
            s.failure = null;
            s.finished = false;
            s.inbox.clearRetainingCapacity();
        }
        objc.msg(void, task, "resume", .{});

        var chunk: std.ArrayList(u8) = .empty;
        defer chunk.deinit(s.gpa);
        var events: Events = .{};
        defer events.deinit(s.gpa);
        var told = false;
        // Why this side stopped reading, once it has.
        var stop: ?anyerror = null;
        while (true) {
            _ = objc.dispatch_semaphore_wait(sem, objc.DISPATCH_TIME_FOREVER);
            s.lock.lock();
            std.mem.swap(std.ArrayList(u8), &s.inbox, &chunk);
            const opened = s.opened;
            const finished = s.finished;
            s.lock.unlock();
            if (stop == null) {
                if (opened and !told) {
                    told = true;
                    listener.open(listener.ctx);
                }
                if (events.feed(s.gpa, chunk.items)) |n| {
                    for (0..n) |_| listener.state(listener.ctx);
                } else |e| {
                    stop = e;
                    objc.msg(void, task, "cancel", .{});
                }
            }
            chunk.clearRetainingCapacity();
            // The task's last callback: nothing touches `sem` after it.
            if (finished) break;
        }
        s.lock.lock();
        const canceled = s.canceled;
        const refused = s.refused;
        const failure = s.failure;
        s.canceled = false;
        objc.release(s.task.?);
        s.task = null;
        s.sem = null;
        s.lock.unlock();
        if (canceled) return error.Canceled;
        if (stop) |e| return e;
        if (refused) |e| return e;
        if (failure) |e| return e;
    }

    fn signal(s: *EventStream) void {
        _ = objc.dispatch_semaphore_signal(s.sem.?);
    }
};

fn gotResponse(self: Object, _: objc.SEL, _: Object, _: Object, response: Object, handler: Object) callconv(.c) void {
    noteThread();
    var go: NSInteger = 0; // NSURLSessionResponseCancel
    if (objc.getZig(EventStream, self)) |s| {
        const verdict: ?anyerror = if (apple.statusOf(response) != 200)
            error.PushRefused
        else if (!std.ascii.startsWithIgnoreCase(apple.header(response, "Content-Type") orelse "", "text/event-stream"))
            error.NotEventStream
        else
            null;
        s.lock.lock();
        if (verdict) |e| s.refused = e else s.opened = true;
        s.signal();
        s.lock.unlock();
        if (verdict == null) go = 1; // NSURLSessionResponseAllow
    }
    apple.callBlock(handler, NSInteger, go);
}

fn gotData(self: Object, _: objc.SEL, _: Object, task: Object, data: Object) callconv(.c) void {
    noteThread();
    const s = objc.getZig(EventStream, self) orelse return;
    s.lock.lock();
    const ok = if (s.inbox.appendSlice(s.gpa, apple.bytesOf(data))) true else |_| false;
    if (!ok and s.failure == null) s.failure = error.OutOfMemory;
    s.signal();
    s.lock.unlock();
    if (!ok) objc.msg(void, task, "cancel", .{});
}

fn completed(self: Object, _: objc.SEL, _: Object, _: Object, err: ?Object) callconv(.c) void {
    noteThread();
    const s = objc.getZig(EventStream, self) orelse return;
    const e: ?anyerror = if (err) |x| apple.mapError(x) else null;
    s.lock.lock();
    defer s.lock.unlock();
    if (s.failure == null) s.failure = e;
    s.finished = true;
    // Under the lock: `run` frees the semaphore once it sees `finished`.
    s.signal();
}

/// An EventSource stream cut into lines, and the state events in them: a
/// blank-line-ended event named `state`, or one without a name whose data
/// is a StateChange.
const Events = struct {
    /// The line not yet ended.
    line: std.ArrayList(u8) = .empty,
    event: enum { other, state } = .other,

    const max_line = 64 * 1024;

    fn deinit(e: *Events, gpa: std.mem.Allocator) void {
        e.line.deinit(gpa);
    }

    /// Takes the next bytes; returns how many state events they ended.
    fn feed(e: *Events, gpa: std.mem.Allocator, bytes: []const u8) !usize {
        var n: usize = 0;
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
            if (e.line.items.len + i > max_line) return error.LineTooLong;
            try e.line.appendSlice(gpa, rest[0..i]);
            if (e.take(std.mem.trimEnd(u8, e.line.items, "\r"))) n += 1;
            e.line.clearRetainingCapacity();
            rest = rest[i + 1 ..];
        }
        if (e.line.items.len + rest.len > max_line) return error.LineTooLong;
        try e.line.appendSlice(gpa, rest);
        return n;
    }

    /// One line; true when it ends a state event.
    fn take(e: *Events, line: []const u8) bool {
        if (line.len == 0) {
            defer e.event = .other;
            return e.event == .state;
        }
        if (std.mem.startsWith(u8, line, "event:")) {
            const name = std.mem.trim(u8, line["event:".len..], " ");
            e.event = if (std.mem.eql(u8, name, "state")) .state else .other;
        } else if (std.mem.startsWith(u8, line, "data:") and e.event == .other) {
            if (std.mem.indexOf(u8, line, "StateChange") != null) e.event = .state;
        }
        return false;
    }
};

// Tests: the lines alone; streams canceled from another thread; with
// NANOMAIL_TEST_URL, push from that server.

const testing = std.testing;
const jmap = @import("client.zig");

fn env(name: [:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(testing.io).toMilliseconds();
}

test "event stream: state events, cut anywhere" {
    const text = "event: state\r\ndata: {\"changed\":{}}\r\n\r\n" ++
        ": ping\n\nevent: ping\ndata: {}\n\n" ++
        "data: {\"@type\":\"StateChange\",\"changed\":{}}\n\n" ++
        "event: state\ndata: {}\n";
    for (0..text.len + 1) |cut| {
        var e: Events = .{};
        defer e.deinit(testing.allocator);
        const n = try e.feed(testing.allocator, text[0..cut]) + try e.feed(testing.allocator, text[cut..]);
        // The last isn't ended.
        try testing.expectEqual(2, n);
    }
    var e: Events = .{};
    defer e.deinit(testing.allocator);
    const long: [Events.max_line + 1]u8 = @splat('x');
    try testing.expectError(error.LineTooLong, e.feed(testing.allocator, &long));
}

const Count = struct {
    opened: std.atomic.Value(u32) = .init(0),
    states: std.atomic.Value(u32) = .init(0),

    fn listener(c: *Count) Listener {
        return .{ .ctx = c, .open = open, .state = state };
    }
    fn open(ctx: *anyopaque) void {
        const c: *Count = @ptrCast(@alignCast(ctx));
        _ = c.opened.fetchAdd(1, .acq_rel);
    }
    fn state(ctx: *anyopaque) void {
        const c: *Count = @ptrCast(@alignCast(ctx));
        _ = c.states.fetchAdd(1, .acq_rel);
    }
};

fn cancelAfter(s: *EventStream, ms: i64, at: *i64) void {
    testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    at.* = nowMs();
    s.cancel();
}

test "event stream: canceled before it runs, and from another thread while it waits" {
    var s = EventStream.init(testing.allocator);
    defer s.deinit();
    var count: Count = .{};
    s.cancel();
    try testing.expectError(error.Canceled, s.run("http://127.0.0.1:1/", "x", count.listener()));
    // The cancel is used up.
    try testing.expectError(error.ConnectionRefused, s.run("http://127.0.0.1:1/", "x", count.listener()));
    // Taken by the kernel, never answered.
    var addr: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try addr.listen(testing.io, .{});
    defer server.deinit(testing.io);
    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    var at: i64 = 0;
    const th = try std.Thread.spawn(.{}, cancelAfter, .{ &s, 300, &at });
    const r = s.run(url, "x", count.listener());
    const back = nowMs();
    th.join();
    try testing.expectError(error.Canceled, r);
    try testing.expect(back - at < 1000);
    try testing.expectEqual(0, count.opened.load(.acquire));
    try testing.expectEqual(0, apple.on_main.load(.monotonic));
}

/// Answers one request per answer, in order: the head at once, the body a
/// moment later (the stream is told open only with the body).
const Fake = struct {
    const Answer = struct { head: []const u8, body: []const u8 };

    fn serve(server: *std.Io.net.Server, answers: []const Answer) void {
        const io = testing.io;
        for (answers) |ans| {
            const conn = server.accept(io) catch return;
            defer conn.close(io);
            var rbuf: [4096]u8 = undefined;
            var reader = conn.reader(io, &rbuf);
            while (true) {
                const line = (reader.interface.takeDelimiter('\n') catch return) orelse return;
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            }
            var wbuf: [1024]u8 = undefined;
            var writer = conn.writer(io, &wbuf);
            writer.interface.writeAll(ans.head) catch return;
            writer.interface.flush() catch return;
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            writer.interface.writeAll(ans.body) catch return;
            writer.interface.flush() catch return;
        }
    }

    fn chunk(comptime text: []const u8) []const u8 {
        return std.fmt.comptimePrint("{x}\r\n{s}\r\n", .{ text.len, text });
    }
};

test "event stream: open, state events, the end; a redirect and other types refused" {
    var addr: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try addr.listen(testing.io, .{});
    defer server.deinit(testing.io);
    const answers = [_]Fake.Answer{
        .{
            .head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n",
            .body = comptime Fake.chunk("event: state\ndata: {}\n\n: ping\n") ++ Fake.chunk("\ndata: {\"@type\":\"StateChange\"}\n\n") ++ "0\r\n\r\n",
        },
        // Followed, it would get the next answer.
        .{ .head = "HTTP/1.1 307 Temporary Redirect\r\nLocation: /elsewhere\r\nContent-Length: 0\r\n\r\n", .body = "" },
        .{ .head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\n", .body = "hi" },
    };
    const th = try std.Thread.spawn(.{}, Fake.serve, .{ &server, &answers });
    defer th.join();
    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    var s = EventStream.init(testing.allocator);
    defer s.deinit();
    var count: Count = .{};
    try s.run(url, "x", count.listener());
    try testing.expectEqual(1, count.opened.load(.acquire));
    try testing.expectEqual(2, count.states.load(.acquire));
    try testing.expectError(error.PushRefused, s.run(url, "x", count.listener()));
    try testing.expectError(error.NotEventStream, s.run(url, "x", count.listener()));
    try testing.expectEqual(1, count.opened.load(.acquire));
}

fn waitFor(v: *std.atomic.Value(u32), at_least: u32, ms: i64) !void {
    const until = nowMs() + ms;
    while (v.load(.acquire) < at_least) {
        if (nowMs() > until) return error.NoEvent;
        testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
}

/// From another thread: flags the newest message and puts the flag back,
/// until two state events have come; then cancels the stream. (The stream
/// is told open only with its first event: the first change is made blind.)
const Poke = struct {
    client: *jmap.Client,
    stream: *EventStream,
    count: *Count,
    canceled_at: i64 = 0,
    failure: ?anyerror = null,

    fn run(p: *Poke) void {
        p.change() catch |e| {
            p.failure = e;
        };
        p.canceled_at = nowMs();
        p.stream.cancel();
    }

    fn change(p: *Poke) !void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // The user's own inbox (shared accounts have theirs too).
        const own = p.client.session.?.account_id;
        const inbox = for (try p.client.folders(a)) |f| {
            if (f.role == .inbox and std.mem.eql(u8, f.account_id, own)) break f;
        } else return error.NoInbox;
        const page = try p.client.list(a, own, inbox.id, "", 0, 1);
        if (page.messages.len == 0) return error.EmptyInbox;
        const m = page.messages[0];
        var flagged = m.flags.flagged;
        defer if (flagged != m.flags.flagged) p.client.setKeyword(a, own, &.{m.id}, .flagged, m.flags.flagged) catch {};
        // The stream has a moment to be heard by the server.
        testing.io.sleep(.fromMilliseconds(500), .awake) catch {};
        const before = p.count.states.load(.acquire);
        var tries: u32 = 0;
        while (p.count.states.load(.acquire) < before + 2) : (tries += 1) {
            if (tries == 6) return error.NoEvent;
            const seen = p.count.states.load(.acquire);
            flagged = !flagged;
            try p.client.setKeyword(a, own, &.{m.id}, .flagged, flagged);
            waitFor(&p.count.states, seen + 1, 3000) catch {};
        }
    }
};

test "event stream live: refused without credentials; state on changes; canceled" {
    const url = env("NANOMAIL_TEST_URL") orelse return error.SkipZigTest;
    var h = apple.AppleHttp.init();
    defer h.deinit();
    var c = jmap.Client.init(testing.allocator, h.transport());
    defer c.deinit();
    try c.connect(.{ .server = url, .username = env("NANOMAIL_TEST_USER") orelse "", .secret = env("NANOMAIL_TEST_PASSWORD") orelse "" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var push = c.session.?.event_source_url orelse return error.SkipZigTest;
    push = try std.mem.replaceOwned(u8, a, push, "{types}", "*");
    push = try std.mem.replaceOwned(u8, a, push, "{closeafter}", "no");
    push = try std.mem.replaceOwned(u8, a, push, "{ping}", "60");

    var s = EventStream.init(testing.allocator);
    defer s.deinit();
    var count: Count = .{};
    try testing.expectError(error.PushRefused, s.run(push, "Basic bm9ib2R5Om5vdGhpbmc=", count.listener()));
    try testing.expectEqual(0, count.opened.load(.acquire));

    var poke: Poke = .{ .client = &c, .stream = &s, .count = &count };
    const th = try std.Thread.spawn(.{}, Poke.run, .{&poke});
    const r = s.run(push, c.auth, count.listener());
    const back = nowMs();
    th.join();
    if (poke.failure) |e| return e;
    try testing.expectError(error.Canceled, r);
    try testing.expectEqual(1, count.opened.load(.acquire));
    try testing.expect(count.states.load(.acquire) >= 2);
    try testing.expect(back - poke.canceled_at < 1000);
    try testing.expectEqual(0, apple.on_main.load(.monotonic));
}
