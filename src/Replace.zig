//! Find and replace across a project: `SPC c`, or `<C-r>` in the grep
//! picker (`SPC /`).
//!
//! A form with two fields, what to find and what to put there, searched
//! again by `rg` in the background as either is typed. rg does the matching
//! and writes each replacement (`rg --json --replace`), so a regex and its
//! groups (`$1`) mean exactly what they mean to rg. Plain text unless regex
//! is switched on (`<C-r>`); `<C-b>` matches whole words only; an uppercase
//! letter makes the search case-sensitive (smart case).
//!
//! Every match shows its line as it is and as it will be. `<C-x>` skips a
//! line, `<C-f>` a whole file, `Enter` replaces the rest: each file is
//! opened and changed as one undo step, and a match whose text has changed
//! since the search is left alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const LineInput = @import("input/LineInput.zig");

const Replace = @This();

/// One match in a line: its bytes in the line, and what goes there.
pub const Sub = struct { start: u32, end: u32, with: []const u8 };

/// A line with matches on it (one row of the list).
pub const Match = struct {
    /// Relative to `root`.
    path: []const u8,
    /// 0-based.
    line: u32,
    /// The line, without its line ending.
    text: []const u8,
    /// Ascending, not overlapping.
    subs: []const Sub,
    skip: bool = false,
};

/// More matches than this are not listed (nor replaced).
pub const max_matches = 10_000;
/// Lines longer than this (minified files) are left out.
const max_line = 16 * 1024;

pub const Options = struct {
    /// The search is a regex (rg's), the replacement may name its groups.
    regex: bool = false,
    /// Whole words only.
    word: bool = false,
};

pub const Field = enum { find, with };

gpa: Allocator,
io: Io,
/// The folder searched (owned).
root: []u8,
wake: *const fn () void,
options: Options = .{},
/// What to find, as typed. (The replacement is the prompt's own input.)
find: LineInput = .{},
/// The field that is typed into.
field: Field = .find,
/// Opened from the grep picker: `<Esc>` goes back to it.
from_grep: bool = false,
/// The search whose matches are listed, and the one still running for
/// what has been typed since.
shown: ?*Job = null,
running: ?*Job = null,
/// Searches overtaken by typing, until their rg has gone.
retired: std.ArrayList(*Job) = .empty,
/// The selected line, and the first one shown (maintained by the view).
selected: usize = 0,
top: usize = 0,

