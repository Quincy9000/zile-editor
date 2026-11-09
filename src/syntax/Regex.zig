//! A tiny backtracking regex for tree-sitter query predicates (`#match?`,
//! `#lua-match?`). Highlight queries only use simple patterns like
//! `^[A-Z][A-Z\d_]*$`, so this supports: `^ $ .`, classes `[a-z_]` / `[^...]`,
//! escapes `\d \w \s` (and Lua's `%d %w %s %a %u %l`), and the quantifiers
//! `* + ?`. No groups or alternation: `compile` returns null for those.

const std = @import("std");

const Regex = @This();

const Set = std.StaticBitSet(256);

const Atom = struct {
    set: Set,
    quant: enum { one, star, plus, opt } = .one,
};

const max_atoms = 48;

atoms: [max_atoms]Atom = undefined,
len: usize = 0,
anchor_start: bool = false,
anchor_end: bool = false,

pub fn compile(pattern: []const u8, lua: bool) ?Regex {
    var re: Regex = .{};
    var i: usize = 0;
    const esc: u8 = if (lua) '%' else '\\';
    if (i < pattern.len and pattern[i] == '^') {
        re.anchor_start = true;
        i += 1;
    }
    while (i < pattern.len) {
        const ch = pattern[i];
        if (ch == '$' and i + 1 == pattern.len) {
            re.anchor_end = true;
            break;
        }
        if (re.len == max_atoms) return null;
        var set: Set = .empty;
        switch (ch) {
            '(', ')', '|', '{', '}' => return null,
            '.' => {
                set = .full;
                i += 1;
            },
            '[' => {
                i += 1;
                const negate = i < pattern.len and pattern[i] == '^';
                if (negate) i += 1;
                var first = true;
                while (i < pattern.len and (pattern[i] != ']' or first)) : (first = false) {
                    if (pattern[i] == esc and i + 1 < pattern.len) {
                        set.setUnion(escapeSet(pattern[i + 1]) orelse single(pattern[i + 1]));
                        i += 2;
                    } else if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                        set.setRangeValue(.{ .start = pattern[i], .end = @as(usize, pattern[i + 2]) + 1 }, true);
                        i += 3;
                    } else {
                        set.set(pattern[i]);
                        i += 1;
                    }
                }
                if (i >= pattern.len) return null; // unterminated class
                i += 1; // ']'
                if (negate) set.toggleAll();
            },
            else => {
                if (ch == esc and i + 1 < pattern.len) {
                    set = escapeSet(pattern[i + 1]) orelse single(pattern[i + 1]);
                    i += 2;
                } else {
                    set.set(ch);
                    i += 1;
                }
            },
        }
        var atom: Atom = .{ .set = set };
        if (i < pattern.len) {
            switch (pattern[i]) {
                '*' => atom.quant = .star,
                '+' => atom.quant = .plus,
                '?' => atom.quant = .opt,
                '-' => if (lua) {
                    atom.quant = .star; // lazy in Lua; greedy is fine for full-match checks
                },
                else => {},
            }
            if (atom.quant != .one) i += 1;
        }
        re.atoms[re.len] = atom;
        re.len += 1;
    }
    return re;
}

fn single(ch: u8) Set {
    var s: Set = .empty;
    s.set(ch);
    return s;
}

fn escapeSet(ch: u8) ?Set {
    var s: Set = .empty;
    switch (ch) {
        'd' => s.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true),
        'w' => {
            s.setRangeValue(.{ .start = 'a', .end = 'z' + 1 }, true);
            s.setRangeValue(.{ .start = 'A', .end = 'Z' + 1 }, true);
            s.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true);
            s.set('_');
        },
        'a' => {
            s.setRangeValue(.{ .start = 'a', .end = 'z' + 1 }, true);
            s.setRangeValue(.{ .start = 'A', .end = 'Z' + 1 }, true);
        },
        'u' => s.setRangeValue(.{ .start = 'A', .end = 'Z' + 1 }, true),
        'l' => s.setRangeValue(.{ .start = 'a', .end = 'z' + 1 }, true),
        's' => for (" \t\n\r\x0b\x0c") |c| s.set(c),
        else => return null,
    }
    return s;
}

pub fn isMatch(re: *const Regex, s: []const u8) bool {
    if (re.anchor_start) return re.matchHere(0, s, 0);
    for (0..s.len + 1) |start| {
        if (re.matchHere(0, s, start)) return true;
    }
    return false;
}

fn matchHere(re: *const Regex, ai: usize, s: []const u8, si: usize) bool {
    if (ai == re.len) return !re.anchor_end or si == s.len;
    const atom = re.atoms[ai];
    switch (atom.quant) {
        .one => return si < s.len and atom.set.isSet(s[si]) and re.matchHere(ai + 1, s, si + 1),
        .opt => return (si < s.len and atom.set.isSet(s[si]) and re.matchHere(ai + 1, s, si + 1)) or
            re.matchHere(ai + 1, s, si),
        .star, .plus => {
            var n: usize = 0;
            while (si + n < s.len and atom.set.isSet(s[si + n])) n += 1;
            const min: usize = if (atom.quant == .plus) 1 else 0;
            // Greedy, backing off one at a time.
            while (true) {
                if (n < min) return false;
                if (re.matchHere(ai + 1, s, si + n)) return true;
                if (n == 0) return false;
                n -= 1;
            }
        },
    }
}

const testing = std.testing;

test "patterns used by highlight queries" {
    const constant = compile("^[A-Z][A-Z\\d_]*$", false).?;
    try testing.expect(constant.isMatch("MAX_LEN2"));
    try testing.expect(!constant.isMatch("MaxLen"));
    const upper = compile("^[A-Z]", false).?;
    try testing.expect(upper.isMatch("Foo"));
    try testing.expect(!upper.isMatch("foo"));
    const doc = compile("^//!", true).?;
    try testing.expect(doc.isMatch("//! module doc"));
    try testing.expect(!doc.isMatch("// plain"));
    const lua_type = compile("^[A-Z_][a-zA-Z0-9_]*", true).?;
    try testing.expect(lua_type.isMatch("ArrayList"));
    const typo = compile("^[A-Z][A-Z\\d_]+$'", false).?; // rust's query really has this
    try testing.expect(!typo.isMatch("FOO"));
    try testing.expect(compile("(a|b)", false) == null);
}
