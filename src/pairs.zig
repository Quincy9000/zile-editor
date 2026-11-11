//! Brackets and quotes as pairs: autopairs while typing, and surround
//! (nvim-surround's `ys{motion}{char}`, `ds{char}`, `cs{old}{new}`, visual `S`).
//!
//! Characters name pairs the way nvim-surround does: `)` `]` `}` `>` are the
//! plain pair, `(` `[` `{` `<` the pair with inner spaces (added, or trimmed
//! when deleting), quotes are themselves, and `b` `B` `r` `a` `q` `t` are
//! aliases: nearest bracket, braces, brackets, angles, nearest quote, tag.

const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("core/Text.zig");
const textobjects = @import("core/textobjects.zig");
const motions = @import("core/motions.zig");
const Range = textobjects.Range;

// ---------------------------------------------------------------------------
// Autopairs

const openers = "([{";
const closers = ")]}";
const quotes = "\"'`";

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Typing `cp` in insert mode with autopairs on. Returns false when it
/// should be inserted as usual.
///   - an opener inserts its pair (unless a word follows, or its own closer does with no
///     opener before: `(|)` and `(` makes `((|))`, but `|)` stays `(|)`):
///     `(` -> `(|)`
///   - a closer or quote right before the same character steps over it
///   - a quote pairs when not touching a word: `"` -> `"|"`, but `don't`
pub fn typed(ed: *Editor, cp: u21) !bool {
    if (!ed.options.auto_pairs or cp >= 0x80) return false;
    const c: u8 = @intCast(cp);
    const t = ed.text();
    const pos = ed.view.cursor;
    const ls = t.lineStart(t.lineOf(pos));
    const next: ?u8 = if (pos < t.len() and t.byteAt(pos) != '\n') t.byteAt(pos) else null;
    const prev: ?u8 = if (pos > ls) t.byteAt(pos - 1) else null;

    const is_quote = std.mem.indexOfScalar(u8, quotes, c) != null;
    if ((is_quote or std.mem.indexOfScalar(u8, closers, c) != null) and next == c) {
        ed.setCursor(pos + 1);
        return true;
    }
    if (std.mem.indexOfScalar(u8, openers, c)) |i| {
        if (next) |n| if (isWord(n) or (n == closers[i] and prev != c) or std.mem.indexOfScalar(u8, quotes, n) != null) return false;
        try ed.insertText(&.{ c, closers[i] });
        ed.setCursor(pos + 1);
        return true;
    }
    if (is_quote) {
        if (prev) |p| if (isWord(p) or p == '\\' or (c == '\'' and (p == '&' or p == '<'))) return false;
        if (next) |n| if (isWord(n)) return false;
        try ed.insertText(&.{ c, c });
        ed.setCursor(pos + 1);
        return true;
    }
    return false;
}

/// <Tab> right before a closing bracket or quote steps over it:
/// `f("text|")` -> `f("text"|)` -> `f("text")|`, so the end of a call is a
/// few Tabs away instead of a reach for the arrow keys. Only with autopairs
/// on, only after something on the line (at the start of a line Tab
/// indents), and a quote only when it ends a string, not when it starts one.
/// Returns false when Tab should do what it usually does.
pub fn tabOut(ed: *Editor) !bool {
    if (!ed.options.auto_pairs) return false;
    const t = ed.text();
    const pos = ed.view.cursor;
    if (pos >= t.len()) return false;
    const c = t.byteAt(pos);
    const is_quote = std.mem.indexOfScalar(u8, quotes, c) != null;
    if (!is_quote and std.mem.indexOfScalar(u8, closers, c) == null) return false;
    const ls = t.lineStart(t.lineOf(pos));
    const before = t.slice(ls, pos);
    if (std.mem.indexOfNone(u8, before, " \t") == null) return false;
    if (is_quote) {
        // Inside a string (an odd number of this quote so far, not counting
        // escaped ones) means this one closes it.
        var open = false;
        var i: usize = 0;
        while (i < before.len) : (i += 1) {
            if (before[i] == '\\') {
                i += 1;
            } else if (before[i] == c) open = !open;
        }
        if (!open) return false;
    }
    ed.setCursor(pos + 1);
    return true;
}

