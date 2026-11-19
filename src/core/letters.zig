//! Upper and lower case of letters past ASCII, for `~`, `gU`, `gu` and their
//! visual forms: Latin with its accents, Greek and Cyrillic. (Zig's standard
//! library has ASCII only.) A letter without the other case is itself.

const std = @import("std");

/// Pairs that follow no rule: lower, upper.
const odd = [_][2]u21{
    .{ 0x00FF, 0x0178 }, // ÿ Ÿ
    .{ 0x00DF, 0x1E9E }, // ß ẞ
    .{ 0x0180, 0x0243 }, // ƀ Ƀ
    .{ 0x01C6, 0x01C4 }, // ǆ Ǆ
    .{ 0x01C9, 0x01C7 }, // ǉ Ǉ
    .{ 0x01CC, 0x01CA }, // ǌ Ǌ
    .{ 0x01F3, 0x01F1 }, // ǳ Ǳ
    .{ 0x03AC, 0x0386 }, // ά Ά
    .{ 0x03AD, 0x0388 }, // έ Έ
    .{ 0x03AE, 0x0389 }, // ή Ή
    .{ 0x03AF, 0x038A }, // ί Ί
    .{ 0x03CC, 0x038C }, // ό Ό
    .{ 0x03CD, 0x038E }, // ύ Ύ
    .{ 0x03CE, 0x038F }, // ώ Ώ
};

/// Ranges where upper and lower alternate: `upper_even` says which of a
/// pair is the capital (Ā is even, ā odd; Ĺ is odd, ĺ even).
const Alternating = struct { first: u21, last: u21, upper_even: bool };
const alternating = [_]Alternating{
    .{ .first = 0x0100, .last = 0x012F, .upper_even = true },
    .{ .first = 0x0132, .last = 0x0137, .upper_even = true },
    .{ .first = 0x0139, .last = 0x0148, .upper_even = false },
    .{ .first = 0x014A, .last = 0x0177, .upper_even = true },
    .{ .first = 0x0179, .last = 0x017E, .upper_even = false },
    .{ .first = 0x01CD, .last = 0x01DC, .upper_even = false },
    .{ .first = 0x01DE, .last = 0x01EF, .upper_even = true },
    .{ .first = 0x01F8, .last = 0x021F, .upper_even = true },
    .{ .first = 0x0222, .last = 0x0233, .upper_even = true },
    .{ .first = 0x0460, .last = 0x0481, .upper_even = true },
    .{ .first = 0x048A, .last = 0x04BF, .upper_even = true },
    .{ .first = 0x04D0, .last = 0x052F, .upper_even = true },
    .{ .first = 0x1E00, .last = 0x1E95, .upper_even = true },
    .{ .first = 0x1EA0, .last = 0x1EFF, .upper_even = true },
};

/// Ranges of lower-case letters a fixed distance after their capitals.
const Shifted = struct { first: u21, last: u21, by: u21 };
const shifted = [_]Shifted{
    .{ .first = 0x00E0, .last = 0x00F6, .by = 0x20 }, // à..ö
    .{ .first = 0x00F8, .last = 0x00FE, .by = 0x20 }, // ø..þ
    .{ .first = 0x03B1, .last = 0x03C1, .by = 0x20 }, // α..ρ
    .{ .first = 0x03C3, .last = 0x03CB, .by = 0x20 }, // σ..ϋ
    .{ .first = 0x0430, .last = 0x044F, .by = 0x20 }, // а..я
    .{ .first = 0x0450, .last = 0x045F, .by = 0x50 }, // ѐ..џ
    .{ .first = 0x0561, .last = 0x0586, .by = 0x30 }, // Armenian
};

pub fn upper(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'a' and cp <= 'z') cp - 0x20 else cp;
    if (cp == 0x0131) return 'I'; // ı
    if (cp == 0x03C2) return 0x03A3; // ς (final sigma)
    if (cp == 0x00B5) return 0x039C; // µ
    for (odd) |p| if (p[0] == cp) return p[1];
    for (shifted) |r| if (cp >= r.first and cp <= r.last) return cp - r.by;
    for (alternating) |r| if (cp >= r.first and cp <= r.last) {
        const even = cp % 2 == 0;
        return if (even == r.upper_even) cp else cp - 1;
    };
    return cp;
}

pub fn lower(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 0x20 else cp;
    if (cp == 0x0130) return 'i'; // İ
    for (odd) |p| if (p[1] == cp) return p[0];
    for (shifted) |r| if (cp >= r.first - r.by and cp <= r.last - r.by) {
        // (× and the like sit between capitals: they have no other case.)
        if (cp == 0x00D7) return cp;
        return cp + r.by;
    };
    for (alternating) |r| if (cp >= r.first and cp <= r.last) {
        const even = cp % 2 == 0;
        return if (even == r.upper_even) cp + 1 else cp;
    };
    return cp;
}

test "letters: case past ASCII" {
    const t = std.testing;
    try t.expectEqual('É', upper('é'));
    try t.expectEqual('é', lower('É'));
    try t.expectEqual('ö', lower('Ö'));
    try t.expectEqual('Ÿ', upper('ÿ'));
    try t.expectEqual('ẞ', upper('ß'));
    try t.expectEqual('Σ', upper('σ'));
    try t.expectEqual('Σ', upper('ς'));
    try t.expectEqual('σ', lower('Σ'));
    try t.expectEqual('Я', upper('я'));
    try t.expectEqual('я', lower('Я'));
    try t.expectEqual('Ā', upper('ā'));
    try t.expectEqual('ā', lower('Ā'));
    try t.expectEqual('Ĺ', upper('ĺ'));
    try t.expectEqual('ž', lower('Ž'));
    try t.expectEqual('I', upper('ı'));
    try t.expectEqual('i', lower('İ'));
    try t.expectEqual('Ǆ', upper('ǆ'));
    try t.expectEqual('×', lower('×'));
    try t.expectEqual('÷', upper('÷'));
    try t.expectEqual('Z', upper('z'));
    try t.expectEqual('1', upper('1'));
    try t.expectEqual('→', upper('→'));
}
