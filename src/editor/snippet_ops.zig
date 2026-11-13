//! Snippets: function arguments as placeholders.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Snippet = @import("../lsp/Snippet.zig");
const Editor = @import("../Editor.zig");
const completion_ops = @import("completion_ops.zig");
const lsp_ops = @import("lsp_ops.zig");

pub fn startSnippet(ed: *Editor, at: usize, snip: Snippet, is_call: bool) !void {
    endSnippet(ed);
    if (snip.stops.len == 0) {
        if (is_call) completion_ops.callEnded(ed);
        return;
    }
    // Without a $0 the final cursor is the snippet's end (by the LSP spec;
    // clangd's `printf(${1:...})` has none).
    const explicit_final = snip.stops[snip.stops.len - 1].index == 0;
    const n = snip.stops.len + @intFromBool(!explicit_final);
    const stops = try ed.gpa.alloc([2]usize, n);
    for (snip.stops, stops[0..snip.stops.len]) |st, *r| r.* = .{ at + st.start, at + st.end };
    if (!explicit_final) stops[n - 1] = .{ at + snip.text.len, at + snip.text.len };
    ed.snippet = .{ .buffer = ed.buffer, .stops = stops, .has_final = true, .is_call = is_call };
    goSnippetStop(ed, 0);
}

pub fn endSnippet(ed: *Editor) void {
    const s = ed.snippet orelse return;
    ed.gpa.free(s.stops);
    ed.snippet = null;
}

/// Puts the cursor at stop `i`; the final cursor ($0) ends the session.
pub fn goSnippetStop(ed: *Editor, i: usize) void {
    const s = &(ed.snippet orelse return);
    const r = s.stops[i];
    const last = i == s.stops.len - 1;
    ed.view.cursor = @min(r[0], ed.text().len());
    ed.view.want_col = null;
    if (last and s.has_final) return snippetAtEnd(ed);
    s.current = i;
    s.at_end = false;
    s.fresh = r[1] > r[0];
    // The signature popup follows to this argument.
    if (lsp_ops.lspFor(ed, ed.buffer)) |l| l.requestSignature(ed) catch {};
}

/// Leaving insert mode with a snippet half filled in: the placeholders still
/// holding their default text (the current one if untouched, and the ones
/// not reached yet) are removed together with the comma beside them, so
/// `f(a: A, b: B)` left alone becomes `f()` rather than code that doesn't
/// parse. Placeholders already visited stay as they are.
pub fn dropUnfilledPlaceholders(ed: *Editor) !void {
    if (ed.replaying) return;
    const s = &(ed.snippet orelse return);
    if (s.buffer != ed.buffer or s.at_end or s.keep_defaults) return;
    var first: ?usize = null;
    var i = s.stops.len;
    while (i > s.current) {
        i -= 1;
        if (s.has_final and i == s.stops.len - 1) continue; // the cursor's final place
        if (i == s.current and !s.fresh) continue; // typed into
        var start = s.stops[i][0];
        var end = s.stops[i][1];
        if (end <= start) continue;
        const t = ed.text();
        const line = t.lineOf(start);
        const ls = t.lineStart(line);
        const le = t.lineEnd(line);
        // The comma before it, else the one after it.
        if (start >= ls + 2 and t.byteAt(start - 2) == ',' and t.byteAt(start - 1) == ' ') {
            start -= 2;
        } else if (start >= ls + 1 and t.byteAt(start - 1) == ',') {
            start -= 1;
        } else if (end + 2 <= le and t.byteAt(end) == ',' and t.byteAt(end + 1) == ' ') {
            end += 2;
        } else if (end + 1 <= le and t.byteAt(end) == ',') end += 1;
        try ed.deleteRangeKeepCursor(start, end);
        first = start;
    }
    if (first) |f| {
        ed.view.cursor = @min(f, ed.text().len());
        ed.view.want_col = null;
    }
}

/// <Tab> / <S-Tab> in insert mode. False when there is no session.
pub fn snippetStep(ed: *Editor, forward: bool) bool {
    const s = &(ed.snippet orelse return false);
    if (s.buffer != ed.buffer) {
        endSnippet(ed);
        return false;
    }
    if (forward) {
        if (s.at_end) {
            snippetSemicolon(ed);
            return true;
        }
        if (s.current + 1 >= s.stops.len) {
            // Past the last placeholder (no $0): after it.
            ed.view.cursor = s.stops[s.current][1];
            snippetAtEnd(ed);
            return true;
        }
        goSnippetStop(ed, s.current + 1);
    } else if (s.at_end) {
        goSnippetStop(ed, s.current);
    } else if (s.current > 0) goSnippetStop(ed, s.current - 1);
    return true;
}

/// Languages whose statements end in `;` (the extra <Tab> after a call).
pub fn usesSemicolons(b: *const Buffer) bool {
    const s = b.syntax orelse return false;
    const name = s.lang.name;
    for ([_][]const u8{ "zig", "c", "rust", "javascript", "typescript", "tsx", "css" }) |l| if (std.mem.eql(u8, name, l)) return true;
    return false;
}

/// What follows the cursor on its line, trimmed.
pub fn restOfLine(ed: *Editor) []const u8 {
    const t = ed.text();
    return std.mem.trim(u8, t.slice(ed.view.cursor, t.lineEnd(ed.cursorLine())), " \t");
}

/// The cursor is after the call. If it ends the statement in a language
/// with semicolons, keep the session for one more <Tab> (to the `;`);
/// otherwise the snippet is done.
pub fn snippetAtEnd(ed: *Editor) void {
    const rest = restOfLine(ed);
    const can = ed.snippet.?.is_call and usesSemicolons(ed.buffer) and (rest.len == 0 or std.mem.eql(u8, rest, ";"));
    if (!can) return endSnippet(ed);
    const s = &ed.snippet.?;
    s.at_end = true;
    s.fresh = false;
}

/// The last <Tab>: to the end of the statement, adding the `;` if missing.
pub fn snippetSemicolon(ed: *Editor) void {
    endSnippet(ed);
    const rest = restOfLine(ed);
    // Something was typed after the call that isn't a statement end: stay.
    if (rest.len > 0 and !std.mem.eql(u8, rest, ";")) return;
    const t = ed.text();
    const line = ed.cursorLine();
    var end = t.lineEnd(line);
    while (end > t.lineStart(line) and (t.byteAt(end - 1) == ' ' or t.byteAt(end - 1) == '\t')) end -= 1;
    if (end == t.lineStart(line) or t.byteAt(end - 1) != ';') {
        ed.insertAt(end, ";") catch return;
        end += 1;
    }
    ed.view.cursor = end;
    ed.view.want_col = null;
}

/// The current placeholder, if it still holds its default and the cursor is
/// at its start (where typing replaces it).
pub fn freshPlaceholder(ed: *Editor) ?[2]usize {
    const s = ed.snippet orelse return null;
    if (!s.fresh or s.buffer != ed.buffer) return null;
    const r = s.stops[s.current];
    if (ed.view.cursor != r[0]) return null;
    return r;
}

/// Before typing: a fresh placeholder is replaced by what is typed.
pub fn snippetTypeOver(ed: *Editor) !void {
    const r = freshPlaceholder(ed) orelse return;
    ed.snippet.?.fresh = false;
    try ed.deleteRange(r[0], r[1]);
}

/// <BS> on a fresh placeholder removes it whole. True when it did.
pub fn snippetBackspace(ed: *Editor) !bool {
    if (freshPlaceholder(ed) == null) return false;
    try snippetTypeOver(ed);
    return true;
}
