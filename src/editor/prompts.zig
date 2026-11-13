//! Prompts and search: `/` `?`, the snipe, and the boxed prompts.

const std = @import("std");
const Text = @import("../core/Text.zig");
const LineInput = @import("../input/LineInput.zig");
const search = @import("../core/search.zig");
const Lsp = @import("../lsp/Lsp.zig");
const operators = @import("../operators.zig");
const file_ops = @import("file_ops.zig");
const jumplist = @import("jumplist.zig");
const browser = @import("browser.zig");
const claude_panel = @import("claude_panel.zig");
const run_popup = @import("run_popup.zig");
const multicursor = @import("multicursor.zig");
const row_model = @import("row_model.zig");
const row_search = @import("row_search.zig");
const replacing = @import("replacing.zig");
const Editor = @import("../Editor.zig");
const git_ops = @import("git_ops.zig");
const lsp_ops = @import("lsp_ops.zig");
const RowPos = Editor.RowPos;
const SearchPrompt = Editor.SearchPrompt;
const SnipeLabel = Editor.SnipeLabel;
const snipe_keys = Editor.snipe_keys;
const PromptKind = Editor.PromptKind;

/// The text input that has focus (picker query or search prompt).
pub fn activeInput(ed: *Editor) ?*LineInput {
    return switch (ed.mode) {
        .picker => if (ed.picker) |p| &p.query else null,
        .search => if (ed.search_prompt) |*sp| &sp.input else null,
        else => null,
    };
}

/// Call after editing `activeInput()`.
pub fn inputChanged(ed: *Editor) !void {
    switch (ed.mode) {
        // (Normal mode too: the query is edited there with vim keys.)
        .picker, .picker_normal => if (ed.picker) |p| {
            try p.queryChanged();
            // The server does this search: ask it again for the new text.
            if (p.kind == .workspace_symbols) if (lsp_ops.lspFor(ed, ed.buffer)) |l| try l.requestWorkspaceSymbols(p.activeQuery());
        },
        .search => try searchIncremental(ed),
        else => {},
    }
}

/// Opens the `/` / `?` prompt, or the `s` snipe prompt. Works from normal,
/// visual and operator-pending mode (`d/foo`, `ds`).
pub fn startSearch(ed: *Editor, forward: bool, kind: PromptKind) void {
    ed.snipe_label_count = 0;
    ed.search_prompt = .{
        .forward = forward,
        .origin = ed.view.cursor,
        .origin_top = ed.view.top,
        .origin_ghost = ed.ghost,
        .return_mode = ed.mode,
        .had_highlight = ed.search_highlight,
        .kind = kind,
    };
    ed.mode = .search;
}

/// Opens the rename prompt, prefilled with the identifier under the cursor.
pub fn startRename(ed: *Editor) !void {
    if (lsp_ops.languageServer(ed) == null) return;
    const t = ed.text();
    const r = @import("../core/textobjects.zig").word(t, ed.view.cursor, .inner, false, 1) orelse
        return ed.setMessage(.err, "no symbol under cursor", .{});
    const name = t.slice(r.start, r.end);
    if (name.len == 0 or !search.isWord(name[0])) return ed.setMessage(.err, "no symbol under cursor", .{});
    startSearch(ed, true, .rename);
    try ed.search_prompt.?.input.set(ed.gpa, name);
}

/// Sends the rename typed into the prompt.
pub fn finishRename(ed: *Editor) !void {
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.view.cursor = sp.origin;
    const new_name = sp.input.items();
    if (new_name.len == 0) return;
    const l = lsp_ops.languageServer(ed) orelse return;
    try l.requestRename(ed, sp.origin, new_name);
}

