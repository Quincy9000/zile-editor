//! Rows: text lines plus ghost lines; within a line, its code lens row, then its wrapped pieces.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const motions = @import("../core/motions.zig");
const diff = @import("../git/diff.zig");
const Lsp = @import("../lsp/Lsp.zig");
const operators = @import("../operators.zig");
const textobjects = @import("../core/textobjects.zig");
const notifications = @import("notifications.zig");
const window_ops = @import("window_ops.zig");
const inlay = @import("inlay.zig");
const Editor = @import("../Editor.zig");
const folding = @import("folding.zig");
const code_motion = @import("code_motion.zig");
const git_ops = @import("git_ops.zig");
const lsp_ops = @import("lsp_ops.zig");
const LineHint = Editor.LineHint;
const max_line_hints = Editor.max_line_hints;
const hint_debounce_ms = Editor.hint_debounce_ms;
const hintShift = Editor.hintShift;
const hintVisualToText = Editor.hintVisualToText;
const Row = Editor.Row;
const Seg = Editor.Seg;
const max_segments = Editor.max_segments;
const max_diagnostic_lists = lsp_ops.max_diagnostic_lists;

/// The git hunk whose old lines show as ghost lines before text line `line`.
pub fn ghostHunk(ed: *const Editor, line: usize) ?diff.Hunk {
    if (!ed.options.ghost_lines) return null;
    const g = ed.buffer.git orelse return null;
    for (g.hunks.items) |h| {
        if (h.old_count == 0) continue;
        const at = h.new_start + h.new_count;
        if (at == line) return h;
        if (at > line) break;
    }
    return null;
}

pub fn hasGhosts(ed: *const Editor) bool {
    if (!ed.options.ghost_lines) return false;
    const g = ed.buffer.git orelse return false;
    for (g.hunks.items) |h| if (h.old_count > 0) return true;
    return false;
}

/// The text of ghost line `k` before text line `line`.
pub fn ghostText(ed: *const Editor, line: usize, k: u32) []const u8 {
    const h = ghostHunk(ed, line) orelse return "";
    return ed.buffer.git.?.baseLine(h.old_start + k);
}

// Rows within a line: its code lens row, then its wrapped pieces.

/// Whether some line can take more than one row (then rows can't be
/// counted as lines).
pub fn layered(ed: *const Editor) bool {
    return inlay.wraps(ed) or hasLenses(ed) or (ed.options.diagnostic_text and hasDiagnostics(ed, ed.buffer));
}


/// The rows (wrapped pieces) of `line`, written into `buf`: at least one.
/// A closed fold's line is one row.
pub fn segments(ed: *const Editor, line: usize, buf: *[max_segments]Seg) []Seg {
    const t = &ed.buffer.text;
    const cols = @max(ed.view.cols, 8);
    if (!inlay.wraps(ed) or line >= t.lineCount() or folding.foldAt(ed, line) != null) {
        buf[0] = .{ .start = 0, .end = std.math.maxInt(usize), .indent = 0 };
        return buf[0..1];
    }
    const bytes = t.lineSlice(line);
    const tab = ed.options.tab_width;
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = inlay.lineHints(ed, ed.buffer, line, &hint_buf);
    // Later rows start under the line's indentation (at most half the width).
    const lead = bytes[0 .. std.mem.indexOfNone(u8, bytes, " \t") orelse bytes.len];
    const indent = @min(motions.displayCol(bytes, lead.len, tab), cols / 2);
    var n: usize = 0;
    var row_start: usize = 0;
    var width = cols;
    var last_break: usize = 0; // visual column after the last space in this row
    var col: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const cp_end = @min(i + len, bytes.len);
        const next_col = if (bytes[i] == '\t') motions.nextTabStop(col, tab) else col + 1;
        const v0 = col + hintShift(hints, i);
        const v1 = next_col + hintShift(hints, i);
        if (v1 > row_start + width and v0 > row_start and n + 1 < max_segments) {
            const at = if (last_break > row_start) last_break else v0;
            buf[n] = .{ .start = row_start, .end = at, .indent = if (n == 0) 0 else indent };
            n += 1;
            row_start = at;
            width = cols - indent;
            last_break = row_start;
        }
        if (bytes[i] == ' ' or bytes[i] == '\t') last_break = v1;
        col = next_col;
        i = cp_end;
    }
    buf[n] = .{ .start = row_start, .end = std.math.maxInt(usize), .indent = if (n == 0) 0 else indent };
    return buf[0 .. n + 1];
}

