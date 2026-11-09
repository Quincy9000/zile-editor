//! Vim text objects as pure functions of (text, cursor) -> range.
//! `inner` ("i") excludes delimiters/surrounding space, `around` ("a") includes them.

const std = @import("std");
const Text = @import("Text.zig");
const motions = @import("motions.zig");

/// Byte range `[start, end)`. Linewise ranges cover whole lines: `start` is a
/// line start and `end` the end of the last line (before its newline).
pub const Range = struct {
    start: usize,
    end: usize,
    linewise: bool = false,
};

pub const Scope = enum { inner, around };

const Class = enum { space, word, punct };

fn classOf(b: u8, big: bool) Class {
    if (b == ' ' or b == '\t') return .space;
    if (big) return .word;
    if (b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b)) return .word;
    return .punct;
}

/// iw / aw / iW / aW, within the cursor's line.
pub fn word(t: *const Text, pos: usize, scope: Scope, big: bool, count: usize) ?Range {
    const line = t.lineOf(pos);
    const ls = t.lineStart(line);
    const le = t.lineEnd(line);
    if (ls == le) return null;
    const p = @min(pos, le - 1);

    const run = struct {
        fn end(tt: *const Text, from: usize, limit: usize, b: bool) usize {
            const c = classOf(tt.byteAt(from), b);
            var e = from;
            while (e < limit and classOf(tt.byteAt(e), b) == c) e += 1;
            return e;
        }
    }.end;

    var start = p;
    const c0 = classOf(t.byteAt(p), big);
    while (start > ls and classOf(t.byteAt(start - 1), big) == c0) start -= 1;
    var end = run(t, p, le, big);
    // Each further count adds the next run (word or whitespace).
    for (1..count) |_| {
        if (end >= le) break;
        end = run(t, end, le, big);
    }

    if (scope == .around) {
        if (c0 == .space) {
            // Whitespace plus the following word.
            if (end < le) end = run(t, end, le, big);
        } else if (end < le and classOf(t.byteAt(end), big) == .space) {
            end = run(t, end, le, big); // trailing whitespace
        } else {
            while (start > ls and classOf(t.byteAt(start - 1), big) == .space) start -= 1; // leading
        }
    }
    return .{ .start = start, .end = end };
}

/// i" / a" (and ' `): the quoted string around or after the cursor on its line.
pub fn quote(t: *const Text, pos: usize, q: u8, scope: Scope) ?Range {
    const line = t.lineOf(pos);
    const ls = t.lineStart(line);
    const le = t.lineEnd(line);
    // Pair unescaped quotes left to right: (0,1), (2,3), ...
    var open: ?usize = null;
    var i = ls;
    while (i < le) : (i += 1) {
        const b = t.byteAt(i);
        if (b == '\\') {
            i += 1;
            continue;
        }
        if (b != q) continue;
        if (open) |o| {
            if (pos <= i) {
                if (scope == .inner) return .{ .start = o + 1, .end = i };
                var end = i + 1;
                while (end < le and (t.byteAt(end) == ' ' or t.byteAt(end) == '\t')) end += 1;
                return .{ .start = o, .end = end };
            }
            open = null;
        } else open = i;
    }
    return null;
}

/// i( / a( and friends: the innermost bracket pair around the cursor
/// (`count` levels out). An inner block whose brackets sit on their own lines
/// is linewise, so `di{` keeps the brace lines.
pub fn bracket(t: *const Text, pos: usize, open: u8, close: u8, scope: Scope, count: usize) ?Range {
    if (t.len() == 0) return null;
    var o = pos;
    // On the opening bracket itself: that pair. Otherwise search outwards.
    var depth: usize = if (pos < t.len() and t.byteAt(pos) == open) count - 1 else count;
    if (pos < t.len() and t.byteAt(pos) == close) {
        // On the closing bracket: its pair counts as the first level.
        depth = count;
        o = pos;
        var d: usize = 0;
        while (o > 0) {
            o -= 1;
            const b = t.byteAt(o);
            if (b == close) d += 1 else if (b == open) {
                if (d == 0) break;
                d -= 1;
            }
        } else return null;
        depth -= 1;
    }
    var nest: usize = 0;
    while (depth > 0) {
        if (o == 0) return null;
        o -= 1;
        const b = t.byteAt(o);
        if (b == close) nest += 1 else if (b == open) {
            if (nest == 0) depth -= 1 else nest -= 1;
        }
    }
    // Matching close.
    var c = o + 1;
    nest = 0;
    while (c < t.len()) : (c += 1) {
        const b = t.byteAt(c);
        if (b == open) nest += 1 else if (b == close) {
            if (nest == 0) break;
            nest -= 1;
        }
    } else return null;

    if (scope == .around) return .{ .start = o, .end = c + 1 };
    const lo = t.lineOf(o);
    const lc = t.lineOf(c);
    if (lc >= lo + 2 and isBlank(t, o + 1, t.lineEnd(lo)) and motions.firstNonBlank(t, lc) == c) {
        return .{ .start = t.lineStart(lo + 1), .end = t.lineEnd(lc - 1), .linewise = true };
    }
    return .{ .start = o + 1, .end = c };
}

