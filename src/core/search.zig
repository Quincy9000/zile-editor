//! Plain-text search for `/`, `?`, `n`, `N`, `*`, `#`.
//!
//! Smart case: a needle with an uppercase letter is case-sensitive.
//! `whole_word` (from `*`/`#`) requires word boundaries around the match.
//! TODO: regex patterns.

const std = @import("std");

pub const Pattern = struct {
    needle: []const u8,
    case_sensitive: bool,
    whole_word: bool = false,

    pub fn init(needle: []const u8, whole_word: bool) Pattern {
        var sensitive = false;
        for (needle) |b| sensitive = sensitive or std.ascii.isUpper(b);
        return .{ .needle = needle, .case_sensitive = sensitive, .whole_word = whole_word };
    }

    pub fn matchAt(p: Pattern, hay: []const u8, i: usize) bool {
        const n = p.needle;
        if (n.len == 0 or i + n.len > hay.len) return false;
        const window = hay[i .. i + n.len];
        const eq = if (p.case_sensitive) std.mem.eql(u8, window, n) else std.ascii.eqlIgnoreCase(window, n);
        if (!eq) return false;
        if (!p.whole_word) return true;
        const before_ok = i == 0 or !isWord(hay[i - 1]);
        const after_ok = i + n.len == hay.len or !isWord(hay[i + n.len]);
        return before_ok and after_ok;
    }

    /// First match starting at or after `from`.
    pub fn forward(p: Pattern, hay: []const u8, from: usize) ?usize {
        if (p.needle.len == 0) return null;
        var i = from;
        while (i + p.needle.len <= hay.len) : (i += 1) {
            if (p.matchAt(hay, i)) return i;
        }
        return null;
    }

    /// Last match starting before `before`.
    pub fn backward(p: Pattern, hay: []const u8, before: usize) ?usize {
        if (p.needle.len == 0) return null;
        var i = @min(before, hay.len);
        while (i > 0) {
            i -= 1;
            if (p.matchAt(hay, i)) return i;
        }
        return null;
    }

    /// The next match after/before `pos`, wrapping around the text.
    pub fn next(p: Pattern, hay: []const u8, pos: usize, fwd: bool) ?struct { pos: usize, wrapped: bool } {
        if (fwd) {
            if (p.forward(hay, pos + 1)) |m| return .{ .pos = m, .wrapped = false };
            if (p.forward(hay, 0)) |m| return .{ .pos = m, .wrapped = true };
        } else {
            if (p.backward(hay, pos)) |m| return .{ .pos = m, .wrapped = false };
            if (p.backward(hay, hay.len)) |m| return .{ .pos = m, .wrapped = true };
        }
        return null;
    }

    /// Which match `pos` is (1-based) and how many there are.
    pub fn position(p: Pattern, hay: []const u8, pos: usize) struct { index: usize, total: usize } {
        var index: usize = 0;
        var total: usize = 0;
        var i: usize = 0;
        while (p.forward(hay, i)) |m| {
            total += 1;
            if (m <= pos) index = total;
            i = m + 1;
        }
        return .{ .index = index, .total = total };
    }
};

pub fn isWord(b: u8) bool {
    return b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b);
}

const testing = std.testing;

test "smart case, wrapping, whole words" {
    const hay = "foo Foo food foo";
    const p = Pattern.init("foo", false);
    try testing.expectEqual(4, p.next(hay, 0, true).?.pos); // case-insensitive
    try testing.expectEqual(13, p.next(hay, 8, true).?.pos);
    const wrapped = p.next(hay, 13, true).?;
    try testing.expect(wrapped.wrapped);
    try testing.expectEqual(0, wrapped.pos);
    try testing.expectEqual(13, p.next(hay, 0, false).?.pos);

    const sensitive = Pattern.init("Foo", false);
    try testing.expectEqual(4, sensitive.next(hay, 0, true).?.pos);
    try testing.expectEqual(4, sensitive.next(hay, 4, true).?.pos); // the only match

    const word = Pattern.init("foo", true);
    try testing.expectEqual(13, word.next(hay, 4, true).?.pos); // skips "food"
    const pos = word.position(hay, 13);
    try testing.expectEqual(3, pos.total);
    try testing.expectEqual(3, pos.index);
}
