//! Ligatures for a font on a grid: the font's contextual alternates
//! (`calt`, from its OpenType GSUB table) applied to a line's glyphs.
//!
//! Grid fonts (JetBrains Mono, Fira Code, Cascadia Code) make their
//! ligatures this way: every character keeps its cell and only its glyph
//! changes (the first ones to blank spacers, the last to a glyph reaching
//! back over them), so nothing on the grid moves. Only the lookups that
//! takes are read: single substitution (type 1), context and chained context
//! (5, 6) and extension (7). `liga` (several glyphs merged into one) is not:
//! it doesn't fit a grid.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Gsub = @This();

/// The GSUB table (a slice of the font, which must outlive this).
t: []const u8,
lookup_list: usize,
/// The `calt` lookups, in the order they apply.
lookups: []u16,
/// Glyphs a `calt` lookup can start on: the rest are passed over at once.
starts: std.DynamicBitSetUnmanaged,

/// Nested lookups deeper than this are a broken font.
const max_depth = 8;

/// The font's `calt` rules, or null when it has none.
pub fn init(gpa: Allocator, font: []const u8) Allocator.Error!?Gsub {
    const t = findTable(font, "GSUB") orelse return null;
    const feature_list: usize = r16(t, 6);
    const lookup_list: usize = r16(t, 8);
    if (feature_list == 0 or lookup_list == 0) return null;

    var lookups: std.ArrayList(u16) = .empty;
    defer lookups.deinit(gpa);
    for (0..r16(t, feature_list)) |i| {
        const rec = feature_list + 2 + 6 * i;
        if (rec + 6 > t.len or !std.mem.eql(u8, t[rec .. rec + 4], "calt")) continue;
        const f = feature_list + r16(t, rec + 4);
        for (0..r16(t, f + 2)) |j| {
            const li = r16(t, f + 4 + 2 * j);
            if (std.mem.indexOfScalar(u16, lookups.items, li) == null) try lookups.append(gpa, li);
        }
    }
    if (lookups.items.len == 0) return null;
    std.mem.sort(u16, lookups.items, {}, std.sort.asc(u16));

    var starts: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, 1 << 16);
    errdefer starts.deinit(gpa);
    var g: Gsub = .{ .t = t, .lookup_list = lookup_list, .lookups = &.{}, .starts = starts };
    for (lookups.items) |li| g.markStarts(li);
    g.lookups = try lookups.toOwnedSlice(gpa);
    return g;
}

pub fn deinit(g: *Gsub, gpa: Allocator) void {
    gpa.free(g.lookups);
    g.starts.deinit(gpa);
    g.* = undefined;
}

/// Applies the ligatures to `glyphs` (a line's, one per cell) in place.
pub fn apply(g: *const Gsub, glyphs: []u16) void {
    const any = for (glyphs) |gl| {
        if (g.starts.isSet(gl)) break true;
    } else false;
    if (!any) return;
    for (g.lookups) |li| {
        var i: usize = 0;
        while (i < glyphs.len) {
            if (!g.starts.isSet(glyphs[i])) {
                i += 1;
                continue;
            }
            i += g.applyLookup(li, glyphs, i, 0) orelse 1;
        }
    }
}

// ---------------------------------------------------------------------------
// The font's tables

fn findTable(font: []const u8, tag: []const u8) ?[]const u8 {
    for (0..r16(font, 4)) |i| {
        const rec = 12 + 16 * i;
        if (rec + 16 > font.len) return null;
        if (!std.mem.eql(u8, font[rec .. rec + 4], tag)) continue;
        const off = r32(font, rec + 8);
        const len = r32(font, rec + 12);
        if (off + len > font.len) return null;
        return font[off .. off + len];
    }
    return null;
}

/// Big-endian reads; past the end reads 0 (a broken font matches nothing).
fn r16(t: []const u8, at: usize) u16 {
    if (at + 2 > t.len) return 0;
    return std.mem.readInt(u16, t[at..][0..2], .big);
}

fn r32(t: []const u8, at: usize) usize {
    if (at + 4 > t.len) return 0;
    return std.mem.readInt(u32, t[at..][0..4], .big);
}