fn isBlank(t: *const Text, from: usize, to: usize) bool {
    for (from..to) |i| {
        const b = t.byteAt(i);
        if (b != ' ' and b != '\t') return false;
    }
    return true;
}

/// ip / ap: the run of blank or non-blank lines around the cursor (linewise).
/// `ap` adds the blank lines after it (or before it, at the end of the text).
pub fn paragraph(t: *const Text, pos: usize, scope: Scope) ?Range {
    const n = t.lineCount();
    const line = t.lineOf(pos);
    const blank = t.lineLen(line) == 0;
    var first = line;
    var last = line;
    while (first > 0 and (t.lineLen(first - 1) == 0) == blank) first -= 1;
    while (last + 1 < n and (t.lineLen(last + 1) == 0) == blank) last += 1;
    if (scope == .around and !blank) {
        if (last + 1 < n and t.lineLen(last + 1) == 0) {
            while (last + 1 < n and t.lineLen(last + 1) == 0) last += 1;
        } else {
            while (first > 0 and t.lineLen(first - 1) == 0) first -= 1;
        }
    }
    return .{ .start = t.lineStart(first), .end = t.lineEnd(last), .linewise = true };
}

/// il / al: `il` is the cursor's line without its indentation and trailing
/// whitespace; `al` is every line of the buffer (linewise).
pub fn lineObject(t: *const Text, pos: usize, scope: Scope) ?Range {
    if (scope == .around) return .{ .start = 0, .end = t.len(), .linewise = true };
    const l = t.lineOf(pos);
    var end = t.lineEnd(l);
    const start = motions.firstNonBlank(t, l);
    while (end > start and (t.byteAt(end - 1) == ' ' or t.byteAt(end - 1) == '\t')) end -= 1;
    return .{ .start = start, .end = end };
}

/// it / at: the XML/HTML element around the cursor (`count` levels out),
/// matched textually like vim does. `it` is the content between the tags,
/// `at` includes them.
pub fn tag(t: *const Text, pos: usize, scope: Scope, count: usize) ?Range {
    const src = t.slice(0, t.len());
    // Walk all tags, pairing them with a stack, and remember the pairs that
    // enclose the cursor, innermost last.
    const Open = struct { name: []const u8, start: usize, end: usize };
    var stack: [64]Open = undefined;
    var depth: usize = 0;
    var enclosing: [64]Range = undefined;
    var n_enclosing: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, src, i, '<')) |lt| {
        const tk = parseTag(src, lt) orelse {
            i = lt + 1;
            continue;
        };
        i = tk.end;
        if (!tk.closing) {
            if (tk.self_closing) continue;
            if (depth == stack.len) return null; // absurdly deep: give up
            stack[depth] = .{ .name = tk.name, .start = lt, .end = tk.end };
            depth += 1;
            continue;
        }
        // Close the nearest open tag with this name (lenient with unclosed ones).
        var k = depth;
        while (k > 0) : (k -= 1) {
            if (std.mem.eql(u8, stack[k - 1].name, tk.name)) break;
        } else continue;
        const open = stack[k - 1];
        depth = k - 1;
        if (open.start <= pos and pos < tk.end) {
            // Pairs close inner-first, so later pairs enclose earlier ones.
            if (n_enclosing < enclosing.len) {
                enclosing[n_enclosing] = if (scope == .inner)
                    .{ .start = open.end, .end = lt }
                else
                    .{ .start = open.start, .end = tk.end };
                n_enclosing += 1;
            }
        }
    }
    if (count == 0 or count > n_enclosing) return null;
    return enclosing[count - 1];
}

const Tag = struct { name: []const u8, end: usize, closing: bool, self_closing: bool };

/// The tag starting at `src[lt] == '<'`, or null if it isn't one.
fn parseTag(src: []const u8, lt: usize) ?Tag {
    var i = lt + 1;
    const closing = i < src.len and src[i] == '/';
    if (closing) i += 1;
    // A name must start with a letter (`a < b`, `<!--`, `<?xml` are not tags).
    if (i >= src.len or !std.ascii.isAlphabetic(src[i])) return null;
    const name_start = i;
    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or std.mem.indexOfScalar(u8, "-_:.", src[i]) != null)) i += 1;
    const name = src[name_start..i];
    // Up to '>', skipping quoted attribute values.
    var in_quote: u8 = 0;
    while (i < src.len) : (i += 1) {
        const b = src[i];
        if (in_quote != 0) {
            if (b == in_quote) in_quote = 0;
        } else if (b == '"' or b == '\'') {
            in_quote = b;
        } else if (b == '>') {
            return .{ .name = name, .end = i + 1, .closing = closing, .self_closing = src[i - 1] == '/' };
        } else if (b == '<') return null;
    }
    return null;
}

