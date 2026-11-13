//! Inlay hints: the language server's type and parameter labels, drawn in the text.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const motions = @import("../core/motions.zig");
const operators = @import("../operators.zig");
const sql = @import("../sql.zig");
const textops = @import("../textops.zig");
const window_ops = @import("window_ops.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const lsp_ops = @import("lsp_ops.zig");
const cells = row_model.cells;

/// One hint on a line: its label goes before the text at byte `off`.
pub const LineHint = struct {
    off: usize,
    text: []const u8,

    pub fn cells(h: LineHint) usize {
        return std.unicode.utf8CountCodepoints(h.text) catch h.text.len;
    }
};

pub const max_line_hints = 32;

/// How long the text must stay unchanged before hints are asked for again.
pub const hint_debounce_ms = 250;

/// The hints to draw on `line` of `b`, in order. None while the option is
/// off, and none on the line being typed on in insert mode (they would
/// jump about under the cursor; they come back with Esc).
pub fn lineHints(ed: *const Editor, b: *const Buffer, line: usize, out: []LineHint) []LineHint {
    if (!ed.options.inlay_hints or b.hints.items.len == 0) return out[0..0];
    if (ed.mode == .insert and b == ed.buffer and line == cursorLineConst(ed)) return out[0..0];
    const t = &b.text;
    if (line >= t.lineCount()) return out[0..0];
    const ls = t.lineStart(line);
    const le = t.lineEnd(line);
    // First hint at or after the line's start.
    var lo: usize = 0;
    var hi: usize = b.hints.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (b.hints.items[mid].pos < ls) lo = mid + 1 else hi = mid;
    }
    var n: usize = 0;
    while (lo < b.hints.items.len and b.hints.items[lo].pos <= le and n < out.len) : (lo += 1) {
        const h = b.hints.items[lo];
        out[n] = .{ .off = h.pos - ls, .text = h.text };
        n += 1;
    }
    return out[0..n];
}

pub fn cursorLineConst(ed: *const Editor) usize {
    return ed.buffer.text.lineOf(ed.view.cursor);
}

/// Columns the hints push the text at byte `off` to the right (hints
/// before it, and one at `off` itself, which is drawn in front of it).
pub fn hintShift(hints: []const LineHint, off: usize) usize {
    var n: usize = 0;
    for (hints) |h| if (h.off <= off) {
        n += h.cells();
    };
    return n;
}

/// Like `hintShift`, without a hint at `off` itself: where a range ends,
/// the hint in front of the next character isn't part of it.
pub fn hintShiftBefore(hints: []const LineHint, off: usize) usize {
    var n: usize = 0;
    for (hints) |h| if (h.off < off) {
        n += h.cells();
    };
    return n;
}

/// The text column for a column of the screen: the other way round from
/// `hintShift`. A column on a hint is the text right after it.
pub fn hintVisualToText(hints: []const LineHint, bytes: []const u8, visual: usize, tab_width: usize) usize {
    var shift: usize = 0;
    for (hints) |h| {
        const start = motions.displayCol(bytes, @min(h.off, bytes.len), tab_width) + shift;
        const width = h.cells();
        if (visual < start) break;
        if (visual < start + width) return start - shift;
        shift += width;
    }
    return visual - shift;
}

/// An inlay-hint answer for lines `first..last` of `b` (as at `version`):
/// takes the hints in `new` (the texts go to the buffer) in place of the
/// ones it had for those lines.
pub fn takeInlayHints(ed: *Editor, b: *Buffer, new: *std.ArrayList(Buffer.Hint), first: usize, last: usize, version: u64) !void {
    b.hint_pending = false;
    // The text moved on while the server worked: its answer is for text that
    // is gone. The next tick asks again.
    if (b.edit_version != version) return;
    const t = &b.text;
    const lo = t.lineStart(@min(first, t.lineCount() - 1));
    const hi = t.lineEnd(@min(last, t.lineCount() - 1));
    var kept: std.ArrayList(Buffer.Hint) = .empty;
    errdefer kept.deinit(ed.gpa);
    for (b.hints.items) |h| {
        if (h.pos >= lo and h.pos <= hi) ed.gpa.free(h.text) else try kept.append(ed.gpa, h);
    }
    for (new.items) |h| try kept.append(ed.gpa, h);
    new.clearRetainingCapacity(); // now the buffer's
    std.mem.sort(Buffer.Hint, kept.items, {}, struct {
        fn before(_: void, a: Buffer.Hint, c: Buffer.Hint) bool {
            return a.pos < c.pos;
        }
    }.before);
    b.hints.deinit(ed.gpa);
    b.hints = kept;
    b.hint_version = version;
    b.hint_range = .{ first, last };
    ed.wake_fn();
}

/// The lines of `b` to have hints for while a window shows it from `top`:
/// the screen and a screenful either side.
pub fn hintWindow(b: *const Buffer, top: usize, rows: usize) [2]usize {
    return .{ top -| rows, @min(top + 2 * rows, b.text.lineCount() - 1) };
}

/// Whether `b`'s hints are for what is on screen (from `top`, `rows` tall).
pub fn hintsCover(b: *const Buffer, top: usize, rows: usize) bool {
    const r = b.hint_range;
    return r[0] <= top and top + rows <= r[1] + 1 or (r[1] + 1 >= b.text.lineCount() and r[0] <= top);
}