/// A lookup's subtable `k`: its type and where it is (extensions unwrapped).
fn subtable(g: *const Gsub, lookup: usize, k: usize) struct { kind: u16, at: usize } {
    const kind = r16(g.t, lookup);
    const at = lookup + r16(g.t, lookup + 6 + 2 * k);
    if (kind != 7) return .{ .kind = kind, .at = at };
    return .{ .kind = r16(g.t, at + 2), .at = at + r32(g.t, at + 4) };
}

fn lookupAt(g: *const Gsub, li: usize) usize {
    return g.lookup_list + r16(g.t, g.lookup_list + 2 + 2 * li);
}

/// `glyph`'s index in coverage table `cov`, if it is in it.
fn coverage(g: *const Gsub, cov: usize, glyph: u16) ?u16 {
    const t = g.t;
    const n: usize = r16(t, cov + 2);
    switch (r16(t, cov)) {
        1 => {
            var lo: usize = 0;
            var hi = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const v = r16(t, cov + 4 + 2 * mid);
                if (v == glyph) return @intCast(mid);
                if (v < glyph) lo = mid + 1 else hi = mid;
            }
        },
        2 => {
            var lo: usize = 0;
            var hi = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = cov + 4 + 6 * mid;
                const start = r16(t, rec);
                const end = r16(t, rec + 2);
                if (glyph < start) {
                    hi = mid;
                } else if (glyph > end) {
                    lo = mid + 1;
                } else return r16(t, rec + 4) +% (glyph - start);
            }
        },
        else => {},
    }
    return null;
}

/// `glyph`'s class in class definition `cd` (0: none).
fn classOf(g: *const Gsub, cd: usize, glyph: u16) u16 {
    const t = g.t;
    switch (r16(t, cd)) {
        1 => {
            const first = r16(t, cd + 2);
            if (glyph >= first and glyph - first < r16(t, cd + 4)) return r16(t, cd + 6 + 2 * @as(usize, glyph - first));
        },
        2 => {
            var lo: usize = 0;
            var hi: usize = r16(t, cd + 2);
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = cd + 4 + 6 * mid;
                if (glyph < r16(t, rec)) {
                    hi = mid;
                } else if (glyph > r16(t, rec + 2)) {
                    lo = mid + 1;
                } else return r16(t, rec + 4);
            }
        },
        else => {},
    }
    return 0;
}

/// Marks the glyphs lookup `li` can start a match on.
fn markStarts(g: *Gsub, li: usize) void {
    const lookup = g.lookupAt(li);
    for (0..r16(g.t, lookup + 4)) |k| {
        const s = g.subtable(lookup, k);
        const format = r16(g.t, s.at);
        const cov: usize = switch (s.kind) {
            1 => s.at + r16(g.t, s.at + 2),
            5 => if (format == 3) s.at + r16(g.t, s.at + 6) else s.at + r16(g.t, s.at + 2),
            6 => if (format == 3) blk: {
                const back: usize = r16(g.t, s.at + 2);
                break :blk s.at + r16(g.t, s.at + 6 + 2 * back);
            } else s.at + r16(g.t, s.at + 2),
            else => continue,
        };
        g.markCoverage(cov);
    }
}