/// One run of rg, on its own thread. Everything it finds lives in `arena`.
const Job = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    find: []const u8,
    with: []const u8,
    options: Options,
    wake: *const fn () void,
    thread: std.Thread = undefined,
    joined: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    pid: std.atomic.Value(std.posix.pid_t) = .init(0),
    /// Valid once `done`.
    matches: std.ArrayList(Match) = .empty,
    count: usize = 0,
    /// There were more than `max_matches`.
    truncated: bool = false,
    /// rg isn't installed, or failed.
    failed: bool = false,
    /// What rg said about the search (a regex it can't read).
    err: ?[]const u8 = null,

    fn start(r: *const Replace, find: []const u8, with: []const u8) !*Job {
        const j = try r.gpa.create(Job);
        errdefer r.gpa.destroy(j);
        j.* = .{ .gpa = r.gpa, .io = r.io, .arena = .init(r.gpa), .root = undefined, .find = undefined, .with = undefined, .options = r.options, .wake = r.wake };
        errdefer j.arena.deinit();
        const a = j.arena.allocator();
        j.root = try a.dupe(u8, r.root);
        j.find = try a.dupe(u8, find);
        j.with = try a.dupe(u8, with);
        j.thread = try std.Thread.spawn(.{}, run, .{j});
        return j;
    }

    /// Typing overtook it: rg is stopped, the thread ends soon after.
    fn stop(j: *Job) void {
        j.cancel.store(true, .release);
        const pid = j.pid.load(.acquire);
        if (pid != 0) std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    }

    fn join(j: *Job) void {
        if (j.joined) return;
        j.thread.join();
        j.joined = true;
    }

    fn destroy(j: *Job) void {
        j.join();
        j.arena.deinit();
        j.gpa.destroy(j);
    }

    fn isDone(j: *const Job) bool {
        return j.done.load(.acquire);
    }

    fn same(j: *const Job, find: []const u8, with: []const u8, options: Options) bool {
        return j.sameSearch(find, options) and std.mem.eql(u8, j.with, with);
    }

    fn sameSearch(j: *const Job, find: []const u8, options: Options) bool {
        return std.mem.eql(u8, j.find, find) and j.options.regex == options.regex and j.options.word == options.word;
    }

    fn run(j: *Job) void {
        defer {
            j.done.store(true, .release);
            j.wake();
        }
        j.search() catch {
            j.failed = true;
        };
    }

    fn search(j: *Job) !void {
        const a = j.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        // --no-messages: not the files it can't read (a regex it can't read
        // is still reported).
        // --no-hidden: never in dot files and folders (`.zig-cache`, `.git`),
        // even when the user's own rg config searches them.
        try argv.appendSlice(a, &.{ "rg", "--json", "--no-require-git", "--no-messages", "--smart-case", "--no-hidden" });
        if (!j.options.regex) try argv.append(a, "--fixed-strings");
        if (j.options.word) try argv.append(a, "--word-regexp");
        try argv.append(a, try std.fmt.allocPrint(a, "--regexp={s}", .{j.find}));
        try argv.append(a, try std.fmt.allocPrint(a, "--replace={s}", .{try replacementArg(a, j.with, j.options.regex)}));

        var child = try std.process.spawn(j.io, .{ .argv = argv.items, .cwd = .{ .path = j.root }, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
        j.pid.store(child.id.?, .release);
        defer {
            j.pid.store(0, .release);
            child.kill(j.io);
        }
        var scratch: std.heap.ArenaAllocator = .init(j.gpa);
        defer scratch.deinit();
        const out = child.stdout.?;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(j.gpa);
        var chunk: [64 * 1024]u8 = undefined;
        reading: while (true) {
            if (j.cancel.load(.acquire)) return;
            const n = out.readStreaming(j.io, &.{&chunk}) catch break;
            try buf.appendSlice(j.gpa, chunk[0..n]);
            var from: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buf.items, from, '\n')) |end| {
                defer from = end + 1;
                _ = scratch.reset(.retain_capacity);
                try j.addRecord(scratch.allocator(), buf.items[from..end]);
                if (j.truncated) break :reading;
            }
            buf.replaceRangeAssumeCapacity(0, from, &.{});
        }
        if (j.cancel.load(.acquire)) return;
        if (j.matches.items.len == 0) {
            // Nothing found: perhaps because rg could not read the search.
            const n = child.stderr.?.readStreaming(j.io, &.{&chunk}) catch 0;
            j.err = try complaint(a, chunk[0..n]);
        }
        sort(j.matches.items);
    }

    /// One line of `rg --json`: a line with matches, or something else.
    fn addRecord(j: *Job, scratch: Allocator, record: []const u8) !void {
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch, record, .{}) catch return;
        if (!std.mem.eql(u8, string(v, "type") orelse return, "match")) return;
        const data = member(v, "data") orelse return;
        // (A path or line that isn't UTF-8 comes as `bytes`: left out.)
        var path = string(member(data, "path") orelse return, "text") orelse return;
        if (std.mem.startsWith(u8, path, "./")) path = path[2..];
        const text = std.mem.trimEnd(u8, string(member(data, "lines") orelse return, "text") orelse return, "\r\n");
        if (text.len > max_line) return;
        const line = integer(data, "line_number") orelse return;
        const found = member(data, "submatches") orelse return;
        if (found != .array or line == 0) return;

        const a = j.arena.allocator();
        var subs: std.ArrayList(Sub) = .empty;
        var after: usize = 0;
        for (found.array.items) |sm| {
            const from = integer(sm, "start") orelse continue;
            const to = integer(sm, "end") orelse continue;
            // (A match of nothing, as `x*` finds everywhere, replaces nothing.)
            if (from < after or to <= from or to > text.len) continue;
            const with = string(member(sm, "replacement") orelse continue, "text") orelse continue;
            if (j.count == max_matches) {
                j.truncated = true;
                break;
            }
            try subs.append(a, .{ .start = @intCast(from), .end = @intCast(to), .with = try a.dupe(u8, with) });
            j.count += 1;
            after = to;
        }
        if (subs.items.len == 0) return;
        try j.matches.append(a, .{
            .path = try a.dupe(u8, path),
            .line = @intCast(line - 1),
            .text = try a.dupe(u8, text),
            .subs = subs.items,
        });
    }
};

