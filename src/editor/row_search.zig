//! Search over rows (text and ghost lines), used when ghost lines are shown.

const search = @import("../core/search.zig");
const jumplist = @import("jumplist.zig");
const row_model = @import("row_model.zig");
const Editor = @import("../Editor.zig");
const Row = Editor.Row;
const SearchPrompt = Editor.SearchPrompt;

pub const RowPos = struct { row: Row, col: usize };

/// Whether search should include ghost lines: from normal mode, with ghost
/// lines present or the cursor on one (after an operator, text only).
pub fn usesRows(ed: *const Editor) bool {
    return ed.ghost != null or row_model.hasGhosts(ed);
}

pub fn promptUsesRows(ed: *const Editor, sp: *const SearchPrompt) bool {
    return sp.return_mode == .normal and (sp.origin_ghost != null or row_model.hasGhosts(ed));
}

pub fn promptOrigin(ed: *const Editor, sp: *const SearchPrompt) RowPos {
    if (sp.origin_ghost) |g| return .{ .row = .{ .line = g.line, .ghost = g.k }, .col = g.col };
    const t = &ed.buffer.text;
    const line = t.lineOf(sp.origin);
    return .{ .row = .{ .line = line }, .col = sp.origin - t.lineStart(line) };
}

/// The text of a row.
pub fn rowText(ed: *const Editor, r: Row) []const u8 {
    if (r.ghost) |k| return row_model.ghostText(ed, r.line, k);
    return ed.buffer.text.lineSlice(@min(r.line, ed.buffer.text.lineCount() - 1));
}

/// Rows in file order including lines inside closed folds (search looks there).
pub fn nextRowAll(ed: *const Editor, r: Row) Row {
    const n = ed.buffer.text.lineCount();
    if (r.ghost) |k| {
        const h = row_model.ghostHunk(ed, r.line) orelse return .{ .line = @min(r.line, n - 1) };
        if (k + 1 < h.old_count) return .{ .line = r.line, .ghost = k + 1 };
        return if (r.line < n) .{ .line = r.line } else r;
    }
    if (row_model.ghostHunk(ed, r.line + 1) != null) return .{ .line = r.line + 1, .ghost = 0 };
    return if (r.line + 1 < n) .{ .line = r.line + 1 } else r;
}

pub fn prevRowAll(ed: *const Editor, r: Row) Row {
    if (r.ghost) |k| {
        if (k > 0) return .{ .line = r.line, .ghost = k - 1 };
        return if (r.line == 0) r else .{ .line = r.line - 1 };
    }
    if (row_model.ghostHunk(ed, r.line)) |h| return .{ .line = r.line, .ghost = h.old_count - 1 };
    return if (r.line == 0) r else .{ .line = r.line - 1 };
}

pub fn firstRowAll(ed: *const Editor) Row {
    return if (row_model.ghostHunk(ed, 0) != null) .{ .line = 0, .ghost = 0 } else .{ .line = 0 };
}

pub fn lastRowAll(ed: *const Editor) Row {
    const n = ed.buffer.text.lineCount();
    if (row_model.ghostHunk(ed, n)) |h| return .{ .line = n, .ghost = h.old_count - 1 };
    return .{ .line = n - 1 };
}

/// The next match of `p` from `from` over rows in file order, wrapping.
pub fn searchRows(ed: *const Editor, p: search.Pattern, from: RowPos, forward: bool) ?struct { pos: RowPos, wrapped: bool } {
    if (p.needle.len == 0) return null;
    var ghost_total: usize = 0;
    if (ed.buffer.git) |g| for (g.hunks.items) |h| {
        ghost_total += h.old_count;
    };
    const limit = 2 * (ed.buffer.text.lineCount() + ghost_total) + 4;
    var r = from.row;
    var first = true;
    var wrapped = false;
    for (0..limit) |_| {
        const line = rowText(ed, r);
        const m = if (forward)
            (if (first) p.forward(line, from.col + 1) else p.forward(line, 0))
        else
            (if (first) p.backward(line, from.col) else p.backward(line, line.len));
        if (m) |col| return .{ .pos = .{ .row = r, .col = col }, .wrapped = wrapped };
        first = false;
        const next = if (forward) nextRowAll(ed, r) else prevRowAll(ed, r);
        if (next.eql(r)) {
            r = if (forward) firstRowAll(ed) else lastRowAll(ed);
            wrapped = true;
        } else r = next;
    }
    return null;
}

/// The cursor as a row position.
pub fn rowPos(ed: *const Editor) RowPos {
    if (ed.ghost) |g| return .{ .row = .{ .line = g.line, .ghost = g.k }, .col = g.col };
    const t = &ed.buffer.text;
    const line = t.lineOf(ed.view.cursor);
    return .{ .row = .{ .line = line }, .col = ed.view.cursor - t.lineStart(line) };
}

/// Moves the cursor to a row position (opening folds around it).
pub fn setRowPos(ed: *Editor, rp: RowPos) void {
    if (rp.row.ghost) |k| {
        if (rp.row.line > 0) row_model.revealLine(ed, rp.row.line - 1);
        const anchor = if (ed.ghost) |g| (if (g.line == rp.row.line) g.anchor else null) else null;
        ed.ghost = .{ .line = rp.row.line, .k = k, .col = rp.col, .anchor = anchor };
        ed.view.want_col = rp.col;
        return;
    }
    ed.ghost = null;
    const t = ed.text();
    row_model.revealLine(ed, rp.row.line);
    ed.setCursor(t.lineStart(rp.row.line) + @min(rp.col, t.lineLen(rp.row.line)));
}

