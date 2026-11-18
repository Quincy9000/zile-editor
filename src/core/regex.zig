//! Regex for the select prompt (`s`): where a pattern matches and how far.
//!
//! Supported: literals, `.`, classes `[a-z_]` / `[^...]`, `\d \w \s` (and
//! `\D \W \S`), `\n \t \r`, `\b \B`, `^ $` (at line ends), groups `(...)` /
//! `(?:...)`, alternation `|`, and the quantifiers `* + ? {n} {n,} {n,m}`,
//! lazy with a trailing `?`. No captures or backreferences.
//!
//! Smart case, like the plain search: a pattern without an uppercase letter
//! matches in either case.
//!
//! The pattern compiles to a small program run as a Pike VM (every thread
//! steps over the text together), so no pattern backtracks exponentially.
//! Matches are leftmost, then by the usual greedy / lazy preference, and
//! never empty. Nothing allocates: a pattern too big for the fixed program
//! does not compile.

const std = @import("std");

const Regex = @This();

const Set = std.StaticBitSet(256);

const max_insts = 384;
const max_sets = 32;
const max_repeat = 255;

const Op = enum(u8) {
    /// The byte `x`.
    char,
    /// The letter `x` (lowercase) in either case.
    fold,
    /// Any byte but a line break.
    any,
    /// A byte in `sets[x]`.
    set,
    /// Go on at `x`, or failing that at `y`.
    split,
    jmp,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
    match,
};

const Inst = struct { op: Op, x: u16 = 0, y: u16 = 0 };

pub const Match = struct { start: usize, end: usize };

insts: [max_insts]Inst = undefined,
len: u16 = 0,
sets: [max_sets]Set = undefined,
set_count: u16 = 0,

/// Null for a pattern that is not a regex (`foo(`, `*x`) or is too big.
pub fn compile(pattern: []const u8) ?Regex {
    var re: Regex = .{};
    var c: Compiler = .{ .re = &re, .src = pattern, .fold = !hasUpper(pattern) };
    c.alternation() catch return null;
    if (c.i != pattern.len) return null; // a stray ')'
    c.emit(.{ .op = .match }) catch return null;
    return re;
}

/// An uppercase letter that is not an escape's name (`\S`, `\W`).
fn hasUpper(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\') {
            i += 1;
        } else if (std.ascii.isUpper(pattern[i])) return true;
    }
    return false;
}

