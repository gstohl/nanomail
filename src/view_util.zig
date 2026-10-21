//! Small pieces the views share: text cut to a width with an ellipsis,
//! hairlines, sizes.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

/// The toolbar band across the top of the window (traffic lights in it).
pub const toolbar_h: f32 = 52;
pub const sidebar_w: f32 = 220;
pub const list_w: f32 = 360;
pub const row_h: f32 = 78;
/// Narrower than this, panes stack (a phone, an iPad held upright).
pub const stack_below: f32 = 900;
pub const ios = @import("builtin").os.tag == .ios;
/// Room left at the top for the traffic lights (none on iOS).
pub const top_inset: f32 = if (ios) 6 else toolbar_h;

/// Where a pane is drawn: its width, its left edge, and whether it has
/// the window to itself (stacked panes, with back buttons).
pub const Pane = struct {
    w: f32,
    x: f32 = 0,
    stacked: bool = false,
};

/// A back button: "‹ Mailboxes".
pub fn back(c: *ui.Context, label: []const u8) bool {
    const b = ui.div(c).row().gap(2).itemsCenter().px(4).py(6).control();
    defer b.end();
    ui.icon(c, "chevron.left", .{ .size = 16, .weight = .semibold, .color = c.theme.accent });
    ui.text(c, label, .{ .size = 15, .color = c.theme.accent });
    return b.clicked();
}

/// `s` as it fits in `max_w` points: whole, or cut with "…" (on a UTF-8
/// boundary), in the frame's memory.
pub fn fit(c: *ui.Context, s: []const u8, style: ui.TextStyle, max_w: f32) []const u8 {
    if (max_w <= 0) return "";
    if (c.text.width(s, style) <= max_w) return s;
    const ell = "…";
    const room = max_w - c.text.width(ell, style);
    if (room <= 0) return ell;
    // Where characters start (in the first 600 bytes: more never fits).
    const head = s[0..@min(s.len, 600)];
    var bounds: std.ArrayList(usize) = .empty;
    for (head, 0..) |ch, i| if ((ch & 0xc0) != 0x80) bounds.append(c.alloc(), i) catch return s;
    if (bounds.items.len == 0) return ell;
    // The longest prefix that fits, by halves.
    var lo: usize = 0;
    var hi: usize = bounds.items.len - 1;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (c.text.width(s[0..bounds.items[mid]], style) <= room) lo = mid else hi = mid - 1;
    }
    const trimmed = std.mem.trimEnd(u8, s[0..bounds.items[lo]], " ,.;:-");
    return c.print("{s}{s}", .{ trimmed, ell });
}

/// Text on one line, cut to `max_w`.
pub fn line(c: *ui.Context, s: []const u8, style: ui.TextStyle, max_w: f32) void {
    ui.text(c, fit(c, s, style, max_w), style);
}

/// Text with its line breaks and tabs made spaces (a preview, a subject).
pub fn flat(c: *ui.Context, s: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, s, "\r\n\t") == null) return s;
    const out = c.alloc().dupe(u8, s) catch return s;
    for (out) |*ch| if (ch.* == '\r' or ch.* == '\n' or ch.* == '\t') {
        ch.* = ' ';
    };
    return out;
}

pub fn vline(c: *ui.Context) void {
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = c.theme.border.alpha(0.7) }, .none, null);
}

pub fn hline(c: *ui.Context) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = c.theme.border.alpha(0.7) }, .none, null);
}

/// "12 KB", "3.4 MB".
pub fn size(c: *ui.Context, bytes: u64) []const u8 {
    if (bytes < 1024) return c.print("{d} B", .{bytes});
    if (bytes < 1024 * 1024) return c.print("{d} KB", .{(bytes + 512) / 1024});
    return c.print("{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)});
}

/// The sidebar's tint: a little darker than the window's background.
pub fn sidebarColor(th: ui.Theme) ui.Color {
    return if (th.dark) th.background.mix(.black, 0.18) else th.background.mix(th.border, 0.35);
}

/// The selection's fill in lists.
pub fn selectedColor(th: ui.Theme, focused: bool) ui.Color {
    return if (focused) th.accent else th.accent.alpha(if (th.dark) 0.32 else 0.16);
}
