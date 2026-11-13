//! Moving by the shape of the code (Alt keys; `syntax/objects.zig`).

const std = @import("std");
const motions = @import("../core/motions.zig");
const keys = @import("../input/keys.zig");
const KeyEvent = keys.KeyEvent;
const km = @import("../input/keymap.zig");
const syntax_objects = @import("../syntax/objects.zig");
const operators = @import("../operators.zig");
const Syntax = @import("../syntax/Syntax.zig");
const textobjects = @import("../core/textobjects.zig");
const row_model = @import("row_model.zig");
const Editor = @import("../Editor.zig");

/// What a selection was before `Alt-u` grew it (`normal`: a cursor, not a
/// selection, at `range.start`).
pub const GrowStep = struct { range: textobjects.Range, normal: bool };

/// The selection, or the cursor as a one-character range.
pub fn structureRange(ed: *Editor) textobjects.Range {
    if (ed.mode == .visual) return visualRange(ed);
    const t = ed.text();
    const c = @min(ed.view.cursor, t.len());
    return .{ .start = c, .end = @max(motions.nextChar(t, c), c + 1) };
}

pub fn structureSyntax(ed: *Editor) ?*Syntax {
    if (ed.buffer.syntax) |*s| return s;
    ed.setMessage(.info, "no syntax tree for this file", .{});
    return null;
}

/// Selects `r` charwise, entering visual mode if needed.
pub fn selectNode(ed: *Editor, r: textobjects.Range) void {
    if (ed.mode != .visual) ed.enterVisual(false);
    ed.visual_line = false;
    selectRange(ed, r);
    row_model.revealLine(ed, ed.text().lineOf(ed.view.cursor));
}

/// `Alt-u`: the selection grows to the next node up the syntax tree.
pub fn growSelection(ed: *Editor) !void {
    const s = structureSyntax(ed) orelse return;
    const sel = structureRange(ed);
    const r = syntax_objects.expand(s, ed.text(), sel) orelse return;
    // Keep the way back only while the selection is the one grown last.
    if (ed.grown) |g| {
        if (g.buffer != ed.buffer or g.version != ed.buffer.edit_version or ed.mode != .visual or g.range.start != sel.start or g.range.end != sel.end)
            ed.grow_stack.clearRetainingCapacity();
    } else ed.grow_stack.clearRetainingCapacity();
    try ed.grow_stack.append(ed.gpa, .{ .range = sel, .normal = ed.mode != .visual });
    selectNode(ed, r);
    ed.grown = .{ .buffer = ed.buffer, .version = ed.buffer.edit_version, .range = r };
}

/// `Alt-i`: back to what the selection was before the last `Alt-u`.
pub fn shrinkSelection(ed: *Editor) void {
    const g = ed.grown orelse return;
    const sel = structureRange(ed);
    if (ed.mode != .visual or g.buffer != ed.buffer or g.version != ed.buffer.edit_version or g.range.start != sel.start or g.range.end != sel.end) return;
    const step = ed.grow_stack.pop() orelse return;
    if (step.normal) {
        ed.grown = null;
        ed.grow_stack.clearRetainingCapacity();
        exitVisual(ed);
        ed.setCursor(step.range.start);
        return;
    }
    selectNode(ed, step.range);
    ed.grown = .{ .buffer = ed.buffer, .version = ed.buffer.edit_version, .range = step.range };
}

/// `Alt-n` / `Alt-p`: to the next / previous sibling node (an argument, a
/// statement, a field, a prop, a function): the cursor goes to its start, a
/// selection becomes it.
pub fn siblingNode(ed: *Editor, forward: bool) void {
    const s = structureSyntax(ed) orelse return;
    const visual = ed.mode == .visual;
    const r = syntax_objects.sibling(s, ed.text(), structureRange(ed), !visual, forward) orelse return;
    if (visual) {
        selectNode(ed, r);
        ed.grown = null;
        return;
    }
    row_model.revealLine(ed, ed.text().lineOf(r.start));
    ed.setCursor(r.start);
}