/// <CR> between an empty pair opens it up:
///   {|}  ->  {
///              |
///            }
/// Returns false when the cursor isn't between a pair.
pub fn splitPair(ed: *Editor) !bool {
    if (!ed.options.auto_pairs) return false;
    const t = ed.text();
    const pos = ed.view.cursor;
    if (pos == 0 or pos >= t.len()) return false;
    const i = std.mem.indexOfScalar(u8, openers, t.byteAt(pos - 1)) orelse return false;
    if (t.byteAt(pos) != closers[i]) return false;

    const line = t.lineOf(pos);
    const ls = t.lineStart(line);
    var ie = ls;
    while (ie < t.lineEnd(line) and (t.byteAt(ie) == ' ' or t.byteAt(ie) == '\t')) ie += 1;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const indent = t.slice(ls, ie);
    w.writeAll("\n") catch return false;
    w.writeAll(indent) catch return false;
    var unit_buf: [16]u8 = undefined;
    w.writeAll(ed.indentUnit(&unit_buf)) catch return false;
    const inner_end = w.end;
    w.writeAll("\n") catch return false;
    w.writeAll(indent) catch return false;
    try ed.insertAt(pos, w.buffered());
    ed.setCursor(pos + inner_end);
    return true;
}

// ---------------------------------------------------------------------------
// Surround

/// The text added around a range for `char`, or null if it names no pair.
pub fn pairFor(char: u21) ?struct { []const u8, []const u8 } {
    return switch (char) {
        '(' => .{ "( ", " )" },
        ')', 'b' => .{ "(", ")" },
        '[' => .{ "[ ", " ]" },
        ']', 'r' => .{ "[", "]" },
        '{' => .{ "{ ", " }" },
        '}', 'B' => .{ "{", "}" },
        '<' => .{ "< ", " >" },
        '>', 'a' => .{ "<", ">" },
        // Any other punctuation surrounds with itself: "x", *x*, |x|, $x$.
        '!'...'\'', '*'...'/', ':', ';', '=', '?', '@', '\\', '^', '_', '`', '|', '~' => .{ &same[char - '!'], &same[char - '!'] },
        else => null,
    };
}

/// One-byte strings for every printable punctuation character.
const same = blk: {
    var out: [('~' - '!') + 1][1]u8 = undefined;
    for (&out, 0..) |*s, i| s.* = .{'!' + i};
    break :blk out;
};

/// An existing pair: the opening and closing delimiters' spans.
pub const Found = struct {
    open: Range,
    close: Range,
};