/// `n`/`N` over rows: the [count]th match of the last search.
pub fn searchNextRows(ed: *Editor, reverse: bool, count: usize) ?RowPos {
    if (ed.last_search.items.len == 0) {
        ed.setMessage(.err, "no previous search", .{});
        return null;
    }
    const pattern = search.Pattern.init(ed.last_search.items, ed.last_search_whole_word);
    const forward = ed.last_search_forward != reverse;
    var pos = rowPos(ed);
    var wrapped = false;
    for (0..count) |_| {
        const m = searchRows(ed, pattern, pos, forward) orelse {
            ed.setMessage(.err, "pattern not found: {s}", .{ed.last_search.items});
            return null;
        };
        pos = m.pos;
        wrapped = wrapped or m.wrapped;
    }
    ed.search_highlight = true;
    const prefix: u8 = if (ed.last_search_forward) '/' else '?';
    ed.setMessage(.info, "{c}{s}{s}", .{ prefix, ed.last_search.items, if (wrapped) "  search wrapped" else "" });
    return pos;
}

/// The only match of `p` on screen (text and ghost rows), if exactly one.
pub fn onlyVisibleRowMatch(ed: *const Editor, p: search.Pattern) ?RowPos {
    if (p.needle.len == 0) return null;
    var found: ?RowPos = null;
    var r = row_model.topRow(ed);
    for (0..ed.view.rows) |i| {
        if (i > 0) {
            const next = row_model.nextRow(ed, r);
            if (next.eql(r)) break;
            r = next;
        }
        const line = rowText(ed, r);
        var at: usize = 0;
        while (p.forward(line, at)) |m| : (at = m + 1) {
            if (found != null) return null;
            found = .{ .row = r, .col = m };
        }
    }
    return found;
}

/// Like `finishSearch`, landing on a row position (possibly a ghost line).
pub fn finishSearchRow(ed: *Editor, rp: RowPos) !void {
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    if (sp.input.items().len > 0) {
        try ed.last_search.resize(ed.gpa, 0);
        try ed.last_search.appendSlice(ed.gpa, sp.input.items());
        ed.last_search_whole_word = false;
    }
    ed.last_search_forward = sp.forward;
    ed.search_highlight = true;
    ed.snipe_dot = sp.kind == .snipe and sp.return_mode != .operator;
    ed.find_dot = false;
    ed.mode = sp.return_mode;
    ed.view.top = sp.origin_top;
    if (sp.return_mode != .operator) jumplist.pushJumpAt(ed, sp.origin);
    setRowPos(ed, rp);
}

/// The pattern to highlight: the prompt while typing, else the last search.
pub fn searchPattern(ed: *const Editor) ?search.Pattern {
    if (ed.search_prompt) |*sp| {
        if (sp.kind.boxed()) return null;
        return search.Pattern.init(sp.input.items(), false);
    }
    if (!ed.search_highlight or ed.last_search.items.len == 0) return null;
    return search.Pattern.init(ed.last_search.items, ed.last_search_whole_word);
}

/// The [count]th match of the last search from `from` (`reverse` flips its
/// direction, for `N`). Reports wrapping and "[i/n]" in the status line.
pub fn searchNext(ed: *Editor, from: usize, reverse: bool, count: usize) ?usize {
    if (ed.last_search.items.len == 0) {
        ed.setMessage(.err, "no previous search", .{});
        return null;
    }
    const t = ed.text();
    const hay = t.slice(0, t.len());
    const pattern = search.Pattern.init(ed.last_search.items, ed.last_search_whole_word);
    const forward = ed.last_search_forward != reverse;
    var pos = from;
    var wrapped = false;
    for (0..count) |_| {
        const m = pattern.next(hay, pos, forward) orelse {
            ed.setMessage(.err, "pattern not found: {s}", .{ed.last_search.items});
            return null;
        };
        pos = m.pos;
        wrapped = wrapped or m.wrapped;
    }
    ed.search_highlight = true;
    const where = pattern.position(hay, pos);
    const prefix: u8 = if (ed.last_search_forward) '/' else '?';
    if (wrapped) {
        ed.setMessage(.info, "{c}{s}  [{d}/{d}]  search wrapped", .{ prefix, ed.last_search.items, where.index, where.total });
    } else {
        ed.setMessage(.info, "{c}{s}  [{d}/{d}]", .{ prefix, ed.last_search.items, where.index, where.total });
    }
    return pos;
}

/// `*` / `#`: searches for the word under the cursor.
pub fn searchWord(ed: *Editor, forward: bool, count: usize) !void {
    const t = ed.text();
    const r = @import("../core/textobjects.zig").word(t, ed.view.cursor, .inner, false, 1) orelse return;
    const word = t.slice(r.start, r.end);
    if (word.len == 0 or !search.isWord(word[0])) return ed.setMessage(.err, "no word under cursor", .{});
    try ed.last_search.resize(ed.gpa, 0);
    try ed.last_search.appendSlice(ed.gpa, word);
    ed.last_search_forward = forward;
    ed.last_search_whole_word = true;
    if (searchNext(ed, r.start, false, count)) |pos| ed.setCursor(pos);
}
