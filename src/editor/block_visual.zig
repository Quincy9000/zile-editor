//! Block (column) visual mode, `<C-v>`: the selection is the rectangle of
//! screen columns between the anchor and the cursor, over the lines between
//! them. `d` `y` `c` `I` `A` `p` and the case operators work on the rectangle.

const std = @import("std");
const motions = @import("../core/motions.zig");
const operators = @import("../operators.zig");
const Editor = @import("../Editor.zig");
const code_motion = @import("code_motion.zig");
const multicursor = @import("multicursor.zig");
const Registers = @import("../Registers.zig");

/// Lines `first..last` (inclusive) and screen columns `left..right` (`right`
/// is one past the last column).
pub const Block = struct { first: usize, last: usize, left: usize, right: usize };

const Cells = struct { start: usize, end: usize };

pub fn active(ed: *const Editor) bool {
    return ed.mode == .visual and ed.visual_block and ed.ghost == null;
}

/// The screen columns the character at `pos` covers (a tab covers several).
fn cellsAt(ed: *Editor, pos: usize) Cells {
    const t = ed.text();
    const line = t.lineOf(pos);
    const bytes = t.lineSlice(line);
    const off = pos - t.lineStart(line);
    const tab = ed.options.tab_width;
    const c0 = motions.displayCol(bytes, off, tab);
    if (off >= bytes.len) return .{ .start = c0, .end = c0 + 1 };
    return .{ .start = c0, .end = motions.displayCol(bytes, motions.nextChar(t, pos) - t.lineStart(line), tab) };
}

const to_line_end = std.math.maxInt(usize);

/// Where the cursor is, in screen columns. The block keeps its shape when
/// the cursor is on a line too short for it: the sticky column (`j` / `k`,
/// or `l` past the end) is where the cursor really is, in blank space.
/// `$` is the end of every line.
fn cursorCells(ed: *Editor) Cells {
    return stickyCells(cellsAt(ed, ed.view.cursor), ed.view.want_col);
}

fn anchorCells(ed: *Editor) Cells {
    return stickyCells(cellsAt(ed, ed.view.anchor), ed.block_anchor_col);
}

fn stickyCells(c: Cells, want: ?usize) Cells {
    const w = want orelse return c;
    if (w == to_line_end) return .{ .start = c.start, .end = to_line_end };
    if (w >= c.end) return .{ .start = w, .end = w + 1 };
    return c;
}

/// How far right of the character under the cursor it is, in columns.
pub fn cursorShift(ed: *Editor) usize {
    if (!active(ed)) return 0;
    const c = cellsAt(ed, ed.view.cursor);
    const v = cursorCells(ed);
    return if (v.end == to_line_end) 0 else v.start - c.start;
}

pub fn bounds(ed: *Editor) Block {
    const t = ed.text();
    const a = anchorCells(ed);
    const c = cursorCells(ed);
    const la = t.lineOf(ed.view.anchor);
    const lc = t.lineOf(ed.view.cursor);
    return .{ .first = @min(la, lc), .last = @max(la, lc), .left = @min(a.start, c.start), .right = @max(a.end, c.end) };
}

/// The text of `line` inside the block, or null where the line is shorter.
pub fn span(ed: *Editor, b: Block, line: usize) ?operators.Range {
    const t = ed.text();
    const bytes = t.lineSlice(line);
    const ls = t.lineStart(line);
    const tab = ed.options.tab_width;
    const s = motions.byteAtCol(bytes, b.left, tab);
    if (s >= bytes.len) return null;
    const last = motions.byteAtCol(bytes, b.right - 1, tab);
    const e = if (last >= bytes.len) bytes.len else motions.nextChar(t, ls + last) - ls;
    return .{ .start = ls + s, .end = ls + e };
}

/// Where column `col` is on `line`, or null if the line is shorter than that.
fn reach(ed: *Editor, line: usize, col: usize) ?usize {
    const t = ed.text();
    const bytes = t.lineSlice(line);
    const tab = ed.options.tab_width;
    if (motions.displayCol(bytes, bytes.len, tab) < col) return null;
    return t.lineStart(line) + motions.byteAtCol(bytes, col, tab);
}

fn topLeft(ed: *Editor, b: Block) usize {
    const t = ed.text();
    const bytes = t.lineSlice(b.first);
    return t.lineStart(b.first) + motions.byteAtCol(bytes, b.left, ed.options.tab_width);
}

/// Puts the block in `register`, a row per line, and remembers that it is one.
fn store(ed: *Editor, b: Block, register: ?u8, kind: Registers.Kind) !void {
    if (ed.replaying) return;
    const t = ed.text();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ed.gpa);
    for (b.first..b.last + 1) |line| {
        if (line > b.first) try out.append(ed.gpa, '\n');
        if (span(ed, b, line)) |r| try out.appendSlice(ed.gpa, t.slice(r.start, r.end));
    }
    try ed.registers.store(register, kind, out.items, false);
    var width = b.right -| b.left;
    if (b.right == to_line_end) {
        width = 0;
        var rows = std.mem.splitScalar(u8, out.items, '\n');
        while (rows.next()) |row| width = @max(width, motions.displayCol(row, row.len, ed.options.tab_width));
    }
    try ed.registers.noteBlock(out.items, width);
}

