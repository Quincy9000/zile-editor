//! Cursor motions as pure functions of (text, byte position) -> byte position.
//! No editor state here, so every motion works the same for every cursor.
//!
//! Positions are byte offsets that always sit on a UTF-8 codepoint boundary.
//! Word classification works byte-wise: every byte of a multi-byte UTF-8
//! sequence is >= 0x80 and classified as a word byte, so class boundaries
//! always fall on codepoint boundaries.

const std = @import("std");
const Text = @import("Text.zig");

pub fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Start of the codepoint containing `pos`.
pub fn charStart(t: *const Text, pos: usize) usize {
    var p = pos;
    while (p > 0 and p < t.len() and isContinuation(t.byteAt(p))) p -= 1;
    return p;
}

/// Position of the next codepoint (or `len()`).
pub fn nextChar(t: *const Text, pos: usize) usize {
    if (pos >= t.len()) return t.len();
    var p = pos + 1;
    while (p < t.len() and isContinuation(t.byteAt(p))) p += 1;
    return p;
}

/// Position of the previous codepoint (or 0).
pub fn prevChar(t: *const Text, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and isContinuation(t.byteAt(p))) p -= 1;
    return p;
}

/// In normal mode the cursor sits on a character, never past the end of a
/// non-empty line.
pub fn clampNormal(t: *const Text, pos: usize) usize {
    const line = t.lineOf(pos);
    const start = t.lineStart(line);
    const end = t.lineEnd(line);
    if (pos < end or end == start) return pos;
    return prevChar(t, end);
}

// ---------------------------------------------------------------------------
// Display columns

pub fn nextTabStop(col: usize, tab_width: usize) usize {
    return (col / tab_width + 1) * tab_width;
}

/// Display column of byte offset `off` within `line` (tabs expanded).
/// TODO: wide characters (use ghostty's unicode width tables, see DESIGN.md).
pub fn displayCol(line: []const u8, off: usize, tab_width: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < off and i < line.len) {
        if (line[i] == '\t') {
            col = nextTabStop(col, tab_width);
            i += 1;
        } else {
            col += 1;
            i += 1;
            while (i < line.len and isContinuation(line[i])) i += 1;
        }
    }
    return col;
}

/// Byte offset of the character that covers display column `col`, or
/// `line.len` if the line is shorter.
pub fn byteAtCol(line: []const u8, col: usize, tab_width: usize) usize {
    var c: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const next_c = if (line[i] == '\t') nextTabStop(c, tab_width) else c + 1;
        if (col < next_c) return i;
        c = next_c;
        i += 1;
        while (i < line.len and isContinuation(line[i])) i += 1;
    }
    return line.len;
}

// ---------------------------------------------------------------------------
// Line motions

pub fn firstNonBlank(t: *const Text, line: usize) usize {
    const start = t.lineStart(line);
    const end = t.lineEnd(line);
    var p = start;
    while (p < end and isBlank(t.byteAt(p))) p += 1;
    return p;
}

fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

// ---------------------------------------------------------------------------
// Word motions (vim's w/b/e and W/B/E)

const Class = enum { space, word, punct };

fn classify(b: u8, big: bool) Class {
    if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return .space;
    if (big) return .word;
    if (b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b)) return .word;
    return .punct;
}

/// An empty line (two consecutive newlines, or a newline at the text edges)
/// counts as a word, like in vim.
fn isEmptyLineAt(t: *const Text, p: usize) bool {
    const at_nl = p == t.len() or t.byteAt(p) == '\n';
    const after_nl = p == 0 or t.byteAt(p - 1) == '\n';
    return at_nl and after_nl;
}

/// `w` / `W`: start of the next word.
pub fn wordForward(t: *const Text, pos: usize, big: bool) usize {
    const n = t.len();
    if (pos >= n) return n;
    var p = pos;
    const c0 = classify(t.byteAt(p), big);
    if (c0 != .space) {
        while (p < n and classify(t.byteAt(p), big) == c0) p += 1;
    }
    while (p < n) {
        const b = t.byteAt(p);
        if (classify(b, big) != .space) break;
        if (b == '\n') {
            p += 1;
            if (p < n and t.byteAt(p) == '\n') break; // stop on an empty line
            continue;
        }
        p += 1;
    }
    return p;
}

