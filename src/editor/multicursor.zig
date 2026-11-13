//! Multicursor: commands typed at the primary cursor are replayed at the others.

const std = @import("std");
const motions = @import("../core/motions.zig");
const keys = @import("../input/keys.zig");
const KeyEvent = keys.KeyEvent;
const search = @import("../core/search.zig");
const operators = @import("../operators.zig");
const textobjects = @import("../core/textobjects.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const code_motion = @import("code_motion.zig");
const prompts = @import("prompts.zig");
const Cursor = Editor.Cursor;

/// After each key: replays the command once it is complete.
pub fn multiAfterKey(ed: *Editor) void {
    if (ed.replaying) return;
    const done = ed.mode == .insert or ed.isIdle();
    if (!done) return;
    defer ed.multi_keys.clearRetainingCapacity();
    if (ed.multi_once or ed.mode == .picker or ed.mode == .picker_normal or ed.cursors.items.len == 0) return;
    replayAtCursors(ed, ed.multi_keys.items);
}

pub fn saveCursor(ed: *const Editor) Cursor {
    return .{ .pos = ed.view.cursor, .anchor = ed.view.anchor, .want_col = ed.view.want_col };
}

pub fn replayAtCursors(ed: *Editor, keys_: []const KeyEvent) void {
    const final_mode = ed.mode;
    const final_visual_line = ed.visual_line;
    const final_highlight = ed.search_highlight;
    // `.` should repeat the primary's change, recorded once.
    const capturing = ed.capturing;
    const capture_repeatable = ed.capture_repeatable;
    ed.capturing = false;

    ed.primary_saved = saveCursor(ed);
    ed.replaying = true;
    for (0..ed.cursors.items.len) |i| {
        const c = ed.cursors.items[i];
        const len = ed.text().len();
        ed.view.cursor = @min(c.pos, len);
        ed.view.anchor = @min(c.anchor, len);
        ed.view.want_col = c.want_col;
        ed.mode = ed.multi_start.mode;
        ed.visual_line = ed.multi_start.visual_line;
        ed.op = null;
        ed.count = 0;
        ed.pending_len = 0;
        ed.register = null;
        ed.awaiting_register = false;
        ed.awaiting_char = null;
        for (keys_) |k| ed.handleKeyInner(k) catch {
            ed.resetCommand();
            break;
        };
        if (ed.search_prompt != null) prompts.cancelSearch(ed);
        ed.cursors.items[i] = saveCursor(ed);
    }
    ed.replaying = false;
    const p = ed.primary_saved.?;
    ed.primary_saved = null;
    ed.view.cursor = p.pos;
    ed.view.anchor = p.anchor;
    ed.view.want_col = p.want_col;
    ed.mode = final_mode;
    ed.visual_line = final_visual_line;
    ed.search_highlight = final_highlight;
    ed.op = null;
    ed.awaiting_char = null;
    ed.capturing = capturing;
    ed.capture_repeatable = capture_repeatable;
    mergeCursors(ed);
}

/// Keeps stored cursors on the same text when `[start, end)` is replaced by
/// `inserted` bytes (an insert has start == end, a delete inserted == 0).
pub fn shiftCursors(ed: *Editor, start: usize, end: usize, inserted: usize) void {
    const S = struct {
        fn shift(p: *usize, s: usize, e: usize, n: usize) void {
            if (p.* >= e and (p.* > s or n > 0)) {
                p.* = p.* - (e - s) + n;
            } else if (p.* > s) p.* = s;
        }
    };
    for (ed.cursors.items) |*c| {
        S.shift(&c.pos, start, end, inserted);
        S.shift(&c.anchor, start, end, inserted);
    }
    if (ed.primary_saved) |*c| {
        S.shift(&c.pos, start, end, inserted);
        S.shift(&c.anchor, start, end, inserted);
    }
    for (ed.jumps.items) |*j| if (j.buffer == ed.buffer) S.shift(&j.pos, start, end, inserted);
    for (ed.marks.items) |*m| if (m.buffer == ed.buffer) S.shift(&m.pos, start, end, inserted);
    // Placeholders grow with typing at their end, not their start.
    if (ed.snippet) |sn| if (sn.buffer == ed.buffer) for (sn.stops) |*r| {
        if (start == end and inserted > 0) {
            if (r[0] > start) r[0] += inserted;
            if (r[1] >= start) r[1] += inserted;
        } else {
            S.shift(&r[0], start, end, inserted);
            S.shift(&r[1], start, end, inserted);
        }
    };
    // Other windows on this buffer keep their place too.
    for (ed.window_list.items) |w| if (w != ed.window and w.buffer == ed.buffer) {
        S.shift(&w.view.cursor, start, end, inserted);
        S.shift(&w.view.anchor, start, end, inserted);
    };
}

/// Drops cursors that landed on the primary or on each other.
pub fn mergeCursors(ed: *Editor) void {
    const len = ed.text().len();
    var out: usize = 0;
    outer: for (ed.cursors.items) |c| {
        var cc = c;
        cc.pos = @min(cc.pos, len);
        cc.anchor = @min(cc.anchor, len);
        if (cc.pos == ed.view.cursor) continue;
        for (ed.cursors.items[0..out]) |o| if (o.pos == cc.pos) continue :outer;
        ed.cursors.items[out] = cc;
        out += 1;
    }
    ed.cursors.items.len = out;
}

/// Leaves a cursor where the primary is (before the primary moves on).
pub fn addCursorHere(ed: *Editor) !void {
    try ed.cursors.append(ed.gpa, saveCursor(ed));
}

pub fn clearCursors(ed: *Editor) void {
    ed.cursors.clearRetainingCapacity();
}

pub fn removeLastCursor(ed: *Editor) void {
    if (ed.cursors.pop()) |c| {
        ed.view.cursor = c.pos;
        ed.view.anchor = c.anchor;
        ed.placeCursor(c.pos);
    }
}

pub fn reportCursors(ed: *Editor) void {
    ed.setMessage(.info, "{d} cursors (qq or Esc removes them)", .{ed.cursors.items.len + 1});
}

/// What `gzn`/`gzm` look for: the charwise selection, else the word under
/// the cursor (whole words only).
pub fn matchTarget(ed: *Editor) ?struct { start: usize, end: usize, whole: bool } {
    const t = ed.text();
    if (ed.mode == .visual and !ed.visual_line) {
        const r = code_motion.visualRange(ed);
        if (r.end > r.start) return .{ .start = r.start, .end = r.end, .whole = false };
        return null;
    }
    const r = textobjects.word(t, ed.view.cursor, .inner, false, 1) orelse return null;
    if (r.end == r.start or !search.isWord(t.byteAt(r.start))) return null;
    return .{ .start = r.start, .end = r.end, .whole = true };
}

/// `qn` / `qN` / `qs` / `qa`: a cursor on the next/previous match of the
/// word (or selection), skipping one, or on every match.
pub fn cursorAtMatch(ed: *Editor, how: enum { next, previous, skip, all }) !void {
    const target = matchTarget(ed) orelse return ed.setMessage(.info, "no word under the cursor", .{});
    const t = ed.text();
    const hay = t.slice(0, t.len());
    const needle = try ed.gpa.dupe(u8, hay[target.start..target.end]);
    defer ed.gpa.free(needle);
    const pattern = search.Pattern.init(needle, target.whole);
    const visual = ed.mode == .visual;
    // Where the primary sits inside the match (kept at each new cursor).
    const offset = ed.view.cursor - target.start;
    const anchor_offset = ed.view.anchor -| target.start;
    const place = struct {
        fn at(m: usize, off: usize, aoff: usize, vis: bool) Cursor {
            return .{ .pos = m + off, .anchor = if (vis) m + aoff else m + off };
        }
    }.at;

    if (how == .all) {
        var from: usize = 0;
        while (pattern.forward(hay, from)) |m| : (from = m + 1) {
            if (m == target.start) continue;
            try ed.cursors.append(ed.gpa, place(m, offset, anchor_offset, visual));
        }
        mergeCursors(ed);
        return reportCursors(ed);
    }
    const m = pattern.next(hay, target.start, how != .previous) orelse return;
    if (m.pos == target.start) return ed.setMessage(.info, "no other match", .{});
    if (how != .skip) try addCursorHere(ed);
    const c = place(m.pos, offset, anchor_offset, visual);
    ed.view.cursor = c.pos;
    ed.view.anchor = c.anchor;
    ed.view.want_col = null;
    row_model.revealLine(ed, t.lineOf(c.pos));
    mergeCursors(ed);
    reportCursors(ed);
}

/// Visual `I` / `A` (and `qI` / `qA`): a cursor at the start (first
/// non-blank) or end of every selected line. `insert` starts typing there.
pub fn cursorsOnLines(ed: *Editor, at_end: bool, insert: bool) !void {
    if (ed.mode != .visual) return;
    const t = ed.text();
    const first = t.lineOf(@min(ed.view.anchor, ed.view.cursor));
    const last = t.lineOf(@max(ed.view.anchor, ed.view.cursor));
    code_motion.exitVisual(ed);
    clearCursors(ed);
    var line = last;
    while (true) : (line -= 1) {
        const ls = t.lineStart(line);
        const le = t.lineEnd(line);
        const pos = if (!at_end) motions.firstNonBlank(t, line) else if (insert or le == ls) le else motions.prevChar(t, le);
        if (line == first) {
            ed.view.cursor = pos;
            ed.view.anchor = pos;
            break;
        }
        try ed.cursors.append(ed.gpa, .{ .pos = pos, .anchor = pos });
    }
    if (insert) ed.setMode(.insert) else ed.placeCursor(ed.view.cursor);
    reportCursors(ed);
}

/// `s` (visual: in the selection; normal: in the whole file): asks for text, then puts a cursor on every match of it
/// inside the selection, each match selected (`c` changes them all).
pub fn startSelectIn(ed: *Editor) void {
    if (ed.ghost != null or (ed.mode != .visual and ed.mode != .normal)) return;
    const t = ed.text();
    // From normal mode there is no selection: the whole file.
    var r: operators.Range = if (ed.mode == .visual) code_motion.visualRange(ed) else .{ .start = 0, .end = t.len() };
    if (ed.visual_line) {
        r.start = t.lineStart(t.lineOf(r.start));
        r.end = t.lineEnd(t.lineOf(@max(r.start, r.end -| 1)));
    }
    prompts.startSearch(ed, true, .select_in);
    ed.search_prompt.?.within_start = r.start;
    ed.search_prompt.?.within_end = r.end;
}

/// <Tab> in the snipe (`s`) or search (`/`) prompt: a cursor on every match
/// (on screen for snipe, in the file for search), each match selected, so
/// `c` changes them all and <Esc> leaves plain cursors.
pub fn cursorsFromPrompt(ed: *Editor) !void {
    const sp = ed.search_prompt orelse return;
    // In the replace prompt, <Tab> skips a line instead.
    if (sp.kind == .replace) if (ed.replace) |r| return r.toggle();
    if (sp.kind != .search and sp.kind != .snipe and sp.kind != .select_in) return;
    const needle = try ed.gpa.dupe(u8, sp.input.items());
    defer ed.gpa.free(needle);
    if (needle.len == 0) return;
    const t = ed.text();
    var from: usize = 0;
    var to = t.len();
    if (sp.kind == .select_in) {
        from = sp.within_start;
        to = @min(sp.within_end, t.len());
    }
    if (sp.kind == .snipe) {
        from = t.lineStart(@min(sp.origin_top, t.lineCount() - 1));
        to = t.lineEnd(@min(sp.origin_top + ed.view.rows, t.lineCount()) - 1);
    }
    prompts.cancelSearch(ed);
    const hay = t.slice(0, to);
    const pattern = search.Pattern.init(needle, false);
    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(ed.gpa);
    var i = from;
    while (pattern.forward(hay, i)) |m| : (i = m + needle.len) try matches.append(ed.gpa, m);
    if (matches.items.len == 0) return ed.setMessage(.info, "no matches", .{});

    // The primary takes the match nearest the cursor.
    var primary: usize = 0;
    for (matches.items, 0..) |m, k| {
        if (m <= ed.view.cursor) primary = k;
    }
    clearCursors(ed);
    if (ed.mode != .visual) ed.enterVisual(false);
    ed.visual_line = false;
    const last_off = motions.prevChar(t, matches.items[0] + needle.len) - matches.items[0];
    for (matches.items, 0..) |m, k| {
        const c: Cursor = .{ .pos = m + last_off, .anchor = m };
        if (k == primary) {
            ed.view.cursor = c.pos;
            ed.view.anchor = c.anchor;
        } else try ed.cursors.append(ed.gpa, c);
    }
    reportCursors(ed);
}