/// Each frame: asks the language server for the hints of whatever a window
/// shows that has none, or stale ones.
pub fn tickInlayHints(ed: *Editor) void {
    if (!ed.options.inlay_hints) return;
    for (ed.window_list.items) |w| {
        if (w.term != null) continue;
        const b = window_ops.windowBuffer(ed, w);
        const l = lsp_ops.lspFor(ed, b) orelse continue;
        if (!l.can_inlay or b.hint_pending or b.path == null) continue;
        // The text changing resets the wait.
        if (b.hint_seen != b.edit_version) {
            b.hint_seen = b.edit_version;
            b.hint_changed = ed.now;
        }
        const v = window_ops.windowView(ed, w);
        const stale = b.hint_version != b.edit_version;
        const covered = hintsCover(b, v.top, v.rows);
        if (!stale and covered) continue;
        // After edits: once the text has been still for a moment. Scrolling
        // to lines never asked for: at once.
        if (stale and b.hint_changed.durationTo(ed.now).nanoseconds < hint_debounce_ms * std.time.ns_per_ms) continue;
        const range = hintWindow(b, v.top, v.rows);
        l.requestInlayHints(ed, b, range[0], range[1]) catch {};
    }
}

/// Some window's hints are waiting out the debounce (a frame must come).
pub fn inlayHintsDue(ed: *const Editor) bool {
    if (!ed.options.inlay_hints) return false;
    for (ed.window_list.items) |w| {
        if (w.term != null) continue;
        const b = if (w == ed.window) ed.buffer else w.buffer;
        const l = lsp_ops.lspFor(ed, b) orelse continue;
        if (!l.can_inlay or b.hint_pending or b.path == null) continue;
        if (b.hint_version != b.edit_version) return true;
    }
    return false;
}

/// Writes a todo tag as a comment (`SPC l t`, insert-mode `<C-t>`): a blank
/// line becomes the comment, a line of code gets it at its end. Then insert
/// mode, after the tag.
pub fn writeTodoTag(ed: *Editor, tag: []const u8) !void {
    const t = ed.text();
    const line = ed.cursorLine();
    const st = textops.commentStyle(ed, line);
    var buf: [64]u8 = undefined;
    const blank = motions.firstNonBlank(t, line) == t.lineEnd(line);
    const written = try std.fmt.bufPrint(&buf, "{s}{s} {s}: ", .{ if (blank) "" else " ", st.open, tag });
    ed.setMode(.insert);
    const at = t.lineEnd(line);
    try ed.insertAt(at, written);
    // A block comment closes after where you type.
    if (st.close.len > 0) {
        var cbuf: [16]u8 = undefined;
        try ed.insertAt(at + written.len, std.fmt.bufPrint(&cbuf, " {s}", .{st.close}) catch st.close);
    }
    ed.setCursor(at + written.len);
}

/// Long lines wrap in this buffer (the option, unless the buffer is a table).
pub fn wraps(ed: *const Editor) bool {
    return ed.options.wrap and !ed.buffer.no_wrap;
}

/// The last SQL results as a table in a buffer of its own: a header, a
/// line per row, the columns lined up. Being text, vim does the rest:
/// `V` and `j` take rows, Ctrl-v a column, `/` finds, `y` yanks.
pub fn openSqlTable(ed: *Editor) !void {
    const r = ed.sql_results orelse return ed.setMessage(.info, "no SQL has run yet (Ctrl-Enter in a SQL file)", .{});
    if (!r.done.load(.acquire) or r.columns.len == 0) return ed.setMessage(.info, "no rows to show", .{});
    const table = try sql.tableText(ed.gpa, r.columns, r.rows);
    defer ed.gpa.free(table);
    try openTextBuffer(ed, "SQL results", table);
    ed.buffer.no_wrap = true;
    // On the first row, under the header.
    if (ed.text().lineCount() > 2) ed.setCursor(ed.text().lineStart(2));
}

/// Opens `text` as a new buffer named `label` (a manual page, say): not a
/// file, and not counted as modified.
pub fn openTextBuffer(ed: *Editor, label: []const u8, contents: []const u8) !void {
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try b.text.insert(ed.gpa, 0, std.mem.trimEnd(u8, contents, "\n"));
    b.label = try ed.gpa.dupe(u8, label);
    try ed.buffers.append(ed.gpa, b);
    window_ops.focusEditorWindow(ed);
    ed.switchTo(b);
}

/// `SPC f y`: pastes register `name` after the cursor.
pub fn pasteRegister(ed: *Editor, name: u8) !void {
    const v = ed.registers.get(name) orelse return ed.setMessage(.info, "register {c} is empty", .{name});
    const copy = try ed.gpa.dupe(u8, v.text);
    defer ed.gpa.free(copy);
    try operators.paste(ed, .{ .text = copy, .linewise = v.linewise }, 1, false, true);
}

/// `SPC f u`: takes the buffer to any state in its undo tree.
pub fn undoTo(ed: *Editor, node: u32) !void {
    ed.cursors.clearRetainingCapacity();
    const b = ed.buffer;
    try b.history.commit(ed.gpa);
    const cursor = try b.history.goTo(ed.gpa, node, b) orelse return;
    b.modified = b.history.isModified();
    ed.setCursor(cursor);
}

/// A closed buffer's jumps keep their file path (or go, for scratch buffers).
pub fn forgetJumps(ed: *Editor, b: *Buffer) void {
    var i: usize = 0;
    while (i < ed.jumps.items.len) {
        const j = &ed.jumps.items[i];
        if (j.buffer == b) {
            j.buffer = null;
            if (j.path == null) {
                _ = ed.jumps.orderedRemove(i);
                if (ed.jump_index > i) ed.jump_index -= 1;
                continue;
            }
        }
        i += 1;
    }
    ed.jump_index = @min(ed.jump_index, ed.jumps.items.len);
}
