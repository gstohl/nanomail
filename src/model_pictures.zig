//! Pictures in mail, for the reader: fetched once each (by the sync
//! thread's picture queue), kept for a while, and those on the web only
//! for messages whose pictures the user asked to see.
const std = @import("std");
const k = @import("mail/kinds.zig");
const Model = @import("model.zig").Model;

pub const State = union(enum) {
    loading,
    failed,
    /// The bytes, and the arena they live in.
    ready: struct { arena: std.heap.ArenaAllocator, bytes: []const u8 },
};

/// Pictures kept at most; past that, the oldest go.
const max_kept = 160;

/// The bytes of `p`, if they're here; else asked for (when it may be).
pub fn picture(m: *Model, p: k.Picture, message_id: []const u8) ?[]const u8 {
    const key = p.key();
    if (key.len == 0) return null;
    if (m.pictures.get(key)) |st| return switch (st) {
        .ready => |r| r.bytes,
        else => null,
    };
    if (p.url != null and !remoteAllowed(m, message_id)) return null;
    const owned = m.gpa.dupe(u8, key) catch return null;
    m.pictures.put(m.gpa, owned, .loading) catch {
        m.gpa.free(owned);
        return null;
    };
    m.submit(.{ .picture = .{ .key = key, .account_id = p.account_id, .blob_id = p.blob_id, .url = p.url, .type = p.type } });
    trim(m);
    return null;
}

/// Whether `p` is loading (else: here, failed, or not asked for).
pub fn pictureLoading(m: *const Model, p: k.Picture) bool {
    const st = m.pictures.get(p.key()) orelse return false;
    return st == .loading;
}

pub fn pictureFailed(m: *const Model, p: k.Picture) bool {
    const st = m.pictures.get(p.key()) orelse return false;
    return st == .failed;
}

/// The bytes came (or didn't): `arena` holds them, and is the model's now.
pub fn received(m: *Model, arena: std.heap.ArenaAllocator, key: []const u8, bytes: ?[]const u8) bool {
    const entry = m.pictures.getEntry(key) orelse return false;
    entry.value_ptr.* = if (bytes) |b| .{ .ready = .{ .arena = arena, .bytes = b } } else .failed;
    return bytes != null;
}

/// The pictures on the web, for this message: the user asked.
pub fn allowRemote(m: *Model, message_id: []const u8) void {
    if (remoteAllowed(m, message_id)) return;
    const owned = m.gpa.dupe(u8, message_id) catch return;
    m.remote_ok.put(m.gpa, owned, {}) catch m.gpa.free(owned);
}

pub fn remoteAllowed(m: *const Model, message_id: []const u8) bool {
    return m.remote_ok.contains(message_id);
}

fn trim(m: *Model) void {
    while (m.pictures.count() > max_kept) {
        // The oldest (first put), unless it's still on its way.
        var it = m.pictures.iterator();
        const victim = while (it.next()) |e| {
            if (e.value_ptr.* != .loading) break e.key_ptr.*;
        } else return;
        if (m.pictures.fetchOrderedRemove(victim)) |kv| {
            if (kv.value == .ready) {
                var a = kv.value.ready.arena;
                a.deinit();
            }
            m.gpa.free(kv.key);
        }
    }
}

pub fn deinit(m: *Model) void {
    var it = m.pictures.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .ready) e.value_ptr.ready.arena.deinit();
        m.gpa.free(e.key_ptr.*);
    }
    m.pictures.deinit(m.gpa);
    var r = m.remote_ok.keyIterator();
    while (r.next()) |key| m.gpa.free(key.*);
    m.remote_ok.deinit(m.gpa);
}