/// `b` / `B`: start of the previous word.
pub fn wordBackward(t: *const Text, pos: usize, big: bool) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    // Skip whitespace backwards, stopping on an empty line.
    while (p > 0 and classify(t.byteAt(p), big) == .space) {
        if (isEmptyLineAt(t, p)) return p;
        p -= 1;
    }
    if (classify(t.byteAt(p), big) == .space) return p; // reached position 0
    const c = classify(t.byteAt(p), big);
    while (p > 0 and classify(t.byteAt(p - 1), big) == c) p -= 1;
    return p;
}

/// `e` / `E`: end of the current/next word (the start of its last codepoint).
pub fn wordEnd(t: *const Text, pos: usize, big: bool) usize {
    const n = t.len();
    if (n == 0) return 0;
    var p = nextChar(t, pos);
    while (p < n and classify(t.byteAt(p), big) == .space) p += 1;
    if (p >= n) return charStart(t, n - 1);
    const c = classify(t.byteAt(p), big);
    while (p + 1 < n and classify(t.byteAt(p + 1), big) == c) p += 1;
    return charStart(t, p);
}

/// End of the word under the cursor (for `cw`, which changes to the end of the
/// current word rather than to the start of the next one).
pub fn wordEndCurrent(t: *const Text, pos: usize, big: bool) usize {
    const n = t.len();
    if (pos >= n) return pos;
    const c = classify(t.byteAt(pos), big);
    var p = pos;
    while (p + 1 < n and classify(t.byteAt(p + 1), big) == c) p += 1;
    return charStart(t, p);
}

pub fn isSpaceAt(t: *const Text, pos: usize) bool {
    return pos >= t.len() or classify(t.byteAt(pos), false) == .space;
}

// ---------------------------------------------------------------------------
// Character search (f, F, t, T)

pub const Find = struct {
    /// The character as UTF-8.
    bytes: [4]u8,
    len: u3,
    forward: bool,
    /// t/T: stop one character before the match.
    till: bool,

    pub fn init(cp: u21, forward: bool, till: bool) ?Find {
        var f: Find = .{ .bytes = undefined, .len = 0, .forward = forward, .till = till };
        f.len = std.unicode.utf8Encode(cp, &f.bytes) catch return null;
        return f;
    }

    pub fn needle(f: *const Find) []const u8 {
        return f.bytes[0..f.len];
    }
};

/// The first `needle` at or after `from`. A letter matches in either case
/// (`f` and `t` ignore it), anything else exactly.
pub fn indexOfFold(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len != 1 or !std.ascii.isAlphabetic(needle[0])) return std.mem.indexOfPos(u8, hay, from, needle);
    const want = std.ascii.toLower(needle[0]);
    var i = from;
    while (i < hay.len) : (i += 1) if (std.ascii.toLower(hay[i]) == want) return i;
    return null;
}

/// The last `needle` in `hay`, case-insensitive for a letter.
pub fn lastIndexOfFold(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len != 1 or !std.ascii.isAlphabetic(needle[0])) return std.mem.lastIndexOf(u8, hay, needle);
    const want = std.ascii.toLower(needle[0]);
    var i = hay.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.toLower(hay[i]) == want) return i;
    }
    return null;
}

/// The `count`th occurrence of the character on the cursor's line, or null.
/// `repeat` (from `;`/`,`) makes t/T skip a match right next to the cursor,
/// so repeating a till moves on instead of staying put.
pub fn findInLine(t: *const Text, pos: usize, f: Find, count: usize, repeat: bool) ?usize {
    const line = t.lineOf(pos);
    const ls = t.lineStart(line);
    const bytes = t.lineSlice(line);
    const needle = f.needle();
    var at = pos - ls;
    for (0..count) |i| {
        const skip: usize = @intFromBool(f.till and repeat and i == 0);
        if (f.forward) {
            const from = at + 1 + skip;
            if (from > bytes.len) return null;
            at = indexOfFold(bytes, from, needle) orelse return null;
        } else {
            const end = at -| skip;
            if (end == 0) return null;
            at = lastIndexOfFold(bytes[0..end], needle) orelse return null;
        }
    }
    const target = ls + at;
    if (!f.till) return target;
    return if (f.forward) prevChar(t, target) else nextChar(t, target);
}

