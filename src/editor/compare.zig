//! Side by side: a file as it was (left, read-only) beside the file as it
//! is (right), in two windows that scroll together. Changed lines are
//! tinted; where one side has more lines than the other, the other shows
//! blank rows, so the same line of code is at the same height on both.
//!
//! The file against HEAD: the right side is the file itself, to work in as
//! always. A commit against the one before it: both sides are read-only.
//!
//! Each side is a buffer whose diff (`Buffer.git`) is against the other
//! side's text, so both know the same changes; the blank rows are the rows
//! `row_model` already has for a change's old lines, here empty and only as
//! many as this side is short.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Text = @import("../core/Text.zig");
const Syntax = @import("../syntax/Syntax.zig");
const Git = @import("../git/Git.zig");
const diff = @import("../git/diff.zig");
const motions = @import("../core/motions.zig");
const Windows = @import("../Windows.zig");
const Editor = @import("../Editor.zig");
const window_ops = @import("window_ops.zig");
const git_ops = @import("git_ops.zig");
const blame = @import("blame.zig");
const row_model = @import("row_model.zig");

/// The pair on screen.
pub const Pair = struct {
    left: *Windows.Window,
    right: *Windows.Window,
    /// The left side's buffer: ours, closed with the pair.
    old: *Buffer,
    /// The right side's: the file's, or (a commit) ours too.
    new: *Buffer,
    new_owned: bool = false,
    /// What the right window showed before a commit took it.
    back: ?*Buffer = null,
    /// The right side's `edit_version` the left side's diff was made for.
    seen: u64,
    /// Whether the right side's lines were kept from wrapping before (both
    /// sides are while this is up: a wrapped line is a row the other side
    /// doesn't have).
    new_no_wrap: bool = false,
};

/// A row of one side: a line, or blank row `filler` of those before it.
pub const Place = struct { line: usize, filler: ?u32 = null };

/// Where the row `p` of one side is on the other. `hunks`: that side's
/// diff (its lines are the new ones, the other side's the old).
pub fn across(hunks: []const diff.Hunk, p: Place) Place {
    var delta: isize = 0;
    for (hunks) |h| {
        const end = h.new_start + h.new_count;
        if (p.filler) |k| {
            // Blank rows here are the lines the other side has more of.
            if (end == p.line and h.old_count > h.new_count) return .{ .line = h.old_start + h.new_count + k };
        } else if (p.line >= h.new_start and p.line < end) {
            const o = p.line - h.new_start;
            if (o < h.old_count) return .{ .line = h.old_start + o };
            // More lines here than there: the other side's blank rows.
            return .{ .line = h.old_start + h.old_count, .filler = @intCast(o - h.old_count) };
        }
        if (h.new_start > p.line or end > p.line) break;
        delta = @as(isize, @intCast(h.old_start + h.old_count)) - @as(isize, @intCast(end));
    }
    return .{ .line = @intCast(@max(@as(isize, @intCast(p.line)) + delta, 0)) };
}

fn has(ed: *const Editor, b: *const Buffer) bool {
    for (ed.buffers.items) |o| if (o == b) return true;
    return false;
}

fn shown(ed: *const Editor, w: *const Windows.Window) bool {
    for (ed.window_list.items) |o| if (o == w) return true;
    return false;
}

/// The pair, if it is still as it was put up (both windows, each on its
/// side's buffer).
fn intact(ed: *Editor) ?*Pair {
    const c = &(ed.comparing orelse return null);
    if (!has(ed, c.old) or !has(ed, c.new)) return null;
    if (!shown(ed, c.left) or !shown(ed, c.right)) return null;
    if (window_ops.windowBuffer(ed, c.left) != c.old or window_ops.windowBuffer(ed, c.right) != c.new) return null;
    if (c.left.term != null or c.right.term != null) return null;
    return c;
}

/// A read-only buffer of `text` (as git gave it), coloured as `path` is,
/// whose diff is against `other`.
fn side(ed: *Editor, text: []const u8, against: []const u8, path: []const u8, label: []u8) !*Buffer {
    errdefer ed.gpa.free(label);
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try b.text.insert(ed.gpa, 0, text);
    b.syntax = Syntax.forPath(path);
    b.read_only = true;
    b.git = .{ .base = try Text.init(ed.gpa, against) };
    b.label = label;
    try ed.buffers.append(ed.gpa, b);
    return b;
}

/// Puts `old` in a new window left of the focused one (which shows `new`).
fn open(ed: *Editor, old: *Buffer, new: *Buffer, new_owned: bool, back: ?*Buffer) !void {
    const right = ed.window;
    ed.zoom = null;
    const left = try ed.windows.split(right, .left, .{ .rows = ed.view.rows, .cols = ed.view.cols }, old);
    window_ops.refreshWindowList(ed);
    old.compare = .old;
    new.compare = .new;
    ed.comparing = .{ .left = left, .right = right, .old = old, .new = new, .new_owned = new_owned, .back = back, .seen = new.edit_version, .new_no_wrap = new.no_wrap };
    old.no_wrap = true;
    new.no_wrap = true;
    ed.ghost = null;
    git_ops.updateGit(ed);
}

