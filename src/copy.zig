//! Deep copies of plain data (structs, unions, optionals, slices,
//! strings) into an arena: what crosses between threads owns its memory.
const std = @import("std");

pub fn deep(comptime T: type, arena: std.mem.Allocator, v: T) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void, .comptime_int, .comptime_float => return v,
        .optional => |o| return if (v) |inner| try deep(o.child, arena, inner) else null,
        .pointer => |p| {
            if (p.size != .slice) return v;
            const out = try arena.alloc(p.child, v.len);
            for (v, 0..) |item, i| out[i] = try deep(p.child, arena, item);
            return out;
        },
        .array => |a| {
            var out: T = undefined;
            for (v, 0..) |item, i| out[i] = try deep(a.child, arena, item);
            return out;
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return v;
            var out: T = v;
            inline for (s.field_names, s.field_types) |name, FT| {
                @field(out, name) = try deep(FT, arena, @field(v, name));
            }
            return out;
        },
        .@"union" => {
            switch (v) {
                inline else => |payload, tag| {
                    const P = @TypeOf(payload);
                    return @unionInit(T, @tagName(tag), try deep(P, arena, payload));
                },
            }
        },
        else => @compileError("copy.deep: can't copy " ++ @typeName(T)),
    }
}

test "deep copies own their strings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const U = union(enum) { a: struct { s: []const u8, list: []const []const u8, n: ?u32 }, b };
    var src_buf = "hello".*;
    const list = [_][]const u8{ "x", "y" };
    const v: U = .{ .a = .{ .s = &src_buf, .list = &list, .n = 3 } };
    const c = try deep(U, arena.allocator(), v);
    src_buf[0] = 'j';
    try std.testing.expectEqualStrings("hello", c.a.s);
    try std.testing.expectEqualStrings("y", c.a.list[1]);
    try std.testing.expectEqual(@as(?u32, 3), c.a.n);
    try std.testing.expect((try deep(U, arena.allocator(), .b)) == .b);
}