/// `findInLine` without the line: f/F/t/T reach the next occurrence anywhere
/// in the text (mini.jump).
pub fn findAcross(t: *const Text, pos: usize, f: Find, count: usize, repeat: bool) ?usize {
    const bytes = t.slice(0, t.len());
    const needle = f.needle();
    var at = pos;
    for (0..count) |i| {
        const skip: usize = @intFromBool(f.till and repeat and i == 0);
        if (f.forward) {
            const from = at + 1 + skip;
            if (from > bytes.len) return null;
            at = indexOfFold(bytes, from, needle) orelse return null;
        } else {
            const end = at -| skip;
            if (end == 0) return null;
            at = lastIndexOfFold(bytes[0..end], needle) orelse return null;
        }
    }
    if (!f.till) return at;
    return if (f.forward) prevChar(t, at) else nextChar(t, at);
}

// ---------------------------------------------------------------------------
// Brackets and paragraphs

/// `%`: from the first bracket at or after the cursor on its line, the
/// position of its partner.
pub fn matchBracket(t: *const Text, pos: usize) ?usize {
    const pairs = "()[]{}";
    const le = t.lineEnd(t.lineOf(pos));
    var p = pos;
    const idx = while (p < le) : (p += 1) {
        if (std.mem.indexOfScalar(u8, pairs, t.byteAt(p))) |i| break i;
    } else return null;
    const open = pairs[idx & ~@as(usize, 1)];
    const close = pairs[idx | 1];
    var depth: usize = 0;
    if (idx % 2 == 0) {
        var q = p + 1;
        while (q < t.len()) : (q += 1) {
            const b = t.byteAt(q);
            if (b == open) depth += 1 else if (b == close) {
                if (depth == 0) return q;
                depth -= 1;
            }
        }
    } else {
        var q = p;
        while (q > 0) {
            q -= 1;
            const b = t.byteAt(q);
            if (b == close) depth += 1 else if (b == open) {
                if (depth == 0) return q;
                depth -= 1;
            }
        }
    }
    return null;
}

/// `}`: the next empty line after the current paragraph (or the end).
pub fn paragraphForward(t: *const Text, pos: usize, count: usize) usize {
    const last = t.lineCount() - 1;
    var l = t.lineOf(pos);
    for (0..count) |_| {
        while (l < last and t.lineLen(l) == 0) l += 1;
        while (l < last and t.lineLen(l) != 0) l += 1;
    }
    return if (l == last and t.lineLen(l) != 0) t.len() else t.lineStart(l);
}

/// `{`: the previous empty line before the current paragraph (or the start).
pub fn paragraphBackward(t: *const Text, pos: usize, count: usize) usize {
    var l = t.lineOf(pos);
    for (0..count) |_| {
        while (l > 0 and t.lineLen(l) == 0) l -= 1;
        while (l > 0 and t.lineLen(l) != 0) l -= 1;
    }
    return t.lineStart(l);
}

const testing = std.testing;

test "find in line" {
    var t = try textFrom("a,b,c,d");
    defer t.deinit(testing.allocator);
    const f = Find.init(',', true, false).?;
    try testing.expectEqual(1, findInLine(&t, 0, f, 1, false));
    try testing.expectEqual(5, findInLine(&t, 0, f, 3, false));
    try testing.expectEqual(null, findInLine(&t, 0, f, 4, false));
    const till = Find.init(',', true, true).?;
    try testing.expectEqual(0, findInLine(&t, 0, till, 1, false)); // already before ','
    try testing.expectEqual(2, findInLine(&t, 0, till, 2, false));
    try testing.expectEqual(2, findInLine(&t, 0, till, 1, true)); // `;` moves on
    const back = Find.init(',', false, false).?;
    try testing.expectEqual(3, findInLine(&t, 6, back, 2, false));
    const till_back = Find.init(',', false, true).?;
    try testing.expectEqual(6, findInLine(&t, 6, till_back, 1, false));
    try testing.expectEqual(4, findInLine(&t, 6, till_back, 1, true));
}