/// Applies edits from the language server (a rename): opens each file,
/// applies its edits bottom-up as one undo step, then returns to the buffer
/// the cursor was in.
pub fn applyEdits(ed: *Editor, edits: []const Lsp.TextEdit) !void {
    if (edits.len == 0) return ed.setMessage(.info, "nothing to change", .{});
    const home = ed.buffer;
    const home_cursor = ed.view.cursor;
    var files: usize = 0;
    const done = try ed.gpa.alloc(bool, edits.len);
    defer ed.gpa.free(done);
    @memset(done, false);
    for (edits, 0..) |first, i| {
        if (done[i]) continue;
        try ed.openFile(first.path);
        files += 1;
        // This file's edits, last first, so earlier positions stay valid.
        var mine: std.ArrayList(Lsp.TextEdit) = .empty;
        defer mine.deinit(ed.gpa);
        for (edits[i..], i..) |e, j| if (std.mem.eql(u8, e.path, first.path)) {
            try mine.append(ed.gpa, e);
            done[j] = true;
        };
        std.mem.sort(Lsp.TextEdit, mine.items, {}, struct {
            fn later(_: void, a: Lsp.TextEdit, b: Lsp.TextEdit) bool {
                return if (a.start_line != b.start_line) a.start_line > b.start_line else a.start_col > b.start_col;
            }
        }.later);
        for (mine.items) |e| {
            const start = offsetOf(ed, e.start_line, e.start_col);
            const end = offsetOf(ed, e.end_line, e.end_col);
            try ed.deleteRangeKeepCursor(start, @max(start, end));
            try ed.insertAt(start, e.text);
        }
        try ed.buffer.history.commit(ed.gpa);
        ed.buffer.modified = ed.buffer.history.isModified();
    }
    ed.switchTo(home);
    ed.setCursor(home_cursor);
    ed.setMessage(.info, "renamed: {d} edit(s) in {d} file(s) (SPC s to save)", .{ edits.len, files });
}

/// Byte offset of a (line, column) position, clamped to the text.
pub fn offsetOf(ed: *Editor, line: usize, col: usize) usize {
    const t = ed.text();
    if (line >= t.lineCount()) return t.len();
    return t.lineStart(line) + @min(col, t.lineLen(line));
}

/// Moves to the first match as the pattern is typed (back to the origin when
/// there is none). A snipe jumps once a single match is left on screen.
pub fn searchIncremental(ed: *Editor) !void {
    const sp = &(ed.search_prompt orelse return);
    ed.snipe_label_count = 0;
    if (sp.kind.boxed()) return;
    if (sp.kind == .select_in) {
        // Only shows the matches (the cursors come on <CR> / <Tab>).
        try ed.last_search.resize(ed.gpa, 0);
        try ed.last_search.appendSlice(ed.gpa, sp.input.items());
        ed.last_search_whole_word = false;
        ed.search_highlight = sp.input.items().len > 0;
        return;
    }
    ed.view.cursor = sp.origin;
    ed.view.top = sp.origin_top;
    ed.ghost = sp.origin_ghost;
    const pattern = search.Pattern.init(sp.input.items(), false);
    if (row_search.promptUsesRows(ed, sp)) {
        // Ghost lines on screen: matches in them count too.
        if (sp.kind == .snipe) {
            if (row_search.onlyVisibleRowMatch(ed, pattern)) |rp| return row_search.finishSearchRow(ed, rp);
        }
        if (sp.kind == .snipe) try labelSnipeMatches(ed, sp, pattern);
        const pos = promptRowMatch(ed, sp, pattern) orelse return;
        row_search.setRowPos(ed, pos);
        ed.search_highlight = true;
        return;
    }
    if (sp.kind == .snipe) {
        if (onlyVisibleMatch(ed, pattern)) |pos| return finishSearch(ed, pos);
        try labelSnipeMatches(ed, sp, pattern);
    }
    ed.view.cursor = promptMatch(ed, sp, pattern) orelse return;
    ed.search_highlight = true;
}

/// A snipe from normal or visual mode goes to the match nearest the cursor,
/// before it or after; `/`, `?` and a snipe after an operator go one way.
pub fn snipesNearest(sp: *const SearchPrompt) bool {
    return sp.kind == .snipe and sp.return_mode != .operator;
}

