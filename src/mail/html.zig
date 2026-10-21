//! HTML mail as plain text, for a reader that draws text: blocks become
//! lines, lists bullets, quotes `> `, links their text (and where they
//! go, kept aside), pictures a line of their own (U+FFFC, also kept
//! aside), entities their characters; styles, scripts and the head go.
//! Forgiving: it reads what mail clients send, not only valid HTML.
const std = @import("std");

/// Bytes [start, end) of the text go to `url`.
pub const Link = struct { start: u32, end: u32, url: []const u8 };

/// A picture, at the n-th U+FFFC of the text.
pub const Image = struct { src: []const u8, alt: []const u8 = "", width: ?u32 = null, height: ?u32 = null };

/// Where a picture stands in the text: a line of its own.
pub const image_mark = "\u{FFFC}";

pub const Converted = struct {
    text: []u8,
    links: []Link,
    images: []Image,
};

const Out = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Newlines owed before the next text (2 for a paragraph's gap).
    pending_breaks: u8 = 0,
    /// A space owed before the next word.
    pending_space: bool = false,
    quote_depth: u8 = 0,
    list_depth: u8 = 0,
    pre: bool = false,
    links: std.ArrayList(Link) = .empty,
    images: std.ArrayList(Image) = .empty,
    /// An <a> open: where it goes, and where its text began (once it has).
    link_url: ?[]const u8 = null,
    link_start: ?u32 = null,

    fn atLineStart(o: *Out) bool {
        return o.buf.items.len == 0 or o.buf.items[o.buf.items.len - 1] == '\n';
    }

    fn lineBreak(o: *Out, n: u8) void {
        if (o.buf.items.len == 0 or o.onlyMarker()) return;
        o.pending_breaks = @max(o.pending_breaks, n);
        o.pending_space = false;
    }

    /// The line so far is only a bullet (`<li><p>One` stays on one line).
    fn onlyMarker(o: *Out) bool {
        const start = if (std.mem.lastIndexOfScalar(u8, o.buf.items, '\n')) |i| i + 1 else 0;
        const line = std.mem.trim(u8, o.buf.items[start..], " >");
        return std.mem.eql(u8, line, "•");
    }

    fn flushBreaks(o: *Out) !void {
        if (o.pending_breaks == 0) return;
        // Trailing spaces go before the line ends.
        while (o.buf.items.len > 0 and o.buf.items[o.buf.items.len - 1] == ' ') o.buf.items.len -= 1;
        var have: u8 = 0;
        var i = o.buf.items.len;
        while (i > 0 and o.buf.items[i - 1] == '\n') : (i -= 1) have += 1;
        while (have < o.pending_breaks) : (have += 1) try o.buf.append(o.gpa, '\n');
        o.pending_breaks = 0;
    }

    /// An <img>: a line of its own, unless it's a tracking pixel or a spacer.
    fn image(o: *Out, inner: []const u8) !void {
        const a = o.gpa;
        const src = (try attr(a, inner, "src")) orelse return;
        if (src.len == 0) return;
        const w = if (try attr(a, inner, "width")) |v| std.fmt.parseInt(u32, std.mem.trimEnd(u8, v, "px"), 10) catch null else null;
        const h = if (try attr(a, inner, "height")) |v| std.fmt.parseInt(u32, std.mem.trimEnd(u8, v, "px"), 10) catch null else null;
        if ((w != null and w.? <= 3) or (h != null and h.? <= 3)) return;
        o.lineBreak(1);
        try o.literal(image_mark);
        o.lineBreak(1);
        try o.images.append(a, .{ .src = src, .alt = (try attr(a, inner, "alt")) orelse "", .width = w, .height = h });
    }

    fn quotePrefix(o: *Out) !void {
        var d: u8 = 0;
        while (d < o.quote_depth) : (d += 1) try o.buf.appendSlice(o.gpa, "> ");
    }

    /// Text from the document, its whitespace collapsed (unless in `pre`).
    fn text(o: *Out, s: []const u8) !void {
        for (s) |ch| {
            const ws = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
            if (o.pre) {
                if (ch == '\r') continue;
                if (ch == '\n') {
                    try o.buf.append(o.gpa, '\n');
                    continue;
                }
                try o.startText();
                try o.buf.append(o.gpa, ch);
                continue;
            }
            if (ws) {
                if (!o.atLineStart() and o.pending_breaks == 0) o.pending_space = true;
                continue;
            }
            try o.startText();
            try o.buf.append(o.gpa, ch);
        }
    }

    /// Characters decoded from an entity: whitespace is not collapsed away.
    fn literal(o: *Out, s: []const u8) !void {
        try o.startText();
        try o.buf.appendSlice(o.gpa, s);
    }

    fn startText(o: *Out) !void {
        try o.flushBreaks();
        if (o.atLineStart()) {
            try o.quotePrefix();
            o.pending_space = false;
        }
        if (o.pending_space) {
            try o.buf.append(o.gpa, ' ');
            o.pending_space = false;
        }
        if (o.link_url != null and o.link_start == null) o.link_start = @intCast(o.buf.items.len);
    }

    fn closeLink(o: *Out) !void {
        const url = o.link_url orelse return;
        if (o.link_start) |start| {
            const end: u32 = @intCast(o.buf.items.len);
            if (end > start) try o.links.append(o.gpa, .{ .start = start, .end = end, .url = url });
        }
        o.link_url = null;
        o.link_start = null;
    }
};