const testing = std.testing;

test "tag objects" {
    const src = "<div class=\"a>b\">\n  <p>hi <b>there</b></p><br/>\n</div>";
    var t = try Text.init(testing.allocator, src);
    defer t.deinit(testing.allocator);
    const at_there = std.mem.indexOf(u8, src, "there").?;
    try testing.expectEqualStrings("there", sliceOf(&t, tag(&t, at_there, .inner, 1)));
    try testing.expectEqualStrings("<b>there</b>", sliceOf(&t, tag(&t, at_there, .around, 1)));
    try testing.expectEqualStrings("hi <b>there</b>", sliceOf(&t, tag(&t, at_there, .inner, 2)));
    const div_inner = sliceOf(&t, tag(&t, at_there, .inner, 3));
    try testing.expectEqualStrings("\n  <p>hi <b>there</b></p><br/>\n", div_inner);
    // On a tag itself: that element.
    try testing.expectEqualStrings("hi <b>there</b>", sliceOf(&t, tag(&t, std.mem.indexOf(u8, src, "<p>").?, .inner, 1)));
    var plain = try Text.init(testing.allocator, "if (a < b) x = 1;");
    defer plain.deinit(testing.allocator);
    try testing.expect(tag(&plain, 5, .inner, 1) == null);
}

test "line objects" {
    var t = try Text.init(testing.allocator, "a\n    b c  \nd");
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("b c", sliceOf(&t, lineObject(&t, 8, .inner)));
    const all = lineObject(&t, 8, .around).?;
    try testing.expect(all.linewise);
    try testing.expectEqualStrings("a\n    b c  \nd", t.slice(all.start, all.end));
}

fn sliceOf(t: *const Text, r: ?Range) []const u8 {
    const rr = r orelse return "<null>";
    return t.slice(rr.start, rr.end);
}

test "word objects" {
    var t = try Text.init(testing.allocator, "foo bar.baz  qux");
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("bar", sliceOf(&t, word(&t, 5, .inner, false, 1)));
    try testing.expectEqualStrings("bar", sliceOf(&t, word(&t, 4, .inner, false, 1)));
    try testing.expectEqualStrings("foo ", sliceOf(&t, word(&t, 1, .around, false, 1)));
    try testing.expectEqualStrings("bar.baz", sliceOf(&t, word(&t, 5, .inner, true, 1)));
    try testing.expectEqualStrings("bar.baz  ", sliceOf(&t, word(&t, 5, .around, true, 1)));
    // Last word without trailing space takes the leading space.
    try testing.expectEqualStrings("  qux", sliceOf(&t, word(&t, 14, .around, false, 1)));
    try testing.expectEqualStrings("bar.", sliceOf(&t, word(&t, 4, .inner, false, 2)));
}

test "quote objects" {
    var t = try Text.init(testing.allocator, "x = \"a \\\"b\" + 'c'");
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("a \\\"b", sliceOf(&t, quote(&t, 6, '"', .inner)));
    try testing.expectEqualStrings("\"a \\\"b\" ", sliceOf(&t, quote(&t, 6, '"', .around)));
    // Cursor before any quote: the first pair after it.
    try testing.expectEqualStrings("a \\\"b", sliceOf(&t, quote(&t, 0, '"', .inner)));
    try testing.expectEqualStrings("c", sliceOf(&t, quote(&t, 0, '\'', .inner)));
}

test "bracket objects" {
    var t = try Text.init(testing.allocator, "f(a, (b), c)");
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("b", sliceOf(&t, bracket(&t, 6, '(', ')', .inner, 1)));
    try testing.expectEqualStrings("a, (b), c", sliceOf(&t, bracket(&t, 6, '(', ')', .inner, 2)));
    try testing.expectEqualStrings("(a, (b), c)", sliceOf(&t, bracket(&t, 2, '(', ')', .around, 1)));
    try testing.expectEqualStrings("a, (b), c", sliceOf(&t, bracket(&t, 1, '(', ')', .inner, 1))); // on '('
    try testing.expectEqualStrings("b", sliceOf(&t, bracket(&t, 7, '(', ')', .inner, 1))); // on ')'

    var blk = try Text.init(testing.allocator, "fn x() {\n    a;\n    b;\n}");
    defer blk.deinit(testing.allocator);
    const r = bracket(&blk, 14, '{', '}', .inner, 1).?;
    try testing.expect(r.linewise);
    try testing.expectEqualStrings("    a;\n    b;", blk.slice(r.start, r.end));
}

test "paragraph objects" {
    var t = try Text.init(testing.allocator, "a\nb\n\n\nc");
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("a\nb", sliceOf(&t, paragraph(&t, 0, .inner)));
    try testing.expectEqualStrings("a\nb\n\n", sliceOf(&t, paragraph(&t, 0, .around)));
    try testing.expectEqualStrings("\n\nc", sliceOf(&t, paragraph(&t, 6, .around)));
}
