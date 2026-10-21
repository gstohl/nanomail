//! Secrets in the keychain (the login keychain on the Mac, the app's on iOS) (Security.framework's generic passwords),
//! called directly as nanoui calls the system: no C, no shims.
const std = @import("std");
const builtin = @import("builtin");
/// macOS and iOS: the same keychain calls.
const apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

const CFTypeRef = *const anyopaque;
const CFStringRef = *const anyopaque;
const CFDictionaryRef = *const anyopaque;
const CFDataRef = *const anyopaque;
const OSStatus = i32;

const CFDictionaryKeyCallBacks = extern struct { version: isize, retain: ?*const anyopaque, release: ?*const anyopaque, copyDescription: ?*const anyopaque, equal: ?*const anyopaque, hash: ?*const anyopaque };
const CFDictionaryValueCallBacks = extern struct { version: isize, retain: ?*const anyopaque, release: ?*const anyopaque, copyDescription: ?*const anyopaque, equal: ?*const anyopaque };

extern "c" var kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern "c" var kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
extern "c" var kCFBooleanTrue: CFTypeRef;
extern "c" var kSecClass: CFStringRef;
extern "c" var kSecClassGenericPassword: CFStringRef;
extern "c" var kSecAttrService: CFStringRef;
extern "c" var kSecAttrAccount: CFStringRef;
extern "c" var kSecAttrLabel: CFStringRef;
extern "c" var kSecValueData: CFStringRef;
extern "c" var kSecReturnData: CFStringRef;
extern "c" var kSecMatchLimit: CFStringRef;
extern "c" var kSecMatchLimitOne: CFStringRef;

extern "c" fn CFDictionaryCreate(alloc: ?*const anyopaque, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, n: isize, kcb: *const CFDictionaryKeyCallBacks, vcb: *const CFDictionaryValueCallBacks) ?CFDictionaryRef;
extern "c" fn CFStringCreateWithBytes(alloc: ?*const anyopaque, bytes: [*]const u8, n: isize, encoding: u32, external: bool) ?CFStringRef;
extern "c" fn CFDataCreate(alloc: ?*const anyopaque, bytes: [*]const u8, n: isize) ?CFDataRef;
extern "c" fn CFDataGetBytePtr(d: CFDataRef) [*]const u8;
extern "c" fn CFDataGetLength(d: CFDataRef) isize;
extern "c" fn CFRelease(obj: CFTypeRef) void;
extern "c" fn SecItemAdd(attrs: CFDictionaryRef, result: ?*?CFTypeRef) OSStatus;
extern "c" fn SecItemCopyMatching(query: CFDictionaryRef, result: *?CFTypeRef) OSStatus;
extern "c" fn SecItemUpdate(query: CFDictionaryRef, changes: CFDictionaryRef) OSStatus;
extern "c" fn SecItemDelete(query: CFDictionaryRef) OSStatus;

const utf8: u32 = 0x08000100;
const err_not_found: OSStatus = -25300;
const err_duplicate: OSStatus = -25299;

/// CF objects made for one call, released together.
const Made = struct {
    objs: [8]CFTypeRef = undefined,
    n: usize = 0,

    fn str(m: *Made, s: []const u8) !CFStringRef {
        const o = CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8, false) orelse return error.Keychain;
        m.objs[m.n] = o;
        m.n += 1;
        return o;
    }

    fn data(m: *Made, s: []const u8) !CFDataRef {
        const o = CFDataCreate(null, s.ptr, @intCast(s.len)) orelse return error.Keychain;
        m.objs[m.n] = o;
        m.n += 1;
        return o;
    }

    fn dict(m: *Made, keys: []const CFTypeRef, values: []const CFTypeRef) !CFDictionaryRef {
        const o = CFDictionaryCreate(null, @ptrCast(keys.ptr), @ptrCast(values.ptr), @intCast(keys.len), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.Keychain;
        m.objs[m.n] = o;
        m.n += 1;
        return o;
    }

    fn release(m: *Made) void {
        for (m.objs[0..m.n]) |o| CFRelease(o);
    }
};

/// Stores `secret` for (`service`, `account`), replacing what was there.
pub fn save(service: []const u8, account: []const u8, secret: []const u8) !void {
    if (comptime !apple) return error.Unsupported;
    var m: Made = .{};
    defer m.release();
    const svc = try m.str(service);
    const acc = try m.str(account);
    const value = try m.data(secret);
    const query = try m.dict(&.{ kSecClass, kSecAttrService, kSecAttrAccount }, &.{ kSecClassGenericPassword, svc, acc });
    const changes = try m.dict(&.{kSecValueData}, &.{value});
    var status = SecItemUpdate(query, changes);
    if (status == err_not_found) {
        const label = try m.str(service);
        const attrs = try m.dict(&.{ kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrLabel, kSecValueData }, &.{ kSecClassGenericPassword, svc, acc, label, value });
        status = SecItemAdd(attrs, null);
    }
    if (status != 0) return error.Keychain;
}

/// The secret for (`service`, `account`), in `gpa`'s memory; null if none.
pub fn load(gpa: std.mem.Allocator, service: []const u8, account: []const u8) !?[]u8 {
    if (comptime !apple) return null;
    var m: Made = .{};
    defer m.release();
    const query = try m.dict(
        &.{ kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit },
        &.{ kSecClassGenericPassword, try m.str(service), try m.str(account), kCFBooleanTrue, kSecMatchLimitOne },
    );
    var out: ?CFTypeRef = null;
    const status = SecItemCopyMatching(query, &out);
    if (status == err_not_found) return null;
    if (status != 0) return error.Keychain;
    const d = out orelse return null;
    defer CFRelease(d);
    const len: usize = @intCast(CFDataGetLength(d));
    return try gpa.dupe(u8, CFDataGetBytePtr(d)[0..len]);
}

pub fn remove(service: []const u8, account: []const u8) void {
    if (comptime !apple) return;
    var m: Made = .{};
    defer m.release();
    const svc = m.str(service) catch return;
    const acc = m.str(account) catch return;
    const query = m.dict(&.{ kSecClass, kSecAttrService, kSecAttrAccount }, &.{ kSecClassGenericPassword, svc, acc }) catch return;
    _ = SecItemDelete(query);
}