/// The pair `char` names, around the cursor or nearest to it (the same
/// search as the `i`/`a` text objects).
pub fn find(t: *const Text, pos: usize, char: u21, count: usize) ?Found {
    const bracket: ?[2]u8 = switch (char) {
        '(', ')' => .{ '(', ')' },
        '[', ']', 'r' => .{ '[', ']' },
        '{', '}', 'B' => .{ '{', '}' },
        '<', '>', 'a' => .{ '<', '>' },
        else => null,
    };
    var found: Found = undefined;
    if (bracket) |b| {
        const r = textobjects.bracket(t, pos, b[0], b[1], .around, count) orelse return null;
        found = .{ .open = .{ .start = r.start, .end = r.start + 1 }, .close = .{ .start = r.end - 1, .end = r.end } };
    } else switch (char) {
        'b' => {
            const r = textobjects.anyBracket(t, pos, .around, count) orelse return null;
            found = .{ .open = .{ .start = r.start, .end = r.start + 1 }, .close = .{ .start = r.end - 1, .end = r.end } };
        },
        '"', '\'', '`', 'q' => {
            const r = (if (char == 'q') textobjects.anyQuote(t, pos, .inner) else textobjects.quote(t, pos, @intCast(char), .inner)) orelse return null;
            found = .{ .open = .{ .start = r.start - 1, .end = r.start }, .close = .{ .start = r.end, .end = r.end + 1 } };
        },
        't' => {
            const outer = textobjects.tag(t, pos, .around, count) orelse return null;
            const inner = textobjects.tag(t, pos, .inner, count) orelse return null;
            found = .{ .open = .{ .start = outer.start, .end = inner.start }, .close = .{ .start = inner.end, .end = outer.end } };
        },
        else => return null,
    }
    // The spaced forms also take the whitespace just inside the pair.
    if (char == '(' or char == '[' or char == '{' or char == '<') {
        while (found.open.end < found.close.start and isSpace(t.byteAt(found.open.end))) found.open.end += 1;
        while (found.close.start > found.open.end and isSpace(t.byteAt(found.close.start - 1))) found.close.start -= 1;
    }
    return found;
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// `ys{motion}{char}`, `yss{char}`, `S{char}`: puts the pair around `r`.
/// Linewise ranges wrap the lines' text (without indentation) unless
/// `own_lines`, which puts the delimiters on lines of their own.
pub fn add(ed: *Editor, r: Range, char: u21, own_lines: bool) !void {
    const pair = pairFor(char) orelse return ed.setMessage(.err, "no pair for '{u}'", .{char});
    const t = ed.text();
    if (r.linewise) {
        const first = t.lineOf(r.start);
        const last = t.lineOf(if (r.end > r.start) r.end - 1 else r.start);
        if (own_lines) {
            const ls = t.lineStart(first);
            const indent = t.slice(ls, motions.firstNonBlank(t, first));
            var buf: [512]u8 = undefined;
            const close = std.fmt.bufPrint(&buf, "\n{s}{s}", .{ indent, std.mem.trim(u8, pair[1], " ") }) catch return;
            try ed.insertAt(t.lineEnd(last), close);
            const open = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ indent, std.mem.trim(u8, pair[0], " ") }) catch return;
            try ed.insertAt(ls, open);
            ed.setCursor(ls + indent.len);
            return;
        }
        const start = motions.firstNonBlank(t, first);
        var end = t.lineEnd(last);
        while (end > start and isSpace(t.byteAt(end - 1))) end -= 1;
        return wrap(ed, start, end, pair);
    }
    try wrap(ed, r.start, r.end, pair);
}

fn wrap(ed: *Editor, start: usize, end: usize, pair: struct { []const u8, []const u8 }) !void {
    try ed.insertAt(end, pair[1]);
    try ed.insertAt(start, pair[0]);
    ed.setCursor(start);
}

/// `ds{char}`: removes the pair, keeping what's inside.
pub fn delete(ed: *Editor, char: u21, count: usize) !void {
    const f = find(ed.text(), ed.view.cursor, char, count) orelse return notFound(ed, char);
    try ed.deleteRangeKeepCursor(f.close.start, f.close.end);
    try ed.deleteRangeKeepCursor(f.open.start, f.open.end);
    ed.setCursor(f.open.start);
}

/// `cs{old}{new}`: swaps the pair for another.
pub fn change(ed: *Editor, old: u21, new: u21, count: usize) !void {
    const pair = pairFor(new) orelse return ed.setMessage(.err, "no pair for '{u}'", .{new});
    const f = find(ed.text(), ed.view.cursor, old, count) orelse return notFound(ed, old);
    try ed.deleteRangeKeepCursor(f.close.start, f.close.end);
    try ed.insertAt(f.close.start, pair[1]);
    try ed.deleteRangeKeepCursor(f.open.start, f.open.end);
    try ed.insertAt(f.open.start, pair[0]);
    ed.setCursor(f.open.start);
}

fn notFound(ed: *Editor, char: u21) void {
    ed.setMessage(.err, "no '{u}' pair here", .{char});
}