/// The match the prompt goes to: for a snipe the nearest one (by lines, then
/// by bytes; the one after the cursor on a tie), else the next one its way,
/// around the end of the text.
pub fn promptMatch(ed: *Editor, sp: *const SearchPrompt, pattern: search.Pattern) ?usize {
    const t = ed.text();
    const hay = t.slice(0, t.len());
    if (snipesNearest(sp)) {
        const after = pattern.forward(hay, sp.origin + 1);
        const before = pattern.backward(hay, sp.origin);
        const a = after orelse return before;
        const b = before orelse return a;
        const line = t.lineOf(sp.origin);
        const down = t.lineOf(a) - line;
        const up = line - t.lineOf(b);
        if (down != up) return if (down < up) a else b;
        return if (a - sp.origin <= sp.origin - b) a else b;
    }
    return (pattern.next(hay, sp.origin, sp.forward) orelse return null).pos;
}

/// The same over rows (with ghost lines on screen).
pub fn promptRowMatch(ed: *const Editor, sp: *const SearchPrompt, pattern: search.Pattern) ?RowPos {
    const from = row_search.promptOrigin(ed, sp);
    const one_way = row_search.searchRows(ed, pattern, from, sp.forward) orelse return null;
    if (!snipesNearest(sp)) return one_way.pos;
    const after = row_search.searchRows(ed, pattern, from, true) orelse return null;
    const before = row_search.searchRows(ed, pattern, from, false) orelse return null;
    if (before.wrapped) return after.pos;
    if (after.wrapped) return before.pos;
    const down = after.pos.row.line - from.row.line;
    const up = from.row.line - before.pos.row.line;
    return if (down <= up) after.pos else before.pos;
}

/// The snipe's labels while its prompt is open.
pub fn snipeLabels(ed: *const Editor) []const SnipeLabel {
    const sp = ed.search_prompt orelse return &.{};
    return if (sp.kind == .snipe) ed.snipe_label_buf[0..ed.snipe_label_count] else &.{};
}

/// Whether `a` is nearer `origin` than `b`: by lines, then by bytes, the one
/// after the cursor on a tie.
pub fn nearer(t: *const Text, origin: usize, a: usize, b: usize) bool {
    const line = t.lineOf(origin);
    const la = t.lineOf(a);
    const lb = t.lineOf(b);
    const da = @max(la, line) - @min(la, line);
    const db = @max(lb, line) - @min(lb, line);
    if (da != db) return da < db;
    const ba = @max(a, origin) - @min(a, origin);
    const bb = @max(b, origin) - @min(b, origin);
    return if (ba != bb) ba < bb else a > b;
}

/// Gives the matches on screen a key each, the nearest ones the easiest
/// keys. A key that could be the pattern's next character (the one after
/// some match) is left out, so typing on never jumps by accident.
pub fn labelSnipeMatches(ed: *Editor, sp: *const SearchPrompt, pattern: search.Pattern) !void {
    if (pattern.needle.len == 0) return;
    const t = ed.text();
    const first = @min(ed.view.top, t.lineCount() - 1);
    const last = @min(ed.view.top + ed.view.rows, t.lineCount()) - 1;
    const start = t.lineStart(first);
    const visible = t.slice(start, t.lineEnd(last));
    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(ed.gpa);
    var continues: [256]bool = @splat(false);
    var at: usize = 0;
    while (pattern.forward(visible, at)) |m| : (at = m + 1) {
        if (start + m != sp.origin) try matches.append(ed.gpa, start + m);
        const end = m + pattern.needle.len;
        if (end < visible.len) continues[std.ascii.toLower(visible[end])] = true;
    }
    const Ctx = struct { t: *const Text, origin: usize };
    std.mem.sort(usize, matches.items, Ctx{ .t = t, .origin = sp.origin }, struct {
        fn f(c: Ctx, a: usize, b: usize) bool {
            return nearer(c.t, c.origin, a, b);
        }
    }.f);
    var k: usize = 0;
    for (matches.items) |pos| {
        while (k < snipe_keys.len and continues[snipe_keys[k]]) k += 1;
        if (k == snipe_keys.len) break;
        ed.snipe_label_buf[ed.snipe_label_count] = .{ .pos = pos, .end = pos + pattern.needle.len, .key = snipe_keys[k] };
        ed.snipe_label_count += 1;
        k += 1;
    }
}

