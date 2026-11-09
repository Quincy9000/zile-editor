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

/// How far ahead (in lines) objects look for a pair when the cursor isn't in
/// one, like mini.ai's `n_lines`.
pub const seek_lines = 50;

/// i" / a" (and ' `): the quoted string around or after the cursor on its
/// line, else the first one on the following lines.
pub fn quote(t: *const Text, pos: usize, q: u8, scope: Scope) ?Range {
    if (quoteOnLine(t, pos, q, scope)) |r| return r;
    const first = t.lineOf(pos) + 1;
    for (first..@min(t.lineCount(), first + seek_lines)) |line| {
        if (quoteOnLine(t, t.lineStart(line), q, scope)) |r| return r;
    }
    return null;
}

/// `iq` / `aq`: whichever kind of quote is nearest: the innermost around
/// the cursor, else the next one.
pub fn anyQuote(t: *const Text, pos: usize, scope: Scope) ?Range {
    var best: ?Range = null;
    var best_outer: Range = undefined;
    for ("\"'`") |q| {
        const outer = quote(t, pos, q, .around) orelse continue;
        const covers = outer.start <= pos;
        const better = if (best == null) true else blk: {
            const best_covers = best_outer.start <= pos;
            if (covers != best_covers) break :blk covers;
            // Both around the cursor: the inner one; both ahead: the nearer.
            break :blk if (covers) outer.start > best_outer.start else outer.start < best_outer.start;
        };
        if (better) {
            best = quote(t, pos, q, scope);
            best_outer = outer;
        }
    }
    return best;
}

fn quoteOnLine(t: *const Text, pos: usize, q: u8, scope: Scope) ?Range {
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
/// (`count` levels out). Not inside one: the next pair ahead (within
/// `seek_lines`), else the previous one, like mini.ai. An inner block whose
/// brackets sit on their own lines is linewise, so `di{` keeps the brace lines.
pub fn bracket(t: *const Text, pos: usize, open: u8, close: u8, scope: Scope, count: usize) ?Range {
    const pair = [_][2]u8{.{ open, close }};
    return bracketOf(t, pos, &pair, scope, count);
}

/// `ib` / `ab`: the same, for whichever of (), [] and {} is nearest.
pub fn anyBracket(t: *const Text, pos: usize, scope: Scope, count: usize) ?Range {
    return bracketOf(t, pos, &any_brackets, scope, count);
}

const any_brackets = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };

fn pairIndex(pairs: []const [2]u8, b: u8, side: u1) ?usize {
    for (pairs, 0..) |p, i| if (p[side] == b) return i;
    return null;
}

fn bracketOf(t: *const Text, pos: usize, pairs: []const [2]u8, scope: Scope, count: usize) ?Range {
    if (t.len() == 0) return null;
    if (enclosingOpen(t, pos, pairs, count)) |o| {
        if (pairFrom(t, o, pairs, scope)) |r| return r;
    }
    return seekPair(t, pos, pairs, scope);
}

/// The opening bracket `count` levels out from `pos`. The cursor on a
/// bracket counts as inside that pair.
fn enclosingOpen(t: *const Text, pos: usize, pairs: []const [2]u8, count: usize) ?usize {
    var remaining = count;
    var from = @min(pos, t.len());
    var found: ?usize = null;
    if (pos < t.len()) {
        const b = t.byteAt(pos);
        if (pairIndex(pairs, b, 0) != null) {
            found = pos;
            remaining -= 1;
        } else if (pairIndex(pairs, b, 1)) |pi| {
            found = matchBackward(t, pos, pairs[pi]) orelse return null;
            from = found.?;
            remaining -= 1;
        }
    }
    // Walk back; a closer means a pair to skip over, per kind.
    var skip: [any_brackets.len]usize = @splat(0);
    var i = from;
    while (remaining > 0) {
        if (i == 0) return null;
        i -= 1;
        const b = t.byteAt(i);
        if (pairIndex(pairs, b, 1)) |pi| {
            skip[pi] += 1;
        } else if (pairIndex(pairs, b, 0)) |pi| {
            if (skip[pi] > 0) skip[pi] -= 1 else {
                found = i;
                remaining -= 1;
            }
        }
    }
    return found;
}

fn matchBackward(t: *const Text, close_pos: usize, pair: [2]u8) ?usize {
    var o = close_pos;
    var d: usize = 0;
    while (o > 0) {
        o -= 1;
        const b = t.byteAt(o);
        if (b == pair[1]) d += 1 else if (b == pair[0]) {
            if (d == 0) return o;
            d -= 1;
        }
    }
    return null;
}

