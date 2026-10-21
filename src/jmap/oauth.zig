//! Signing in through the browser: OAuth 2.0's authorization code flow
//! with PKCE (RFC 6749, RFC 7636), as native apps do it (RFC 8252). The
//! server is found from the JMAP server (RFC 9728, then RFC 8414 or
//! OpenID Connect discovery), the app registers itself where it may
//! (RFC 7591), and the browser comes back to a loopback address
//! (loopback.zig).
const std = @import("std");
const jmap = @import("client.zig");
const session = @import("session.zig");

pub const Metadata = struct {
    issuer: []const u8 = "",
    authorization_endpoint: []const u8 = "",
    token_endpoint: []const u8 = "",
    registration_endpoint: ?[]const u8 = null,
    scopes_supported: ?[]const []const u8 = null,
    code_challenge_methods_supported: ?[]const []const u8 = null,
};

pub const Tokens = struct {
    access_token: []const u8 = "",
    token_type: []const u8 = "",
    refresh_token: ?[]const u8 = null,
    expires_in: ?u64 = null,
};

/// The server's words when a step failed (the sync thread's alone).
pub var problem: []const u8 = "";
var problem_buf: [400]u8 = undefined;

fn get(arena: std.mem.Allocator, t: jmap.Transport, url: []const u8) !?[]const u8 {
    const r = t.send(t.ctx, arena, .{ .method = .GET, .url = url }) catch return null;
    return if (r.status == 200) r.body else null;
}

/// Where the session lives, found without credentials: the discovery URL
/// with its redirects followed.
pub fn findSession(arena: std.mem.Allocator, t: jmap.Transport, url_in: []const u8) ![]const u8 {
    var url = url_in;
    var hops: u8 = 0;
    while (hops < 6) : (hops += 1) {
        const r = try t.send(t.ctx, arena, .{ .method = .GET, .url = url });
        if (r.status >= 300 and r.status < 400) {
            url = try session.resolve(arena, url, r.location orelse return url);
            continue;
        }
        return url;
    }
    return error.TooManyRedirects;
}

/// The authorization server for the JMAP server at `session_url`.
pub fn discover(arena: std.mem.Allocator, t: jmap.Transport, session_url: []const u8) !Metadata {
    const origin = session.origin(session_url);
    // The resource names its authorization server (RFC 9728); else it's
    // the same origin.
    var issuer: []const u8 = origin;
    if (try get(arena, t, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource", .{origin}))) |body| {
        const R = struct { authorization_servers: []const []const u8 = &.{} };
        if (std.json.parseFromSliceLeaky(R, arena, body, .{ .ignore_unknown_fields = true })) |r| {
            if (r.authorization_servers.len > 0) issuer = std.mem.trimEnd(u8, r.authorization_servers[0], "/");
        } else |_| {}
    }
    // RFC 8414 puts the well-known path between an issuer's host and path.
    const io = session.origin(issuer);
    const path = issuer[io.len..];
    const candidates = [_][]const u8{
        try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server{s}", .{ io, path }),
        try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration", .{issuer}),
    };
    for (candidates) |url| {
        const body = (try get(arena, t, url)) orelse continue;
        const md = std.json.parseFromSliceLeaky(Metadata, arena, body, .{ .ignore_unknown_fields = true }) catch continue;
        if (md.authorization_endpoint.len == 0 or md.token_endpoint.len == 0) continue;
        return md;
    }
    return error.NoAuthorizationServer;
}

/// Registers nanomail as a public client that comes back to `redirect_uri`.
pub fn register(arena: std.mem.Allocator, t: jmap.Transport, endpoint: []const u8, redirect_uri: []const u8) ![]const u8 {
    const body = try std.json.Stringify.valueAlloc(arena, .{
        .client_name = "nanomail",
        .redirect_uris = &[_][]const u8{redirect_uri},
        .token_endpoint_auth_method = "none",
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .application_type = "native",
    }, .{});
    const r = try t.send(t.ctx, arena, .{ .url = endpoint, .body = body });
    if (r.status != 200 and r.status != 201) return error.RegistrationRefused;
    const R = struct { client_id: []const u8 = "" };
    const got = std.json.parseFromSliceLeaky(R, arena, r.body, .{ .ignore_unknown_fields = true }) catch return error.RegistrationRefused;
    if (got.client_id.len == 0) return error.RegistrationRefused;
    return got.client_id;
}

/// A sign-in's secrets: the PKCE verifier (and its challenge), and the
/// state that ties the browser's answer to this request.
pub const Pkce = struct {
    verifier: [43]u8,
    challenge: [43]u8,
    state: [22]u8,

    pub fn make(io: std.Io) Pkce {
        var p: Pkce = undefined;
        var raw: [32]u8 = undefined;
        io.random(&raw);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&p.verifier, &raw);
        var st: [16]u8 = undefined;
        io.random(&st);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&p.state, &st);
        p.challenge = challengeOf(&p.verifier);
        return p;
    }
};