/// `Alt-N` / `Alt-P`: the node at the cursor (or the selected one) trades
/// places with its next / previous sibling, and stays selected / under the
/// cursor, so pressing again carries it further. One undo step.
pub fn swapNode(ed: *Editor, forward: bool) !void {
    const s = structureSyntax(ed) orelse return;
    const visual = ed.mode == .visual;
    const t = ed.text();
    const pair = syntax_objects.swapPair(s, t, structureRange(ed), !visual, forward) orelse return;
    const node = pair[0];
    const other = pair[1];
    const first = if (node.start < other.start) node else other;
    const second = if (node.start < other.start) other else node;
    if (first.end > second.start) return; // overlapping: not siblings
    const a = try ed.gpa.dupe(u8, t.slice(first.start, first.end));
    defer ed.gpa.free(a);
    const b = try ed.gpa.dupe(u8, t.slice(second.start, second.end));
    defer ed.gpa.free(b);
    // The later one first, so the earlier positions hold.
    try ed.deleteRangeKeepCursor(second.start, second.end);
    try ed.insertAt(second.start, a);
    try ed.deleteRangeKeepCursor(first.start, first.end);
    try ed.insertAt(first.start, b);
    try ed.buffer.history.commit(ed.gpa);
    // Where the node is now.
    const len = node.end - node.start;
    const at = if (node.start == first.start) second.start + b.len - a.len else first.start;
    const moved: textobjects.Range = .{ .start = at, .end = at + len };
    if (visual) {
        selectNode(ed, moved);
        ed.grown = null;
    } else {
        row_model.revealLine(ed, ed.text().lineOf(at));
        ed.setCursor(at);
    }
}

/// `Alt-f` / `Alt-F`: to the next / previous function.
pub fn functionJump(ed: *Editor, forward: bool) void {
    const s = structureSyntax(ed) orelse return;
    const pos = syntax_objects.functionStart(s, ed.text(), ed.view.cursor, forward) orelse
        return ed.setMessage(.info, "no {s} function", .{if (forward) "next" else "previous"});
    row_model.revealLine(ed, ed.text().lineOf(pos));
    ed.setCursor(pos);
}

/// `Alt-c`: the name under the cursor (or each name in the selection) in
/// the next case: snake_case, camelCase, PascalCase, SCREAMING_CASE,
/// kebab-case, and round again.
pub fn cycleCase(ed: *Editor) !void {
    const case = @import("../core/case.zig");
    const t = ed.text();
    var r: textobjects.Range = undefined;
    if (ed.mode == .visual) {
        r = visualRange(ed);
        exitVisual(ed);
    } else {
        const c = @min(ed.view.cursor, t.len());
        const line = t.lineOf(c);
        const ls = t.lineStart(line);
        const le = t.lineEnd(line);
        if (c >= le or !case.isNameChar(t.byteAt(c))) return;
        var start = c;
        var end = c;
        while (start > ls and case.isNameChar(t.byteAt(start - 1))) start -= 1;
        while (end < le and case.isNameChar(t.byteAt(end))) end += 1;
        // A `-` only joins words (`a - b` isn't one name).
        while (start < end and t.byteAt(start) == '-') start += 1;
        while (end > start and t.byteAt(end - 1) == '-') end -= 1;
        r = .{ .start = start, .end = end };
    }
    if (r.end <= r.start) return;
    // Each name in the range, converted; the rest as it was.
    const src = try ed.gpa.dupe(u8, t.slice(r.start, r.end));
    defer ed.gpa.free(src);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ed.gpa);
    var i: usize = 0;
    while (i < src.len) {
        if (!case.isNameChar(src[i])) {
            try out.append(ed.gpa, src[i]);
            i += 1;
            continue;
        }
        var j = i;
        while (j < src.len and case.isNameChar(src[j])) j += 1;
        const next = try case.cycle(ed.gpa, src[i..j]);
        defer ed.gpa.free(next);
        try out.appendSlice(ed.gpa, next);
        i = j;
    }
    if (std.mem.eql(u8, out.items, src)) return;
    try ed.deleteRangeKeepCursor(r.start, r.end);
    try ed.insertAt(r.start, out.items);
    ed.setCursor(r.start);
}

/// Sticky context for the window: the scope headers the top line is inside
/// (outermost first), fewer when the text under them would hide the cursor.
pub fn contextLines(ed: *Editor, out: []usize) []usize {
    if (!ed.options.sticky_context or ed.ghost != null) return out[0..0];
    const s = if (ed.buffer.syntax) |*sx| sx else return out[0..0];
    const t = ed.text();
    const top = row_model.topRow(ed).line;
    var lines = syntax_objects.contextLines(s, t, top, out);
    // The context covers its own rows: look again from the line under it.
    if (lines.len > 0 and top + lines.len < t.lineCount()) {
        var again: [8]usize = undefined;
        const more = syntax_objects.contextLines(s, t, top + lines.len, again[0..out.len]);
        if (more.len >= lines.len) {
            @memcpy(out[0..more.len], more);
            lines = out[0..more.len];
        }
    }
    // Never over the cursor's row.
    const cur = ed.cursorLine();
    var n = lines.len;
    while (n > 0 and top + n > cur) n -= 1;
    return lines[0..n];
}