fn tagName(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-' or s[i] == ':')) i += 1;
    return s[0..i];
}

fn isBlock(name: []const u8) bool {
    const blocks = [_][]const u8{ "p", "div", "table", "tr", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer", "center", "form", "dl", "dt", "dd", "address", "figure", "main", "nav", "aside" };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The value of attribute `name` in a tag's inside (`a href="…"`), its
/// `&amp;`s made `&`; in `arena`.
pub fn attr(arena: std.mem.Allocator, inner: []const u8, name: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i < inner.len) {
        // The next attribute's name.
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == '\n' or inner[i] == '\r' or inner[i] == '/')) i += 1;
        const start = i;
        while (i < inner.len and inner[i] != '=' and inner[i] != ' ' and inner[i] != '\t' and inner[i] != '\n' and inner[i] != '\r' and inner[i] != '>') i += 1;
        const key = inner[start..i];
        while (i < inner.len and inner[i] == ' ') i += 1;
        if (i >= inner.len or inner[i] != '=') {
            if (i == start) i += 1;
            continue;
        }
        i += 1;
        while (i < inner.len and inner[i] == ' ') i += 1;
        var value: []const u8 = "";
        if (i < inner.len and (inner[i] == '"' or inner[i] == '\'')) {
            const q = inner[i];
            const end = std.mem.indexOfScalarPos(u8, inner, i + 1, q) orelse inner.len;
            value = inner[i + 1 .. end];
            i = @min(inner.len, end + 1);
        } else {
            const end = std.mem.indexOfAnyPos(u8, inner, i, " \t\n\r>") orelse inner.len;
            value = inner[i..end];
            i = end;
        }
        if (std.ascii.eqlIgnoreCase(key, name)) {
            const v = std.mem.trim(u8, value, " \t\n\r");
            return try std.mem.replaceOwned(u8, arena, v, "&amp;", "&");
        }
    }
    return null;
}

/// Converts `html` to text in `gpa`'s memory.
pub fn toText(gpa: std.mem.Allocator, html: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c = try convert(arena.allocator(), html);
    return gpa.dupe(u8, c.text);
}