/// The visual column (inlay hints counted) of byte `off` of `line`.
pub fn visualCol(ed: *const Editor, line: usize, off: usize) usize {
    const t = &ed.buffer.text;
    const bytes = t.lineSlice(line);
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = inlay.lineHints(ed, ed.buffer, line, &hint_buf);
    return motions.displayCol(bytes, @min(off, bytes.len), ed.options.tab_width) + hintShift(hints, off);
}

/// Which of `segs` visual column `vcol` is on.
pub fn segmentIndex(segs: []const Seg, vcol: usize) usize {
    var k: usize = 0;
    while (k + 1 < segs.len and vcol >= segs[k + 1].start) k += 1;
    return k;
}

/// A code lens title for `line` of `b`: joined to the line's others.
pub fn addLens(ed: *Editor, b: *Buffer, line: u32, title: []const u8) !void {
    const clean = std.mem.trim(u8, title, " ");
    if (clean.len == 0) return;
    var i: usize = 0;
    while (i < b.lenses.items.len and b.lenses.items[i].line < line) i += 1;
    if (i < b.lenses.items.len and b.lenses.items[i].line == line) {
        const lens = &b.lenses.items[i];
        const old = lens.text;
        // The first new title replaces the one kept from the last answer.
        lens.text = if (lens.stale) try ed.gpa.dupe(u8, clean) else try std.mem.concat(ed.gpa, u8, &.{ old, " | ", clean });
        lens.stale = false;
        ed.gpa.free(old);
        return;
    }
    const owned = try ed.gpa.dupe(u8, clean);
    errdefer ed.gpa.free(owned);
    try b.lenses.insert(ed.gpa, i, .{ .line = line, .text = owned });
}

/// Each frame: code lens for the buffers on screen, asked for once their
/// text has been still a moment (as inlay hints).
pub fn tickCodeLens(ed: *Editor) void {
    if (!ed.options.code_lens) return;
    for (ed.window_list.items) |w| {
        if (w.term != null) continue;
        const b = window_ops.windowBuffer(ed, w);
        const l = lsp_ops.lspFor(ed, b) orelse continue;
        if (!l.can_lens or b.lens_pending or b.lens_version == b.edit_version or b.path == null) continue;
        if (b.hint_changed.durationTo(ed.now).nanoseconds < hint_debounce_ms * std.time.ns_per_ms and b.hint_seen == b.edit_version) continue;
        l.requestCodeLens(b) catch {};
    }
}

pub fn hasLenses(ed: *const Editor) bool {
    return ed.options.code_lens and ed.buffer.lenses.items.len > 0;
}

/// The code lens text shown above `line`, if any.
pub fn lensText(ed: *const Editor, line: usize) ?[]const u8 {
    if (!ed.options.code_lens) return null;
    for (ed.buffer.lenses.items) |l| {
        if (l.line == line and !l.gone) return l.text;
        if (l.line > line) break;
    }
    return null;
}

pub fn lensRows(ed: *const Editor, line: usize) usize {
    return @intFromBool(lensText(ed, line) != null);
}

/// Rows `line` takes on screen: its lens, its text, and the rest of its
/// diagnostic message.
pub fn subRows(ed: *const Editor, line: usize) usize {
    var buf: [max_segments]Seg = undefined;
    const segs = segments(ed, line, &buf);
    const extra = if (diagText(ed, line, segs)) |d| d.rows() else 0;
    return lensRows(ed, line) + segs.len + extra;
}