const Compiler = struct {
    re: *Regex,
    src: []const u8,
    i: usize = 0,
    fold: bool,

    const Error = error{Bad};

    fn peek(c: *const Compiler) ?u8 {
        return if (c.i < c.src.len) c.src[c.i] else null;
    }

    fn emit(c: *Compiler, inst: Inst) Error!void {
        if (c.re.len == max_insts) return error.Bad;
        c.re.insts[c.re.len] = inst;
        c.re.len += 1;
    }

    /// Puts `inst` at `at`, moving what is there (and the jumps into it) up.
    /// A jump from before `at` to `at` itself now lands on `inst`.
    fn insert(c: *Compiler, at: u16, inst: Inst) Error!void {
        if (c.re.len == max_insts) return error.Bad;
        const insts = &c.re.insts;
        var k = c.re.len;
        while (k > at) : (k -= 1) insts[k] = insts[k - 1];
        c.re.len += 1;
        insts[at] = inst;
        for (insts[0..c.re.len], 0..) |*in, idx| {
            if (idx == at or (in.op != .split and in.op != .jmp)) continue;
            const moved = idx > at;
            if (in.x > at or (moved and in.x == at)) in.x += 1;
            if (in.op == .split and (in.y > at or (moved and in.y == at))) in.y += 1;
        }
    }

    fn addSet(c: *Compiler, set: Set) Error!void {
        if (c.re.set_count == max_sets) return error.Bad;
        c.re.sets[c.re.set_count] = set;
        try c.emit(.{ .op = .set, .x = c.re.set_count });
        c.re.set_count += 1;
    }

    fn literal(c: *Compiler, ch: u8) Error!void {
        if (c.fold and std.ascii.isAlphabetic(ch)) return c.emit(.{ .op = .fold, .x = std.ascii.toLower(ch) });
        try c.emit(.{ .op = .char, .x = ch });
    }

    /// `a|b|c`: the earlier alternative wins.
    fn alternation(c: *Compiler) Error!void {
        const start = c.re.len;
        try c.sequence();
        while (c.peek() == '|') {
            c.i += 1;
            try c.insert(start, .{ .op = .split });
            const jmp = c.re.len;
            try c.emit(.{ .op = .jmp });
            c.re.insts[start].x = start + 1;
            c.re.insts[start].y = c.re.len;
            try c.sequence();
            c.re.insts[jmp].x = c.re.len;
        }
    }

    fn sequence(c: *Compiler) Error!void {
        while (c.peek()) |ch| {
            if (ch == '|' or ch == ')') return;
            try c.piece();
        }
    }

    /// An atom and its quantifier.
    fn piece(c: *Compiler) Error!void {
        const start = c.re.len;
        try c.atom();
        var min: u16 = 0;
        var max: ?u16 = null;
        switch (c.peek() orelse return) {
            '*' => c.i += 1,
            '+' => {
                min = 1;
                c.i += 1;
            },
            '?' => {
                max = 1;
                c.i += 1;
            },
            '{' => {
                const counts = c.counted() orelse return; // a plain `{`, taken next
                min = counts[0];
                max = counts[1];
            },
            else => return,
        }
        var lazy = false;
        if (c.peek() == '?') {
            lazy = true;
            c.i += 1;
        }
        try c.repeat(start, min, max, lazy);
    }

    /// `{n}`, `{n,}` or `{n,m}` at the cursor; null (nothing consumed) for
    /// anything else, which is then a literal brace.
    fn counted(c: *Compiler) ?struct { u16, ?u16 } {
        var j = c.i + 1;
        const min = number(c.src, &j) orelse return null;
        var max: ?u16 = min;
        if (j < c.src.len and c.src[j] == ',') {
            j += 1;
            max = number(c.src, &j);
        }
        if (j >= c.src.len or c.src[j] != '}') return null;
        if (max) |m| if (m < min) return null;
        c.i = j + 1;
        return .{ min, max };
    }

    fn number(src: []const u8, j: *usize) ?u16 {
        const from = j.*;
        var n: u16 = 0;
        while (j.* < src.len and std.ascii.isDigit(src[j.*])) : (j.* += 1) {
            n = n * 10 + (src[j.*] - '0');
            if (n > max_repeat) return null;
        }
        return if (j.* == from) null else n;
    }

    /// Rewrites the fragment from `start` to the end of the program as
    /// `min` to `max` (null: any number) of itself.
    fn repeat(c: *Compiler, start: u16, min: u16, max: ?u16, lazy: bool) Error!void {
        // The fragment, its jumps relative to its start.
        var frag: [max_insts]Inst = undefined;
        const n = c.re.len - start;
        for (c.re.insts[start..c.re.len], frag[0..n]) |in, *f| {
            f.* = in;
            if (in.op == .split or in.op == .jmp) f.x -= start;
            if (in.op == .split) f.y -= start;
        }
        c.re.len = start;
        var last = start;
        for (0..min) |_| {
            last = c.re.len;
            try c.copy(frag[0..n]);
        }
        if (max) |m| {
            // Each further one optional.
            for (min..m) |_| {
                const at = c.re.len;
                try c.emit(.{ .op = .split });
                try c.copy(frag[0..n]);
                c.setSplit(at, at + 1, c.re.len, lazy);
            }
        } else if (min == 0) {
            const at = c.re.len;
            try c.emit(.{ .op = .split });
            try c.copy(frag[0..n]);
            try c.emit(.{ .op = .jmp, .x = at });
            c.setSplit(at, at + 1, c.re.len, lazy);
        } else {
            // Back around the last one.
            const at = c.re.len;
            try c.emit(.{ .op = .split });
            c.setSplit(at, last, at + 1, lazy);
        }
    }

    /// The split at `at`: `more` first (after it when lazy), else `done`.
    fn setSplit(c: *Compiler, at: u16, more: u16, done: u16, lazy: bool) void {
        c.re.insts[at].x = if (lazy) done else more;
        c.re.insts[at].y = if (lazy) more else done;
    }

    fn copy(c: *Compiler, frag: []const Inst) Error!void {
        const base = c.re.len;
        for (frag) |f| {
            var in = f;
            if (in.op == .split or in.op == .jmp) in.x += base;
            if (in.op == .split) in.y += base;
            try c.emit(in);
        }
    }

    fn atom(c: *Compiler) Error!void {
        const ch = c.peek() orelse return error.Bad;
        c.i += 1;
        switch (ch) {
            '(' => {
                if (std.mem.startsWith(u8, c.src[c.i..], "?:")) c.i += 2;
                try c.alternation();
                if (c.peek() != ')') return error.Bad;
                c.i += 1;
            },
            ')', '*', '+', '?' => return error.Bad,
            '[' => try c.class(),
            '.' => try c.emit(.{ .op = .any }),
            '^' => try c.emit(.{ .op = .bol }),
            '$' => try c.emit(.{ .op = .eol }),
            '\\' => {
                const e = c.peek() orelse return error.Bad;
                c.i += 1;
                if (escapeSet(e)) |set| return c.addSet(set);
                switch (e) {
                    'b' => try c.emit(.{ .op = .word_boundary }),
                    'B' => try c.emit(.{ .op = .not_word_boundary }),
                    else => try c.literal(escapeChar(e)),
                }
            },
            else => try c.literal(ch),
        }
    }

    /// After the `[`.
    fn class(c: *Compiler) Error!void {
        var set: Set = .empty;
        const negate = c.peek() == '^';
        if (negate) c.i += 1;
        var first = true;
        while (true) : (first = false) {
            var ch = c.peek() orelse return error.Bad; // no closing ']'
            c.i += 1;
            if (ch == ']' and !first) break;
            if (ch == '\\') {
                const e = c.peek() orelse return error.Bad;
                c.i += 1;
                if (escapeSet(e)) |s| {
                    set.setUnion(s);
                    continue;
                }
                ch = escapeChar(e);
            }
            // `a-z`, unless the `-` is the class's last character.
            if (c.i + 1 < c.src.len and c.src[c.i] == '-' and c.src[c.i + 1] != ']') {
                var hi = c.src[c.i + 1];
                c.i += 2;
                if (hi == '\\') {
                    hi = escapeChar(c.peek() orelse return error.Bad);
                    c.i += 1;
                }
                if (hi < ch) return error.Bad;
                set.setRangeValue(.{ .start = ch, .end = @as(usize, hi) + 1 }, true);
            } else set.set(ch);
        }
        if (c.fold) {
            for ('a'..'z' + 1) |lower| {
                const upper = lower - 'a' + 'A';
                if (set.isSet(lower) or set.isSet(upper)) {
                    set.set(lower);
                    set.set(upper);
                }
            }
        }
        if (negate) set.toggleAll();
        try c.addSet(set);
    }
};