/// Converts `html` to text, with its links and pictures, in `arena`.
pub fn convert(arena: std.mem.Allocator, html: []const u8) !Converted {
    const gpa = arena;
    var o: Out = .{ .gpa = gpa };
    var i: usize = 0;
    // What a skipped element (style, script, head's title) ends with.
    var skip_until: ?[]const u8 = null;
    while (i < html.len) {
        const ch = html[i];
        if (ch == '<') {
            // Comments, conditional comments, CDATA, doctype.
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
                i = @min(html.len, end + 3);
                continue;
            }
            // A tag starts with a letter, / ! or ?; else "<" is text ("a < b").
            const next_ch: u8 = if (i + 1 < html.len) html[i + 1] else ' ';
            if (!(std.ascii.isAlphabetic(next_ch) or next_ch == '/' or next_ch == '!' or next_ch == '?')) {
                if (skip_until == null) try o.literal("<");
                i += 1;
                continue;
            }
            const close = tagEnd(html, i + 1) orelse {
                i = html.len;
                break;
            };
            const inner = html[i + 1 .. close];
            i = close + 1;
            if (inner.len == 0 or inner[0] == '!' or inner[0] == '?') continue;
            const closing = inner[0] == '/';
            const name = tagName(if (closing) inner[1..] else inner);
            if (skip_until) |want| {
                if (closing and eq(name, want)) skip_until = null;
                // A head that isn't closed ends where the body starts.
                if (!closing and eq(want, "head") and eq(name, "body")) skip_until = null;
                continue;
            }
            if (!closing and (eq(name, "style") or eq(name, "script") or eq(name, "head") or eq(name, "title"))) {
                if (!(inner.len > 0 and inner[inner.len - 1] == '/')) skip_until = name;
                continue;
            }
            if (eq(name, "a")) {
                try o.closeLink();
                if (!closing) if (try attr(gpa, inner[name.len..], "href")) |href| {
                    if (followable(href)) o.link_url = href;
                };
            } else if (eq(name, "img") and !closing) {
                try o.image(inner[name.len..]);
            } else if (eq(name, "br")) {
                try o.flushBreaks();
                o.pending_breaks = 1;
                // Two <br>s in a row make an empty line.
                if (o.buf.items.len > 0 and o.buf.items[o.buf.items.len - 1] == '\n') {
                    try o.buf.append(gpa, '\n');
                    o.pending_breaks = 0;
                }
                o.pending_space = false;
            } else if (eq(name, "p") or eq(name, "h1") or eq(name, "h2") or eq(name, "h3") or eq(name, "h4") or eq(name, "h5") or eq(name, "h6") or eq(name, "table") or eq(name, "ul") or eq(name, "ol")) {
                if (eq(name, "ul") or eq(name, "ol")) {
                    if (closing) o.list_depth -|= 1 else o.list_depth += 1;
                }
                // Inside a list, paragraphs and lists are its items' lines.
                o.lineBreak(if (o.list_depth > 0) 1 else 2);
            } else if (eq(name, "blockquote")) {
                o.lineBreak(1);
                if (closing) o.quote_depth -|= 1 else o.quote_depth += 1;
                if (o.quote_depth == 0 and closing) o.lineBreak(2);
            } else if (eq(name, "li")) {
                o.lineBreak(1);
                if (!closing) {
                    try o.flushBreaks();
                    try o.literal("");
                    var d: u8 = 1;
                    while (d < o.list_depth) : (d += 1) try o.buf.appendSlice(gpa, "  ");
                    try o.buf.appendSlice(gpa, "• ");
                }
            } else if (eq(name, "hr")) {
                o.lineBreak(1);
                try o.literal("────────────");
                o.lineBreak(1);
            } else if (eq(name, "pre")) {
                o.lineBreak(1);
                o.pre = !closing;
            } else if (eq(name, "td") or eq(name, "th")) {
                if (!closing) o.pending_space = !o.atLineStart();
            } else if (isBlock(name)) {
                o.lineBreak(1);
            }
            continue;
        }
        if (skip_until != null) {
            i += 1;
            continue;
        }
        if (ch == '&') {
            if (entity(html[i..])) |e| {
                if (e.text.len > 0) {
                    if (std.mem.eql(u8, e.text, " ")) {
                        // A non-breaking space keeps its width.
                        try o.startText();
                        try o.buf.append(gpa, ' ');
                    } else try o.literal(e.text);
                }
                i += e.len;
                continue;
            }
        }
        const next = std.mem.indexOfAnyPos(u8, html, i, "<&") orelse html.len;
        try o.text(html[i..@max(next, i + 1)]);
        i = @max(next, i + 1);
    }
    try o.closeLink();
    // Lines without trailing spaces, and at most one empty line in a row;
    // where each kept line went, to move the links' offsets along.
    var out: std.ArrayList(u8) = .empty;
    var moved: std.ArrayList([3]u32) = .empty; // from, to, len
    var lines = std.mem.splitScalar(u8, o.buf.items, '\n');
    var blank: u32 = 0;
    var first = true;
    var at: u32 = 0;
    while (lines.next()) |raw| {
        defer at += @intCast(raw.len + 1);
        const line = trimSpaces(raw);
        if (line.len == 0) {
            blank += 1;
            continue;
        }
        if (!first) try out.appendSlice(gpa, if (blank > 0) "\n\n" else "\n");
        first = false;
        blank = 0;
        try moved.append(gpa, .{ at, @intCast(out.items.len), @intCast(line.len) });
        try out.appendSlice(gpa, line);
    }
    var links: std.ArrayList(Link) = .empty;
    for (o.links.items) |l| {
        const s = remap(moved.items, l.start, false);
        const e = remap(moved.items, l.end, true);
        if (e > s) try links.append(gpa, .{ .start = s, .end = e, .url = l.url });
    }
    return .{ .text = out.items, .links = links.items, .images = o.images.items };
}