/// Whether `r` holds text the cursor can be on (not a lens row or a
/// diagnostic message's row).
pub fn isTextRow(ed: *const Editor, r: Row) bool {
    if (r.ghost != null or !layered(ed)) return true;
    var buf: [max_segments]Seg = undefined;
    const lens = lensRows(ed, r.line);
    return r.sub >= lens and r.sub < lens + segments(ed, r.line, &buf).len;
}

/// Whether `b` has any diagnostics.
pub fn hasDiagnostics(ed: *const Editor, b: *const Buffer) bool {
    var buf: [max_diagnostic_lists][]const Lsp.Diagnostic = undefined;
    return lsp_ops.diagnosticLists(ed, b, &buf).len > 0;
}

/// The most severe diagnostic on `line` of the current buffer.
pub fn lineDiagnostic(ed: *const Editor, line: usize) ?*const Lsp.Diagnostic {
    var buf: [max_diagnostic_lists][]const Lsp.Diagnostic = undefined;
    var best: ?*const Lsp.Diagnostic = null;
    for (lsp_ops.diagnosticLists(ed, ed.buffer, &buf)) |list| {
        // Most severe first within a line.
        const on = Lsp.diagnosticsOnLine(list, line);
        if (on.len == 0) continue;
        if (best == null or @intFromEnum(on[0].severity) < @intFromEnum(best.?.severity)) best = &on[0];
    }
    return best;
}

/// The current buffer's diagnostics starting on `line` (with `col`: only
/// those whose range covers that byte of it), into `out`.
pub fn diagnosticsOn(ed: *const Editor, line: usize, col: ?usize, out: []*const Lsp.Diagnostic) []*const Lsp.Diagnostic {
    var buf: [max_diagnostic_lists][]const Lsp.Diagnostic = undefined;
    var n: usize = 0;
    for (lsp_ops.diagnosticLists(ed, ed.buffer, &buf)) |list| for (Lsp.diagnosticsOnLine(list, line)) |*d| {
        if (n == out.len) break;
        if (col) |c| {
            const end: usize = if (d.end_line == d.line) @max(d.end_col, d.col + 1) else std.math.maxInt(usize);
            if (c < d.col or c >= end) continue;
        }
        out[n] = d;
        n += 1;
    };
    return out[0..n];
}

/// A line's diagnostic message (option `diagnostic_text`), laid out: as
/// much as fits after the text, the rest word-wrapped on rows of its own
/// under the line, at its indent.
pub const DiagText = struct {
    pub const max_rows = 6;
    severity: Lsp.Severity,
    /// What goes after the text (may be empty), then a piece per row below.
    pieces: [max_rows + 1][]const u8 = undefined,
    n: usize = 0,
    /// Screen column of the first piece, and of the rows below.
    first_col: usize = 0,
    col: usize = 0,

    pub fn rows(d: DiagText) usize {
        return d.n - 1;
    }
};

/// `line`'s diagnostic message laid out for the window (`segs`: its rows).
pub fn diagText(ed: *const Editor, line: usize, segs: []const Seg) ?DiagText {
    if (!ed.options.diagnostic_text or folding.foldAt(ed, line) != null) return null;
    const diag = lineDiagnostic(ed, line) orelse return null;
    const t = &ed.buffer.text;
    if (line >= t.lineCount()) return null;
    const msg = std.mem.trim(u8, diag.message, " \t\r\n");
    if (msg.len == 0) return null;
    const cols = @max(ed.view.cols, 8);
    const tab = ed.options.tab_width;
    const bytes = t.lineSlice(line);
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = inlay.lineHints(ed, ed.buffer, line, &hint_buf);
    const end = motions.displayCol(bytes, bytes.len, tab) + hintShift(hints, bytes.len);
    // Where the text ends on its last row, on screen.
    const last = segs[segs.len - 1];
    const left = if (inlay.wraps(ed)) last.start else ed.view.left;
    const shown_end: ?usize = if (end >= left) end - left + last.indent else null;
    const lead = std.mem.indexOfNone(u8, bytes, " \t") orelse bytes.len;
    const indent = motions.displayCol(bytes, lead, tab) -| (if (inlay.wraps(ed)) 0 else ed.view.left);

    var d: DiagText = .{ .severity = diag.severity };
    d.col = @min(indent, cols / 2);
    const width = cols - d.col;
    var rest = msg;
    // After the text when it all fits there, or when there's a fair room.
    if (shown_end) |e| if (e + 3 < cols) {
        const room = cols - (e + 3);
        if (cells(firstLine(rest)) <= room or room >= 20) {
            d.first_col = e + 3;
            const p = wrapPiece(rest, room);
            d.pieces[0] = p[0];
            rest = p[1];
            d.n = 1;
        }
    };
    if (d.n == 0) {
        d.pieces[0] = "";
        d.n = 1;
    }
    while (rest.len > 0 and d.n < d.pieces.len) {
        const p = wrapPiece(rest, width);
        d.pieces[d.n] = p[0];
        rest = p[1];
        d.n += 1;
    }
    return d;
}

