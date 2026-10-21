//! The account kept between launches: where and who in
//! `~/Library/Application Support/nanomail/account.json`, the secret in
//! the keychain. NANOMAIL_URL, NANOMAIL_USER and NANOMAIL_PASSWORD (or
//! NANOMAIL_TOKEN) stand in for both, touching neither: for trying a
//! server, and for headless runs.
const std = @import("std");
const nanoui = @import("nanoui");
const k = @import("mail/kinds.zig");
const keychain = @import("keychain.zig");

pub const service = "nanomail";

const Saved = struct {
    server: []const u8 = "",
    username: []const u8 = "",
    token: bool = false,
    session_url: []const u8 = "",
    /// Signed in through the browser (the keychain holds a refresh token).
    oauth_client_id: []const u8 = "",
    oauth_token_endpoint: []const u8 = "",
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The folder holding account.json; null when it can't be had.
    dir: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Store {
        return .{ .gpa = gpa, .io = io, .dir = nanoui.path(gpa, .data, "nanomail") catch null };
    }

    pub fn deinit(s: *Store) void {
        if (s.dir) |d| s.gpa.free(d);
    }

    fn file(s: *Store, a: std.mem.Allocator) ?[]const u8 {
        const d = s.dir orelse return null;
        return std.fs.path.join(a, &.{ d, "account.json" }) catch null;
    }

    /// The account to sign in to at launch, in `arena`; null if none.
    pub fn load(s: *Store, arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?k.Account {
        if (env.get("NANOMAIL_USER")) |user| {
            const token = env.get("NANOMAIL_TOKEN");
            return .{
                .server = env.get("NANOMAIL_URL") orelse "",
                .username = user,
                .secret = token orelse env.get("NANOMAIL_PASSWORD") orelse "",
                .token = token != null,
            };
        }
        const path = s.file(arena) orelse return null;
        const json = std.Io.Dir.cwd().readFileAlloc(s.io, path, arena, .limited(64 * 1024)) catch return null;
        const saved = std.json.parseFromSliceLeaky(Saved, arena, json, .{ .ignore_unknown_fields = true }) catch return null;
        if (saved.username.len == 0) return null;
        const secret = keychain.load(arena, service, saved.username) catch null orelse return null;
        // The session's own URL saves finding it again.
        return .{
            .server = if (saved.session_url.len > 0) saved.session_url else saved.server,
            .username = saved.username,
            .secret = secret,
            .token = saved.token,
            .oauth = if (saved.oauth_client_id.len > 0) .{ .client_id = saved.oauth_client_id, .token_endpoint = saved.oauth_token_endpoint } else null,
        };
    }

    /// Keeps `account`: the secret in the keychain, the rest in the file.
    pub fn save(s: *Store, account: k.Account, session_url: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try keychain.save(service, account.username, account.secret);
        const path = s.file(a) orelse return error.NoDataFolder;
        const json = try std.json.Stringify.valueAlloc(a, Saved{
            .server = account.server,
            .username = account.username,
            .token = account.token,
            .session_url = session_url,
            .oauth_client_id = if (account.oauth) |o| o.client_id else "",
            .oauth_token_endpoint = if (account.oauth) |o| o.token_endpoint else "",
        }, .{ .whitespace = .indent_2 });
        try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = json });
    }

    /// A new secret (a refresh token the server replaced) for the account kept.
    pub fn updateSecret(s: *Store, secret: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = s.file(a) orelse return error.NoDataFolder;
        const json = try std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(64 * 1024));
        const saved = try std.json.parseFromSliceLeaky(Saved, a, json, .{ .ignore_unknown_fields = true });
        try keychain.save(service, saved.username, secret);
    }

    /// Signs out for good: the file and the secret go.
    pub fn forget(s: *Store) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = s.file(a) orelse return;
        if (std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(64 * 1024))) |json| {
            if (std.json.parseFromSliceLeaky(Saved, a, json, .{ .ignore_unknown_fields = true })) |saved| {
                keychain.remove(service, saved.username);
            } else |_| {}
        } else |_| {}
        std.Io.Dir.cwd().deleteFile(s.io, path) catch {};
    }
};