fn deleteBlock(ed: *Editor, b: Block) !void {
    var line = b.last + 1;
    while (line > b.first) {
        line -= 1;
        if (span(ed, b, line)) |r| try ed.deleteRange(r.start, r.end);
    }
}

/// A cursor at each of `positions` (the first is the primary), typing there.
fn cursorsAt(ed: *Editor, positions: []const usize, typing: bool) !void {
    if (positions.len == 0) return;
    multicursor.clearCursors(ed);
    for (positions[1..]) |p| try ed.cursors.append(ed.gpa, .{ .pos = p, .anchor = p });
    ed.view.cursor = positions[0];
    ed.view.anchor = positions[0];
    if (typing) ed.setMode(.insert) else ed.placeCursor(positions[0]);
    if (positions.len > 1) multicursor.reportCursors(ed);
}

/// `I` / `A` on a block: a cursor on every line at the block's left edge or
/// just after its right edge (short lines are padded for `A`).
pub fn insert(ed: *Editor, at_end: bool, typing: bool) !void {
    const b = bounds(ed);
    code_motion.exitVisual(ed);
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(ed.gpa);
    if (at_end and b.right == to_line_end) {
        const t = ed.text();
        for (b.first..b.last + 1) |l| try positions.append(ed.gpa, t.lineEnd(l));
    } else if (at_end) {
        const t = ed.text();
        var line = b.last + 1;
        while (line > b.first) {
            line -= 1;
            const bytes = t.lineSlice(line);
            const width = motions.displayCol(bytes, bytes.len, ed.options.tab_width);
            if (width < b.right) try ed.insertAt(t.lineEnd(line), try spaces(ed, b.right - width));
        }
        for (b.first..b.last + 1) |l| try positions.append(ed.gpa, reach(ed, l, b.right).?);
    } else {
        for (b.first..b.last + 1) |l| if (reach(ed, l, b.left)) |p| try positions.append(ed.gpa, p);
    }
    try cursorsAt(ed, positions.items, typing);
}

/// A run of `n` spaces that lives until the next call.
fn spaces(ed: *Editor, n: usize) ![]const u8 {
    const buf = struct {
        var bytes: [256]u8 = @splat(' ');
    };
    _ = ed;
    return buf.bytes[0..@min(n, buf.bytes.len)];
}

/// An operator on the block (`d`, `y`, `c`, case changes, shifts).
pub fn apply(ed: *Editor, op: operators.Operator, register: ?u8) !void {
    const b = bounds(ed);
    const charwise = code_motion.visualRange(ed);
    code_motion.exitVisual(ed);
    const t = ed.text();
    switch (op) {
        .yank => {
            try store(ed, b, register, .yank);
            ed.setCursor(topLeft(ed, b));
        },
        .delete => {
            try store(ed, b, register, .delete);
            try deleteBlock(ed, b);
            ed.setCursor(topLeft(ed, b));
        },
        .change => {
            try store(ed, b, register, .delete);
            var positions: std.ArrayList(usize) = .empty;
            defer positions.deinit(ed.gpa);
            var lines: std.ArrayList(usize) = .empty;
            defer lines.deinit(ed.gpa);
            for (b.first..b.last + 1) |l| if (reach(ed, l, b.left) != null) try lines.append(ed.gpa, l);
            try deleteBlock(ed, b);
            for (lines.items) |l| try positions.append(ed.gpa, reach(ed, l, b.left).?);
            try cursorsAt(ed, positions.items, true);
        },
        .lowercase, .uppercase, .toggle_case => {
            var line = b.last + 1;
            while (line > b.first) {
                line -= 1;
                if (span(ed, b, line)) |r| try operators.apply(ed, op, r, null);
            }
            ed.setCursor(topLeft(ed, b));
        },
        .indent, .outdent, .comment => try operators.apply(ed, op, operators.linesRange(t, b.first, b.last), register),
        else => try operators.apply(ed, op, charwise, register),
    }
}

/// `h` / `l` in a block: past the end of a line the cursor goes on into
/// blank space (the sticky column), so the block keeps growing.
pub fn horizontal(ed: *Editor, right: bool, count: usize) bool {
    if (!active(ed)) return false;
    const t = ed.text();
    const c = cellsAt(ed, ed.view.cursor);
    const v = cursorCells(ed);
    if (v.end == to_line_end) return false;
    const virtual = v.start > c.start;
    if (right) {
        const at_end = virtual or ed.view.cursor >= t.lineEnd(t.lineOf(ed.view.cursor)) or
            motions.nextChar(t, ed.view.cursor) >= t.lineEnd(t.lineOf(ed.view.cursor));
        if (!at_end) return false;
        ed.view.want_col = v.start + count;
        return true;
    }
    if (!virtual) return false;
    // Back onto the line's last character once the blank space is used up.
    ed.view.want_col = if (v.start -| count < c.end) null else v.start - count;
    return true;
}