/// Where byte `off` of the text before tidying is after it: inside a kept
/// line, moved with it; else at the next kept line's start (or, for a
/// link's end, the last one's end).
fn remap(moved: []const [3]u32, off: u32, end: bool) u32 {
    var last_end: u32 = 0;
    for (moved) |m| {
        if (off >= m[0] and off <= m[0] + m[2]) return m[1] + (off - m[0]);
        if (off < m[0]) return if (end) last_end else m[1];
        last_end = m[1] + m[2];
    }
    return last_end;
}

/// A link worth following from a mail: the web, or an address.
fn followable(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "mailto:");
}

/// Without trailing spaces, tabs and no-break spaces (U+00A0, as its two
/// bytes: never a byte of another character).
fn trimSpaces(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        if (s[end - 1] == ' ' or s[end - 1] == '\t') {
            end -= 1;
        } else if (end >= 2 and s[end - 2] == 0xc2 and s[end - 1] == 0xa0) {
            end -= 2;
        } else break;
    }
    return s[0..end];
}

/// Where the tag starting at `from` ends: its ">" outside quoted values.
fn tagEnd(html: []const u8, from: usize) ?usize {
    var quote: u8 = 0;
    var i = from;
    while (i < html.len) : (i += 1) {
        const ch = html[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            // Only a value's quote: after "=" (with spaces between).
            var j = i;
            while (j > from and html[j - 1] == ' ') j -= 1;
            if (j > from and html[j - 1] == '=') quote = ch;
        } else if (ch == '>') return i;
    }
    return null;
}

const Entity = struct { text: []const u8, len: usize };