/// S256: base64url(SHA-256(verifier)).
pub fn challengeOf(verifier: []const u8) [43]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var out: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &digest);
    return out;
}

/// The scopes asked for: mail and a refresh token, where the server
/// names them; else the usual OpenID ones.
pub fn scopes(arena: std.mem.Allocator, md: Metadata) ![]const u8 {
    const want = [_][]const u8{ "openid", "email", "offline_access", "urn:ietf:params:oauth:scope:mail", "urn:ietf:params:oauth:scope:submission" };
    const supported = md.scopes_supported orelse return "openid email offline_access";
    var out: std.ArrayList(u8) = .empty;
    for (want) |w| for (supported) |s| if (std.mem.eql(u8, s, w)) {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, w);
        break;
    };
    return out.items;
}

/// The page the browser opens.
pub fn authorizationUrl(arena: std.mem.Allocator, md: Metadata, client_id: []const u8, redirect_uri: []const u8, p: *const Pkce, scope: []const u8, login_hint: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll(md.authorization_endpoint);
    try w.writeByte(if (std.mem.indexOfScalar(u8, md.authorization_endpoint, '?') == null) '?' else '&');
    const params = [_][2][]const u8{
        .{ "response_type", "code" },
        .{ "client_id", client_id },
        .{ "redirect_uri", redirect_uri },
        .{ "scope", scope },
        .{ "state", &p.state },
        .{ "code_challenge", &p.challenge },
        .{ "code_challenge_method", "S256" },
        .{ "login_hint", login_hint },
    };
    try form(w, &params);
    return aw.written();
}

/// `k=v&k=v`, form-encoded; empty values left out.
fn form(w: *std.Io.Writer, params: []const [2][]const u8) !void {
    var first = true;
    for (params) |kv| {
        if (kv[1].len == 0) continue;
        if (!first) try w.writeByte('&');
        first = false;
        try encode(w, kv[0]);
        try w.writeByte('=');
        try encode(w, kv[1]);
    }
}

fn encode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else try w.print("%{X:0>2}", .{ch});
    }
}

pub const Callback = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    iss: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

/// The browser's request to the redirect URI ("/callback?code=…").
pub fn parseCallback(arena: std.mem.Allocator, target: []const u8) !Callback {
    var cb: Callback = .{};
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return cb;
    var pairs = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const v = try decode(arena, pair[eq + 1 ..]);
        const key = pair[0..eq];
        inline for (.{ "code", "state", "iss", "error", "error_description" }) |name| {
            if (std.mem.eql(u8, key, name)) @field(cb, name) = v;
        }
    }
    return cb;
}

