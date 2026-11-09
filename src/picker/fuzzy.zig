//! fzf-style fuzzy matching.
//!
//! A query matches if its bytes appear in order in the text. Among all ways to
//! match, dynamic programming picks the best-scoring one: matches at word
//! boundaries (after `/`, `_`, spaces, camelCase humps) and consecutive runs
//! score higher; gaps cost a little. Scoring constants follow fzf.
//!
//! Smart case: an uppercase letter in the query makes the match case-sensitive.
//! Matching is byte-wise; non-ASCII bytes compare exactly.

const std = @import("std");

pub const score_match = 16;
pub const gap_start = -3;
pub const gap_extension = -1;
pub const bonus_boundary_white = 10;
pub const bonus_boundary_delimiter = 9;
pub const bonus_boundary = 8;
pub const bonus_camel = 7;
pub const bonus_consecutive = -(gap_start + gap_extension);
pub const first_char_multiplier = 2;

/// Queries and texts beyond these sizes fall back to a greedy match.
pub const max_query = 64;
pub const max_text = 512;

const unreachable_score: i32 = std.math.minInt(i32) / 2;

pub const Query = struct {
    bytes: []const u8,
    case_sensitive: bool,

    pub fn init(bytes: []const u8) Query {
        var sensitive = false;
        for (bytes) |b| sensitive = sensitive or std.ascii.isUpper(b);
        return .{ .bytes = bytes, .case_sensitive = sensitive };
    }

    fn eq(q: Query, qc: u8, tc: u8) bool {
        if (q.case_sensitive) return qc == tc;
        return std.ascii.toLower(qc) == std.ascii.toLower(tc);
    }
};

const Class = enum { white, delimiter, non_word, lower, upper, digit };

fn classify(b: u8) Class {
    return switch (b) {
        ' ', '\t', '\n' => .white,
        '/', '\\', ':', ';', ',', '|' => .delimiter,
        'a'...'z', 0x80...0xFF => .lower,
        'A'...'Z' => .upper,
        '0'...'9' => .digit,
        else => .non_word,
    };
}

fn bonusAt(text: []const u8, j: usize) i32 {
    const prev: Class = if (j == 0) .white else classify(text[j - 1]);
    return switch (classify(text[j])) {
        .white => bonus_boundary_white,
        .delimiter, .non_word => bonus_boundary,
        .lower, .upper, .digit => |cur| switch (prev) {
            .white => bonus_boundary_white,
            .delimiter => bonus_boundary_delimiter,
            .non_word => bonus_boundary,
            .lower => if (cur == .upper or cur == .digit) bonus_camel else 0,
            .upper => if (cur == .digit) bonus_camel else 0,
            .digit => if (cur != .digit) bonus_camel else 0,
        },
    };
}

/// The smallest window [start, end] that can hold a match: from the first
/// occurrence of the first query byte to the last occurrence of the last one.
/// Null when the query is not a subsequence of the text.
fn window(q: Query, text: []const u8) ?struct { start: usize, end: usize } {
    const m = q.bytes.len;
    if (m == 0 or m > text.len) return null;
    var i: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, j| {
        if (i < m and q.eq(q.bytes[i], c)) {
            if (i == 0) start = j;
            i += 1;
        }
    }
    if (i < m) return null;
    var end = text.len - 1;
    while (!q.eq(q.bytes[m - 1], text[end])) end -= 1;
    return .{ .start = start, .end = end };
}

/// Per-thread scratch for `score` (rolling DP rows).
pub const Scratch = struct {
    rows: [4 * max_text]i32 = undefined,
};

/// The best match score, or null if the query does not match. An empty query
/// matches everything with score 0.
pub fn score(q: Query, text: []const u8, scratch: *Scratch) ?i32 {
    if (q.bytes.len == 0) return 0;
    const win = window(q, text) orelse return null;
    const w = win.end + 1 - win.start;
    if (w > max_text or q.bytes.len > max_query) return greedy(q, text, win.start, null);

    var d_prev = scratch.rows[0..w];
    var g_prev = scratch.rows[w .. 2 * w];
    var d_cur = scratch.rows[2 * w .. 3 * w];
    var g_cur = scratch.rows[3 * w .. 4 * w];
    fillRow(q, text, win.start, 0, d_cur, g_cur, d_prev, g_prev);
    for (1..q.bytes.len) |i| {
        std.mem.swap([]i32, &d_prev, &d_cur);
        std.mem.swap([]i32, &g_prev, &g_cur);
        fillRow(q, text, win.start, i, d_cur, g_cur, d_prev, g_prev);
    }
    const best = std.mem.max(i32, d_cur);
    return if (best <= unreachable_score / 2) null else best;
}

