//! A server's documentation (markdown) as plain lines for a popup: the
//! marks that only a renderer reads are taken out, and prose is wrapped.
//!
//! The CSS and HTML servers send MDN's text with escaped punctuation
//! (`flex\-start`), an inline image (kilobytes of base64) and a link; shown
//! as they come that is one endless line.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `md` as plain text, prose wrapped at `width` columns (bytes: close
/// enough for documentation). Code blocks keep their lines. Caller frees.
pub fn plain(gpa: Allocator, md: []const u8, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);
    var fenced = false;
    var blank = true; // no blank lines at the top, nor two in a row
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            fenced = !fenced;
            continue;
        }
        if (fenced) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            blank = false;
            continue;
        }
        line_buf.clearRetainingCapacity();
        try inlineText(gpa, line, &line_buf);
        // An image taken from the start of a line leaves its space behind.
        const indented = line.len > 0 and line[0] == ' ';
        const text = std.mem.trimEnd(u8, if (indented) line_buf.items else std.mem.trimStart(u8, line_buf.items, " "), " ");
        if (std.mem.trim(u8, text, " ").len == 0) {
            if (!blank) try out.append(gpa, '\n');
            blank = true;
            continue;
        }
        blank = false;
        try wrap(gpa, text, width, &out);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    return out.toOwnedSlice(gpa);
}

/// One line without its markdown: images gone, a link as `text (url)`,
/// escapes and entities as their characters, emphasis marks dropped.
/// What is in `backticks` stays as written.
fn inlineText(gpa: Allocator, line: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    var code = false;
    while (i < line.len) {
        const b = line[i];
        if (b == '`') {
            code = !code;
            try out.append(gpa, b);
            i += 1;
            continue;
        }
        if (code) {
            try out.append(gpa, b);
            i += 1;
            continue;
        }
        if (b == '\\' and i + 1 < line.len and std.ascii.isPunctuation(line[i + 1])) {
            try out.append(gpa, line[i + 1]);
            i += 2;
            continue;
        }
        if (b == '!' and i + 1 < line.len and line[i + 1] == '[') if (link(line[i + 1 ..])) |l| {
            i += 1 + l.len;
            continue;
        };
        if (b == '[') if (link(line[i..])) |l| {
            try inlineText(gpa, l.text, out);
            if (l.url.len > 0 and !std.mem.eql(u8, l.url, l.text)) try out.print(gpa, " ({s})", .{l.url});
            i += l.len;
            continue;
        };
        if (b == '&') if (entity(line[i..])) |e| {
            try out.appendSlice(gpa, e.text);
            i += e.len;
            continue;
        };
        if (b == '*' or b == '_') {
            // `**bold**`, `_emphasis_`: a run at a word's edge. (`a * b`
            // and `snake_case` are neither.)
            var end = i;
            while (end < line.len and line[end] == b) end += 1;
            const before_space = i == 0 or line[i - 1] == ' ' or line[i - 1] == '(';
            const after_space = end == line.len or line[end] == ' ' or std.mem.indexOfScalar(u8, ".,;:)!?", line[end]) != null;
            if (before_space != after_space) {
                i = end;
                continue;
            }
        }
        try out.append(gpa, b);
        i += 1;
    }
}

const Link = struct { text: []const u8, url: []const u8, len: usize };

/// `[text](url)` at the start of `s`.
fn link(s: []const u8) ?Link {
    if (s.len == 0 or s[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    if (close + 1 >= s.len or s[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, s, close + 2, ')') orelse return null;
    return .{ .text = s[1..close], .url = s[close + 2 .. end], .len = end + 1 };
}

fn entity(s: []const u8) ?struct { text: []const u8, len: usize } {
    const all = [_][2][]const u8{
        .{ "&lt;", "<" },   .{ "&gt;", ">" },    .{ "&amp;", "&" },
        .{ "&quot;", "\"" }, .{ "&nbsp;", " " }, .{ "&#39;", "'" },
    };
    for (all) |e| if (std.mem.startsWith(u8, s, e[0])) return .{ .text = e[1], .len = e[0].len };
    return null;
}

/// `text` over as many lines as it needs, broken at spaces (a word longer
/// than a line, a URL say, is cut).
fn wrap(gpa: Allocator, text: []const u8, width: usize, out: *std.ArrayList(u8)) !void {
    const w = @max(width, 8);
    var rest = text;
    while (rest.len > w) {
        var cut = std.mem.lastIndexOfScalar(u8, rest[0 .. w + 1], ' ') orelse w;
        if (cut == 0) cut = w;
        // Not through the middle of a character.
        while (cut > 0 and cut < rest.len and rest[cut] & 0xC0 == 0x80) cut -= 1;
        try out.appendSlice(gpa, std.mem.trimEnd(u8, rest[0..cut], " "));
        try out.append(gpa, '\n');
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    try out.appendSlice(gpa, rest);
    try out.append(gpa, '\n');
}

test "plain: MDN's markdown reads as text" {
    const gpa = std.testing.allocator;
    const got = try plain(gpa,
        \\Aligns flex items along the main axis of the current line of the flex container\.
        \\
        \\![Baseline icon](data:image/svg+xml;base64,AAAA) _Widely available across major browsers (Baseline since 2015)_
        \\
        \\Syntax: normal | &lt;content\-distribution&gt;
        \\
        \\[MDN Reference](https://developer.mozilla.org/docs/Web/CSS/justify-content)
    , 40);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        \\Aligns flex items along the main axis of
        \\the current line of the flex container.
        \\
        \\Widely available across major browsers
        \\(Baseline since 2015)
        \\
        \\Syntax: normal | <content-distribution>
        \\
        \\MDN Reference
        \\(https://developer.mozilla.org/docs/Web/
        \\CSS/justify-content)
    , got);
}

test "plain: code keeps its lines and its marks" {
    const gpa = std.testing.allocator;
    const got = try plain(gpa, "```zig\nfn a_b(x: *T) void\n```\n\nCalls `__init__` with **care**, see snake_case.", 80);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("fn a_b(x: *T) void\n\nCalls `__init__` with care, see snake_case.", got);
}
