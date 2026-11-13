//! What follows a typed character: when completion opens, on which words.

const std = @import("std");
const signature_help = @import("signature_help.zig");
const completion_ops = @import("completion_ops.zig");
const sql_ops = @import("sql_ops.zig");
const Editor = @import("../Editor.zig");
const lsp_ops = @import("lsp_ops.zig");

pub fn closeCompletion(ed: *Editor) void {
    if (ed.completion) |*c| c.deinit(ed.gpa);
    ed.completion = null;
}

pub fn isIdent(b: u8) bool {
    return b == '_' or b == '@' or std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// A character of a name being completed in this buffer: in CSS and HTML
/// `-` is part of one (`background-color`, `--gap`, `aria-label`).
pub fn isNameChar(ed: *const Editor, b: u8) bool {
    if (isIdent(b)) return true;
    if (b != '-') return false;
    const lang = if (ed.buffer.syntax) |sx| sx.lang.name else return false;
    for ([_][]const u8{ "css", "scss", "less", "html" }) |l| if (std.mem.eql(u8, lang, l)) return true;
    return false;
}

/// Start of the identifier ending at the cursor.
pub fn wordStart(ed: *Editor) usize {
    const t = ed.text();
    const ls = t.lineStart(ed.cursorLine());
    var p = ed.view.cursor;
    while (p > ls and isNameChar(ed, t.byteAt(p - 1))) p -= 1;
    return p;
}

/// After typing in insert mode: asks for completions after one of the
/// server's trigger characters (`.`, `::`, `->`...) or two identifier chars.
pub fn afterTyped(ed: *Editor, cp: u21) void {
    if (ed.cursors.items.len > 0 or ed.replaying) return; // completion is single-cursor
    // Signature help: `(` opens it, `,` updates it, `)` closes it.
    if (cp == ')') signature_help.closeSignature(ed);
    if (sql_ops.isSql(ed) and lsp_ops.lspFor(ed, ed.buffer) == null) {
        // No server (sqlite, or none installed): our own list, the
        // database's tables and columns.
        if (cp == '.') closeCompletion(ed);
        if (ed.completion != null) return;
        const start = wordStart(ed);
        if (cp == '.' or (cp < 0x80 and isNameChar(ed, @intCast(cp)) and ed.view.cursor > start)) sql_ops.sqlCompletion(ed, start);
        return;
    }
    const l = lsp_ops.lspFor(ed, ed.buffer) orelse return;
    // A `,` asks again even if the popup was closed meanwhile (by a nested
    // call, say): the server answers with nothing outside a call.
    // After a `)` too: the call around the one just closed takes over.
    if (cp == ')' or l.isSignatureTrigger(cp, true)) l.requestSignature(ed) catch {};
    const trigger = l.isTrigger(cp);
    // A trigger starts a new list even if a popup is open.
    if (trigger) closeCompletion(ed);
    // A list we have is refiltered as you type (and comes back by itself
    // when a typo is fixed); only a cut-short one needs asking for again.
    if (ed.completion) |c| if (!c.incomplete) return;
    const start = wordStart(ed);
    const ask = trigger or (cp < 0x80 and isNameChar(ed, @intCast(cp)) and ed.view.cursor > start) or
        (cp == ' ' and cssValueStarts(ed));
    if (!ask) return;
    completion_ops.askCompletion(ed, l, start);
}

/// The cursor is after `property: ` in CSS (a stylesheet, or a page's
/// `<style>` or `style=""`): its values are suggested without a letter
/// typed, as an enum's would be after a `.`.
pub fn cssValueStarts(ed: *Editor) bool {
    const lang = if (ed.buffer.syntax) |sx| sx.lang.name else return false;
    const styled = for ([_][]const u8{ "css", "scss", "less", "html" }) |l| {
        if (std.mem.eql(u8, lang, l)) break true;
    } else false;
    if (!styled) return false;
    const t = ed.text();
    const ls = t.lineStart(ed.cursorLine());
    const cur = ed.view.cursor;
    // `name: |`: one space, a colon, and a property's name before it.
    if (cur < ls + 3 or t.byteAt(cur - 1) != ' ' or t.byteAt(cur - 2) != ':') return false;
    return isNameChar(ed, t.byteAt(cur - 3));
}

/// The current file's folder (absolute), else the working folder. Caller
/// frees.
pub fn fileFolder(ed: *Editor) ![]u8 {
    const path = ed.buffer.path orelse return ed.gpa.dupe(u8, ed.cwd);
    const abs = try ed.absolutePath(path);
    defer ed.gpa.free(abs);
    return ed.gpa.dupe(u8, std.fs.path.dirname(abs) orelse ed.cwd);
}