const named = [_]struct { []const u8, []const u8 }{
    .{ "amp", "&" },        .{ "lt", "<" },         .{ "gt", ">" },         .{ "quot", "\"" },
    .{ "apos", "'" },       .{ "nbsp", " " },       .{ "rsquo", "’" },      .{ "lsquo", "‘" },
    .{ "rdquo", "”" },      .{ "ldquo", "“" },      .{ "mdash", "—" },      .{ "ndash", "–" },
    .{ "hellip", "…" },     .{ "copy", "©" },       .{ "reg", "®" },        .{ "trade", "™" },
    .{ "euro", "€" },       .{ "pound", "£" },      .{ "yen", "¥" },        .{ "cent", "¢" },
    .{ "bull", "•" },       .{ "middot", "·" },     .{ "laquo", "«" },      .{ "raquo", "»" },
    .{ "deg", "°" },        .{ "times", "×" },      .{ "divide", "÷" },     .{ "zwnj", "" },
    .{ "zwj", "" },         .{ "shy", "" },         .{ "thinsp", " " },     .{ "ensp", " " },
    .{ "emsp", " " },       .{ "auml", "ä" },       .{ "ouml", "ö" },       .{ "uuml", "ü" },
    .{ "Auml", "Ä" },       .{ "Ouml", "Ö" },       .{ "Uuml", "Ü" },       .{ "szlig", "ß" },
    .{ "eacute", "é" },     .{ "egrave", "è" },     .{ "agrave", "à" },     .{ "aacute", "á" },
    .{ "ccedil", "ç" },     .{ "ntilde", "ñ" },     .{ "oacute", "ó" },     .{ "iacute", "í" },
    .{ "uacute", "ú" },     .{ "rarr", "→" },       .{ "larr", "←" },       .{ "check", "✓" },
    .{ "Eacute", "É" },     .{ "Egrave", "È" },     .{ "Agrave", "À" },     .{ "Aacute", "Á" },
    .{ "aring", "å" },      .{ "Aring", "Å" },      .{ "aelig", "æ" },      .{ "AElig", "Æ" },
    .{ "oslash", "ø" },     .{ "Oslash", "Ø" },     .{ "ecirc", "ê" },      .{ "acirc", "â" },
    .{ "icirc", "î" },      .{ "ocirc", "ô" },      .{ "ucirc", "û" },      .{ "euml", "ë" },
    .{ "iuml", "ï" },       .{ "atilde", "ã" },     .{ "otilde", "õ" },     .{ "Ccedil", "Ç" },
    .{ "Ntilde", "Ñ" },     .{ "iexcl", "¡" },      .{ "iquest", "¿" },     .{ "sect", "§" },
    .{ "para", "¶" },       .{ "plusmn", "±" },     .{ "frac12", "½" },     .{ "frac14", "¼" },
    .{ "uarr", "↑" },       .{ "darr", "↓" },       .{ "lsaquo", "‹" },     .{ "rsaquo", "›" },
    .{ "sbquo", "‚" },      .{ "bdquo", "„" },      .{ "dagger", "†" },     .{ "permil", "‰" },
    .{ "prime", "′" },      .{ "minus", "−" },      .{ "infin", "∞" },      .{ "ne", "≠" },
    .{ "le", "≤" },         .{ "ge", "≥" },         .{ "hearts", "♥" },     .{ "star", "☆" },
};

/// Entities old pages write without the semicolon.
const bare = [_][]const u8{ "nbsp", "amp", "lt", "gt", "quot", "copy", "reg" };

fn entity(s: []const u8) ?Entity {
    const semi = std.mem.indexOfScalar(u8, s[0..@min(s.len, 12)], ';') orelse {
        for (bare) |b| if (std.mem.startsWith(u8, s[1..], b)) {
            for (named) |e| if (std.mem.eql(u8, e[0], b)) return .{ .text = e[1], .len = 1 + b.len };
        };
        return null;
    };
    const body = s[1..semi];
    if (body.len == 0) return null;
    if (body[0] == '#') {
        const cp = if (body.len > 1 and (body[1] == 'x' or body[1] == 'X'))
            std.fmt.parseInt(u21, body[2..], 16) catch return null
        else
            std.fmt.parseInt(u21, body[1..], 10) catch return null;
        // Invisible characters marketing mail pads previews with.
        if (cp == 0x200c or cp == 0x200b or cp == 0x200d or cp == 0xad or cp == 0x34f or cp == 0xfeff or cp == 0x2007) return .{ .text = "", .len = semi + 1 };
        if (cp == 0xa0) return .{ .text = " ", .len = semi + 1 };
        const S = struct {
            threadlocal var buf: [4]u8 = undefined;
        };
        const n = std.unicode.utf8Encode(cp, &S.buf) catch return null;
        return .{ .text = S.buf[0..n], .len = semi + 1 };
    }
    for (named) |e| if (std.mem.eql(u8, e[0], body)) return .{ .text = e[1], .len = semi + 1 };
    return null;
}