pub fn firstLine(s: []const u8) []const u8 {
    return std.mem.sliceTo(s, '\n');
}

pub fn cells(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// The start of `s` that fits in `width` cells (to its first newline,
/// broken after a space if it can be), and what is left after it.
pub fn wrapPiece(s: []const u8, width: usize) [2][]const u8 {
    const line = firstLine(s);
    var it = std.unicode.Utf8View.initUnchecked(line).iterator();
    var n: usize = 0;
    var cut: usize = line.len;
    var space: ?usize = null;
    while (it.i < line.len) : (n += 1) {
        if (n == width) {
            cut = if (space) |sp| sp else it.i;
            break;
        }
        if (line[it.i] == ' ') space = it.i;
        _ = it.nextCodepointSlice();
    }
    const piece = std.mem.trimEnd(u8, line[0..cut], " ");
    var rest = s[cut..];
    if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];
    return .{ piece, std.mem.trimStart(u8, rest, " \t") };
}

pub fn nextRow(ed: *const Editor, r: Row) Row {
    const n = ed.buffer.text.lineCount();
    if (r.ghost) |k| {
        const h = ghostHunk(ed, r.line) orelse return .{ .line = @min(r.line, n - 1) };
        if (k + 1 < h.old_count) return .{ .line = r.line, .ghost = k + 1 };
        return if (r.line < n) .{ .line = r.line } else r;
    }
    if (layered(ed) and r.line < n and r.sub + 1 < subRows(ed, r.line)) return .{ .line = r.line, .sub = r.sub + 1 };
    const after = (if (folding.foldAt(ed, r.line)) |f| f.last else r.line) + 1;
    if (ghostHunk(ed, after) != null) return .{ .line = after, .ghost = 0 };
    return if (after < n) .{ .line = after } else r;
}

pub fn prevRow(ed: *const Editor, r: Row) Row {
    if (r.ghost) |k| {
        if (k > 0) return .{ .line = r.line, .ghost = k - 1 };
        return if (r.line == 0) r else lastRowOf(ed, folding.visibleLine(ed, r.line - 1));
    }
    if (r.sub > 0) return .{ .line = r.line, .sub = r.sub - 1 };
    if (ghostHunk(ed, r.line)) |h| return .{ .line = r.line, .ghost = h.old_count - 1 };
    return if (r.line == 0) r else lastRowOf(ed, folding.visibleLine(ed, r.line - 1));
}

/// The bottom row of `line` (its last wrapped piece).
pub fn lastRowOf(ed: *const Editor, line: usize) Row {
    if (!layered(ed)) return .{ .line = line };
    return .{ .line = line, .sub = @intCast(subRows(ed, line) - 1) };
}

/// The row `delta` rows away from `r` (stops at the ends).
pub fn stepRows(ed: *const Editor, r: Row, delta: isize) Row {
    if (ed.buffer.folds.isEmpty() and !hasGhosts(ed) and r.ghost == null and !layered(ed)) {
        return .{ .line = folding.stepVisible(ed, r.line, delta) };
    }
    var cur = r;
    var n = @abs(delta);
    while (n > 0) : (n -= 1) {
        const next = if (delta > 0) nextRow(ed, cur) else prevRow(ed, cur);
        if (next.eql(cur)) break;
        cur = next;
    }
    return cur;
}

