//! JMAP requests and responses (RFC 8620 §3): method calls batched into
//! one request, each answered by id; results of one call fed to the next
//! by reference (`#ids`).
const std = @import("std");

/// A request being built: calls added in order, then `body`.
pub const Request = struct {
    arena: std.mem.Allocator,
    using: []const []const u8,
    calls: std.ArrayList(u8) = .empty,
    count: u32 = 0,

    pub fn init(arena: std.mem.Allocator, using: []const []const u8) Request {
        return .{ .arena = arena, .using = using };
    }

    /// Adds `name` with `args` (a struct or `std.json.Value`); returns the
    /// call's id, for references and to find its answer.
    pub fn call(r: *Request, name: []const u8, args: anytype) ![]const u8 {
        const id = try std.fmt.allocPrint(r.arena, "c{d}", .{r.count});
        r.count += 1;
        var aw: std.Io.Writer.Allocating = .fromArrayList(r.arena, &r.calls);
        defer r.calls = aw.toArrayList();
        const w = &aw.writer;
        if (r.count > 1) try w.writeByte(',');
        try w.writeByte('[');
        try std.json.Stringify.value(name, .{}, w);
        try w.writeByte(',');
        try std.json.Stringify.value(args, .{ .emit_null_optional_fields = false }, w);
        try w.writeByte(',');
        try std.json.Stringify.value(id, .{}, w);
        try w.writeByte(']');
        return id;
    }

    /// The request's JSON.
    pub fn body(r: *Request) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(r.arena);
        const w = &aw.writer;
        try w.writeAll("{\"using\":");
        try std.json.Stringify.value(r.using, .{}, w);
        try w.writeAll(",\"methodCalls\":[");
        try w.writeAll(r.calls.items);
        try w.writeAll("]}");
        return aw.written();
    }
};

/// `{"resultOf": id, "name": method, "path": path}`: another call's result.
pub const ResultRef = struct {
    resultOf: []const u8,
    name: []const u8,
    path: []const u8,
};

pub const MethodError = struct {
    type: []const u8 = "serverFail",
    description: ?[]const u8 = null,
};

/// A response, parsed into `arena`.
pub const Response = struct {
    arena: std.mem.Allocator,
    responses: []const std.json.Value,
    session_state: []const u8 = "",
    /// The last method error found (`get` returned error.MethodError).
    method_error: ?MethodError = null,

    pub fn parse(arena: std.mem.Allocator, json: []const u8) !Response {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.BadResponse;
        if (v != .object) return error.BadResponse;
        const list = v.object.get("methodResponses") orelse {
            // A request-level error (RFC 7807 problem details).
            return error.RequestRejected;
        };
        if (list != .array) return error.BadResponse;
        var state: []const u8 = "";
        if (v.object.get("sessionState")) |s| if (s == .string) {
            state = s.string;
        };
        return .{ .arena = arena, .responses = list.array.items, .session_state = state };
    }

    /// The arguments of the answer to call `id`.
    pub fn args(r: *Response, id: []const u8) !std.json.Value {
        for (r.responses) |inv| {
            if (inv != .array or inv.array.items.len != 3) continue;
            const items = inv.array.items;
            if (items[2] != .string or !std.mem.eql(u8, items[2].string, id)) continue;
            if (items[0] == .string and std.mem.eql(u8, items[0].string, "error")) {
                r.method_error = std.json.parseFromValueLeaky(MethodError, r.arena, items[1], .{ .ignore_unknown_fields = true }) catch .{};
                return error.MethodError;
            }
            return items[1];
        }
        return error.MissingResponse;
    }

    /// The answer to call `id` as a `T`.
    pub fn get(r: *Response, comptime T: type, id: []const u8) !T {
        const a = try r.args(id);
        return std.json.parseFromValueLeaky(T, r.arena, a, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    }
};

/// `{"id1": true, "id2": true}`.
pub fn idSet(arena: std.mem.Allocator, ids: []const []const u8) !std.json.Value {
    var m: std.json.ObjectMap = .empty;
    for (ids) |id| try m.put(arena, id, .{ .bool = true });
    return .{ .object = m };
}

test "request with a back reference" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Request.init(a, &.{ "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail" });
    const q = try r.call("Email/query", .{ .accountId = "u1", .filter = .{ .inMailbox = "m1" }, .limit = @as(u32, 50) });
    _ = try r.call("Email/get", .{ .accountId = "u1", .@"#ids" = ResultRef{ .resultOf = q, .name = "Email/query", .path = "/ids" }, .properties = &[_][]const u8{ "id", "subject" }, .missing = @as(?u32, null) });
    try std.testing.expectEqualStrings(
        \\{"using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"],"methodCalls":[["Email/query",{"accountId":"u1","filter":{"inMailbox":"m1"},"limit":50},"c0"],["Email/get",{"accountId":"u1","#ids":{"resultOf":"c0","name":"Email/query","path":"/ids"},"properties":["id","subject"]},"c1"]]}
    , try r.body());
}

test "null is JSON's null, not a string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = Request.init(arena.allocator(), &.{"urn:ietf:params:jmap:mail"});
    _ = try r.call("Mailbox/get", .{ .accountId = "u1", .ids = @as(std.json.Value, .null) });
    try std.testing.expect(std.mem.indexOf(u8, try r.body(), "\"ids\":null") != null);
}

test "patch objects with run-time keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var patch: std.json.ObjectMap = .empty;
    try patch.put(a, "keywords/$seen", .{ .bool = true });
    try patch.put(a, "mailboxIds/m2", .null);
    var update: std.json.ObjectMap = .empty;
    try update.put(a, "e1", .{ .object = patch });
    var r = Request.init(a, &.{"urn:ietf:params:jmap:mail"});
    _ = try r.call("Email/set", .{ .accountId = "u1", .update = std.json.Value{ .object = update } });
    try std.testing.expectEqualStrings(
        \\{"using":["urn:ietf:params:jmap:mail"],"methodCalls":[["Email/set",{"accountId":"u1","update":{"e1":{"keywords/$seen":true,"mailboxIds/m2":null}}},"c0"]]}
    , try r.body());
}

test "responses by id, and method errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r = try Response.parse(arena.allocator(),
        \\{"methodResponses":[["Email/query",{"accountId":"u1","ids":["a","b"],"position":0,"total":2,"queryState":"q"},"c0"],
        \\["error",{"type":"invalidArguments","description":"bad"},"c1"]],"sessionState":"s9"}
    );
    try std.testing.expectEqualStrings("s9", r.session_state);
    const q = try r.get(@import("types.zig").QueryResponse, "c0");
    try std.testing.expectEqual(@as(usize, 2), q.ids.len);
    try std.testing.expectEqual(@as(?u64, 2), q.total);
    try std.testing.expectError(error.MethodError, r.args("c1"));
    try std.testing.expectEqualStrings("invalidArguments", r.method_error.?.type);
    try std.testing.expectError(error.MissingResponse, r.args("c7"));
}
