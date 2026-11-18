//! Insert mode's own keys, as Vim has them: Ctrl-w / Ctrl-u delete back
//! (each an undo step of its own), Ctrl-a types the last insert again,
//! Ctrl-v takes the next key as it is (or `u` and hex digits: a codepoint),
//! Ctrl-k takes two keys for a digraph, Ctrl-y / Ctrl-e copy the character
//! above / below, Ctrl-t / Ctrl-d shift the line (`0` Ctrl-d: all of its
//! indentation).

const std = @import("std");
const Editor = @import("../Editor.zig");
const Text = @import("../core/Text.zig");
const motions = @import("../core/motions.zig");
const keys = @import("../input/keys.zig");
const digraphs = @import("../input/digraphs.zig");
const indenting = @import("indenting.zig");
const completion_ops = @import("completion_ops.zig");
const after_typing = @import("after_typing.zig");
const KeyEvent = keys.KeyEvent;

/// A key that waits for more: Ctrl-v (the next key as it is; `u`: hex
/// digits of a codepoint), Ctrl-k (the two keys of a digraph).
pub const Pending = union(enum) {
    none,
    literal,
    hex: struct { value: u21 = 0, digits: u8 = 0 },
    digraph: ?u21,
};

/// The most hex digits `Ctrl-v u` takes.
const max_hex = 4;

// ---------------------------------------------------------------------------
// What was typed (Ctrl-a)

/// Insert mode begins or ends: what was typed in it is kept for Ctrl-a.
pub fn modeChange(ed: *Editor, to: Editor.Mode) void {
    if (ed.replaying) return;
    if (to == .insert and ed.mode != .insert) {
        ed.insert_typed.clearRetainingCapacity();
        ed.insert_zero = null;
    } else if (ed.mode == .insert and to != .insert) {
        ed.insert_pending = .none;
        if (ed.insert_typed.items.len == 0) return;
        ed.insert_last.clearRetainingCapacity();
        ed.insert_last.appendSlice(ed.gpa, ed.insert_typed.items) catch {};
    }
}

/// `bytes` went in at the cursor while typing.
pub fn typed(ed: *Editor, bytes: []const u8) void {
    if (ed.mode != .insert or ed.replaying) return;
    ed.insert_typed.appendSlice(ed.gpa, bytes) catch {};
}

/// The `n` bytes before the cursor were deleted while typing.
pub fn untyped(ed: *Editor, n: usize) void {
    if (ed.mode != .insert or ed.replaying) return;
    ed.insert_typed.shrinkRetainingCapacity(ed.insert_typed.items.len -| n);
}

/// Ctrl-a: what the insert before this one typed, typed again.
pub fn again(ed: *Editor) !void {
    if (ed.insert_last.items.len == 0) return ed.setMessage(.info, "nothing typed before to insert again", .{});
    // (A copy: typing it is recorded, and may be this insert's own text.)
    const text = try ed.gpa.dupe(u8, ed.insert_last.items);
    defer ed.gpa.free(text);
    try ed.insertText(text);
}

// ---------------------------------------------------------------------------
// Deleting back

/// A deletion that is an undo step of its own: what was typed before it is
/// one step, the deletion the next.
fn deleteStep(ed: *Editor, from: usize, to: usize) !void {
    if (from >= to) return;
    try ed.buffer.history.commit(ed.gpa);
    untyped(ed, to - from);
    try ed.deleteRange(from, to);
    try ed.buffer.history.commit(ed.gpa);
}

/// Where Ctrl-w deletes back to from `p`: over any blanks, then one run of
/// word characters or of other ones; not past the start of the line,
/// unless `p` is there (then the line joins the one before).
pub fn wordStart(t: *const Text, p: usize) usize {
    const start = t.lineStart(t.lineOf(p));
    if (p == start) return if (p > 0) p - 1 else 0;
    var i = p;
    while (i > start and isBlank(t.byteAt(i - 1))) i -= 1;
    if (i == start) return start;
    const word = isWord(t.byteAt(i - 1));
    while (i > start and !isBlank(t.byteAt(i - 1)) and isWord(t.byteAt(i - 1)) == word) i -= 1;
    return i;
}

fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// A keyword character (and the bytes of anything past ASCII: a letter
/// with an accent is part of its word).
fn isWord(b: u8) bool {
    return b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b);
}