/// The first change into view, if the cursor isn't in one already.
fn toFirstChange(ed: *Editor) void {
    const g = ed.buffer.git orelse return;
    if (g.hunks.items.len == 0) return;
    if (git_ops.hunkAtCursor(ed) != null) return;
    const t = ed.text();
    const line = @min(g.hunks.items[0].new_start, t.lineCount() - 1);
    row_model.revealLine(ed, line);
    ed.setCursor(motions.firstNonBlank(t, line));
}

/// The file in the focused window beside HEAD's version of it; again (or
/// from either side): back to the one window.
pub fn toggleFile(ed: *Editor) !void {
    if (ed.comparing != null) return close(ed);
    if (ed.window.term != null or @import("side_float.zig").focused(ed) or ed.cmd_float != null)
        return ed.setMessage(.info, "side by side is for a file in a code window", .{});
    const b = ed.buffer;
    const path = b.path orelse return ed.setMessage(.info, "this buffer has no file to compare", .{});
    const g = &(b.git orelse return ed.setMessage(.info, "{s} isn't in HEAD yet (a new file, or not a git repository): nothing to put beside it", .{path}));
    const t = &b.text;
    const label = try std.fmt.allocPrint(ed.gpa, "HEAD: {s}", .{path});
    const old = try side(ed, g.base.slice(0, g.base.len()), t.slice(0, t.len()), path, label);
    errdefer discard(ed, old);
    try open(ed, old, b, false, null);
    toFirstChange(ed);
    ed.setMessage(.info, "side by side with HEAD (q on the left closes it)", .{});
}

/// File `rel` (from the repository's top) as commit `rev` left it, beside
/// how it was before.
pub fn showCommit(ed: *Editor, root: []const u8, rev: []const u8, rel: []const u8) !void {
    if (ed.comparing != null) close(ed);
    window_ops.focusEditorWindow(ed);
    const gpa = ed.gpa;
    const parent = try std.fmt.allocPrint(gpa, "{s}^", .{rev});
    defer gpa.free(parent);
    const before = try textAt(ed, root, parent, rel);
    defer gpa.free(before);
    const after = try textAt(ed, root, rev, rel);
    defer gpa.free(after);
    const old = try side(ed, before, after, rel, try std.fmt.allocPrint(gpa, "{s}^: {s}", .{ rev, rel }));
    errdefer discard(ed, old);
    const new = try side(ed, after, before, rel, try std.fmt.allocPrint(gpa, "{s}: {s}", .{ rev, rel }));
    errdefer discard(ed, new);
    const back = ed.buffer;
    ed.switchTo(new);
    try open(ed, old, new, true, back);
    toFirstChange(ed);
    ed.setMessage(.info, "{s}: before and after (q closes it)", .{rev});
}

/// `rel` in `rev`, as a buffer would have it; empty if it wasn't there.
fn textAt(ed: *Editor, root: []const u8, rev: []const u8, rel: []const u8) ![]u8 {
    const raw = Git.fileAt(ed.gpa, ed.io, root, rev, rel) orelse return ed.gpa.dupe(u8, "");
    defer ed.gpa.free(raw);
    return Git.normalize(ed.gpa, raw);
}

/// Closes one of our buffers (windows showing it show another).
fn discard(ed: *Editor, b: *Buffer) void {
    if (!has(ed, b)) return;
    b.modified = false;
    ed.killBuffer(b) catch {};
}

/// Back to one window: the left one closes, our buffers with it.
pub fn close(ed: *Editor) void {
    const c = ed.comparing orelse return;
    ed.comparing = null;
    if (has(ed, c.new)) {
        c.new.compare = .none;
        c.new.no_wrap = c.new_no_wrap;
    }
    if (has(ed, c.old)) c.old.compare = .none;
    const left = shown(ed, c.left);
    const right = shown(ed, c.right);
    // The left window goes, if it is still the one we made (and not the
    // last there is).
    if (left and ed.window_list.items.len > 1 and window_ops.windowBuffer(ed, c.left) == c.old) {
        if (ed.window == c.left) window_ops.focusWindow(ed, if (right) c.right else other(ed, c.left));
        ed.zoom = null;
        _ = ed.windows.close(c.left);
        window_ops.refreshWindowList(ed);
    }
    // A commit's right side: its window shows what it showed before.
    if (c.new_owned and has(ed, c.new)) {
        if (ed.buffer == c.new) if (c.back) |b| if (has(ed, b)) ed.switchTo(b);
        discard(ed, c.new);
    }
    discard(ed, c.old);
    ed.ghost = null;
    git_ops.updateGit(ed);
}

