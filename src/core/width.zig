//! How many terminal cells a character takes: 2 for East Asian wide and
//! fullwidth characters (CJK, kana, hangul, fullwidth forms) and emoji, 0
//! for combining marks and other zero-width characters, else 1. The ranges
//! are Unicode's EastAsianWidth W and F (and Emoji_Presentation), as
//! terminals' wcwidth tables have them, so zile and the terminal agree on
//! where each character goes.

const std = @import("std");

/// Wide (2 cells), sorted, inclusive.
const wide = [_][2]u21{
    .{ 0x1100, 0x115F }, // hangul jamo initials
    .{ 0x231A, 0x231B }, .{ 0x2329, 0x232A }, .{ 0x23E9, 0x23EC }, .{ 0x23F0, 0x23F0 }, .{ 0x23F3, 0x23F3 },
    .{ 0x25FD, 0x25FE }, .{ 0x2614, 0x2615 }, .{ 0x2648, 0x2653 }, .{ 0x267F, 0x267F }, .{ 0x2693, 0x2693 },
    .{ 0x26A1, 0x26A1 }, .{ 0x26AA, 0x26AB }, .{ 0x26BD, 0x26BE }, .{ 0x26C4, 0x26C5 }, .{ 0x26CE, 0x26CE },
    .{ 0x26D4, 0x26D4 }, .{ 0x26EA, 0x26EA }, .{ 0x26F2, 0x26F3 }, .{ 0x26F5, 0x26F5 }, .{ 0x26FA, 0x26FA },
    .{ 0x26FD, 0x26FD }, .{ 0x2705, 0x2705 }, .{ 0x270A, 0x270B }, .{ 0x2728, 0x2728 }, .{ 0x274C, 0x274C },
    .{ 0x274E, 0x274E }, .{ 0x2753, 0x2755 }, .{ 0x2757, 0x2757 }, .{ 0x2795, 0x2797 }, .{ 0x27B0, 0x27B0 },
    .{ 0x27BF, 0x27BF }, .{ 0x2B1B, 0x2B1C }, .{ 0x2B50, 0x2B50 }, .{ 0x2B55, 0x2B55 },
    .{ 0x2E80, 0x303E }, // CJK radicals, punctuation, ideographic space
    .{ 0x3041, 0x33FF }, // hiragana, katakana, bopomofo, CJK compatibility
    .{ 0x3400, 0x4DBF }, // CJK extension A
    .{ 0x4E00, 0x9FFF }, // CJK unified ideographs
    .{ 0xA000, 0xA4CF }, // yi
    .{ 0xA960, 0xA97F }, // hangul jamo extended-A
    .{ 0xAC00, 0xD7A3 }, // hangul syllables
    .{ 0xF900, 0xFAFF }, // CJK compatibility ideographs
    .{ 0xFE10, 0xFE19 }, // vertical forms
    .{ 0xFE30, 0xFE6F }, // CJK compatibility forms, small forms
    .{ 0xFF00, 0xFF60 }, // fullwidth forms
    .{ 0xFFE0, 0xFFE6 },
    .{ 0x16FE0, 0x16FE4 }, .{ 0x17000, 0x18CFF }, .{ 0x1AFF0, 0x1B2FF }, // tangut, kana supplement
    .{ 0x1F004, 0x1F004 }, .{ 0x1F0CF, 0x1F0CF }, .{ 0x1F18E, 0x1F18E }, .{ 0x1F191, 0x1F19A },
    .{ 0x1F200, 0x1F202 }, .{ 0x1F210, 0x1F23B }, .{ 0x1F240, 0x1F248 }, .{ 0x1F250, 0x1F251 }, .{ 0x1F260, 0x1F265 },
    .{ 0x1F300, 0x1F320 }, .{ 0x1F32D, 0x1F335 }, .{ 0x1F337, 0x1F37C }, .{ 0x1F37E, 0x1F393 }, .{ 0x1F3A0, 0x1F3CA },
    .{ 0x1F3CF, 0x1F3D3 }, .{ 0x1F3E0, 0x1F3F0 }, .{ 0x1F3F4, 0x1F3F4 }, .{ 0x1F3F8, 0x1F43E }, .{ 0x1F440, 0x1F440 },
    .{ 0x1F442, 0x1F4FC }, .{ 0x1F4FF, 0x1F53D }, .{ 0x1F54B, 0x1F54E }, .{ 0x1F550, 0x1F567 }, .{ 0x1F57A, 0x1F57A },
    .{ 0x1F595, 0x1F596 }, .{ 0x1F5A4, 0x1F5A4 }, .{ 0x1F5FB, 0x1F64F }, .{ 0x1F680, 0x1F6C5 }, .{ 0x1F6CC, 0x1F6CC },
    .{ 0x1F6D0, 0x1F6D2 }, .{ 0x1F6D5, 0x1F6D7 }, .{ 0x1F6DC, 0x1F6DF }, .{ 0x1F6EB, 0x1F6EC }, .{ 0x1F6F4, 0x1F6FC },
    .{ 0x1F7E0, 0x1F7EB }, .{ 0x1F7F0, 0x1F7F0 }, .{ 0x1F90C, 0x1F93A }, .{ 0x1F93C, 0x1F945 }, .{ 0x1F947, 0x1F9FF },
    .{ 0x1FA70, 0x1FAFF }, // emoji
    .{ 0x20000, 0x2FFFD }, .{ 0x30000, 0x3FFFD }, // CJK extensions B and on
};

