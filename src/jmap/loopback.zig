//! Where the browser comes back after signing in (RFC 8252 §7.3): a
//! listener on 127.0.0.1 at a port the system picks, for as long as one
//! sign-in takes. It answers the browser's request with a page saying to
//! go back to nanomail, and hands over the request's target.
const std = @import("std");
const Io = std.Io;

pub const Loopback = struct {
    server: Io.net.Server,
    port: u16,

    pub fn open(io: Io) !Loopback {
        const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{});
        return .{ .server = server, .port = server.socket.address.getPort() };
    }

    pub fn close(lb: *Loopback, io: Io) void {
        lb.server.deinit(io);
    }

    /// "http://127.0.0.1:<port>/callback".
    pub fn redirectUri(lb: *const Loopback, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/callback", .{lb.port});
    }

    /// Waits for the browser's request to /callback and answers it; other
    /// requests (a favicon) get a 404 and the wait goes on. Returns the
    /// target ("/callback?code=…"), in `arena`.
    pub fn wait(lb: *Loopback, io: Io, arena: std.mem.Allocator) ![]const u8 {
        while (true) {
            const stream = try lb.server.accept(io);
            defer stream.close(io);
            var rbuf: [8192]u8 = undefined;
            var reader = stream.reader(io, &rbuf);
            const line = (reader.interface.takeDelimiter('\n') catch continue) orelse continue;
            // "GET /callback?code=… HTTP/1.1"
            var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
            const method = parts.next() orelse continue;
            const target = parts.next() orelse continue;
            const ours = std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, target, "/callback");
            const owned = if (ours) try arena.dupe(u8, target) else "";
            // The rest of the request's head, unread, is no matter.
            var wbuf: [4096]u8 = undefined;
            var writer = stream.writer(io, &wbuf);
            const w = &writer.interface;
            if (!ours) {
                w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                w.flush() catch {};
                continue;
            }
            const failed = std.mem.indexOf(u8, target, "error=") != null;
            const body = if (failed) page_failed else page_done;
            w.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{s}", .{ body.len, body }) catch {};
            w.flush() catch {};
            return owned;
        }
    }
};

const page_head =
    \\<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    \\<title>nanomail</title><style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;
    \\height:90vh;margin:0;color:#1d1d1f;background:#f5f5f7}@media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#1c1c1e}}
    \\main{text-align:center}h1{font-size:22px;margin:.4em 0}p{color:#6e6e73}</style><main>
;
const page_done = page_head ++
    \\<h1>You're signed in</h1><p>You can close this tab and go back to nanomail.</p></main>
;
const page_failed = page_head ++
    \\<h1>Not signed in</h1><p>Go back to nanomail to see why, and try again.</p></main>
;

test "the browser's request comes back, answered" {
    const io = std.testing.io;
    var lb = try Loopback.open(io);
    defer lb.close(io);
    try std.testing.expect(lb.port != 0);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Browser = struct {
        fn visit(port: u16, path: []const u8, out: *[512]u8, len: *usize) void {
            const addr: Io.net.IpAddress = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
            const s = addr.connect(std.testing.io, .{ .mode = .stream }) catch return;
            defer s.close(std.testing.io);
            var wb: [256]u8 = undefined;
            var w = s.writer(std.testing.io, &wb);
            w.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{path}) catch return;
            w.interface.flush() catch return;
            var rb: [1024]u8 = undefined;
            var r = s.reader(std.testing.io, &rb);
            const line = (r.interface.takeDelimiter('\n') catch return) orelse return;
            len.* = @min(line.len, out.len);
            @memcpy(out[0..len.*], line[0..len.*]);
        }
    };
    var first: [512]u8 = undefined;
    var first_len: usize = 0;
    var second: [512]u8 = undefined;
    var second_len: usize = 0;
    const t1 = try std.Thread.spawn(.{}, struct {
        fn run(port: u16, a: *[512]u8, al: *usize, b: *[512]u8, bl: *usize) void {
            Browser.visit(port, "/favicon.ico", a, al);
            Browser.visit(port, "/callback?code=abc&state=xyz", b, bl);
        }
    }.run, .{ lb.port, &first, &first_len, &second, &second_len });
    const target = try lb.wait(io, arena.allocator());
    t1.join();
    try std.testing.expectEqualStrings("/callback?code=abc&state=xyz", target);
    try std.testing.expect(std.mem.startsWith(u8, first[0..first_len], "HTTP/1.1 404"));
    try std.testing.expect(std.mem.startsWith(u8, second[0..second_len], "HTTP/1.1 200"));
}