fn markCoverage(g: *Gsub, cov: usize) void {
    const n: usize = r16(g.t, cov + 2);
    switch (r16(g.t, cov)) {
        1 => for (0..n) |i| g.starts.set(r16(g.t, cov + 4 + 2 * i)),
        2 => for (0..n) |i| {
            const rec = cov + 4 + 6 * i;
            const start = r16(g.t, rec);
            const end = r16(g.t, rec + 2);
            if (start <= end) g.starts.setRangeValue(.{ .start = start, .end = @as(usize, end) + 1 }, true);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Applying lookups

/// Applies lookup `li` at `glyphs[i]`: the length of what it matched, or
/// null when nothing did.
fn applyLookup(g: *const Gsub, li: usize, glyphs: []u16, i: usize, depth: usize) ?usize {
    if (depth > max_depth) return null;
    const lookup = g.lookupAt(li);
    for (0..r16(g.t, lookup + 4)) |k| {
        const s = g.subtable(lookup, k);
        const matched = switch (s.kind) {
            1 => g.single(s.at, glyphs, i),
            5 => g.contextual(false, s.at, glyphs, i, depth),
            6 => g.contextual(true, s.at, glyphs, i, depth),
            else => null,
        };
        if (matched) |n| return n;
    }
    return null;
}

fn single(g: *const Gsub, at: usize, glyphs: []u16, i: usize) ?usize {
    const idx = g.coverage(at + r16(g.t, at + 2), glyphs[i]) orelse return null;
    switch (r16(g.t, at)) {
        1 => glyphs[i] +%= r16(g.t, at + 4), // a delta, modulo 65536
        2 => {
            if (idx >= r16(g.t, at + 4)) return null;
            glyphs[i] = r16(g.t, at + 6 + 2 * @as(usize, idx));
        },
        else => return null,
    }
    return 1;
}

/// How a rule names the glyphs it matches.
const Match = union(enum) {
    glyph,
    /// Classes of this class definition.
    class: usize,
    /// Coverage tables, at offsets from here.
    coverage: usize,
};

/// An array of `n` u16 values in the table.
const Seq = struct { at: usize, n: usize };

/// One rule of a (chained) context subtable.
const Rule = struct {
    back: Seq = .{ .at = 0, .n = 0 },
    back_by: Match = .glyph,
    /// Without the first glyph unless `first_listed` (format 3 lists it).
    input: Seq,
    input_by: Match,
    first_listed: bool = false,
    ahead: Seq = .{ .at = 0, .n = 0 },
    ahead_by: Match = .glyph,
    /// (sequence index, lookup index) pairs.
    records: Seq,
};

fn contextual(g: *const Gsub, chained: bool, at: usize, glyphs: []u16, i: usize, depth: usize) ?usize {
    const t = g.t;
    switch (r16(t, at)) {
        // By glyph, or by class: rule sets for the first glyph.
        1, 2 => |format| {
            const idx = g.coverage(at + r16(t, at + 2), glyphs[i]) orelse return null;
            var by: [3]Match = .{ .glyph, .glyph, .glyph };
            var set_index: usize = idx;
            var sets: Seq = undefined;
            if (format == 1) {
                sets = .{ .at = at + 6, .n = r16(t, at + 4) };
            } else if (chained) {
                by = .{ .{ .class = at + r16(t, at + 4) }, .{ .class = at + r16(t, at + 6) }, .{ .class = at + r16(t, at + 8) } };
                set_index = g.classOf(by[1].class, glyphs[i]);
                sets = .{ .at = at + 12, .n = r16(t, at + 10) };
            } else {
                by[1] = .{ .class = at + r16(t, at + 4) };
                set_index = g.classOf(by[1].class, glyphs[i]);
                sets = .{ .at = at + 8, .n = r16(t, at + 6) };
            }
            if (set_index >= sets.n) return null;
            const set_off = r16(t, sets.at + 2 * set_index);
            if (set_off == 0) return null;
            const set = at + set_off;
            for (0..r16(t, set)) |k| {
                var p = set + r16(t, set + 2 + 2 * k);
                var rule: Rule = undefined;
                if (chained) {
                    const back: Seq = .{ .at = p + 2, .n = r16(t, p) };
                    p += 2 + 2 * back.n;
                    const input: Seq = .{ .at = p + 2, .n = r16(t, p) -| 1 };
                    p += 2 + 2 * input.n;
                    const ahead: Seq = .{ .at = p + 2, .n = r16(t, p) };
                    p += 2 + 2 * ahead.n;
                    rule = .{ .back = back, .back_by = by[0], .input = input, .input_by = by[1], .ahead = ahead, .ahead_by = by[2], .records = .{ .at = p + 2, .n = r16(t, p) } };
                } else {
                    const input: Seq = .{ .at = p + 4, .n = r16(t, p) -| 1 };
                    rule = .{ .input = input, .input_by = by[1], .records = .{ .at = input.at + 2 * input.n, .n = r16(t, p + 2) } };
                }
                if (g.tryRule(rule, glyphs, i, depth)) |n| return n;
            }
            return null;
        },
        // By coverage, one rule.
        3 => {
            var rule: Rule = undefined;
            if (chained) {
                var p = at + 2;
                const back: Seq = .{ .at = p + 2, .n = r16(t, p) };
                p += 2 + 2 * back.n;
                const input: Seq = .{ .at = p + 2, .n = r16(t, p) };
                p += 2 + 2 * input.n;
                const ahead: Seq = .{ .at = p + 2, .n = r16(t, p) };
                p += 2 + 2 * ahead.n;
                rule = .{ .back = back, .back_by = .{ .coverage = at }, .input = input, .input_by = .{ .coverage = at }, .first_listed = true, .ahead = ahead, .ahead_by = .{ .coverage = at }, .records = .{ .at = p + 2, .n = r16(t, p) } };
            } else {
                const input: Seq = .{ .at = at + 6, .n = r16(t, at + 2) };
                rule = .{ .input = input, .input_by = .{ .coverage = at }, .first_listed = true, .records = .{ .at = input.at + 2 * input.n, .n = r16(t, at + 4) } };
            }
            return g.tryRule(rule, glyphs, i, depth);
        },
        else => return null,
    }
}

fn matches(g: *const Gsub, by: Match, value: u16, glyph: u16) bool {
    return switch (by) {
        .glyph => value == glyph,
        .class => |cd| g.classOf(cd, glyph) == value,
        .coverage => |base| g.coverage(base + value, glyph) != null,
    };
}

/// `rule` at `glyphs[i]`: when it matches, its lookups are applied and the
/// input's length returned.
fn tryRule(g: *const Gsub, rule: Rule, glyphs: []u16, i: usize, depth: usize) ?usize {
    const t = g.t;
    const len = rule.input.n + @intFromBool(!rule.first_listed);
    if (len == 0 or i + len + rule.ahead.n > glyphs.len or rule.back.n > i) return null;
    const first: usize = @intFromBool(!rule.first_listed);
    for (0..rule.input.n) |k| {
        if (!g.matches(rule.input_by, r16(t, rule.input.at + 2 * k), glyphs[i + first + k])) return null;
    }
    // Backtrack runs backwards from the glyph before.
    for (0..rule.back.n) |k| {
        if (!g.matches(rule.back_by, r16(t, rule.back.at + 2 * k), glyphs[i - 1 - k])) return null;
    }
    for (0..rule.ahead.n) |k| {
        if (!g.matches(rule.ahead_by, r16(t, rule.ahead.at + 2 * k), glyphs[i + len + k])) return null;
    }
    for (0..rule.records.n) |k| {
        const seq: usize = r16(t, rule.records.at + 4 * k);
        const li = r16(t, rule.records.at + 4 * k + 2);
        if (seq < len) _ = g.applyLookup(li, glyphs, i + seq, depth + 1);
    }
    return len;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

extern fn zile_ttf_open(data: [*]const u8, pixel_height: c_int) ?*anyopaque;
extern fn zile_ttf_close(f: *anyopaque) void;
extern fn zile_ttf_glyph(f: *const anyopaque, codepoint: c_int) c_int;

test "JetBrains Mono: -> != => become ligatures, letters don't" {
    const path = "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf";
    const io = testing.io;
    const font = std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .unlimited) catch return error.SkipZigTest;
    defer testing.allocator.free(font);
    var g = (try init(testing.allocator, font)).?;
    defer g.deinit(testing.allocator);
    const ttf = zile_ttf_open(font.ptr, 16).?;
    defer zile_ttf_close(ttf);

    const shaped = struct {
        fn f(gs: *const Gsub, f_: *anyopaque, s: []const u8, out: []u16) []const u16 {
            for (s, 0..) |ch, i| out[i] = @intCast(zile_ttf_glyph(f_, ch));
            gs.apply(out[0..s.len]);
            return out[0..s.len];
        }
    }.f;
    const plain = struct {
        fn f(f_: *anyopaque, ch: u8) u16 {
            return @intCast(zile_ttf_glyph(f_, ch));
        }
    }.f;
    var buf: [16]u16 = undefined;
    for ([_][]const u8{ "->", "!=", "=>", "<=" }) |lig| {
        const out = shaped(&g, ttf, lig, &buf);
        // Both cells change: a spacer, then the ligature reaching back.
        try testing.expect(out[0] != plain(ttf, lig[0]));
        try testing.expect(out[1] != plain(ttf, lig[1]));
    }
    // Plain text, and a lone `-`, stay as they are.
    const text = shaped(&g, ttf, "ab - c", &buf);
    for ("ab - c", text) |ch, gl| try testing.expectEqual(plain(ttf, ch), gl);
    // Inside a line: only the ligature's cells.
    const line = shaped(&g, ttf, "a -> b", &buf);
    try testing.expectEqual(plain(ttf, 'a'), line[0]);
    try testing.expect(line[2] != plain(ttf, '-') and line[3] != plain(ttf, '>'));
    try testing.expectEqual(plain(ttf, 'b'), line[5]);
}
