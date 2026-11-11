//! Search and replace across a project: `<C-r>` in the grep picker (`SPC /`).
//!
//! The picker's query becomes the search, matched exactly (smart case: an
//! uppercase letter makes it case-sensitive) by `rg` in the background. The
//! replacement is typed into a prompt box; every match shows its line as it
//! is and as it will be. `Tab` skips a match, `S-Tab` a whole file, `Enter`
//! replaces the rest: each file is opened and changed as one undo step, and
//! a match whose text has changed since the search is left alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Replace = @This();

/// A line with matches on it (one row of the list).
pub const Match = struct {
    /// Relative to `root`.
    path: []u8,
    /// 0-based.
    line: u32,
    /// Byte offsets of the matches in the line, ascending (owned).
    cols: []u32,
    /// The line as rg printed it (owned; may be cut short).
    text: []u8,
    skip: bool = false,
};

/// More matches than this are not listed (nor replaced).
pub const max_matches = 10_000;

gpa: Allocator,
io: Io,
/// What to find (owned).
needle: []u8,
/// The folder searched (owned): the picker's project.
root: []u8,
case_sensitive: bool,
wake: *const fn () void,
thread: std.Thread = undefined,
done: std.atomic.Value(bool) = .init(false),
joined: bool = false,
/// Valid once `done`.
matches: std.ArrayList(Match) = .empty,
/// There were more than `max_matches`.
truncated: bool = false,
/// rg isn't installed, or failed.
failed: bool = false,
/// The selected match, and the first match row shown (maintained by the view).
selected: usize = 0,
top: usize = 0,

pub fn start(gpa: Allocator, io: Io, needle: []const u8, root: []const u8, wake: *const fn () void) !*Replace {
    const r = try gpa.create(Replace);
    errdefer gpa.destroy(r);
    const n = try gpa.dupe(u8, needle);
    errdefer gpa.free(n);
    const ro = try gpa.dupe(u8, root);
    errdefer gpa.free(ro);
    r.* = .{
        .gpa = gpa,
        .io = io,
        .needle = n,
        .root = ro,
        .case_sensitive = hasUpper(needle),
        .wake = wake,
    };
    r.thread = try std.Thread.spawn(.{}, run, .{r});
    return r;
}

pub fn wait(r: *Replace) void {
    if (r.joined) return;
    r.thread.join();
    r.joined = true;
}

pub fn destroy(r: *Replace) void {
    r.wait();
    r.freeMatches();
    r.gpa.free(r.needle);
    r.gpa.free(r.root);
    r.gpa.destroy(r);
}

fn freeMatches(r: *Replace) void {
    for (r.matches.items) |m| {
        r.gpa.free(m.path);
        r.gpa.free(m.cols);
        r.gpa.free(m.text);
    }
    r.matches.deinit(r.gpa);
}

pub fn isDone(r: *const Replace) bool {
    return r.done.load(.acquire);
}

fn hasUpper(s: []const u8) bool {
    for (s) |b| if (std.ascii.isUpper(b)) return true;
    return false;
}

fn run(r: *Replace) void {
    defer {
        r.done.store(true, .release);
        r.wake();
    }
    const res = std.process.run(r.gpa, r.io, .{
        .argv = &.{
            "rg",                 "--null",       "--vimgrep", "--fixed-strings", "--no-require-git", "--color=never",
            if (r.case_sensitive) "--case-sensitive" else "--ignore-case",
            "--max-columns=400",  "--max-columns-preview",
            "-e",                 r.needle,
        },
        .cwd = .{ .path = r.root },
    }) catch {
        r.failed = true;
        return;
    };
    defer r.gpa.free(res.stdout);
    defer r.gpa.free(res.stderr);
    // 1: no matches. 2: an error (but it may still have found some).
    if (res.term != .exited or res.term.exited > 2) {
        r.failed = true;
        return;
    }
    r.parse(res.stdout) catch {};
}