test "match bracket and paragraphs" {
    var t = try textFrom("f(a[1]) {\n}\n\nx");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(6, matchBracket(&t, 0)); // from 'f', first bracket is '('
    try testing.expectEqual(1, matchBracket(&t, 6));
    try testing.expectEqual(5, matchBracket(&t, 3));
    try testing.expectEqual(10, matchBracket(&t, 8));
    try testing.expectEqual(12, paragraphForward(&t, 0, 1)); // the empty line
    try testing.expectEqual(t.len(), paragraphForward(&t, 0, 2));
    try testing.expectEqual(12, paragraphBackward(&t, 13, 1));
    try testing.expectEqual(0, paragraphBackward(&t, 13, 2));
}

fn textFrom(s: []const u8) !Text {
    return Text.init(testing.allocator, s);
}

test "char stepping over utf-8" {
    var t = try textFrom("aé€b");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(1, nextChar(&t, 0));
    try testing.expectEqual(3, nextChar(&t, 1)); // é is 2 bytes
    try testing.expectEqual(6, nextChar(&t, 3)); // € is 3 bytes
    try testing.expectEqual(3, prevChar(&t, 6));
    try testing.expectEqual(1, prevChar(&t, 3));
    try testing.expectEqual(3, charStart(&t, 5));
}

test "display columns with tabs" {
    const line = "\tab\tc";
    try testing.expectEqual(0, displayCol(line, 0, 4));
    try testing.expectEqual(4, displayCol(line, 1, 4));
    try testing.expectEqual(8, displayCol(line, 4, 4));
    try testing.expectEqual(0, byteAtCol(line, 2, 4)); // inside the tab
    try testing.expectEqual(2, byteAtCol(line, 5, 4));
    try testing.expectEqual(5, byteAtCol(line, 99, 4));
}

test "word forward" {
    var t = try textFrom("foo.bar  baz\n\nqux");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(3, wordForward(&t, 0, false)); // foo -> .
    try testing.expectEqual(4, wordForward(&t, 3, false)); // . -> bar
    try testing.expectEqual(9, wordForward(&t, 4, false)); // bar -> baz
    try testing.expectEqual(13, wordForward(&t, 9, false)); // baz -> empty line
    try testing.expectEqual(14, wordForward(&t, 13, false)); // empty line -> qux
    try testing.expectEqual(9, wordForward(&t, 0, true)); // W skips punctuation
}

test "word backward" {
    var t = try textFrom("foo.bar  baz\n\nqux");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(13, wordBackward(&t, 14, false)); // qux -> empty line
    try testing.expectEqual(9, wordBackward(&t, 13, false)); // empty line -> baz
    try testing.expectEqual(4, wordBackward(&t, 9, false));
    try testing.expectEqual(3, wordBackward(&t, 4, false));
    try testing.expectEqual(0, wordBackward(&t, 3, false));
    try testing.expectEqual(0, wordBackward(&t, 9, true));
    try testing.expectEqual(0, wordBackward(&t, 0, false));
}

test "word end" {
    var t = try textFrom("foo.bar  héé");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(2, wordEnd(&t, 0, false));
    try testing.expectEqual(3, wordEnd(&t, 2, false));
    try testing.expectEqual(6, wordEnd(&t, 3, false));
    // "héé": h at 9, é at 10 and 12 -> end is 12 (start of last codepoint)
    try testing.expectEqual(12, wordEnd(&t, 6, false));
}

test "clamp normal" {
    var t = try textFrom("abc\n\nx");
    defer t.deinit(testing.allocator);
    try testing.expectEqual(2, clampNormal(&t, 3)); // past end of "abc"
    try testing.expectEqual(4, clampNormal(&t, 4)); // empty line stays
    try testing.expectEqual(5, clampNormal(&t, 6)); // end of text
}