/// One DP row for query byte `i`:
///   d[k]: best score with q[i] matched exactly at text[start + k]
///   g[k]: best score with q[i] matched before k and text[start + k] skipped
fn fillRow(q: Query, text: []const u8, start: usize, i: usize, d: []i32, g: []i32, d_prev: []const i32, g_prev: []const i32) void {
    for (d, g, 0..) |*dk, *gk, k| {
        const j = start + k;
        dk.* = unreachable_score;
        if (q.eq(q.bytes[i], text[j])) {
            if (i == 0) {
                dk.* = score_match + bonusAt(text, j) * first_char_multiplier;
            } else if (k > 0) {
                const best = @max(d_prev[k - 1] + bonus_consecutive, g_prev[k - 1]);
                if (best > unreachable_score / 2) dk.* = best + score_match + bonusAt(text, j);
            }
        }
        gk.* = if (k == 0) unreachable_score else @max(d[k - 1] + gap_start, g[k - 1] + gap_extension);
    }
}

/// Scratch for `positions`: full DP matrices for traceback.
pub const PositionScratch = struct {
    d: [max_query * max_text]i32 = undefined,
    g: [max_query * max_text]i32 = undefined,
};

/// Byte offsets in `text` of the best match, written to `out` (len >= query
/// length). Null when the query does not match.
pub fn positions(q: Query, text: []const u8, scratch: *PositionScratch, out: []usize) ?[]usize {
    const m = q.bytes.len;
    if (m == 0) return out[0..0];
    const win = window(q, text) orelse return null;
    const w = win.end + 1 - win.start;
    if (w > max_text or m > max_query) {
        _ = greedy(q, text, win.start, out);
        return out[0..m];
    }

    for (0..m) |i| {
        const row = i * w;
        const prev = if (i == 0) row else row - w;
        fillRow(q, text, win.start, i, scratch.d[row .. row + w], scratch.g[row .. row + w], scratch.d[prev .. prev + w], scratch.g[prev .. prev + w]);
    }

    // Trace back from the best final cell, making the same choices fillRow made.
    const last = (m - 1) * w;
    var k = std.mem.indexOfMax(i32, scratch.d[last .. last + w]);
    var i = m - 1;
    out[i] = win.start + k;
    while (i > 0) {
        const prev = (i - 1) * w;
        if (scratch.d[prev + k - 1] + bonus_consecutive >= scratch.g[prev + k - 1]) {
            k -= 1;
        } else {
            // Walk the gap back to where it opened.
            var kk = k - 1;
            while (scratch.d[prev + kk - 1] + gap_start < scratch.g[prev + kk - 1] + gap_extension) kk -= 1;
            k = kk - 1;
        }
        i -= 1;
        out[i] = win.start + k;
    }
    return out[0..m];
}

/// Leftmost greedy match from `start`, scored with the same rules. Used for
/// inputs too large for the DP. Optionally records positions.
fn greedy(q: Query, text: []const u8, start: usize, out: ?[]usize) i32 {
    var total: i32 = 0;
    var i: usize = 0;
    var last: ?usize = null;
    for (text[start..], start..) |c, j| {
        if (i == q.bytes.len) break;
        if (!q.eq(q.bytes[i], c)) continue;
        const bonus = bonusAt(text, j);
        if (last) |l| {
            const gap: i32 = @intCast(j - l - 1);
            total += score_match + bonus + if (gap == 0) bonus_consecutive else gap_start + (gap - 1) * gap_extension;
        } else {
            total += score_match + bonus * first_char_multiplier;
        }
        if (out) |o| o[i] = j;
        last = j;
        i += 1;
    }
    return total;
}

const testing = std.testing;

fn testScore(query: []const u8, text: []const u8) ?i32 {
    var scratch: Scratch = .{};
    return score(Query.init(query), text, &scratch);
}

test "subsequence and smart case" {
    try testing.expect(testScore("fb", "foo_bar") != null);
    try testing.expect(testScore("bf", "foo_bar") == null);
    try testing.expect(testScore("foo", "FOO") != null); // lowercase query: insensitive
    try testing.expect(testScore("Foo", "foo") == null); // uppercase: sensitive
    try testing.expectEqual(0, testScore("", "anything").?);
}

test "boundaries and consecutive runs rank higher" {
    // Word boundary after '_' beats a mid-word match.
    try testing.expect(testScore("fb", "foo_bar").? > testScore("fb", "afbx").?);
    // Basename after '/' beats a match inside a directory name.
    try testing.expect(testScore("main", "src/main.zig").? > testScore("main", "src/domain/x.zig").?);
    // camelCase humps count as boundaries.
    try testing.expect(testScore("fb", "fooBar").? > testScore("fb", "foobar").?);
}

test "positions follow the best match" {
    var scratch: PositionScratch = .{};
    var out: [8]usize = undefined;
    const p = positions(Query.init("fb"), "foo_bar", &scratch, &out).?;
    try testing.expectEqualSlices(usize, &.{ 0, 4 }, p);
    // Prefers the boundary 'm' of main over the earlier mid-word 'm'.
    const p2 = positions(Query.init("main"), "src/domain/main.zig", &scratch, &out).?;
    try testing.expectEqualSlices(usize, &.{ 11, 12, 13, 14 }, p2);
}
