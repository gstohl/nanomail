//! JMAP over HTTP with std.http.Client: one request at a time from the
//! thread that owns it, each raced against a timeout (std.http has none),
//! redirects handed back to the client to follow. Also the long-lived
//! EventSource stream that push arrives on.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const jmap = @import("client.zig");

pub const Http = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: http.Client,
    timeout_ms: i64 = 45_000,
    /// The largest body read (attachments included).
    max_body: usize = 64 * 1024 * 1024,
    /// When the certificates were last read, to read them again hourly.
    certs_at: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io) Http {
        return .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(h: *Http) void {
        h.client.deinit();
    }

    pub fn transport(h: *Http) jmap.Transport {
        return .{ .ctx = h, .send = send };
    }

    fn send(ctx: *anyopaque, arena: std.mem.Allocator, req: jmap.Request) anyerror!jmap.Reply {
        const h: *Http = @ptrCast(@alignCast(ctx));
        // The client keeps the time it checked certificates against.
        const now = Io.Clock.real.now(h.io).toSeconds();
        if (now - h.certs_at > 3600) {
            h.client.now = null;
            h.certs_at = now;
        }
        const U = union(enum) { done: anyerror!jmap.Reply, timeout: Io.Cancelable!void };
        var buf: [2]U = undefined;
        var sel: Io.Select(U) = .init(h.io, &buf);
        errdefer sel.cancelDiscard();
        try sel.concurrent(.done, sendNow, .{ h, arena, req });
        try sel.concurrent(.timeout, sleepMs, .{ h.io, req.timeout_ms orelse h.timeout_ms });
        const first = try sel.await();
        sel.cancelDiscard();
        return switch (first) {
            .done => |r| r,
            .timeout => error.Timeout,
        };
    }

    fn sleepMs(io: Io, ms: i64) Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(ms), .awake);
    }

    fn sendNow(h: *Http, arena: std.mem.Allocator, r: jmap.Request) anyerror!jmap.Reply {
        const uri = try std.Uri.parse(r.url);
        var req = try h.client.request(if (r.method == .POST) .POST else .GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = if (r.body != null) .{ .override = r.content_type } else .default,
                .authorization = if (r.auth) |v| .{ .override = v } else .omit,
            },
            .extra_headers = &.{.{ .name = "accept", .value = r.accept }},
        });
        defer req.deinit();
        if (r.body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var bw = req.sendBodyUnflushed(&.{}) catch return writeCause(&req);
            bw.writer.writeAll(payload) catch return writeCause(&req);
            bw.end() catch return writeCause(&req);
            req.connection.?.flush() catch return writeCause(&req);
        } else req.sendBodiless() catch return writeCause(&req);

        var response = req.receiveHead(&.{}) catch |err| switch (err) {
            error.ReadFailed => return readCause(&req),
            error.WriteFailed => return writeCause(&req),
            else => |e| return e,
        };
        // The head's strings go once the body is read: copy what's needed.
        const status: u16 = @backingInt(response.head.status);
        const location: ?[]const u8 = if (response.head.location) |l| try arena.dupe(u8, l) else null;
        if (status >= 300 and status < 400) return .{ .status = status, .location = location };
        var challenge: ?[]const u8 = null;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |hd| if (std.ascii.eqlIgnoreCase(hd.name, "www-authenticate")) {
            challenge = try arena.dupe(u8, hd.value);
        };
        const decompress_buf: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .gzip, .deflate => try arena.alloc(u8, std.compress.flate.max_window_len),
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var transfer_buf: [64]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
        const body = body_reader.allocRemaining(arena, .limited(h.max_body)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse readCause(&req),
            else => |e| return e,
        };
        return .{ .status = status, .body = body, .location = location, .challenge = challenge };
    }
};

/// The real cause of a read that failed (Io's readers only say ReadFailed).
fn readCause(req: *const http.Client.Request) anyerror {
    if (req.connection) |c| if (c.stream_reader.err) |e| return e;
    return error.ReadFailed;
}

fn writeCause(req: *const http.Client.Request) anyerror {
    if (req.connection) |c| if (c.stream_writer.err) |e| return e;
    return error.WriteFailed;
}

/// What a push stream tells: that it's open, and each state change.
pub const Listener = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque) void,
    state: *const fn (ctx: *anyopaque) void,
};

/// Reads an EventSource stream (JMAP push, RFC 8620 §7.3) until the
/// server closes it, it fails, or the task is canceled.
pub fn eventStream(client: *http.Client, url: []const u8, auth: []const u8, listener: Listener) anyerror!void {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        // Credentials never follow a redirect here.
        .redirect_behavior = .unhandled,
        .headers = .{ .authorization = .{ .override = auth }, .accept_encoding = .omit },
        .extra_headers = &.{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
        .keep_alive = false,
    });
    defer req.deinit();
    req.sendBodiless() catch return writeCause(&req);
    var response = req.receiveHead(&.{}) catch |err| switch (err) {
        error.ReadFailed => return readCause(&req),
        else => |e| return e,
    };
    if (response.head.status != .ok) return error.PushRefused;
    if (response.head.content_encoding != .identity) return error.UnexpectedContentEncoding;
    const ct = response.head.content_type orelse "";
    if (!std.mem.startsWith(u8, ct, "text/event-stream")) return error.NotEventStream;
    listener.open(listener.ctx);
    // The transfer buffer is the longest line read.
    var line_buf: [64 * 1024]u8 = undefined;
    const r = response.reader(&line_buf);
    var event: enum { other, state } = .other;
    while (true) {
        const raw = r.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse readCause(&req),
            error.StreamTooLong => return error.LineTooLong,
        } orelse return;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (event == .state) listener.state(listener.ctx);
            event = .other;
        } else if (std.mem.startsWith(u8, line, "event:")) {
            const name = std.mem.trim(u8, line["event:".len..], " ");
            event = if (std.mem.eql(u8, name, "state")) .state else .other;
        } else if (std.mem.startsWith(u8, line, "data:") and event == .other) {
            // Without an event line: a StateChange object is a state event.
            if (std.mem.indexOf(u8, line, "StateChange") != null) event = .state;
        }
    }
}