fn check(html: []const u8, want: []const u8) !void {
    const got = try toText(std.testing.allocator, html);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "paragraphs, breaks and whitespace" {
    try check("<p>Hello   <b>world</b></p><p>Second\n line</p>", "Hello world\n\nSecond line");
    try check("one<br>two<br><br>three", "one\ntwo\n\nthree");
    try check("<div>a</div><div>b</div>", "a\nb");
}

test "head, style and script go" {
    try check("<html><head><title>T</title><style>p{color:red}</style></head><body><script>x()</script><p>Body</p></body></html>", "Body");
    try check("<!-- hidden --><p>Shown</p><!--[if mso]>no<![endif]-->", "Shown");
}

test "entities" {
    try check("Tom &amp; Jerry &lt;3 caf&eacute; &#8364;5 &#x1F600; it&rsquo;s", "Tom & Jerry <3 café €5 😀 it’s");
    try check("a&nbsp;&nbsp;b", "a  b");
    try check("pre&zwnj;&#8203;view", "preview");
    try check("AT&T and & alone", "AT&T and & alone");
}

test "lists, quotes and rules" {
    try check("<ul><li>One</li><li>Two</li></ul>", "• One\n• Two");
    try check("<p>Hi</p><blockquote><p>Earlier</p><p>More</p></blockquote><p>Bye</p>", "Hi\n\n> Earlier\n\n> More\n\nBye");
    try check("a<hr>b", "a\n────────────\nb");
    try check("<pre>  x\n  y</pre>", "  x\n  y");
}

test "review: what broke" {
    // Characters whose last byte is A0 (as U+00A0's) stay whole.
    try check("<p>voilà</p><p>これは本だ</p>", "voilà\n\nこれは本だ");
    try check("<p>x&nbsp;</p>", "x");
    // A head without its end, a lone "<", ">" in a quoted value.
    try check("<head><title>T</title><body><p>Hello</p>", "Hello");
    try check("a < b and c > d", "a < b and c > d");
    try check("<span title=\"a > b\">shown</span>", "shown");
    try check("<ul><li><p>One</p></li><li>Two</li></ul>", "• One\n• Two");
    try check("&Eacute;t&eacute; &aring; &nbsp;x &amp so", "Été å  x & so");
}

test "links keep where they go, pictures their place" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try convert(arena.allocator(),
        \\<p>Read <a href="https://x.test/a?b=1&amp;c=2">the   notes</a> now.</p>
        \\<p><img src="cid:logo@x" alt="Logo" width="120"><img src="https://t.test/p.gif" width="1" height="1"></p>
        \\<p><a href='mailto:ada@x.test'>Write</a> or <a href="javascript:x()">not</a></p>
    );
    try std.testing.expectEqualStrings("Read the notes now.\n\n\u{FFFC}\n\nWrite or not", c.text);
    try std.testing.expectEqual(@as(usize, 2), c.links.len);
    try std.testing.expectEqualStrings("the notes", c.text[c.links[0].start..c.links[0].end]);
    try std.testing.expectEqualStrings("https://x.test/a?b=1&c=2", c.links[0].url);
    try std.testing.expectEqualStrings("Write", c.text[c.links[1].start..c.links[1].end]);
    try std.testing.expectEqual(@as(usize, 1), c.images.len);
    try std.testing.expectEqualStrings("cid:logo@x", c.images[0].src);
    try std.testing.expectEqualStrings("Logo", c.images[0].alt);
}

test "tables read across" {
    try check("<table><tr><td>Total</td><td>$5</td></tr><tr><td>Tax</td><td>$1</td></tr></table>", "Total $5\nTax $1");
}