/// A key typed into the snipe prompt that is a match's label: jumps there.
pub fn takeSnipeLabel(ed: *Editor, cp: u21) !bool {
    for (snipeLabels(ed)) |sl| if (sl.key == cp) {
        const sp = &ed.search_prompt.?;
        if (!row_search.promptUsesRows(ed, sp)) {
            try finishSearch(ed, sl.pos);
            return true;
        }
        const t = ed.text();
        const line = t.lineOf(sl.pos);
        try row_search.finishSearchRow(ed, .{ .row = .{ .line = line }, .col = sl.pos - t.lineStart(line) });
        return true;
    };
    return false;
}

/// The position of the match of `pattern` if it is the only one on screen.
pub fn onlyVisibleMatch(ed: *Editor, pattern: search.Pattern) ?usize {
    if (pattern.needle.len == 0) return null;
    const t = ed.text();
    const first = @min(ed.view.top, t.lineCount() - 1);
    const last = @min(ed.view.top + ed.view.rows, t.lineCount()) - 1;
    const start = t.lineStart(first);
    const visible = t.slice(start, t.lineEnd(last));
    const m = pattern.forward(visible, 0) orelse return null;
    if (pattern.forward(visible, m + 1) != null) return null;
    return start + m;
}

/// Closes the prompt (keeping its text as the last search for `n`/`N`) and
/// moves to `pos`, or applies the pending operator up to it.
pub fn finishSearch(ed: *Editor, pos: usize) !void {
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
    ed.view.cursor = sp.origin;
    ed.view.top = sp.origin_top;
    if (sp.return_mode != .operator) jumplist.pushJumpAt(ed, sp.origin);
    if (sp.return_mode == .operator) {
        return ed.applyPending(operators.motionRange(ed.text(), sp.origin, pos, .exclusive));
    }
    row_model.revealLine(ed, ed.text().lineOf(pos));
    ed.setCursor(pos);
}

/// <CR>: the next match from where the prompt opened (an empty pattern
/// repeats the last search, like vim).
pub fn acceptSearch(ed: *Editor) !void {
    const sp = &(ed.search_prompt orelse return);
    switch (sp.kind) {
        .rename => return finishRename(ed),
        .git_commit => return git_ops.finishGitCommit(ed),
        .git_remote => return git_ops.finishGitRemote(ed),
        .new_file, .save_as, .rename_file, .copy_file => |k| return file_ops.finishFilePrompt(ed, k),
        .run_command => |k| return run_popup.finishRunPrompt(ed, k),
        .ask_claude => return claude_panel.finishAskClaude(ed),
        .browse_new_folder, .browse_new_file, .browse_rename, .browse_move => |k| return browser.finishBrowsePrompt(ed, k),
        .select_in => return multicursor.cursorsFromPrompt(ed),
        .replace => return replacing.finishReplace(ed),
        .search, .snipe => {},
    }
    if (sp.input.items().len > 0) {
        try ed.last_search.resize(ed.gpa, 0);
        try ed.last_search.appendSlice(ed.gpa, sp.input.items());
        ed.last_search_whole_word = false;
    }
    ed.last_search_forward = sp.forward;
    if (row_search.promptUsesRows(ed, sp)) {
        const pattern = search.Pattern.init(ed.last_search.items, false);
        const pos = promptRowMatch(ed, sp, pattern) orelse {
            ed.setMessage(.err, "pattern not found: {s}", .{ed.last_search.items});
            return cancelSearch(ed);
        };
        return row_search.finishSearchRow(ed, pos);
    }
    const pos = (if (snipesNearest(sp)) promptMatch(ed, sp, search.Pattern.init(ed.last_search.items, false)) else null) orelse
        row_search.searchNext(ed, sp.origin, false, 1) orelse return cancelSearch(ed);
    try finishSearch(ed, pos);
}

pub fn cancelSearch(ed: *Editor) void {
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.view.cursor = sp.origin;
    ed.view.top = sp.origin_top;
    ed.ghost = sp.origin_ghost;
    ed.search_highlight = sp.had_highlight;
    if (sp.return_mode == .operator) ed.resetCommand();
    // Cancelling one of the browser's prompts goes back to the browser.
    switch (sp.kind) {
        .browse_new_folder, .browse_new_file, .browse_rename, .browse_move => browser.reopenBrowser(ed, null),
        .replace => replacing.cancelReplace(ed),
        else => {},
    }
}