fn other(ed: *Editor, w: *Windows.Window) *Windows.Window {
    for (ed.window_list.items) |o| if (o != w) return o;
    return w;
}

/// Each frame: the pair closes once it isn't as it was put up (a window
/// closed, another buffer in one); the left side follows what is typed on
/// the right.
pub fn tick(ed: *Editor) void {
    if (ed.comparing == null) return;
    const c = intact(ed) orelse return close(ed);
    if (c.new.edit_version == c.seen) return;
    c.seen = c.new.edit_version;
    const g = &(c.old.git orelse return);
    const t = &c.new.text;
    const base = Text.init(ed.gpa, t.slice(0, t.len())) catch return;
    g.base.deinit(ed.gpa);
    g.base = base;
    g.version = std.math.maxInt(u64);
}

/// Before drawing: the window that isn't focused shows the rows the focused
/// one does (and keeps its cursor on the same line, for when it is gone to).
pub fn sync(ed: *Editor) void {
    const c = intact(ed) orelse return;
    const from, const to = if (ed.window == c.left) .{ c.left, c.right } else if (ed.window == c.right) .{ c.right, c.left } else return;
    _ = from;
    git_ops.updateGit(ed);
    const hunks = (ed.buffer.git orelse return).hunks.items;
    const tb = to.buffer;
    const lines = tb.text.lineCount();
    const top = across(hunks, .{ .line = ed.view.top, .filler = ed.view.top_ghost });
    const v = &to.view;
    v.top = @min(top.line, lines - 1);
    // (Blank rows after the last line are before line `lines`.)
    if (top.filler != null and top.line <= lines) {
        v.top = top.line;
        v.top_ghost = top.filler;
    } else v.top_ghost = null;
    v.top_sub = 0;
    v.left = ed.view.left;
    v.scroll_offset = ed.view.scroll_offset;
    v.scroll_frac = ed.view.scroll_frac;
    v.scroll_idle = ed.view.scroll_idle;
    v.seen_top = v.top;
    v.seen_buffer = tb;
    const at = across(hunks, .{ .line = ed.cursorLine() });
    v.cursor = tb.text.lineStart(@min(at.line, lines - 1));
}

/// `q` on a side that can't be changed closes the pair. True if it did.
pub fn key(ed: *Editor, ev: Editor.KeyEvent) bool {
    if (ed.comparing == null or ed.buffer.compare == .none or !ed.buffer.read_only) return false;
    if (ed.mode != .normal or !ed.isIdle() or ed.picker != null or ed.search_prompt != null or ed.cursors.items.len > 0) return false;
    if (ev.mods.any() or ev.key != .codepoint or ev.key.codepoint != 'q') return false;
    close(ed);
    return true;
}

test "across: lines before, in and after a change; the blank rows of the shorter side" {
    // This side: 0 1 [2 3 4] 5 ; the other: 0 1 [2] 3   (one line became three)
    const grew = [_]diff.Hunk{.{ .old_start = 2, .old_count = 1, .new_start = 2, .new_count = 3 }};
    try std.testing.expectEqual(Place{ .line = 1 }, across(&grew, .{ .line = 1 }));
    try std.testing.expectEqual(Place{ .line = 2 }, across(&grew, .{ .line = 2 }));
    // Its second and third lines are beside the other side's blank rows.
    try std.testing.expectEqual(Place{ .line = 3, .filler = 0 }, across(&grew, .{ .line = 3 }));
    try std.testing.expectEqual(Place{ .line = 3, .filler = 1 }, across(&grew, .{ .line = 4 }));
    try std.testing.expectEqual(Place{ .line = 3 }, across(&grew, .{ .line = 5 }));
    // The other way: this side 0 1 [2] 3, the other 0 1 [2 3 4] 5.
    const shrank = [_]diff.Hunk{.{ .old_start = 2, .old_count = 3, .new_start = 2, .new_count = 1 }};
    try std.testing.expectEqual(Place{ .line = 2 }, across(&shrank, .{ .line = 2 }));
    try std.testing.expectEqual(Place{ .line = 3 }, across(&shrank, .{ .line = 3, .filler = 0 }));
    try std.testing.expectEqual(Place{ .line = 4 }, across(&shrank, .{ .line = 3, .filler = 1 }));
    try std.testing.expectEqual(Place{ .line = 5 }, across(&shrank, .{ .line = 3 }));
    // Lines only the other side has (deleted here, before line 1).
    const gone = [_]diff.Hunk{.{ .old_start = 1, .old_count = 2, .new_start = 1, .new_count = 0 }};
    try std.testing.expectEqual(Place{ .line = 0 }, across(&gone, .{ .line = 0 }));
    try std.testing.expectEqual(Place{ .line = 1 }, across(&gone, .{ .line = 1, .filler = 0 }));
    try std.testing.expectEqual(Place{ .line = 3 }, across(&gone, .{ .line = 1 }));
}

comptime {
    _ = blame;
}