pub fn exitVisual(ed: *Editor) void {
    ed.mode = .normal;
    if (ed.ghost) |*g| g.anchor = null;
    ed.placeCursor(ed.view.cursor);
}

/// The visual selection as an operator range (inclusive of the cursor char).
pub fn visualRange(ed: *Editor) operators.Range {
    return selectionRange(ed, ed.view.anchor, ed.view.cursor);
}

/// The visual selection between anchor `a` and cursor `c`.
pub fn selectionRange(ed: *Editor, a: usize, c: usize) operators.Range {
    const t = ed.text();
    if (ed.visual_line) return operators.linesRange(t, t.lineOf(@min(a, c)), t.lineOf(@max(a, c)));
    const last = @max(a, c);
    return .{ .start = @min(a, c), .end = if (last < t.len()) motions.nextChar(t, last) else last };
}

/// Selects `r` in visual mode (text objects in visual mode).
pub fn selectRange(ed: *Editor, r: operators.Range) void {
    const t = ed.text();
    if (r.linewise) ed.visual_line = true;
    ed.view.anchor = r.start;
    ed.view.cursor = if (r.end > r.start) motions.prevChar(t, r.end) else r.start;
}

/// `.`: replays the last change, with `count` replacing its count if given.
pub fn repeatLastChange(ed: *Editor, count: usize, has_count: bool) !void {
    if (ed.last_change.items.len == 0) return;
    var keys_buf: std.ArrayList(KeyEvent) = .empty;
    defer keys_buf.deinit(ed.gpa);
    const n = if (has_count) count else ed.last_change_count;
    if (n > 0) {
        var digits: [20]u8 = undefined;
        for (std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable) |d| try keys_buf.append(ed.gpa, KeyEvent.char(d));
    }
    try keys_buf.appendSlice(ed.gpa, ed.last_change.items);
    try ed.queue.insertSlice(ed.gpa, 0, keys_buf.items);
}

pub fn startMacro(ed: *Editor, register: u21) void {
    const r = std.ascii.toLower(std.math.cast(u8, register) orelse return);
    if (r < 'a' or r > 'z') return ed.setMessage(.err, "macros record into a-z", .{});
    ed.macro_register = r;
    ed.macro_keys.clearRetainingCapacity();
}

pub fn stopMacro(ed: *Editor) !void {
    const r = ed.macro_register orelse return;
    ed.macro_register = null;
    // Drop the `Q` that stopped the recording.
    const recorded = ed.macro_keys.items[0..ed.macro_keys.items.len -| 1];
    var out: std.Io.Writer.Allocating = .init(ed.gpa);
    defer out.deinit();
    for (recorded) |k| try k.format(&out.writer);
    try ed.registers.setNamed(r, out.written());
    ed.last_macro = r;
    ed.setMessage(.info, "recorded @{c}", .{r});
}

pub fn playMacro(ed: *Editor, register: u21, count: usize) !void {
    const r: u8 = if (register == '@') ed.last_macro orelse return else std.math.cast(u8, register) orelse return;
    const v = ed.registers.get(r) orelse return ed.setMessage(.err, "register {c} is empty", .{r});
    ed.last_macro = r;
    try ed.queueNotation(v.text, count);
}

pub fn undo(ed: *Editor, count: usize) !void {
    ed.cursors.clearRetainingCapacity(); // their positions no longer apply
    const b = ed.buffer;
    try b.history.commit(ed.gpa);
    for (0..count) |_| {
        const cursor = try b.history.undo(ed.gpa, b) orelse {
            ed.setMessage(.info, "already at oldest change", .{});
            break;
        };
        ed.setCursor(cursor);
    }
}

pub fn redo(ed: *Editor, count: usize) !void {
    ed.cursors.clearRetainingCapacity();
    const b = ed.buffer;
    for (0..count) |_| {
        const cursor = try b.history.redo(ed.gpa, b) orelse {
            ed.setMessage(.info, "already at newest change", .{});
            break;
        };
        ed.setCursor(cursor);
    }
}

/// Keys typed so far toward a multi-key binding.
pub fn pendingKeys(ed: *const Editor) []const KeyEvent {
    return ed.pending[0..ed.pending_len];
}

/// Everything typed for the command in progress ("2d", "\"ay"), for the status line.
pub fn showcmdKeys(ed: *const Editor) []const KeyEvent {
    return ed.showcmd[0..ed.showcmd_len];
}

/// The which-key menu for the keys typed so far (empty when nothing is pending).
pub fn whichKey(ed: *const Editor, out: []km.Continuation) []km.Continuation {
    if (ed.pending_len == 0) return out[0..0];
    return ed.keymap.continuations(ed.mode, pendingKeys(ed), out);
}
