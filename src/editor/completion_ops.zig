//! Completion: asking the server, showing and narrowing the list, accepting an item; emmet.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Lsp = @import("../lsp/Lsp.zig");
const Completion = @import("../lsp/Completion.zig");
const tags = @import("../tags.zig");
const emmet = @import("../emmet.zig");
const snippets = @import("../snippets.zig");
const Snippet = @import("../lsp/Snippet.zig");
const indenting = @import("indenting.zig");
const snippet_ops = @import("snippet_ops.zig");
const after_typing = @import("after_typing.zig");
const sql_ops = @import("sql_ops.zig");
const Editor = @import("../Editor.zig");
const lsp_ops = @import("lsp_ops.zig");

/// Asks for completions for the word starting at `start`, unless the answer
/// to that same question is still on its way.
pub fn askCompletion(ed: *Editor, l: *Lsp, start: usize) void {
    if (ed.completion_pending and ed.completion_asked == start) return;
    ed.completion_asked = start;
    ed.completion_pending = true;
    l.requestCompletion(ed, start) catch {
        ed.completion_pending = false;
    };
}

/// After deleting in insert mode (<BS>, <C-w>): completion comes back for
/// what is left of the word, instead of staying gone until the word is
/// retyped from its start.
pub fn afterDeleted(ed: *Editor) void {
    if (ed.cursors.items.len > 0 or ed.replaying) return;
    if (sql_ops.isSql(ed) and lsp_ops.lspFor(ed, ed.buffer) == null) {
        if (ed.completion != null) return;
        const start = after_typing.wordStart(ed);
        const t = ed.text();
        const after_dot = ed.view.cursor > 0 and t.byteAt(ed.view.cursor - 1) == '.';
        if (ed.view.cursor > start or after_dot) sql_ops.sqlCompletion(ed, start);
        return;
    }
    const l = lsp_ops.lspFor(ed, ed.buffer) orelse return;
    // A list is still held for this word: it was refiltered already.
    if (ed.completion) |c| {
        if (c.incomplete) askCompletion(ed, l, c.word_start);
        return;
    }
    const t = ed.text();
    const cur = ed.view.cursor;
    const start = after_typing.wordStart(ed);
    const after_trigger = cur > t.lineStart(ed.cursorLine()) and l.isTrigger(t.byteAt(cur - 1));
    if (cur == start and !after_trigger) return; // nothing here to complete
    askCompletion(ed, l, start);
}

/// The completion popup, when it has something to show. (A list with no
/// match for a typo is kept, out of sight, until the text matches again.)
pub fn completionShown(ed: *Editor) ?*Completion {
    const c = &(ed.completion orelse return null);
    return if (c.shown.items.len > 0) c else null;
}

/// Manual trigger (<C-n> / <C-Space> in insert mode).
pub fn requestCompletion(ed: *Editor) !void {
    const l = lsp_ops.languageServer(ed) orelse return;
    const start = after_typing.wordStart(ed);
    ed.completion_asked = start;
    ed.completion_pending = true;
    try l.requestCompletion(ed, start);
}

/// A completion reply arrived: show it if the cursor is still on that word.
pub fn showCompletion(ed: *Editor, b: *Buffer, word_start: usize, result: std.json.Value) !void {
    ed.completion_pending = false;
    if (b != ed.buffer or ed.mode != .insert or ed.view.cursor < word_start) return;
    if (ed.text().lineOf(word_start) != ed.cursorLine()) return;
    after_typing.closeCompletion(ed);
    ed.completion = try Completion.fromJson(ed.gpa, result, word_start);
    // The server's own idea of where the word starts wins over ours (zls
    // completes builtins from after the `@`, and filters without it).
    if (ed.completion.?.edit_col) |col| {
        const start = ed.text().lineStart(ed.cursorLine()) + col;
        if (start <= ed.view.cursor) ed.completion.?.word_start = start;
    }
    // Words of the file as well: the server may not have parsed it.
    if (ed.text().len() <= 2 << 20) {
        const t = ed.text();
        const src = t.slice(0, t.len());
        const ws = ed.completion.?.word_start;
        // Between tags: elements, and in JSX the file's components
        // (`view` -> `<View></View>`).
        const kind = tags.kindOf(ed);
        if (kind != .none and tags.childAt(ed, kind, src, ws)) {
            var unit_buf: [16]u8 = undefined;
            try ed.completion.?.addMarkup(src, ws, kind == .jsx, indenting.indentUnit(ed, &unit_buf));
        }
        try ed.completion.?.addWords(src, ws);
        // Our snippets for this kind of file.
        if (ed.buffer.syntax) |syn| {
            const lists = snippets.forFile(syn.lang.name, ed.buffer.path orelse "");
            const ls = t.lineStart(t.lineOf(ws));
            const line = t.slice(ls, t.lineEnd(t.lineOf(ws)));
            const indent = line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];
            var unit_buf: [16]u8 = undefined;
            try ed.completion.?.addSnippets(lists, indent, indenting.indentUnit(ed, &unit_buf));
        }
    }
    try refreshCompletion(ed);
}

