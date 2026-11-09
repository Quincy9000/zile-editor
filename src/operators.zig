//! Operators (d, c, y, >, <, gu, gU, g~) and the other register-aware edits
//! (paste, join, replace). An operator acts on a `Range` produced by a
//! motion, a text object, a visual selection or a doubled operator (`dd`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("Editor.zig");
const Text = @import("core/Text.zig");
const motions = @import("core/motions.zig");
const textobjects = @import("core/textobjects.zig");
const Registers = @import("Registers.zig");

pub const Range = textobjects.Range;

pub const Operator = enum { delete, change, yank, indent, outdent, lowercase, uppercase, toggle_case, fold,
    /// `ys`: waits for the pair character, then surrounds the range.
    surround };

/// How a motion's span becomes a range (`:h exclusive`, `:h linewise`).
pub const MotionKind = enum { exclusive, inclusive, linewise };

/// The range an operator acts on when the cursor moves from `from` to `to`.
pub fn motionRange(t: *const Text, from: usize, to: usize, kind: MotionKind) Range {
    const start = @min(from, to);
    var end = @max(from, to);
    switch (kind) {
        .linewise => return linesRange(t, t.lineOf(start), t.lineOf(end)),
        .inclusive => {
            // Include the character at `end`, but never the line break.
            end = @min(motions.nextChar(t, end), t.lineEnd(t.lineOf(end)));
        },
        .exclusive => {
            // An exclusive motion ending at the start of a later line stops at the
            // end of the previous one (`dw` on a line's last word keeps the break).
            const end_line = t.lineOf(end);
            if (end > start and end_line > t.lineOf(start) and end == t.lineStart(end_line)) end -= 1;
        },
    }
    return .{ .start = start, .end = end };
}

pub fn linesRange(t: *const Text, first: usize, last: usize) Range {
    return .{ .start = t.lineStart(first), .end = t.lineEnd(last), .linewise = true };
}

pub fn apply(ed: *Editor, op: Operator, range: Range, register: ?u8) !void {
    // Linewise operators on a closed fold act on the whole fold.
    const r = ed.extendToFolds(range);
    // Nothing to act on (e.g. `x` on an empty line): leave the registers alone.
    if (!r.linewise and r.start == r.end) {
        if (op == .change) {
            ed.setMode(.insert);
            ed.setCursor(r.start);
        }
        return;
    }
    switch (op) {
        .surround => return ed.awaitSurroundChar(r),
        .yank => {
            try yank(ed, r, register, .yank);
            if (r.start < ed.view.cursor) {
                if (r.linewise) ed.gotoLine(ed.text().lineOf(r.start)) else ed.setCursor(r.start);
            }
        },
        .delete => {
            try yank(ed, r, register, .delete);
            try deleteText(ed, r);
        },
        .change => {
            try yank(ed, r, register, .delete);
            const t = ed.text();
            ed.setMode(.insert);
            if (r.linewise) {
                // Keep one line, with the first line's indentation.
                var buf: [256]u8 = undefined;
                const indent = copyIndent(t, t.lineOf(r.start), &buf);
                try ed.deleteRange(r.start, r.end);
                try ed.insertText(indent);
            } else {
                try ed.deleteRange(r.start, r.end);
            }
        },
        .indent, .outdent => try shiftLines(ed, r, op == .indent),
        .fold => {
            // zf{motion}: a manual fold over the lines the range touches.
            const t = ed.text();
            const first = t.lineOf(r.start);
            try ed.buffer.folds.add(ed.gpa, t, first, t.lineOf(r.end));
            ed.setCursor(motions.firstNonBlank(t, first));
        },
        .lowercase, .uppercase, .toggle_case => try changeCase(ed, r, op),
    }
}

/// Copies the range into a register (linewise ranges get a trailing newline).
fn yank(ed: *Editor, r: Range, register: ?u8, kind: Registers.Kind) !void {
    // With several cursors the registers keep what the primary cursor yanked.
    if (ed.replaying) return;
    const body = ed.text().slice(r.start, r.end);
    if (!r.linewise) return ed.registers.store(register, kind, body, false);
    const with_nl = try std.mem.concat(ed.gpa, u8, &.{ body, "\n" });
    defer ed.gpa.free(with_nl);
    try ed.registers.store(register, kind, with_nl, true);
}

fn deleteText(ed: *Editor, r: Range) !void {
    const t = ed.text();
    if (!r.linewise) return ed.deleteRange(r.start, r.end);
    const first = t.lineOf(r.start);
    const last = t.lineOf(r.end);
    var start = r.start;
    var end = r.end;
    if (last + 1 < t.lineCount()) {
        end += 1; // the trailing line break
    } else if (first > 0) {
        start -= 1; // through the end of the text: the preceding break
    }
    try ed.deleteRange(start, end);
    ed.setCursor(motions.firstNonBlank(t, @min(first, t.lineCount() - 1)));
}

