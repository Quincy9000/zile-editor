//! Indentation: the file's own style where it has one (`Buffer.indent_style`,
//! detected when it is read), else the options.

const std = @import("std");
const Text = @import("../core/Text.zig");
const motions = @import("../core/motions.zig");
const config = @import("../config/config.zig");
const Editor = @import("../Editor.zig");

pub fn usesTabs(ed: *const Editor) bool {
    if (ed.buffer.indent_style) |s| return s.tabs;
    // A Go file with no indentation yet: tabs, as gofmt writes them.
    if (ed.buffer.syntax) |syn| if (std.mem.eql(u8, syn.lang.name, "go")) return true;
    return !ed.options.expand_tab;
}

/// The columns one level of indentation takes.
pub fn indentWidth(ed: *const Editor) usize {
    if (ed.buffer.indent_style) |s| if (!s.tabs) return s.width;
    // The config's for the language.
    if (ed.buffer.syntax) |syn| if (config.settingsFor(syn.lang.name)) |cfg| if (cfg.indent) |n| return n;
    // A file with no indentation yet: the web and config languages indent
    // by two (as prettier writes them, and YAML is usually written).
    if (ed.buffer.syntax) |syn| for ([_][]const u8{ "javascript", "typescript", "tsx", "html", "css", "json", "yaml", "toml" }) |l| {
        if (std.mem.eql(u8, syn.lang.name, l)) return 2;
    };
    return ed.options.tab_width;
}

/// One level of indentation, as text.
pub fn indentUnit(ed: *const Editor, buf: *[16]u8) []const u8 {
    if (usesTabs(ed)) return "\t";
    const n = @min(indentWidth(ed), buf.len);
    @memset(buf[0..n], ' ');
    return buf[0..n];
}

/// The indentation for a new line made by breaking `line` at `at`: the
/// line's own, one level deeper after something that opens a block (`{`,
/// `(`, `[`; `:` in Python).
pub fn newlineIndent(ed: *Editor, line: usize, at: usize, buf: []u8) []const u8 {
    const t = ed.text();
    // A blank line has no indentation of its own to go by: the code around it does.
    if (isBlankLine(ed, t, line)) return contextIndent(ed, line, buf);
    const ls = t.lineStart(line);
    const base = t.slice(ls, @min(motions.firstNonBlank(t, line), @max(at, ls)));
    const before = std.mem.trimEnd(u8, t.slice(ls, @max(at, ls)), " \t");
    const python = if (ed.buffer.path) |p| std.mem.endsWith(u8, p, ".py") else false;
    const opens = before.len > 0 and switch (before[before.len - 1]) {
        '{', '(', '[' => true,
        ':' => python,
        else => false,
    };
    var unit_buf: [16]u8 = undefined;
    const unit: []const u8 = if (opens) indentUnit(ed, &unit_buf) else "";
    if (base.len + unit.len > buf.len) return "";
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..unit.len], unit);
    return buf[0 .. base.len + unit.len];
}

pub fn isBlankLine(_: *const Editor, t: *const Text, line: usize) bool {
    return std.mem.indexOfNone(u8, t.lineSlice(line), " \t") == null;
}

/// The indentation a new line made on blank line `line` should have: where
/// the code around it is. That of the nearest line above that has text (a
/// level deeper when it opens a block); with none above, the nearest below.
pub fn contextIndent(ed: *Editor, line: usize, buf: []u8) []const u8 {
    const t = ed.text();
    var l = line;
    while (l > 0) {
        l -= 1;
        if (!isBlankLine(ed, t, l)) return newlineIndent(ed, l, t.lineEnd(l), buf);
    }
    l = line + 1;
    while (l < t.lineCount()) : (l += 1) {
        if (isBlankLine(ed, t, l)) continue;
        const own = t.slice(t.lineStart(l), motions.firstNonBlank(t, l));
        const n = @min(own.len, buf.len);
        @memcpy(buf[0..n], own[0..n]);
        return buf[0..n];
    }
    return buf[0..0];
}

/// A closing bracket typed as the first thing on its line lines up with the
/// line that opened it.
pub fn dedentCloser(ed: *Editor) !void {
    const t = ed.text();
    const pos = ed.view.cursor;
    if (pos == 0) return;
    const line = t.lineOf(pos - 1);
    const ls = t.lineStart(line);
    if (std.mem.indexOfNone(u8, t.slice(ls, pos - 1), " \t") != null) return; // not first on the line
    const open = motions.matchBracket(t, pos - 1) orelse return;
    const open_line = t.lineOf(open);
    if (open_line >= line) return;
    var buf: [256]u8 = undefined;
    const want = t.slice(t.lineStart(open_line), motions.firstNonBlank(t, open_line));
    if (want.len > buf.len or std.mem.eql(u8, want, t.slice(ls, pos - 1))) return;
    @memcpy(buf[0..want.len], want);
    try ed.deleteRangeKeepCursor(ls, pos - 1);
    try ed.insertAt(ls, buf[0..want.len]);
    ed.view.cursor = ls + want.len + 1;
    ed.view.want_col = null;
}