/// A type is expected at `pos`: after `name:` (maybe with `*`, `?`, `!`,
/// `[]` or `const` in between), as in `fn f(a: *Actor)`.
pub fn typeExpected(ed: *Editor, pos: usize) bool {
    const t = ed.text();
    const ls = t.lineStart(t.lineOf(pos));
    var p = pos;
    while (p > ls) {
        const b = t.byteAt(p - 1);
        if (b == ' ' or b == '*' or b == '?' or b == '!' or b == '[' or b == ']') {
            p -= 1;
            continue;
        }
        if (b == 't' and p - ls >= 5 and std.mem.eql(u8, t.slice(p - 5, p), "const")) {
            p -= 5;
            continue;
        }
        return b == ':' and !(p - 1 > ls and t.byteAt(p - 2) == ':');
    }
    return false;
}

/// Re-filters the popup for the text typed so far, closing it when the
/// cursor left the word or nothing matches.
pub fn refreshCompletion(ed: *Editor) !void {
    const c = &(ed.completion orelse return);
    const t = ed.text();
    const valid = ed.mode == .insert and ed.view.cursor >= c.word_start and
        t.lineOf(c.word_start) == ed.cursorLine();
    if (!valid) return after_typing.closeCompletion(ed);
    const typed = t.slice(c.word_start, ed.view.cursor);
    for (typed) |b| if (!after_typing.isNameChar(ed, b)) return after_typing.closeCompletion(ed);
    try c.filter(ed.gpa, typed, typeExpected(ed, c.word_start));
    // No match for what is typed (a typo, say): the list is kept, hidden,
    // and returns as soon as the text matches again. An empty answer has
    // nothing to bring back.
    if (c.items.len == 0) after_typing.closeCompletion(ed);
}

/// Replaces the typed word with the selected item.
/// Typing `(` while the suggestions are open takes the selected one, as
/// Enter would, but only its name: the `(` that follows is the call's own
/// (with its closing pair), so `drawtex(` becomes `drawText(|)`, not
/// `drawText(args)(`.
pub fn commitCompletionName(ed: *Editor) !void {
    const c = completionShown(ed) orelse return;
    const item = c.current() orelse return;
    const start = c.word_start;
    var snip: ?Snippet = null;
    defer if (snip) |s| s.deinit(ed.gpa);
    // What the suggestion inserts, up to where its arguments begin.
    var full: []const u8 = item.insert;
    if (item.snippet) {
        snip = try Snippet.parse(ed.gpa, item.insert);
        full = snip.?.text;
    }
    const name_end = std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    const name = try ed.gpa.dupe(u8, if (name_end > 0) full[0..name_end] else item.label);
    defer ed.gpa.free(name);
    after_typing.closeCompletion(ed);
    try ed.deleteRange(start, ed.view.cursor);
    try ed.insertText(name);
}