/// Screen rows from `a` down to `b`, counting at most `cap`.
pub fn rowsFrom(ed: *const Editor, a: Row, b: Row, cap: usize) usize {
    if (!a.before(b)) return 0;
    if (ed.buffer.folds.isEmpty() and !hasGhosts(ed) and a.ghost == null and b.ghost == null and !layered(ed)) {
        return @min(b.line - a.line, cap);
    }
    var cur = a;
    var rows: usize = 0;
    while (cur.before(b) and rows < cap) : (rows += 1) {
        const next = nextRow(ed, cur);
        if (next.eql(cur)) break;
        cur = next;
    }
    return rows;
}

/// Screen rows from line `a` down to line `b`, counting at most `cap`.
pub fn rowsBetween(ed: *const Editor, a: usize, b: usize, cap: usize) usize {
    return rowsFrom(ed, .{ .line = a }, .{ .line = b }, cap);
}

pub fn topRow(ed: *const Editor) Row {
    return .{ .line = ed.view.top, .ghost = ed.view.top_ghost, .sub = if (ed.view.top_ghost == null) ed.view.top_sub else 0 };
}

pub fn setTop(ed: *Editor, r: Row) void {
    ed.view.top = r.line;
    ed.view.top_ghost = r.ghost;
    ed.view.top_sub = r.sub;
}

pub fn cursorRow(ed: *const Editor) Row {
    if (ed.ghost) |g| return .{ .line = g.line, .ghost = g.k };
    const t = &ed.buffer.text;
    const line = folding.visibleLine(ed, t.lineOf(ed.view.cursor));
    if (!layered(ed)) return .{ .line = line };
    var buf: [max_segments]Seg = undefined;
    const segs = segments(ed, line, &buf);
    const k = if (line == t.lineOf(ed.view.cursor)) segmentIndex(segs, visualCol(ed, line, ed.view.cursor - t.lineStart(line))) else 0;
    return .{ .line = line, .sub = @intCast(lensRows(ed, line) + k) };
}

/// The screen row of `r`, if it is on screen.
pub fn rowOnScreen(ed: *const Editor, r: Row) ?usize {
    const top = topRow(ed);
    if (r.before(top)) return null;
    const row = rowsFrom(ed, top, r, ed.view.rows);
    return if (row < ed.view.rows) row else null;
}

/// The screen row of text `line`, if it is on screen.
pub fn screenRow(ed: *const Editor, line: usize) ?usize {
    return rowOnScreen(ed, .{ .line = folding.visibleLine(ed, line) });
}

/// Moves the cursor to a row: a ghost row puts it on that ghost line.
pub fn setCursorRow(ed: *Editor, r: Row) void {
    const col = ed.view.want_col orelse (if (ed.ghost) |g| g.col else ed.cursorCol());
    if (r.ghost) |k| {
        const len = ghostText(ed, r.line, k).len;
        const anchor = if (ed.ghost) |g| (if (g.line == r.line) g.anchor else null) else null;
        ed.ghost = .{ .line = r.line, .k = k, .col = @min(col, len -| 1), .anchor = anchor };
        ed.view.want_col = col;
    } else {
        ed.ghost = null;
        if (layered(ed) and inlay.wraps(ed)) return setCursorScreenRow(ed, r);
        ed.gotoLine(r.line);
        ed.view.want_col = col;
    }
}

/// Onto a wrapped line's row `r` (a lens row counts as its first piece):
/// at the screen column the cursor was on, which sticks while moving up
/// and down (as `gj` / `gk`).
pub fn setCursorScreenRow(ed: *Editor, r: Row) void {
    const screen = wantScreenCol(ed);
    const t = ed.text();
    const line = @min(r.line, t.lineCount() - 1);
    var buf: [max_segments]Seg = undefined;
    const segs = segments(ed, line, &buf);
    const lens = lensRows(ed, line);
    const k = @min(@as(usize, r.sub) -| lens, segs.len - 1);
    const seg = segs[k];
    var vcol = seg.start + (screen -| seg.indent);
    // Not past this row's end (its last column, or the line's end).
    if (k + 1 < segs.len and vcol >= seg.end) vcol = seg.end -| 1;
    const bytes = t.lineSlice(line);
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = inlay.lineHints(ed, ed.buffer, line, &hint_buf);
    const text_col = hintVisualToText(hints, bytes, vcol, ed.options.tab_width);
    ed.setCursor(t.lineStart(line) + motions.byteAtCol(bytes, text_col, ed.options.tab_width));
    ed.wrap_want = .{ .cursor = ed.view.cursor, .screen = screen };
}

