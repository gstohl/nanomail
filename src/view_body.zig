//! A message's text as the reader draws it: paragraphs with their links
//! (underlined; a click opens them, the pointer over one shows where it
//! goes), quoted lines set apart, pictures where the mail puts them. The
//! text can be selected and copied.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const k = @import("mail/kinds.zig");
const html = @import("mail/html.zig");

/// The link under the pointer in this frame, for the reader's status pill.
pub var hover_url: ?[]const u8 = null;

/// A run of the message's text copied into a block: from where, to where.
const Seg = struct { from: u32, to: u32, len: u32 };

const Block = struct {
    text: std.ArrayList(u8) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    quoted: bool = false,
};

pub fn body(m: *Model, c: *ui.Context, d: *const k.Detail) void {
    const th = c.theme;
    hover_url = null;
    const col = ui.div(c).column().wFull().maxW(760).gap(10);
    c.node(col.index).style.selectable = true;
    defer col.end();
    const text = d.text[0..@min(d.text.len, 400_000)];
    if (std.mem.trim(u8, text, " \n\r\t").len == 0 and d.pictures.len == 0) {
        ui.text(c, "This message has no text.", .{ .color = th.muted, .italic = true });
        return;
    }
    const a = c.alloc();
    var block: Block = .{};
    var n_block: usize = 0;
    var n_picture: usize = 0;
    var at: usize = 0;
    while (at <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[at..nl], "\r");
        const line_at = at;
        at = nl + 1;
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), html.image_mark)) {
            flush(m, c, d, &block, &n_block);
            if (n_picture < d.pictures.len) picture(m, c, d, d.pictures[n_picture], n_picture);
            n_picture += 1;
            continue;
        }
        const is_quote = line.len > 0 and line[0] == '>';
        const blank = std.mem.trim(u8, line, " \t").len == 0;
        // A block ends at a blank line, or where quoting starts or stops.
        if ((blank and !block.quoted) or (block.text.items.len > 0 and is_quote != block.quoted and !blank)) {
            flush(m, c, d, &block, &n_block);
            if (blank and !block.quoted) continue;
        }
        if (block.text.items.len == 0) block.quoted = is_quote;
        var content = line;
        var from: usize = line_at;
        if (block.quoted and content.len > 0 and content[0] == '>') {
            content = content[1..];
            from += 1;
            if (content.len > 0 and content[0] == ' ') {
                content = content[1..];
                from += 1;
            }
        }
        block.segs.append(a, .{ .from = @intCast(from), .to = @intCast(block.text.items.len), .len = @intCast(content.len) }) catch return;
        block.text.appendSlice(a, content) catch return;
        block.text.append(a, '\n') catch return;
    }
    flush(m, c, d, &block, &n_block);
}

/// Draws the block gathered so far, then starts a new one.
fn flush(m: *Model, c: *ui.Context, d: *const k.Detail, block: *Block, n: *usize) void {
    defer block.* = .{};
    if (block.text.items.len == 0) return;
    const th = c.theme;
    const str = std.mem.trimEnd(u8, block.text.items, "\n");
    ui.key(c, c.print("b{d}", .{n.*}));
    n.* += 1;
    const style: ui.TextStyle = if (block.quoted)
        .{ .size = 13.5, .wrap = true, .leading = 1.3, .color = th.muted }
    else
        .{ .size = 14, .wrap = true, .leading = 1.35 };
    // The message's links, in this block's offsets.
    var spans: std.ArrayList(ui.Span) = .empty;
    var urls: std.ArrayList([]const u8) = .empty;
    for (d.links) |l| {
        for (block.segs.items) |s| {
            const lo = @max(l.start, s.from);
            const hi = @min(l.end, s.from + s.len);
            if (lo >= hi) continue;
            const start = s.to + (lo - s.from);
            const end = @min(s.to + (hi - s.from), @as(u32, @intCast(str.len)));
            if (end <= start) continue;
            spans.append(c.alloc(), .{ .start = start, .end = end, .color = th.accent, .underline = true }) catch return;
            urls.append(c.alloc(), l.url) catch return;
        }
    }
    var row = ui.div(c).row().wFull().gap(10);
    defer row.end();
    if (block.quoted) _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .fill, .radius = 1.5, .background = th.accent.alpha(0.35) }, .none, null);
    const box = ui.div(c).grow();
    defer box.end();
    if (spans.items.len == 0) return ui.text(c, str, style);
    ui.richText(c, str, spans.items, style);
    const it = box.interaction();
    const r = it.rect orelse return;
    if (!it.hovered) return;
    c.wants_moves = true;
    const url = linkAt(c, str, style, r, c.input.mouse, spans.items, urls.items) orelse return;
    c.cursor = .hand;
    hover_url = url;
    if (it.clicked) m.openLink(url);
}