/// Ctrl-w.
pub fn deleteWord(ed: *Editor) !void {
    const c = ed.view.cursor;
    try deleteStep(ed, wordStart(ed.text(), c), c);
}

/// Ctrl-u: back to the line's first character that isn't a blank (the
/// indentation stays); from there or before it, to the start of the line.
pub fn deleteLine(ed: *Editor) !void {
    const t = ed.text();
    const c = ed.view.cursor;
    const line = t.lineOf(c);
    const first = motions.firstNonBlank(t, line);
    try deleteStep(ed, if (c > first) first else t.lineStart(line), c);
}

// ---------------------------------------------------------------------------
// The character above / below

/// Ctrl-y (`above`) / Ctrl-e: the character of the line above / below that
/// is in the cursor's column on screen (tabs counted as they are drawn).
/// Nothing when that line doesn't reach the column.
pub fn copyFrom(ed: *Editor, above: bool) !void {
    const t = ed.text();
    const line = t.lineOf(ed.view.cursor);
    if (above and line == 0) return;
    if (!above and line + 1 >= t.lineCount()) return;
    const other = t.lineSlice(if (above) line - 1 else line + 1);
    const tab = ed.options.tab_width;
    const col = ed.cursorCol();
    const at = motions.byteAtCol(other, col, tab);
    if (at >= other.len) return;
    // A tab reaching over the column is past it only if it started there.
    const n = std.unicode.utf8ByteSequenceLength(other[at]) catch 1;
    if (at + n > other.len) return;
    var buf: [4]u8 = undefined;
    @memcpy(buf[0..n], other[at..][0..n]);
    try ed.insertText(buf[0..n]);
}

/// Ctrl-y with the suggestions open takes the selected one; Ctrl-e closes
/// them (Vim's own). True when that was done.
pub fn popupKey(ed: *Editor, accept: bool) !bool {
    if (completion_ops.completionShown(ed) == null) return false;
    if (accept) try completion_ops.acceptCompletion(ed) else after_typing.closeCompletion(ed);
    return true;
}

// ---------------------------------------------------------------------------
// Indentation

/// The columns the indentation `indent` takes.
fn width(indent: []const u8, tab: usize) usize {
    return motions.displayCol(indent, indent.len, tab);
}

/// Makes the cursor line's indentation `cols` columns wide, written as the
/// file writes it (tabs, or spaces). The cursor stays on the character it
/// was on.
fn setIndent(ed: *Editor, cols: usize) !void {
    const t = ed.text();
    const c = ed.view.cursor;
    const line = t.lineOf(c);
    const start = t.lineStart(line);
    const first = motions.firstNonBlank(t, line);
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    const tab = @max(ed.options.tab_width, 1);
    if (indenting.usesTabs(ed)) {
        const tabs = @min(cols / tab, buf.len);
        @memset(buf[0..tabs], '\t');
        n = tabs;
        const rest = @min(cols % tab, buf.len - n);
        @memset(buf[n..][0..rest], ' ');
        n += rest;
    } else {
        n = @min(cols, buf.len);
        @memset(buf[0..n], ' ');
    }
    const old = t.slice(start, first);
    if (std.mem.eql(u8, old, buf[0..n])) return;
    // Past the indentation the cursor moves with the text; inside it, it
    // goes to the text's first character.
    const after = if (c >= first) c - first else 0;
    try ed.deleteRangeKeepCursor(start, first);
    try ed.insertAt(start, buf[0..n]);
    ed.view.cursor = start + n + after;
    ed.view.want_col = null;
}

/// Ctrl-t (`deeper`) / Ctrl-d: the line's indentation, a level more or
/// less: to the next multiple of the indent width that way, as Vim's
/// 'shiftround' does.
pub fn shift(ed: *Editor, deeper: bool) !void {
    const t = ed.text();
    const line = t.lineOf(ed.view.cursor);
    const now = width(t.slice(t.lineStart(line), motions.firstNonBlank(t, line)), @max(ed.options.tab_width, 1));
    const sw = @max(indenting.indentWidth(ed), 1);
    // `0` Ctrl-d: the 0 just typed goes, and all of the indentation.
    if (!deeper) if (ed.insert_zero) |z| {
        const c = ed.view.cursor;
        if (z == c and c > 0 and t.byteAt(c - 1) == '0') {
            untyped(ed, 1);
            try ed.deleteRange(c - 1, c);
            ed.insert_zero = null;
            return setIndent(ed, 0);
        }
    };
    const to = if (deeper) (now / sw + 1) * sw else if (now % sw != 0) now - now % sw else now -| sw;
    try setIndent(ed, to);
}