/// Zero width: combining marks, joiners, variation selectors.
const zero = [_][2]u21{
    .{ 0x0300, 0x036F }, .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05BD }, .{ 0x0610, 0x061A }, .{ 0x064B, 0x065F },
    .{ 0x0E31, 0x0E31 }, .{ 0x0E34, 0x0E3A }, .{ 0x0E47, 0x0E4E },
    .{ 0x1AB0, 0x1AFF }, .{ 0x1DC0, 0x1DFF },
    .{ 0x200B, 0x200F }, // zero-width space, joiners, marks
    .{ 0x20D0, 0x20FF }, // combining marks for symbols
    .{ 0x302A, 0x302D }, .{ 0x3099, 0x309A }, // CJK and kana combining marks
    .{ 0xFE00, 0xFE0F }, // variation selectors
    .{ 0xFE20, 0xFE2F }, .{ 0xFEFF, 0xFEFF },
    .{ 0xE0100, 0xE01EF },
};

fn in(table: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < table[mid][0]) hi = mid else if (cp > table[mid][1]) lo = mid + 1 else return true;
    }
    return false;
}

/// The cells `cp` takes: 0, 1 or 2.
pub fn of(cp: u21) usize {
    if (cp < 0x300) return 1;
    if (in(&zero, cp)) return 0;
    if (in(&wide, cp)) return 2;
    return 1;
}

/// The cells UTF-8 `s` takes (an invalid byte is one).
pub fn ofText(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const cp = if (i + len <= s.len) std.unicode.utf8Decode(s[i .. i + len]) catch 0xFFFD else 0xFFFD;
        n += of(cp);
        i += if (i + len <= s.len) len else 1;
    }
    return n;
}

/// The cells of the character starting at `s[i]`, and its length in bytes.
pub fn at(s: []const u8, i: usize) struct { cells: usize, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cells = 1, .len = 1 };
    if (i + len > s.len) return .{ .cells = 1, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .cells = 1, .len = 1 };
    return .{ .cells = of(cp), .len = len };
}

test "width: CJK, kana, hangul, fullwidth and emoji are two cells; combining marks none" {
    const t = std.testing;
    for ([_]u21{ 'a', ' ', '~', 0xE9, 0x3B1, 0x416, 0x2500, 0x2713 }) |cp| try t.expectEqual(1, of(cp));
    for ([_]u21{ 0x3042, 0x30A2, 0x4E2D, 0x554F, 0xAC00, 0xFF21, 0x3000, 0x1F600, 0x1F680, 0x20000 }) |cp| try t.expectEqual(2, of(cp));
    for ([_]u21{ 0x301, 0x200D, 0xFE0F, 0x3099 }) |cp| try t.expectEqual(0, of(cp));
    try t.expectEqual(16, ofText("い合わせください"));
    try t.expectEqual(5, ofText("ab中c"));
    try t.expectEqual(1, ofText("e\u{301}"));
    for (wide[1..], 0..) |r, i| try t.expect(r[0] > wide[i][1]);
    for (zero[1..], 0..) |r, i| try t.expect(r[0] > zero[i][1]);
}