/// The link at point `p` of text `str` drawn in `r` (wrapped as layout
/// wraps it), if any.
fn linkAt(c: *ui.Context, str: []const u8, style: ui.TextStyle, r: ui.Rect, p: ui.Point, spans: []const ui.Span, urls: []const []const u8) ?[]const u8 {
    const lines = c.text.wrap(str, style, r.w);
    if (lines.len == 0) return null;
    const lh = c.text.lineHeight(style);
    const li_f = @floor((p.y - r.y) / lh);
    if (li_f < 0 or li_f >= @as(f32, @floatFromInt(lines.len))) return null;
    const line = lines[@intFromFloat(li_f)];
    const x = p.x - r.x;
    if (x < 0 or x > line.width) return null;
    // Where the line's characters start; the last whose start is left of
    // x is the one under it (found by halves).
    var starts: std.ArrayList(usize) = .empty;
    for (line.start..line.end) |i| if ((str[i] & 0xc0) != 0x80) starts.append(c.alloc(), i) catch return null;
    if (starts.items.len == 0) return null;
    var lo: usize = 0;
    var hi: usize = starts.items.len - 1;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (c.text.width(str[line.start..starts.items[mid]], style) <= x) lo = mid else hi = mid - 1;
    }
    const at = starts.items[lo];
    for (spans, urls) |s, u| if (at >= s.start and at < s.end) return u;
    return null;
}

/// A picture of the message, where the mail puts it.
fn picture(m: *Model, c: *ui.Context, d: *const k.Detail, p: k.Picture, i: usize) void {
    const th = c.theme;
    ui.key(c, c.print("pic{d}", .{i}));
    if (p.key().len == 0 or (p.url != null and !m.remoteAllowed(d.message.id))) {
        if (p.alt.len > 0) ui.text(c, c.print("[{s}]", .{p.alt}), .{ .size = 13, .color = th.muted, .italic = true });
        return;
    }
    const max_w: f32 = @min(@as(f32, @floatFromInt(p.width orelse 640)), 700);
    if (m.picture(p, d.message.id)) |bytes| {
        if (ui.image(c, .{ .key = p.key(), .bytes = bytes, .max_width = max_w, .max_height = 1200, .scale = 1, .radius = 4 })) return;
    } else if (m.pictureLoading(p)) {
        const h: f32 = if (p.height) |v| @min(@as(f32, @floatFromInt(v)), 400) else 120;
        kit.skeleton(c, .{ .width = .{ .px = max_w }, .height = h, .radius = 6 });
        return;
    }
    if (p.alt.len > 0) ui.text(c, c.print("[{s}]", .{p.alt}), .{ .size = 13, .color = th.muted, .italic = true });
}

/// Previews of the pictures attached, above their chips.
pub fn attachedPictures(m: *Model, c: *ui.Context, d: *const k.Detail) void {
    var any = false;
    for (d.attachments) |att| any = any or isPicture(att.type);
    if (!any) return;
    const row = ui.div(c).row().wFull().gap(10);
    defer row.end();
    for (d.attachments, 0..) |att, i| {
        if (!isPicture(att.type)) continue;
        ui.key(c, c.print("thumb-{d}", .{i}));
        const p: k.Picture = .{ .account_id = att.account_id, .blob_id = att.blob_id, .type = att.type, .alt = att.name };
        const tile = ui.div(c).control();
        defer tile.end();
        if (tile.clicked()) m.download(att);
        if (m.picture(p, d.message.id)) |bytes| {
            if (ui.image(c, .{ .key = p.key(), .bytes = bytes, .max_width = 220, .max_height = 160, .scale = 2, .radius = 8 })) continue;
        }
        kit.skeleton(c, .{ .width = .{ .px = 160 }, .height = 110, .radius = 8 });
    }
}

pub fn isPicture(mime: []const u8) bool {
    const kinds = [_][]const u8{ "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp", "image/heic", "image/heif", "image/bmp", "image/tiff" };
    for (kinds) |t| if (std.ascii.eqlIgnoreCase(mime, t)) return true;
    return false;
}