fn copyIndent(t: *const Text, line: usize, buf: []u8) []const u8 {
    const indent = t.slice(t.lineStart(line), motions.firstNonBlank(t, line));
    const n = @min(indent.len, buf.len);
    @memcpy(buf[0..n], indent[0..n]);
    return buf[0..n];
}

fn shiftLines(ed: *Editor, r: Range, right: bool) !void {
    const t = ed.text();
    const first = t.lineOf(r.start);
    const last = t.lineOf(r.end);
    const width = ed.options.tab_width;
    // Bottom-up, so earlier line positions stay valid.
    var line = last + 1;
    while (line > first) {
        line -= 1;
        const ls = t.lineStart(line);
        if (right) {
            if (t.lineLen(line) == 0) continue;
            if (ed.options.expand_tab) {
                const spaces: [16]u8 = @splat(' ');
                try ed.insertAt(ls, spaces[0..@min(width, spaces.len)]);
            } else try ed.insertAt(ls, "\t");
        } else {
            var n: usize = 0;
            const le = t.lineEnd(line);
            if (ls < le and t.byteAt(ls) == '\t') {
                n = 1;
            } else while (n < width and ls + n < le and t.byteAt(ls + n) == ' ') n += 1;
            if (n > 0) try ed.deleteRangeKeepCursor(ls, ls + n);
        }
    }
    ed.setCursor(motions.firstNonBlank(t, first));
}

fn changeCase(ed: *Editor, r: Range, op: Operator) !void {
    const t = ed.text();
    const old = t.slice(r.start, r.end);
    const new = try ed.gpa.dupe(u8, old);
    defer ed.gpa.free(new);
    for (new) |*b| b.* = switch (op) {
        .lowercase => std.ascii.toLower(b.*),
        .uppercase => std.ascii.toUpper(b.*),
        else => if (std.ascii.isUpper(b.*)) std.ascii.toLower(b.*) else std.ascii.toUpper(b.*),
    };
    if (!std.mem.eql(u8, old, new)) {
        try ed.deleteRange(r.start, r.end);
        try ed.insertAt(r.start, new);
    }
    ed.setCursor(r.start);
}

/// `p` / `P`: pastes `count` copies after/before the cursor (linewise text
/// goes below/above the current line).
pub fn paste(ed: *Editor, v: Registers.Value, count: usize, before: bool) !void {
    const t = ed.text();
    const gpa = ed.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const line = ed.cursorLine();
    if (v.linewise) {
        const body = if (std.mem.endsWith(u8, v.text, "\n")) v.text[0 .. v.text.len - 1] else v.text;
        for (0..count) |_| {
            if (!before) try buf.append(gpa, '\n');
            try buf.appendSlice(gpa, body);
            if (before) try buf.append(gpa, '\n');
        }
        const pos = if (before) t.lineStart(line) else t.lineEnd(line);
        try ed.insertAt(pos, buf.items);
        ed.setCursor(motions.firstNonBlank(t, if (before) line else line + 1));
    } else {
        for (0..count) |_| try buf.appendSlice(gpa, v.text);
        const le = t.lineEnd(line);
        const pos = if (before or ed.view.cursor >= le) ed.view.cursor else motions.nextChar(t, ed.view.cursor);
        try ed.insertAt(pos, buf.items);
        // On the last pasted character.
        ed.setCursor(motions.prevChar(t, pos + buf.items.len));
    }
}

/// `J`: joins `count` lines (at least two) with single spaces.
pub fn join(ed: *Editor, count: usize) !void {
    const t = ed.text();
    const line = ed.cursorLine();
    var joins = @max(count, 2) - 1;
    while (joins > 0 and line + 1 < t.lineCount()) : (joins -= 1) {
        const nl = t.lineEnd(line);
        const next_text = motions.firstNonBlank(t, line + 1);
        const next_empty = next_text == t.lineEnd(line + 1);
        const ends_blank = nl > t.lineStart(line) and (t.byteAt(nl - 1) == ' ' or t.byteAt(nl - 1) == '\t');
        const needs_space = !next_empty and !ends_blank and nl > t.lineStart(line) and t.byteAt(next_text) != ')';
        try ed.deleteRange(nl, next_text);
        if (needs_space) try ed.insertAt(nl, " ");
        ed.setCursor(nl);
    }
}

/// `r{char}`: replaces `count` characters under the cursor. False if the line
/// is too short.
pub fn replaceChars(ed: *Editor, cp: u21, count: usize) !bool {
    const t = ed.text();
    const le = t.lineEnd(ed.cursorLine());
    var end = ed.view.cursor;
    for (0..count) |_| {
        if (end >= le) return false;
        end = motions.nextChar(t, end);
    }
    var enc: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &enc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ed.gpa);
    for (0..count) |_| try buf.appendSlice(ed.gpa, enc[0..n]);
    const start = ed.view.cursor;
    try ed.deleteRange(start, end);
    try ed.insertAt(start, buf.items);
    ed.setCursor(start + buf.items.len - n);
    return true;
}