fn escapeChar(e: u8) u8 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        else => e,
    };
}

fn escapeSet(e: u8) ?Set {
    var s: Set = .empty;
    switch (std.ascii.toLower(e)) {
        'd' => s.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true),
        'w' => for (0..256) |b| {
            if (isWord(@intCast(b))) s.set(b);
        },
        's' => for (" \t\n\r\x0b\x0c") |b| s.set(b),
        else => return null,
    }
    if (std.ascii.isUpper(e)) s.toggleAll();
    return s;
}

fn isWord(b: u8) bool {
    return b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b);
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// The first match starting at or after `from`.
pub fn find(re: *const Regex, hay: []const u8, from: usize) ?Match {
    return re.run(hay, from, false);
}

/// How long the match starting exactly at `at` is.
pub fn matchLenAt(re: *const Regex, hay: []const u8, at: usize) ?usize {
    const m = re.run(hay, at, true) orelse return null;
    return m.end - m.start;
}

const Threads = struct {
    pcs: [max_insts]u16 = undefined,
    starts: [max_insts]usize = undefined,
    n: usize = 0,
};

const Vm = struct {
    re: *const Regex,
    hay: []const u8,
    /// The list each instruction was last added to.
    seen: [max_insts]u32 = @splat(0),
    gen: u32 = 1,

    /// Adds the thread at `pc`, following what takes no text.
    fn add(vm: *Vm, list: *Threads, pc: u16, start: usize, pos: usize) void {
        if (vm.seen[pc] == vm.gen) return;
        vm.seen[pc] = vm.gen;
        const in = vm.re.insts[pc];
        const hay = vm.hay;
        switch (in.op) {
            .jmp => vm.add(list, in.x, start, pos),
            .split => {
                vm.add(list, in.x, start, pos);
                vm.add(list, in.y, start, pos);
            },
            .bol => if (pos == 0 or hay[pos - 1] == '\n') vm.add(list, pc + 1, start, pos),
            .eol => if (pos == hay.len or hay[pos] == '\n') vm.add(list, pc + 1, start, pos),
            .word_boundary, .not_word_boundary => {
                const before = pos > 0 and isWord(hay[pos - 1]);
                const after = pos < hay.len and isWord(hay[pos]);
                if ((before != after) == (in.op == .word_boundary)) vm.add(list, pc + 1, start, pos);
            },
            else => {
                list.pcs[list.n] = pc;
                list.starts[list.n] = start;
                list.n += 1;
            },
        }
    }
};