/// The screen column the cursor is on (within its row), or the one kept
/// from the last move up or down if the cursor hasn't moved since.
pub fn wantScreenCol(ed: *Editor) usize {
    if (ed.wrap_want) |w| if (w.cursor == ed.view.cursor) return w.screen;
    const t = ed.text();
    const line = t.lineOf(ed.view.cursor);
    var buf: [max_segments]Seg = undefined;
    const segs = segments(ed, line, &buf);
    const vcol = visualCol(ed, line, ed.view.cursor - t.lineStart(line));
    const seg = segs[segmentIndex(segs, vcol)];
    return vcol - seg.start + seg.indent;
}

/// Drops the ghost cursor if its hunk went away (edits, restore, toggle).
pub fn validateGhost(ed: *Editor) void {
    const g = ed.ghost orelse return;
    const h = ghostHunk(ed, g.line) orelse {
        ed.ghost = null;
        return;
    };
    if (g.k >= h.old_count) ed.ghost = null;
}

/// Opens the folds hiding `line` (jumps land on visible text).
pub fn revealLine(ed: *Editor, line: usize) void {
    _ = ed.buffer.folds.open(&ed.buffer.text, line, true);
}

/// Keeps the cursor off hidden lines: in insert mode the fold opens, otherwise
/// the cursor moves to the fold's first line.
pub fn clampToFolds(ed: *Editor) void {
    const line = ed.cursorLine();
    const f = folding.foldAt(ed, line) orelse return;
    if (ed.mode == .insert) return revealLine(ed, line);
    if (line != f.first) ed.setCursor(motions.firstNonBlank(ed.text(), f.first));
}

/// Extends a linewise range to whole folds at either end (`dd` on a closed
/// fold deletes the fold).
pub fn extendToFolds(ed: *const Editor, r: operators.Range) operators.Range {
    if (!r.linewise or ed.buffer.folds.isEmpty()) return r;
    const t = &ed.buffer.text;
    var first = t.lineOf(r.start);
    var last = t.lineOf(r.end);
    if (folding.foldAt(ed, first)) |f| first = f.first;
    if (folding.foldAt(ed, last)) |f| last = f.last;
    return operators.linesRange(t, first, last);
}

/// A mouse button went down on a text cell (`clicks`: 1, 2 or 3 in a
/// row). One places the cursor (dragging from there selects), two select
/// the word, three the line; the selection goes to the clipboard on
/// release, as in kitty.
pub fn mousePress(ed: *Editor, row: usize, col: usize, clicks: u8) void {
    if (ed.mode == .insert) ed.setMode(.normal);
    if (ed.mode == .visual) code_motion.exitVisual(ed);
    clickCell(ed, row, col);
    ed.mouse_drag = .{ .anchor = ed.view.cursor };
    // On a ghost line (old text from HEAD): whole old lines are selected
    // and copied, as `V` / `y` do on them.
    if (ed.ghost) |*g| {
        ed.mouse_drag.?.ghost = .{ .line = g.line, .k = g.k, .last = g.k };
        if (clicks >= 2) {
            ed.mode = .visual;
            ed.visual_line = true;
            g.anchor = g.k;
            ed.mouse_drag.?.selected = true;
        }
        return;
    }
    const t = ed.text();
    switch (clicks) {
        0, 1 => {},
        2 => if (textobjects.word(t, ed.view.cursor, .inner, false, 1)) |r| if (r.end > r.start) {
            ed.enterVisual(false);
            code_motion.selectRange(ed, r);
            ed.mouse_drag.?.selected = true;
        },
        else => {
            ed.enterVisual(true);
            ed.mouse_drag.?.selected = true;
        },
    }
}