// ---------------------------------------------------------------------------
// Ctrl-v and Ctrl-k: the keys they wait for

/// Ctrl-v / Ctrl-k: the next key (or keys) are theirs.
pub fn begin(ed: *Editor, what: Pending) void {
    ed.insert_pending = what;
}

/// The key `ev` as text when taken as it is: its character, a control
/// character for Ctrl and a letter, the character a special key sends.
fn literal(ev: KeyEvent) ?u21 {
    switch (ev.key) {
        .codepoint => |cp| {
            if (!ev.mods.ctrl) return cp;
            // Ctrl-a..Ctrl-z, Ctrl-@ and Ctrl-[ \ ] ^ _ are 0..31; Ctrl-? is DEL.
            if (cp >= 'a' and cp <= 'z') return cp - 'a' + 1;
            if (cp >= '@' and cp <= '_') return cp - '@';
            if (cp == '?') return 0x7f;
            return cp;
        },
        .special => |s| return switch (s) {
            .tab => '\t',
            .enter => '\r',
            .backspace => 0x7f,
            else => null,
        },
    }
}

fn hexDigit(ev: KeyEvent) ?u21 {
    const cp = ev.text() orelse return null;
    return switch (cp) {
        '0'...'9' => cp - '0',
        'a'...'f' => cp - 'a' + 10,
        'A'...'F' => cp - 'A' + 10,
        else => null,
    };
}

fn put(ed: *Editor, cp: u21) !void {
    if (!std.unicode.utf8ValidCodepoint(cp)) return;
    try ed.insertCodepoint(cp);
}

/// A key while Ctrl-v or Ctrl-k waits. Esc gives it up (nothing is
/// inserted). False when the key isn't theirs after all and is to be
/// handled as usual (the key that ends a codepoint's digits).
pub fn pendingKey(ed: *Editor, ev: KeyEvent) !bool {
    const escape = ev.key == .special and ev.key.special == .escape;
    const state = ed.insert_pending;
    if (escape) {
        ed.insert_pending = .none;
        return true;
    }
    switch (state) {
        .none => return false,
        .literal => {
            if (ev.text()) |cp| if (cp == 'u') {
                ed.insert_pending = .{ .hex = .{} };
                return true;
            };
            ed.insert_pending = .none;
            if (literal(ev)) |cp| try put(ed, cp);
            return true;
        },
        .hex => |h| {
            if (hexDigit(ev)) |d| {
                const value = h.value * 16 + d;
                if (h.digits + 1 == max_hex) {
                    ed.insert_pending = .none;
                    try put(ed, value);
                } else ed.insert_pending = .{ .hex = .{ .value = value, .digits = h.digits + 1 } };
                return true;
            }
            // Any other key ends the digits, and is then itself.
            ed.insert_pending = .none;
            if (h.digits > 0) try put(ed, h.value);
            return false;
        },
        .digraph => |first| {
            const cp = ev.text() orelse {
                ed.insert_pending = .none;
                return true;
            };
            if (first == null) {
                ed.insert_pending = .{ .digraph = cp };
                return true;
            }
            ed.insert_pending = .none;
            // No such pair: the second key as it is (Vim's way).
            try put(ed, digraphs.find(first.?, cp) orelse cp);
            return true;
        },
    }
}

/// What the status line shows while Ctrl-v or Ctrl-k waits (`^V`, `^Vu00e`,
/// `^Ka`); empty otherwise.
pub fn indicator(ed: *const Editor, buf: []u8) []const u8 {
    return switch (ed.insert_pending) {
        .none => "",
        .literal => "^V",
        .hex => |h| blk: {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll("^Vu") catch {};
            if (h.digits > 0) w.printInt(h.value, 16, .lower, .{ .width = h.digits, .fill = '0' }) catch {};
            break :blk w.buffered();
        },
        .digraph => |first| blk: {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll("^K") catch {};
            if (first) |cp| {
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &enc) catch 0;
                w.writeAll(enc[0..n]) catch {};
            }
            break :blk w.buffered();
        },
    };
}