pub fn acceptCompletion(ed: *Editor) !void {
    const c = &(ed.completion orelse return);
    const item = c.current() orelse return after_typing.closeCompletion(ed);
    const insert = try ed.gpa.dupe(u8, item.insert);
    defer ed.gpa.free(insert);
    const is_snippet = item.snippet;
    const ours = item.user_snippet or item.markup;
    // What comes next is suggested too (a CSS property's values).
    const again = item.again;
    defer if (again) if (lsp_ops.lspFor(ed, ed.buffer)) |l| askCompletion(ed, l, after_typing.wordStart(ed));
    const start = c.word_start;
    // A function (by its kind, or text that ends in a call when the server
    // doesn't say): <Tab> after it can end the statement with `;`.
    const is_call = !ours and (item.call or std.mem.endsWith(u8, std.mem.trimEnd(u8, insert, "$0"), ")"));
    after_typing.closeCompletion(ed);
    try ed.deleteRange(start, ed.view.cursor);
    if (!is_snippet) {
        try ed.insertText(insert);
        if (is_call) callEnded(ed);
        return;
    }
    // A snippet: insert its text, then fill in the placeholders.
    const snip = try Snippet.parse(ed.gpa, insert);
    defer snip.deinit(ed.gpa);
    try ed.insertText(snip.text);
    try snippet_ops.startSnippet(ed, start, snip, is_call);
    if (ours) if (ed.snippet) |*sn| {
        sn.keep_defaults = true;
    };
}

/// Insert-mode <Tab> after an Emmet abbreviation in markup (`div`,
/// `ul>li*3`, `.card`): the markup, with tab stops in it. False when there
/// is none here.
pub fn expandEmmet(ed: *Editor) !bool {
    if (ed.cursors.items.len > 0) return false;
    const kind = tags.kindOf(ed);
    if (kind == .none) return false;
    const t = ed.text();
    const pos = ed.view.cursor;
    const ls = t.lineStart(t.lineOf(pos));
    const line = t.slice(ls, pos);
    const off = emmetStart(line);
    const abbr = line[off..];
    if (!emmet.looksLikeAbbreviation(abbr, kind == .jsx)) return false;
    const start = ls + off;
    if (!tags.markupAt(ed, kind, t.slice(0, t.len()), start)) return false;
    var unit_buf: [16]u8 = undefined;
    const indent = line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];
    const indent_copy = try ed.gpa.dupe(u8, indent);
    defer ed.gpa.free(indent_copy);
    const abbr_copy = try ed.gpa.dupe(u8, abbr);
    defer ed.gpa.free(abbr_copy);
    const src = (try emmet.expand(ed.gpa, abbr_copy, .{ .jsx = kind == .jsx, .unit = indenting.indentUnit(ed, &unit_buf), .indent = indent_copy })) orelse return false;
    defer ed.gpa.free(src);
    const snip = try Snippet.parse(ed.gpa, src);
    defer snip.deinit(ed.gpa);
    after_typing.closeCompletion(ed);
    try ed.deleteRange(start, pos);
    try ed.insertText(snip.text);
    try snippet_ops.startSnippet(ed, start, snip, false);
    return true;
}

/// Where the abbreviation before the end of `line` starts: back to a
/// space, or to the `>` of a tag written before it (`<View>div` -> `div`).
pub fn emmetStart(line: []const u8) usize {
    var i = line.len;
    var depth: usize = 0;
    while (i > 0) : (i -= 1) {
        const b = line[i - 1];
        if (b == ']' or b == '}' or b == ')') {
            depth += 1;
        } else if (b == '[' or b == '{' or b == '(') {
            if (depth == 0) break;
            depth -= 1;
        } else if (depth == 0 and (b == ' ' or b == '\t' or b == ';' or b == ',' or b == '=' or b == '&' or b == '|' or b == '?' or b == ':')) break;
    }
    const cand = line[i..];
    if (std.mem.lastIndexOfScalar(u8, cand, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, cand, lt, '>') orelse return line.len;
        return i + gt + 1;
    }
    return i;
}

/// A call was inserted with nothing to fill in (`foo()`): the cursor is
/// after it, and <Tab> can go on to the `;`.
pub fn callEnded(ed: *Editor) void {
    snippet_ops.endSnippet(ed);
    const stops = ed.gpa.alloc([2]usize, 1) catch return;
    stops[0] = .{ ed.view.cursor, ed.view.cursor };
    ed.snippet = .{ .buffer = ed.buffer, .stops = stops, .has_final = true, .is_call = true };
    snippet_ops.snippetAtEnd(ed);
}