/// `path\0line:col:text` per match (`rg --null --vimgrep`): the lines with
/// matches, top to bottom, file by file.
fn parse(r: *Replace, out: []const u8) !void {
    const One = struct { path: []const u8, line: u32, col: u32, text: []const u8 };
    var all: std.ArrayList(One) = .empty;
    defer all.deinit(r.gpa);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |rec| {
        if (rec.len == 0) continue;
        if (all.items.len >= max_matches) {
            r.truncated = true;
            break;
        }
        const nul = std.mem.indexOfScalar(u8, rec, 0) orelse continue;
        var it = std.mem.splitScalar(u8, rec[nul + 1 ..], ':');
        const line = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        const col = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        var path = rec[0..nul];
        if (std.mem.startsWith(u8, path, "./")) path = path[2..];
        try all.append(r.gpa, .{ .path = path, .line = line -| 1, .col = col -| 1, .text = std.mem.trimEnd(u8, it.rest(), "\r") });
    }
    std.mem.sort(One, all.items, {}, struct {
        fn less(_: void, a: One, b: One) bool {
            const o = std.mem.order(u8, a.path, b.path);
            if (o != .eq) return o == .lt;
            return if (a.line != b.line) a.line < b.line else a.col < b.col;
        }
    }.less);
    var i: usize = 0;
    while (i < all.items.len) {
        const first = all.items[i];
        var j = i + 1;
        while (j < all.items.len and all.items[j].line == first.line and std.mem.eql(u8, all.items[j].path, first.path)) j += 1;
        const cols = try r.gpa.alloc(u32, j - i);
        errdefer r.gpa.free(cols);
        for (all.items[i..j], cols) |o, *c| c.* = o.col;
        const p = try r.gpa.dupe(u8, first.path);
        errdefer r.gpa.free(p);
        const t = try r.gpa.dupe(u8, first.text);
        errdefer r.gpa.free(t);
        try r.matches.append(r.gpa, .{ .path = p, .line = first.line, .cols = cols, .text = t });
        i = j;
    }
}

/// Matches still to be replaced, and the files they are in.
pub fn counts(r: *const Replace) struct { matches: usize, files: usize } {
    var n: usize = 0;
    var files: usize = 0;
    var last: ?[]const u8 = null;
    for (r.matches.items) |m| {
        if (m.skip) continue;
        n += m.cols.len;
        if (last == null or !std.mem.eql(u8, last.?, m.path)) files += 1;
        last = m.path;
    }
    return .{ .matches = n, .files = files };
}

/// `Tab`: skips the selected line (or takes it back), and moves on.
pub fn toggle(r: *Replace) void {
    if (r.selected >= r.matches.items.len) return;
    const m = &r.matches.items[r.selected];
    m.skip = !m.skip;
    if (r.selected + 1 < r.matches.items.len) r.selected += 1;
}

/// `S-Tab`: every match in the selected one's file, skipped or taken back.
pub fn toggleFile(r: *Replace) void {
    if (r.selected >= r.matches.items.len) return;
    const path = r.matches.items[r.selected].path;
    const skip = !r.matches.items[r.selected].skip;
    for (r.matches.items) |*m| if (std.mem.eql(u8, m.path, path)) {
        m.skip = skip;
    };
}

pub fn move(r: *Replace, delta: isize) void {
    const n = r.matches.items.len;
    if (n == 0) return;
    const i: isize = @intCast(r.selected);
    r.selected = @intCast(@mod(i + delta, @as(isize, @intCast(n))));
}

/// Whether `text` at `at` is the needle (in either case without smart
/// case's uppercase).
pub fn matchesAt(r: *const Replace, text: []const u8, at: usize) bool {
    if (at + r.needle.len > text.len) return false;
    const got = text[at..][0..r.needle.len];
    return if (r.case_sensitive) std.mem.eql(u8, got, r.needle) else std.ascii.eqlIgnoreCase(got, r.needle);
}

/// The line of `m` with its matches replaced (the preview). Caller frees.
pub fn previewLine(r: *const Replace, gpa: Allocator, m: Match, replacement: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    for (m.cols) |c| {
        if (c < i or !r.matchesAt(m.text, c)) continue;
        try out.appendSlice(gpa, m.text[i..c]);
        try out.appendSlice(gpa, replacement);
        i = c + r.needle.len;
    }
    try out.appendSlice(gpa, m.text[@min(i, m.text.len)..]);
    return out.toOwnedSlice(gpa);
}

test "rg's matches, sorted, and replaced lines" {
    const gpa = std.testing.allocator;
    var r: Replace = .{
        .gpa = gpa,
        .io = std.testing.io,
        .needle = try gpa.dupe(u8, "foo"),
        .root = try gpa.dupe(u8, "."),
        .case_sensitive = false,
        .wake = undefined,
        .joined = true,
    };
    defer {
        r.freeMatches();
        gpa.free(r.needle);
        gpa.free(r.root);
    }
    // Two matches on one line of b.zig (one of them `Foo`), one in a.zig.
    try r.parse("./b.zig\x003:5:x = Foo(foo);\nb.zig\x003:9:x = Foo(foo);\na.zig\x001:1:foo\n");
    try std.testing.expectEqual(2, r.matches.items.len);
    try std.testing.expectEqualStrings("a.zig", r.matches.items[0].path);
    const b = r.matches.items[1];
    try std.testing.expectEqualStrings("b.zig", b.path);
    try std.testing.expectEqual(2, b.line);
    try std.testing.expectEqualSlices(u32, &.{ 4, 8 }, b.cols);
    const p = try r.previewLine(gpa, b, "bar");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("x = bar(bar);", p);
    try std.testing.expectEqual(3, r.counts().matches);
    try std.testing.expectEqual(2, r.counts().files);
    r.selected = 1;
    r.toggleFile();
    try std.testing.expectEqual(1, r.counts().matches);
}