/// The pointer moved with the button down: the selection follows it.
pub fn mouseDrag(ed: *Editor, row: usize, col: usize) void {
    const d = &(ed.mouse_drag orelse return);
    if (d.ghost) |*start| {
        clickCell(ed, row, col);
        // Within the hunk it began in; off it, the selection stays where it
        // last was.
        const k = if (ed.ghost) |g| (if (g.line == start.line) g.k else start.last) else start.last;
        start.last = k;
        ed.ghost = .{ .line = start.line, .k = k, .col = 0, .anchor = start.k };
        ed.mode = .visual;
        ed.visual_line = true;
        d.selected = true;
        return;
    }
    if (ed.ghost != null) return;
    const anchor = if (ed.mode == .visual) ed.view.anchor else d.anchor;
    clickCell(ed, row, col);
    if (ed.mode != .visual) {
        if (ed.view.cursor == d.anchor) return;
        ed.enterVisual(false);
    }
    ed.view.anchor = anchor;
    d.selected = true;
}

/// The button came up: a selection made with the mouse is copied.
pub fn mouseRelease(ed: *Editor) void {
    const d = ed.mouse_drag orelse return;
    ed.mouse_drag = null;
    if (!d.selected or ed.mode != .visual) return;
    if (ed.ghost) |g| if (g.anchor) |a| {
        git_ops.yankGhostLines(ed, g.line, a, g.k, '+') catch return;
        const n = @max(a, g.k) - @min(a, g.k) + 1;
        return notifications.notify(ed, .info, "copied {d} old line{s}", .{ n, if (n == 1) "" else "s" });
    };
    const r = code_motion.visualRange(ed);
    const t = ed.text();
    const end = if (ed.visual_line) @min(r.end + 1, t.len()) else r.end;
    if (end <= r.start) return;
    ed.registers.store('+', .yank, t.slice(r.start, end), ed.visual_line) catch return;
    ed.yank_flash = .{ .buffer = ed.buffer, .start = r.start, .end = end, .linewise = ed.visual_line, .born = ed.now };
    const lines = t.lineOf(end -| 1) - t.lineOf(r.start) + 1;
    if (lines > 1) notifications.notify(ed, .info, "copied {d} lines", .{lines}) else notifications.notify(ed, .info, "copied {d} characters", .{end - r.start});
}

/// Places the cursor at a cell of the text area (mouse click).
pub fn clickCell(ed: *Editor, row: usize, col: usize) void {
    const r = stepRows(ed, topRow(ed), @intCast(row));
    if (r.ghost != null) {
        ed.view.want_col = ed.view.left + col;
        return setCursorRow(ed, r);
    }
    ed.ghost = null;
    ed.setCursor(cellOffset(ed, r, col));
}

/// The text position at column `col` of text row `r`.
pub fn cellOffset(ed: *const Editor, r: Row, col: usize) usize {
    const t = &ed.buffer.text;
    // A cell on a line with inlay hints is further along the text than it
    // looks; one on a hint itself is the text right after it. On a wrapped
    // line's later row, the columns go on from the row before (a lens row
    // is the line's start).
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = inlay.lineHints(ed, ed.buffer, r.line, &hint_buf);
    const bytes = t.lineSlice(r.line);
    var vcol = ed.view.left + col;
    if (layered(ed)) {
        var seg_buf: [max_segments]Seg = undefined;
        const segs = segments(ed, r.line, &seg_buf);
        const lens = lensRows(ed, r.line);
        if (r.sub < lens) {
            vcol = 0;
        } else {
            const k = @min(r.sub - lens, segs.len - 1);
            vcol = segs[k].start + (col -| segs[k].indent);
            if (k + 1 < segs.len and vcol >= segs[k].end) vcol = segs[k].end -| 1;
        }
    }
    const text_col = hintVisualToText(hints, bytes, vcol, ed.options.tab_width);
    return t.lineStart(r.line) + motions.byteAtCol(bytes, text_col, ed.options.tab_width);
}