fn run(re: *const Regex, hay: []const u8, from: usize, anchored: bool) ?Match {
    if (from > hay.len) return null;
    var vm: Vm = .{ .re = re, .hay = hay };
    var lists: [2]Threads = .{ .{}, .{} };
    var cur: *Threads = &lists[0];
    var next: *Threads = &lists[1];
    var best: ?Match = null;
    var pos = from;
    while (true) : (pos += 1) {
        // A match may start here too (after the ones already under way),
        // though not in the middle of a character.
        const may_start = if (anchored) pos == from else best == null;
        if (may_start and !(pos < hay.len and isContinuation(hay[pos]))) vm.add(cur, 0, pos, pos);
        if (cur.n == 0 and (anchored or best != null)) break;
        vm.gen += 1;
        next.n = 0;
        const byte: ?u8 = if (pos < hay.len) hay[pos] else null;
        for (cur.pcs[0..cur.n], cur.starts[0..cur.n]) |pc, start| {
            const in = re.insts[pc];
            const ok = switch (in.op) {
                .match => {
                    if (pos == start) continue; // empty
                    best = .{ .start = start, .end = pos };
                    break; // the threads after this one are less preferred
                },
                .char => byte != null and byte.? == in.x,
                .fold => byte != null and std.ascii.toLower(byte.?) == in.x,
                .any => byte != null and byte.? != '\n',
                .set => byte != null and re.sets[in.x].isSet(byte.?),
                else => unreachable,
            };
            if (ok) vm.add(next, pc + 1, start, pos + 1);
        }
        if (byte == null) break;
        std.mem.swap(*Threads, &cur, &next);
    }
    var m = best orelse return null;
    while (m.end < hay.len and isContinuation(hay[m.end])) m.end += 1;
    return m;
}

const testing = std.testing;

fn expectFind(pattern: []const u8, hay: []const u8, want: ?[]const u8) !void {
    const re = compile(pattern) orelse return error.DidNotCompile;
    const m = re.find(hay, 0);
    if (want) |w| {
        try testing.expect(m != null);
        try testing.expectEqualStrings(w, hay[m.?.start..m.?.end]);
    } else try testing.expectEqual(null, m);
}

test "literals, classes, quantifiers" {
    try expectFind("self.dir = .*", "x\n    self.dir = foo;\nnext", "self.dir = foo;");
    try expectFind("self\\.dir = *", "self.dir =    1", "self.dir =    ");
    try expectFind("a+b?", "caab", "aab");
    try expectFind("[a-c]+", "xxabcabd", "abcab");
    try expectFind("[^ ]+", "  foo bar", "foo");
    try expectFind("\\d+", "abc 1234 x", "1234");
    try expectFind("\\w+\\s*=", "  foo_1  = 2", "foo_1  =");
    try expectFind("[]x]+", "a]x]b", "]x]");
    try expectFind("[a\\-z]+", "b-a-z", "-a-z");
    try expectFind("a.c", "a\nc abc", "abc");
}

test "groups, alternation, counts, lazy" {
    try expectFind("foo|bar", "a bar foo", "bar");
    try expectFind("(foo|bar)+!", "foobarfoo!", "foobarfoo!");
    try expectFind("a(b|c|d)e", "ace ade", "ace");
    try expectFind("(?:ab)*c", "ababc", "ababc");
    try expectFind("x{2,3}", "x xx xxxx", "xx");
    try expectFind("x{3}", "xx xxxx", "xxx");
    try expectFind("x{2,}", "x xxxxx", "xxxxx");
    try expectFind("\".*?\"", "say \"a\" and \"b\"", "\"a\"");
    try expectFind("\".*\"", "say \"a\" and \"b\"", "\"a\" and \"b\"");
    try expectFind("fn {", "fn {", "fn {"); // not a count: a plain brace
    try expectFind("(a*)*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac", null);
}

test "anchors, word boundaries, smart case" {
    try expectFind("^foo", "a foo\nfoo", "foo");
    try testing.expectEqual(6, compile("^foo").?.find("a foo\nfoo", 0).?.start);
    try expectFind("\\w+$", "one two\nthree", "two");
    try expectFind("\\bcat\\b", "concat cat", "cat");
    try testing.expectEqual(7, compile("\\bcat\\b").?.find("concat cat", 0).?.start);
    try expectFind("foo", "a FOO", "FOO");
    try expectFind("Foo", "a FOO Foo", "Foo");
    try expectFind("\\S+", "  Ab ", "Ab");
    try expectFind("[a-c]+", "xABc", "ABc");
}

test "never empty, whole characters, not a regex" {
    try expectFind("a*", "bbb", null);
    try expectFind("a*", "bba", "a");
    try expectFind("é.", "xéüy", "éü");
    const re = compile("b+").?;
    try testing.expectEqual(2, re.matchLenAt("abbc", 1));
    try testing.expectEqual(null, re.matchLenAt("abbc", 0));
    try testing.expectEqual(4, re.find("abbcb", 3).?.start);
    try testing.expect(compile("foo(") == null);
    try testing.expect(compile("*foo") == null);
    try testing.expect(compile("a)") == null);
    try testing.expect(compile("[abc") == null);
}