fn member(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}

fn string(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = member(v, name) orelse return null;
    return if (f == .string) f.string else null;
}

fn integer(v: std.json.Value, name: []const u8) ?usize {
    const f = member(v, name) orelse return null;
    return if (f == .integer and f.integer >= 0) @intCast(f.integer) else null;
}

/// Top to bottom, file by file (rg searches files in any order).
fn sort(rows: []Match) void {
    std.mem.sort(Match, rows, {}, struct {
        fn less(_: void, a: Match, b: Match) bool {
            const o = std.mem.order(u8, a.path, b.path);
            return if (o != .eq) o == .lt else a.line < b.line;
        }
    }.less);
}

/// The replacement as rg wants it. Plain text: every `$` is just a `$`.
/// A regex's: `$1` becomes `${1}`, so that `$1_x` is group 1 and `_x` (rg
/// alone reads a group named `1_x`, which is empty).
fn replacementArg(a: Allocator, with: []const u8, regex: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < with.len) : (i += 1) {
        if (with[i] != '$') {
            try out.append(a, with[i]);
            continue;
        }
        if (!regex) {
            try out.appendSlice(a, "$$");
            continue;
        }
        var end = i + 1;
        while (end < with.len and std.ascii.isDigit(with[end])) end += 1;
        if (end > i + 1) {
            try out.print(a, "${{{s}}}", .{with[i + 1 .. end]});
            i = end - 1;
        } else if (i + 1 < with.len and with[i + 1] == '$') {
            try out.appendSlice(a, "$$");
            i += 1;
        } else try out.append(a, '$');
    }
    return out.items;
}

/// What rg said was wrong with the search: the last line it printed,
/// without its "error: ".
fn complaint(a: Allocator, stderr: []const u8) !?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, stderr, '\n');
    while (lines.next()) |l| {
        var line = std.mem.trim(u8, l, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "error: ")) line = line["error: ".len..];
        return try a.dupe(u8, line);
    }
    return null;
}

pub fn create(gpa: Allocator, io: Io, root: []const u8, wake: *const fn () void) !*Replace {
    const r = try gpa.create(Replace);
    errdefer gpa.destroy(r);
    r.* = .{ .gpa = gpa, .io = io, .root = try gpa.dupe(u8, root), .wake = wake };
    return r;
}

pub fn destroy(r: *Replace) void {
    if (r.running) |j| {
        j.stop();
        j.destroy();
    }
    if (r.shown) |j| j.destroy();
    for (r.retired.items) |j| j.destroy();
    r.retired.deinit(r.gpa);
    r.find.deinit(r.gpa);
    r.gpa.free(r.root);
    r.gpa.destroy(r);
}

/// Searches for what is in `find` now, to be replaced by `with` (unless
/// that is what the last search was for). The matches listed stay until the
/// new ones are in (`poll`).
pub fn search(r: *Replace, with: []const u8) !void {
    const find = r.find.items();
    if (r.running orelse r.shown) |j| if (j.same(find, with, r.options)) return;
    try r.retired.ensureUnusedCapacity(r.gpa, 1);
    if (find.len == 0) {
        r.retire();
        if (r.shown) |j| j.destroy();
        r.shown = null;
        r.selected = 0;
        r.top = 0;
        return;
    }
    const j = try Job.start(r, find, with);
    r.retire();
    r.running = j;
}

fn retire(r: *Replace) void {
    const j = r.running orelse return;
    r.running = null;
    j.stop();
    r.retired.appendAssumeCapacity(j);
}