/// `p` / `P` of a block register: its rows go on successive lines at the
/// cursor's column (after the cursor's character for `p`), padding short
/// lines and adding lines at the end of the text as needed.
pub fn paste(ed: *Editor, text: []const u8, block_width: usize, count: usize, before: bool) !void {
    const t = ed.text();
    const tab = ed.options.tab_width;
    const line0 = ed.cursorLine();
    const cell = cellsAt(ed, ed.view.cursor);
    const col = if (before or ed.view.cursor >= t.lineEnd(line0)) cell.start else cell.end;
    var width: usize = block_width;
    var rows = std.mem.splitScalar(u8, text, '\n');
    while (rows.next()) |row| width = @max(width, motions.displayCol(row, row.len, tab));
    var piece: std.ArrayList(u8) = .empty;
    defer piece.deinit(ed.gpa);
    var line = line0;
    rows = std.mem.splitScalar(u8, text, '\n');
    while (rows.next()) |row| : (line += 1) {
        if (line >= t.lineCount()) try ed.insertAt(t.len(), "\n");
        var bytes = t.lineSlice(line);
        const w = motions.displayCol(bytes, bytes.len, tab);
        if (w < col) try ed.insertAt(t.lineEnd(line), try spaces(ed, col - w));
        bytes = t.lineSlice(line);
        const at = motions.byteAtCol(bytes, col, tab);
        const text_follows = at < bytes.len;
        piece.clearRetainingCapacity();
        const row_width = motions.displayCol(row, row.len, tab);
        for (0..count) |i| {
            try piece.appendSlice(ed.gpa, row);
            if (i + 1 < count or text_follows) try piece.appendNTimes(ed.gpa, ' ', width - row_width);
        }
        try ed.insertAt(t.lineStart(line) + at, piece.items);
    }
    const bytes = t.lineSlice(line0);
    ed.setCursor(t.lineStart(line0) + motions.byteAtCol(bytes, col, tab));
}

/// Where column `col` of `line` is: the character there, or the line's last
/// one with the column kept as the sticky one when the line is shorter.
fn placeAt(ed: *Editor, line: usize, col: usize) struct { pos: usize, col: usize } {
    const t = ed.text();
    const bytes = t.lineSlice(line);
    const ls = t.lineStart(line);
    const tab = ed.options.tab_width;
    if (col >= motions.displayCol(bytes, bytes.len, tab)) {
        const last = if (bytes.len == 0) ls else motions.prevChar(t, ls + bytes.len);
        return .{ .pos = last, .col = col };
    }
    return .{ .pos = ls + motions.byteAtCol(bytes, col, tab), .col = col };
}

/// `o`: the opposite corner (blank-space columns travel with their corner).
pub fn swapEnds(ed: *Editor) void {
    const v = &ed.view;
    std.mem.swap(usize, &v.anchor, &v.cursor);
    const w = v.want_col;
    v.want_col = ed.block_anchor_col;
    ed.block_anchor_col = w;
}

/// `O`: the other corner on the same line: the cursor and the anchor swap
/// columns.
pub fn swapSides(ed: *Editor) void {
    const t = ed.text();
    const a = anchorCells(ed);
    const c = cursorCells(ed);
    if (a.end == to_line_end or c.end == to_line_end) return;
    const pa = placeAt(ed, t.lineOf(ed.view.anchor), c.start);
    const pc = placeAt(ed, t.lineOf(ed.view.cursor), a.start);
    ed.view.anchor = pa.pos;
    ed.block_anchor_col = pa.col;
    ed.view.cursor = pc.pos;
    ed.view.want_col = pc.col;
}

/// `r{char}` on a selection: every character in it (not the line breaks)
/// becomes `cp`; the cursor goes to the selection's start.
pub fn replaceSelection(ed: *Editor, cp: u21) !void {
    const block = active(ed);
    const b = bounds(ed);
    const charwise = code_motion.visualRange(ed);
    code_motion.exitVisual(ed);
    if (block) {
        var line = b.last + 1;
        while (line > b.first) {
            line -= 1;
            if (span(ed, b, line)) |r| try fill(ed, r, cp);
        }
        return ed.setCursor(topLeft(ed, b));
    }
    try fill(ed, charwise, cp);
    ed.setCursor(charwise.start);
}

fn fill(ed: *Editor, r: operators.Range, cp: u21) !void {
    const t = ed.text();
    var enc: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &enc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ed.gpa);
    var pos = r.start;
    while (pos < r.end) {
        const next = @min(motions.nextChar(t, pos), r.end);
        if (t.byteAt(pos) == '\n') try out.append(ed.gpa, '\n') else try out.appendSlice(ed.gpa, enc[0..n]);
        pos = @max(next, pos + 1);
    }
    try ed.deleteRange(r.start, r.end);
    try ed.insertAt(r.start, out.items);
}
