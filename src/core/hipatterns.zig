//! Patterns highlighted in the text (mini.hipatterns): todo words
//! (`TODO`, `FIXME`, `HACK`, `NOTE`, ...) and colour literals (`#rrggbb`,
//! `#rgb`, `#rrggbbaa`, `0xRRGGBB`). Pure: one line in, matches out.

const std = @import("std");

/// How a todo word is coloured.
pub const Class = enum { todo, fixme, hack, note };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Kind = union(enum) {
    todo: Class,
    /// `#rrggbb`: shown on its own colour.
    color: Rgb,
    /// `0xRRGGBB`: underlined in its colour (most hex numbers aren't colours,
    /// so this stays quiet).
    hex_number: Rgb,
};

pub const Match = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

pub const words = [_]struct { []const u8, Class }{
    .{ "TODO", .todo },
    .{ "FIXME", .fixme },
    .{ "BUG", .fixme },
    .{ "XXX", .fixme },
    .{ "HACK", .hack },
    .{ "WARNING", .hack },
    .{ "WARN", .hack },
    .{ "NOTE", .note },
    .{ "PERF", .note },
};

/// A regex alternation of the todo words, for ripgrep.
pub const words_regex = blk: {
    var s: []const u8 = "\\b(";
    for (words, 0..) |w, i| s = s ++ (if (i > 0) "|" else "") ++ w[0];
    break :blk s ++ ")\\b";
};

fn isWord(b: u8) bool {
    return b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b);
}

fn hexRun(line: []const u8, from: usize) usize {
    var n: usize = 0;
    while (from + n < line.len and std.ascii.isHex(line[from + n])) n += 1;
    return n;
}

fn nibble(b: u8) u8 {
    return std.fmt.charToDigit(b, 16) catch 0;
}

fn rgb(digits: []const u8) Rgb {
    if (digits.len == 3) return .{ .r = nibble(digits[0]) * 17, .g = nibble(digits[1]) * 17, .b = nibble(digits[2]) * 17 };
    return .{
        .r = nibble(digits[0]) * 16 + nibble(digits[1]),
        .g = nibble(digits[2]) * 16 + nibble(digits[3]),
        .b = nibble(digits[4]) * 16 + nibble(digits[5]),
    };
}

/// The todo word starting at `i`, if one does (whole word, upper case).
pub fn todoAt(line: []const u8, i: usize) ?struct { len: usize, class: Class } {
    if (i > 0 and isWord(line[i - 1])) return null;
    for (words) |w| {
        if (!std.mem.startsWith(u8, line[i..], w[0])) continue;
        const end = i + w[0].len;
        if (end < line.len and isWord(line[end])) continue;
        return .{ .len = w[0].len, .class = w[1] };
    }
    return null;
}

/// Every match in `line`, in order. Stops when `out` is full.
pub fn scan(line: []const u8, out: []Match) []Match {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < out.len) {
        const b = line[i];
        if (b == '#') {
            const digits = hexRun(line, i + 1);
            const end = i + 1 + digits;
            const bounded = end == line.len or !isWord(line[end]);
            // `#123` is more often an issue number than a colour: three
            // digits need a letter.
            const ok = digits == 6 or digits == 8 or (digits == 3 and std.mem.indexOfAny(u8, line[i + 1 .. end], "abcdefABCDEF") != null);
            if (ok and bounded) {
                out[n] = .{ .start = i, .end = end, .kind = .{ .color = rgb(line[i + 1 .. end]) } };
                n += 1;
                i = end;
                continue;
            }
        } else if (b == '0' and i + 1 < line.len and (line[i + 1] == 'x' or line[i + 1] == 'X') and (i == 0 or !isWord(line[i - 1]))) {
            const digits = hexRun(line, i + 2);
            const end = i + 2 + digits;
            if (digits == 6 and (end == line.len or !isWord(line[end]))) {
                out[n] = .{ .start = i, .end = end, .kind = .{ .hex_number = rgb(line[i + 2 .. end]) } };
                n += 1;
                i = end;
                continue;
            }
        } else if (std.ascii.isUpper(b)) {
            if (todoAt(line, i)) |w| {
                out[n] = .{ .start = i, .end = i + w.len, .kind = .{ .todo = w.class } };
                n += 1;
                i += w.len;
                continue;
            }
            // Skip the rest of this word: a todo word starts one.
            while (i < line.len and isWord(line[i])) i += 1;
            continue;
        }
        i += 1;
    }
    return out[0..n];
}

const testing = std.testing;

test "todo words are whole upper-case words" {
    var buf: [8]Match = undefined;
    const m = scan("// TODO: fix; NOTES and TODOS don't count, FIXME(me) does", &buf);
    try testing.expectEqual(2, m.len);
    try testing.expectEqual(Class.todo, m[0].kind.todo);
    try testing.expectEqual(3, m[0].start);
    try testing.expectEqual(Class.fixme, m[1].kind.todo);
}

test "colour literals" {
    var buf: [8]Match = undefined;
    const m = scan("a #ff8000 b #fff c #123 d #12345 e 0x10ff20 f 0x1234 #ff8000aa", &buf);
    try testing.expectEqual(4, m.len);
    try testing.expectEqual(Rgb{ .r = 255, .g = 128, .b = 0 }, m[0].kind.color);
    try testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, m[1].kind.color);
    try testing.expectEqual(Rgb{ .r = 16, .g = 255, .b = 32 }, m[2].kind.hex_number);
    try testing.expectEqual(Rgb{ .r = 255, .g = 128, .b = 0 }, m[3].kind.color);
    try testing.expectEqualStrings("\\b(TODO|FIXME|BUG|XXX|HACK|WARNING|WARN|NOTE|PERF)\\b", words_regex);
}