/// Takes the matches of a search that has finished. Lines skipped stay
/// skipped while only the replacement changes.
pub fn poll(r: *Replace) void {
    var i: usize = r.retired.items.len;
    while (i > 0) {
        i -= 1;
        if (r.retired.items[i].isDone()) r.retired.swapRemove(i).destroy();
    }
    const j = r.running orelse return;
    if (!j.isDone()) return;
    r.running = null;
    j.join();
    if (r.shown) |old| {
        if (old.sameSearch(j.find, j.options)) keepSkips(old.matches.items, j.matches.items) else {
            r.selected = 0;
            r.top = 0;
        }
        old.destroy();
    }
    r.shown = j;
    r.selected = @min(r.selected, j.matches.items.len -| 1);
}

/// Both sorted the same way.
fn keepSkips(old: []const Match, new: []Match) void {
    var i: usize = 0;
    for (new) |*m| {
        while (i < old.len) : (i += 1) {
            const o = std.mem.order(u8, old[i].path, m.path);
            if (o == .gt or (o == .eq and old[i].line >= m.line)) break;
        }
        if (i == old.len) return;
        if (old[i].line == m.line and std.mem.eql(u8, old[i].path, m.path)) m.skip = old[i].skip;
    }
}

/// Waits for the search that is running, and takes its matches.
pub fn wait(r: *Replace) void {
    if (r.running) |j| j.join();
    r.poll();
}

pub fn busy(r: *const Replace) bool {
    return r.running != null;
}

/// The lines with matches, top to bottom, file by file.
pub fn matches(r: *const Replace) []Match {
    return if (r.shown) |j| j.matches.items else &.{};
}

pub fn truncated(r: *const Replace) bool {
    return if (r.shown) |j| j.truncated else false;
}

pub fn failed(r: *const Replace) bool {
    return if (r.shown) |j| j.failed else false;
}

/// What rg could not read in the search (a regex half typed).
pub fn complaintOf(r: *const Replace) ?[]const u8 {
    return if (r.shown) |j| j.err else null;
}

/// Matches still to be replaced, and the files they are in.
pub fn counts(r: *const Replace) struct { matches: usize, files: usize } {
    var n: usize = 0;
    var files: usize = 0;
    var last: ?[]const u8 = null;
    for (r.matches()) |m| {
        if (m.skip) continue;
        n += m.subs.len;
        if (last == null or !std.mem.eql(u8, last.?, m.path)) files += 1;
        last = m.path;
    }
    return .{ .matches = n, .files = files };
}

/// `<C-x>`: skips the selected line (or takes it back), and moves on.
pub fn toggle(r: *Replace) void {
    const rows = r.matches();
    if (r.selected >= rows.len) return;
    rows[r.selected].skip = !rows[r.selected].skip;
    if (r.selected + 1 < rows.len) r.selected += 1;
}

/// `<C-f>`: every match in the selected one's file, skipped or taken back.
pub fn toggleFile(r: *Replace) void {
    const rows = r.matches();
    if (r.selected >= rows.len) return;
    const path = rows[r.selected].path;
    const skip = !rows[r.selected].skip;
    for (rows) |*m| if (std.mem.eql(u8, m.path, path)) {
        m.skip = skip;
    };
}

pub fn move(r: *Replace, delta: isize) void {
    const n = r.matches().len;
    if (n == 0) return;
    const i: isize = @intCast(r.selected);
    r.selected = @intCast(@mod(i + delta, @as(isize, @intCast(n))));
}

/// Whether `line` (the line as it is now) still has what `s` matched, where
/// it was.
pub fn stillThere(m: Match, s: Sub, line: []const u8) bool {
    return s.end <= line.len and std.mem.eql(u8, line[s.start..s.end], m.text[s.start..s.end]);
}

/// The line of `m` with its matches replaced (the preview). Caller frees.
pub fn previewLine(gpa: Allocator, m: Match) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    for (m.subs) |s| {
        try out.appendSlice(gpa, m.text[i..s.start]);
        try out.appendSlice(gpa, s.with);
        i = s.end;
    }
    try out.appendSlice(gpa, m.text[i..]);
    return out.toOwnedSlice(gpa);
}