fn decode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '+') {
            out[n] = ' ';
            i += 1;
        } else if (s[i] == '%' and i + 3 <= s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                i += 3;
            } else |_| {
                out[n] = '%';
                i += 1;
            }
        } else {
            out[n] = s[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// What the browser brought back: the code, if it's ours and no error.
pub fn checkCallback(cb: Callback, p: *const Pkce, md: Metadata) ![]const u8 {
    if (cb.state == null or !std.mem.eql(u8, cb.state.?, &p.state)) return error.StateMismatch;
    if (cb.@"error") |e| {
        problem = std.fmt.bufPrint(&problem_buf, "The server said no: {s}", .{cb.error_description orelse e}) catch "";
        return if (std.mem.eql(u8, e, "access_denied")) error.AccessDenied else error.AuthorizationFailed;
    }
    // RFC 9207: the answer names its issuer, which must be the one asked.
    if (cb.iss) |iss| if (md.issuer.len > 0 and !std.mem.eql(u8, std.mem.trimEnd(u8, iss, "/"), std.mem.trimEnd(u8, md.issuer, "/"))) return error.IssuerMismatch;
    return cb.code orelse error.NoCode;
}

fn tokenRequest(arena: std.mem.Allocator, t: jmap.Transport, endpoint: []const u8, params: []const [2][]const u8) !Tokens {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try form(&aw.writer, params);
    const r = try t.send(t.ctx, arena, .{ .url = endpoint, .body = aw.written(), .content_type = "application/x-www-form-urlencoded" });
    if (r.status != 200) {
        const E = struct { @"error": []const u8 = "", error_description: ?[]const u8 = null };
        const e = std.json.parseFromSliceLeaky(E, arena, r.body, .{ .ignore_unknown_fields = true }) catch E{};
        problem = std.fmt.bufPrint(&problem_buf, "{s}", .{e.error_description orelse e.@"error"}) catch "";
        return if (std.mem.eql(u8, e.@"error", "invalid_grant")) error.InvalidGrant else error.TokenRefused;
    }
    const tok = std.json.parseFromSliceLeaky(Tokens, arena, r.body, .{ .ignore_unknown_fields = true }) catch return error.TokenRefused;
    if (tok.access_token.len == 0) return error.TokenRefused;
    return tok;
}

/// Trades the browser's code for tokens.
pub fn exchange(arena: std.mem.Allocator, t: jmap.Transport, md: Metadata, client_id: []const u8, code: []const u8, redirect_uri: []const u8, p: *const Pkce) !Tokens {
    return tokenRequest(arena, t, md.token_endpoint, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "redirect_uri", redirect_uri },
        .{ "client_id", client_id },
        .{ "code_verifier", &p.verifier },
    });
}

/// A new access token for a refresh token.
pub fn refresh(arena: std.mem.Allocator, t: jmap.Transport, token_endpoint: []const u8, client_id: []const u8, refresh_token: []const u8) !Tokens {
    return tokenRequest(arena, t, token_endpoint, &.{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", refresh_token },
        .{ "client_id", client_id },
    });
}

test "PKCE's S256 challenge (RFC 7636, appendix B)" {
    const c = challengeOf("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &c);
}

test "the authorization URL, and the browser's answer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Pkce = .{ .verifier = @splat('v'), .challenge = @splat('c'), .state = @splat('s') };
    p.state[0] = 'S';
    const md: Metadata = .{ .issuer = "https://id.example", .authorization_endpoint = "https://id.example/authorize", .token_endpoint = "https://id.example/token", .scopes_supported = &.{ "openid", "offline_access", "urn:ietf:params:oauth:scope:mail", "profile" } };
    const scope = try scopes(a, md);
    try std.testing.expectEqualStrings("openid offline_access urn:ietf:params:oauth:scope:mail", scope);
    const url = try authorizationUrl(a, md, "app 1", "http://127.0.0.1:5000/callback", &p, scope, "me@example.test");
    try std.testing.expect(std.mem.startsWith(u8, url, "https://id.example/authorize?response_type=code&client_id=app%201&redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback&scope=openid%20offline_access"));
    try std.testing.expect(std.mem.indexOf(u8, url, "&code_challenge_method=S256&login_hint=me%40example.test") != null);

    const cb = try parseCallback(a, "/callback?code=abc%2Fdef&state=Ssssssssssssssssssssss&iss=https%3A%2F%2Fid.example");
    try std.testing.expectEqualStrings("abc/def", try checkCallback(cb, &p, md));
    try std.testing.expectError(error.StateMismatch, checkCallback(try parseCallback(a, "/callback?code=x&state=other"), &p, md));
    try std.testing.expectError(error.IssuerMismatch, checkCallback(try parseCallback(a, "/callback?code=x&state=Ssssssssssssssssssssss&iss=https%3A%2F%2Fevil"), &p, md));
    try std.testing.expectError(error.AccessDenied, checkCallback(try parseCallback(a, "/callback?error=access_denied&error_description=No+thanks&state=Ssssssssssssssssssssss"), &p, md));
    try std.testing.expectEqualStrings("The server said no: No thanks", problem);
}