fn matchForward(t: *const Text, open_pos: usize, pair: [2]u8) ?usize {
    var c = open_pos + 1;
    var d: usize = 0;
    while (c < t.len()) : (c += 1) {
        const b = t.byteAt(c);
        if (b == pair[0]) d += 1 else if (b == pair[1]) {
            if (d == 0) return c;
            d -= 1;
        }
    }
    return null;
}

/// The range for the pair opening at `o`.
fn pairFrom(t: *const Text, o: usize, pairs: []const [2]u8, scope: Scope) ?Range {
    const pair = pairs[pairIndex(pairs, t.byteAt(o), 0).?];
    const c = matchForward(t, o, pair) orelse return null;
    if (scope == .around) return .{ .start = o, .end = c + 1 };
    const lo = t.lineOf(o);
    const lc = t.lineOf(c);
    if (lc >= lo + 2 and isBlank(t, o + 1, t.lineEnd(lo)) and motions.firstNonBlank(t, lc) == c) {
        return .{ .start = t.lineStart(lo + 1), .end = t.lineEnd(lc - 1), .linewise = true };
    }
    return .{ .start = o + 1, .end = c };
}

/// Not inside a pair: the first one opening after the cursor, else the
/// last one closing before it.
fn seekPair(t: *const Text, pos: usize, pairs: []const [2]u8, scope: Scope) ?Range {
    const line = t.lineOf(pos);
    const fwd_limit = t.lineEnd(@min(t.lineCount() - 1, line + seek_lines));
    var i = pos;
    while (i < fwd_limit) : (i += 1) {
        if (pairIndex(pairs, t.byteAt(i), 0) != null) {
            if (pairFrom(t, i, pairs, scope)) |r| return r;
        }
    }
    const back_limit = t.lineStart(line -| seek_lines);
    i = @min(pos, t.len());
    while (i > back_limit) {
        i -= 1;
        if (pairIndex(pairs, t.byteAt(i), 1)) |pi| {
            const o = matchBackward(t, i, pairs[pi]) orelse continue;
            return pairFrom(t, o, pairs, scope);
        }
    }
    return null;
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

test "objects seek the nearest pair, like mini.ai" {
    var t = try Text.init(testing.allocator, "x = 1; foo(a, b) + [c]\nbar(d)");
    defer t.deinit(testing.allocator);
    // Not inside: the next pair ahead.
    try testing.expectEqualStrings("a, b", sliceOf(&t, bracket(&t, 0, '(', ')', .inner, 1)));
    try testing.expectEqualStrings("c", sliceOf(&t, bracket(&t, 0, '[', ']', .inner, 1)));
    try testing.expectEqualStrings("a, b", sliceOf(&t, anyBracket(&t, 0, .inner, 1)));
    try testing.expectEqualStrings("c", sliceOf(&t, anyBracket(&t, 17, .inner, 1)));
    // On the next line.
    try testing.expectEqualStrings("d", sliceOf(&t, bracket(&t, 20, '(', ')', .inner, 1)));
    // Nothing ahead: the previous pair.
    try testing.expectEqualStrings("[c]", sliceOf(&t, bracket(&t, t.len() - 1, '[', ']', .around, 1)));

    // `b`: the innermost of any kind around the cursor, then outwards.
    var n = try Text.init(testing.allocator, "f({ x: [1, 2] })");
    defer n.deinit(testing.allocator);
    try testing.expectEqualStrings("1, 2", sliceOf(&n, anyBracket(&n, 8, .inner, 1)));
    try testing.expectEqualStrings(" x: [1, 2] ", sliceOf(&n, anyBracket(&n, 8, .inner, 2)));
    try testing.expectEqualStrings("{ x: [1, 2] }", sliceOf(&n, anyBracket(&n, 8, .inner, 3)));
    try testing.expectEqualStrings("[1, 2]", sliceOf(&n, anyBracket(&n, 12, .around, 1))); // on ']'

    // Quotes: on a later line, and `q` for the nearest kind.
    var q = try Text.init(testing.allocator, "x\nsay('hi', \"yo\")");
    defer q.deinit(testing.allocator);
    try testing.expectEqualStrings("yo", sliceOf(&q, quote(&q, 0, '"', .inner)));
    try testing.expectEqualStrings("hi", sliceOf(&q, anyQuote(&q, 0, .inner)));
    try testing.expectEqualStrings("yo", sliceOf(&q, anyQuote(&q, 13, .inner)));
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