fn testJob(gpa: Allocator) Job {
    return .{ .gpa = gpa, .io = std.testing.io, .arena = .init(gpa), .root = ".", .find = "", .with = "", .options = .{}, .wake = undefined, .joined = true };
}

test "rg's matches, sorted, and replaced lines" {
    const gpa = std.testing.allocator;
    var j = testJob(gpa);
    defer j.arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    // Two matches on one line of b.zig, one in a.zig; other records ignored.
    const records = [_][]const u8{
        \\{"type":"begin","data":{"path":{"text":"./b.zig"}}}
        ,
        \\{"type":"match","data":{"path":{"text":"./b.zig"},"lines":{"text":"x = Foo(foo);\r\n"},"line_number":3,"absolute_offset":0,"submatches":[{"match":{"text":"Foo"},"replacement":{"text":"bar"},"start":4,"end":7},{"match":{"text":"foo"},"replacement":{"text":"bar"},"start":8,"end":11}]}}
        ,
        \\{"type":"match","data":{"path":{"text":"a.zig"},"lines":{"text":"foo\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"foo"},"replacement":{"text":"bar"},"start":0,"end":3}]}}
        ,
        "not json",
    };
    for (records) |rec| try j.addRecord(scratch.allocator(), rec);
    sort(j.matches.items);
    var r: Replace = .{ .gpa = gpa, .io = std.testing.io, .root = undefined, .wake = undefined, .shown = &j };
    try std.testing.expectEqual(2, r.matches().len);
    try std.testing.expectEqualStrings("a.zig", r.matches()[0].path);
    const b = r.matches()[1];
    try std.testing.expectEqualStrings("b.zig", b.path);
    try std.testing.expectEqual(2, b.line);
    try std.testing.expectEqualStrings("x = Foo(foo);", b.text);
    const p = try previewLine(gpa, b);
    defer gpa.free(p);
    try std.testing.expectEqualStrings("x = bar(bar);", p);
    try std.testing.expect(stillThere(b, b.subs[1], "x = Foo(foo); // more"));
    try std.testing.expect(!stillThere(b, b.subs[1], "x = Foo(fox);"));
    try std.testing.expectEqual(3, r.counts().matches);
    try std.testing.expectEqual(2, r.counts().files);
    r.selected = 1;
    r.toggleFile();
    try std.testing.expectEqual(1, r.counts().matches);
}

test "the replacement, as rg wants it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Plain text: a `$` is a `$`.
    try std.testing.expectEqualStrings("$$1 and $$", try replacementArg(a, "$1 and $", false));
    // A regex: numbered groups end where the digits do.
    try std.testing.expectEqualStrings("${1}_x ${12} $$ ${name} $", try replacementArg(a, "$1_x $12 $$ ${name} $", true));
}

test "skipped lines stay skipped when only the replacement changes" {
    const old = [_]Match{
        .{ .path = "a", .line = 1, .text = "", .subs = &.{} },
        .{ .path = "a", .line = 4, .text = "", .subs = &.{}, .skip = true },
        .{ .path = "c", .line = 0, .text = "", .subs = &.{}, .skip = true },
    };
    var new = [_]Match{
        .{ .path = "a", .line = 4, .text = "", .subs = &.{} },
        .{ .path = "b", .line = 0, .text = "", .subs = &.{} },
        .{ .path = "c", .line = 0, .text = "", .subs = &.{} },
    };
    keepSkips(&old, &new);
    try std.testing.expect(new[0].skip);
    try std.testing.expect(!new[1].skip);
    try std.testing.expect(new[2].skip);
}

test "what rg says about a regex it can't read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const said = "rg: regex parse error:\n    (?:foo()\n    ^\nerror: unclosed group\n";
    try std.testing.expectEqualStrings("unclosed group", (try complaint(arena.allocator(), said)).?);
    try std.testing.expectEqual(null, try complaint(arena.allocator(), ""));
}
