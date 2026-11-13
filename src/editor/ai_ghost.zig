//! AI ghost completion: after typing in insert mode, a local model suggests what comes next.

const std = @import("std");
const Ghost = @import("../ai/Ghost.zig");
const snippet_ops = @import("snippet_ops.zig");
const Editor = @import("../Editor.zig");

/// Where Ollama is and which model to ask ($OLLAMA_HOST, $ZILE_AI_MODEL).
pub fn aiConfig() struct { host: []const u8, model: []const u8 } {
    const host: []const u8 = if (std.c.getenv("OLLAMA_HOST")) |h| std.mem.span(h) else "http://localhost:11434";
    const model: []const u8 = if (std.c.getenv("ZILE_AI_MODEL")) |m| std.mem.span(m) else "qwen2.5-coder:1.5b-base";
    return .{ .host = host, .model = model };
}

pub fn clearAiSuggestion(ed: *Editor) void {
    const s = ed.ai_suggestion orelse return;
    ed.gpa.free(s.text);
    ed.ai_suggestion = null;
}

/// The suggestion as it stands at the cursor, if it is still valid there.
pub fn aiSuggestionHere(ed: *Editor) ?[]const u8 {
    const s = ed.ai_suggestion orelse return null;
    if (s.buffer != ed.buffer or ed.mode != .insert) return null;
    const c = ed.view.cursor;
    if (c < s.pos or c - s.pos > s.text.len) return null;
    if (!std.mem.eql(u8, ed.text().slice(s.pos, c), s.text[0 .. c - s.pos])) return null;
    const rest = s.remaining(c);
    return if (rest.len > 0) rest else null;
}

/// After each key: keep a suggestion that is being typed out, otherwise
/// drop it and (at a line's end) ask for a new one.
pub fn updateAi(ed: *Editor) void {
    if (!ed.options.ai_complete or ed.ai_unreachable or ed.mode != .insert or
        ed.replaying or ed.cursors.items.len > 0 or ed.cmd_float != null)
    {
        clearAiSuggestion(ed);
        return;
    }
    if (aiSuggestionHere(ed) != null) return;
    clearAiSuggestion(ed);
    const b = ed.buffer;
    const c = ed.view.cursor;
    if (ed.ai_asked) |a| if (a.buffer == b and a.pos == c and a.version == b.edit_version) return;
    // Only at the end of a line (or before closing brackets/quotes/;):
    // mid-line guesses from a small model are mostly noise.
    const rest = snippet_ops.restOfLine(ed);
    for (rest) |ch| if (std.mem.indexOfScalar(u8, ")]}\"';,", ch) == null) return;
    if (ed.ai_offline) return;
    const t = ed.text();
    if (ed.ai == null) {
        const cfg = aiConfig();
        ed.ai = Ghost.create(ed.gpa, ed.io, ed.wake_fn, cfg.host, cfg.model) catch return;
    }
    // A window around the cursor: from a line start ~6KB back, ~2KB ahead.
    var from = c -| 6000;
    if (from > 0) from = t.lineStart(t.lineOf(from));
    const to = @min(t.len(), c + 2000);
    const tail: []const u8 = if (to == t.len() and b.final_newline) "\n" else "";
    const suffix = std.mem.concat(ed.gpa, u8, &.{ t.slice(c, to), tail }) catch return;
    defer ed.gpa.free(suffix);
    ed.ai_gen += 1;
    ed.ai.?.submit(ed.ai_gen, t.slice(from, c), suffix) catch return;
    ed.ai_asked = .{ .buffer = b, .pos = c, .version = b.edit_version };
}

/// Picks up the model's reply, if it still fits where the cursor is.
pub fn pollAi(ed: *Editor) void {
    const g = ed.ai orelse return;
    const r = g.take() orelse return;
    defer if (r.text) |t| ed.gpa.free(t);
    if (r.failed) {
        ed.ai_unreachable = true;
        clearAiSuggestion(ed);
        ed.setMessage(.err, "AI completion is off: no answer from Ollama at {s} (SPC t a to try again)", .{g.url});
        return;
    }
    if (r.gen != ed.ai_gen or ed.mode != .insert) return;
    const a = ed.ai_asked orelse return;
    if (a.buffer != ed.buffer or a.pos != ed.view.cursor or a.version != ed.buffer.edit_version) return;
    const tidied = Ghost.tidy(r.text.?, snippet_ops.restOfLine(ed), 8);
    // Drop lines that only repeat what's already around the cursor.
    const t = ed.text();
    const line = ed.cursorLine();
    const ctx_from = t.lineStart(line -| 40);
    const ctx_to = t.lineEnd(@min(line + 40, t.lineCount() - 1));
    const prefix_on_line = t.slice(t.lineStart(line), ed.view.cursor);
    const suggestion = Ghost.dropRepeats(tidied, prefix_on_line, t.slice(ctx_from, ctx_to));
    if (suggestion.len == 0) return;
    clearAiSuggestion(ed);
    ed.ai_suggestion = .{ .buffer = ed.buffer, .pos = a.pos, .text = ed.gpa.dupe(u8, suggestion) catch return };
}

pub const AiPart = enum { all, line, char };

/// Takes the suggestion (<A-;>), its current line (<A-l>; at a line break,
/// the break and the next line), or one character (<A-Right>). What's left
/// stays offered. False when there is none.
pub fn acceptAiSuggestion(ed: *Editor, part: AiPart) !bool {
    const rest = aiSuggestionHere(ed) orelse return false;
    const n = switch (part) {
        .all => rest.len,
        .line => blk: {
            const start: usize = if (rest[0] == '\n') 1 else 0;
            break :blk start + (std.mem.indexOfScalar(u8, rest[start..], '\n') orelse rest.len - start);
        },
        .char => std.unicode.utf8ByteSequenceLength(rest[0]) catch 1,
    };
    const taken = try ed.gpa.dupe(u8, rest[0..@min(n, rest.len)]);
    defer ed.gpa.free(taken);
    // Typing it in keeps the rest of the suggestion on offer.
    try ed.insertText(taken);
    if (aiSuggestionHere(ed) == null) clearAiSuggestion(ed);
    return true;
}
