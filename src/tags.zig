//! HTML and JSX tags while typing (nvim-ts-autotag):
//!   - `>` ending an opening tag adds its closing tag: `<div|` -> `<div>|</div>`
//!     (not for `<br>`-like void elements, nor `<x />`); `<>` gets `</>`
//!   - `/` after `<` closes the innermost open element: `</` -> `</div>|`
//!   - <CR> between `<div>|</div>` opens it up onto its own lines
//!   - editing a tag's name edits its partner's too (`<div>` ... `</div>`)
//!
//! Markup is an `.html` file outside `<script>`/`<style>`, or JSX in a
//! `.js`/`.jsx`/`.tsx` file (a `<` where an expression can start, so a
//! TypeScript generic like `Array<string>` is left alone).

const std = @import("std");
const ts = @import("tree_sitter");
const Editor = @import("Editor.zig");
const Text = @import("core/Text.zig");
const jumplist = @import("editor/jumplist.zig");
const indenting = @import("editor/indenting.zig");

pub const Kind = enum { none, html, jsx };

/// What kind of markup the buffer can hold.
pub fn kindOf(ed: *const Editor) Kind {
    const syn = ed.buffer.syntax orelse return .none;
    const name = syn.lang.name;
    if (std.mem.eql(u8, name, "html")) return .html;
    if (std.mem.eql(u8, name, "tsx") or std.mem.eql(u8, name, "javascript")) return .jsx;
    return .none;
}

/// Elements that never have a closing tag.
const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };

pub fn isVoid(name: []const u8) bool {
    for (void_elements) |v| if (std.ascii.eqlIgnoreCase(v, name)) return true;
    return false;
}

pub fn isNameByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == ':' or b == '.';
}

/// Whether the `<` at `lt` can start a JSX element: after something an
/// expression can follow (`(`, `=`, `=>`, `return`, another tag...), not
/// after a name (`useState<T>`, a generic).
pub fn jsxCanStart(src: []const u8, lt: usize) bool {
    var i = lt;
    while (i > 0 and std.ascii.isWhitespace(src[i - 1])) i -= 1;
    if (i == 0) return true;
    const b = src[i - 1];
    if (std.mem.indexOfScalar(u8, "(,=:?>{}[&|;!", b) != null) return true;
    if (std.ascii.isAlphanumeric(b) or b == '_' or b == '$') {
        var s = i;
        while (s > 0 and (std.ascii.isAlphanumeric(src[s - 1]) or src[s - 1] == '_')) s -= 1;
        const word = src[s..i];
        for ([_][]const u8{ "return", "yield", "await", "default", "case" }) |w| if (std.mem.eql(u8, word, w)) return true;
        return false;
    }
    return false;
}

/// Whether an element could be written at `pos`: in HTML, outside any tag
/// and `<script>`/`<style>`; in JSX, where an expression or a child can
/// start (`return (`, `=> `, between tags).
pub fn markupAt(ed: *Editor, kind: Kind, src: []const u8, pos: usize) bool {
    switch (kind) {
        .none => return false,
        .jsx => return jsxCanStart(src, pos) or inJsxChildren(ed, pos),
        .html => {
            var i = pos;
            while (i > 0) : (i -= 1) {
                if (src[i - 1] == '>') break;
                if (src[i - 1] == '<') return false; // inside a tag
            }
            return !inRawText(ed, pos);
        },
    }
}

/// Between a JSX element's tags (in its text, not in a `{...}` or a tag).
pub fn inJsxChildren(ed: *Editor, pos: usize) bool {
    const syn = &(ed.buffer.syntax orelse return false);
    syn.update(ed.text());
    const tree = syn.tree orelse return false;
    const p: u32 = @intCast(pos);
    var node = ts.ts_node_descendant_for_byte_range(ts.ts_tree_root_node(tree), p -| 1, p);
    while (!ts.ts_node_is_null(node)) : (node = ts.ts_node_parent(node)) {
        const ty = std.mem.span(ts.ts_node_type(node));
        if (std.mem.eql(u8, ty, "jsx_element")) return true;
        if (std.mem.eql(u8, ty, "jsx_text")) continue;
        if (std.mem.startsWith(u8, ty, "jsx_") or std.mem.endsWith(u8, ty, "statement") or std.mem.eql(u8, ty, "program")) return false;
    }
    return false;
}

/// Where an element can be completed at `pos` (a word typed between tags
/// in JSX, or in HTML text): stricter than `markupAt`, which a <Tab> uses.
pub fn childAt(ed: *Editor, kind: Kind, src: []const u8, pos: usize) bool {
    return switch (kind) {
        .none => false,
        .jsx => inJsxChildren(ed, pos),
        .html => markupAt(ed, kind, src, pos),
    };
}

/// Inside the raw text of an HTML `<script>` or `<style>` (JavaScript and
/// CSS, not markup).
fn inRawText(ed: *Editor, pos: usize) bool {
    const syn = &(ed.buffer.syntax orelse return false);
    syn.update(ed.text());
    const tree = syn.tree orelse return false;
    const p: u32 = @intCast(pos);
    var node = ts.ts_node_descendant_for_byte_range(ts.ts_tree_root_node(tree), p -| 1, p -| 1);
    while (!ts.ts_node_is_null(node)) : (node = ts.ts_node_parent(node)) {
        const ty = std.mem.span(ts.ts_node_type(node));
        if (std.mem.eql(u8, ty, "raw_text")) return true;
        if (std.mem.eql(u8, ty, "start_tag") or std.mem.eql(u8, ty, "end_tag")) return false;
    }
    return false;
}

/// Whether the `<` at `lt` starts a tag in this buffer's markup.
fn tagCanStart(ed: *Editor, kind: Kind, src: []const u8, lt: usize) bool {
    return switch (kind) {
        .none => false,
        .html => !inRawText(ed, lt),
        .jsx => jsxCanStart(src, lt),
    };
}

/// The opening tag being typed at `pos`: `<name attrs...` up to the cursor,
/// not yet closed by a `>`. Skips quoted values and `{...}` expressions.
const Open = struct { lt: usize, name: []const u8 };

fn openTagAt(src: []const u8, pos: usize) ?Open {
    // The nearest `<` before the cursor (a tag is rarely long).
    const from = pos -| 4096;
    const lt = std.mem.lastIndexOfScalar(u8, src[from..pos], '<') orelse return null;
    const start = from + lt;
    var i = start + 1;
    if (i < pos and src[i] == '/') return null; // a closing tag
    const name_start = i;
    while (i < pos and isNameByte(src[i])) i += 1;
    const name = src[name_start..i];
    if (name.len > 0 and !std.ascii.isAlphabetic(name[0])) return null;
    if (name.len == 0 and i != pos) return null; // `< b`: a comparison
    var quote: u8 = 0;
    var depth: usize = 0;
    while (i < pos) : (i += 1) {
        const b = src[i];
        if (quote != 0) {
            if (b == quote) quote = 0;
        } else if (b == '"' or b == '\'' or b == '`') {
            quote = b;
        } else if (b == '{') {
            depth += 1;
        } else if (b == '}') {
            depth -|= 1;
        } else if (depth == 0 and (b == '>' or b == '<')) return null;
    }
    if (quote != 0 or depth != 0) return null;
    return .{ .lt = start, .name = name };
}

/// Typing `cp` in insert mode: `>` and `/` may close a tag. Returns false
/// when it should be inserted as usual.
pub fn typed(ed: *Editor, cp: u21) !bool {
    if (cp != '>' and cp != '/') return false;
    if (!ed.options.auto_pairs or ed.cursors.items.len > 0) return false;
    const kind = kindOf(ed);
    if (kind == .none) return false;
    const t = ed.text();
    const pos = ed.view.cursor;
    const src = t.slice(0, t.len());
    if (cp == '>') {
        const open = openTagAt(src, pos) orelse return false;
        if (!tagCanStart(ed, kind, src, open.lt)) return false;
        // `<br/` + `>` and `<img` + `>` stay as they are.
        if (pos > 0 and src[pos - 1] == '/') return false;
        if (open.name.len > 0 and isVoid(open.name)) return false;
        var buf: [128]u8 = undefined;
        const closer = std.fmt.bufPrint(&buf, "></{s}>", .{open.name}) catch return false;
        try ed.insertText(closer);
        ed.setCursor(pos + 1);
        return true;
    }
    // `/` right after `<`: the innermost element still open.
    if (pos == 0 or src[pos - 1] != '<') return false;
    if (!tagCanStart(ed, kind, src, pos - 1)) return false;
    const inner = innermostOpen(ed, kind, src[0 .. pos - 1]) orelse return false;
    var buf: [128]u8 = undefined;
    const rest = std.fmt.bufPrint(&buf, "/{s}>", .{inner.name}) catch return false;
    // On a line of its own: at the opening tag's indentation.
    const line = t.lineOf(pos);
    const ls = t.lineStart(line);
    const before = src[ls .. pos - 1];
    var at = pos;
    if (std.mem.trim(u8, before, " \t").len == 0) {
        const ols = t.lineStart(t.lineOf(inner.lt));
        const o_line = src[ols..inner.lt];
        const indent = o_line[0 .. std.mem.indexOfNone(u8, o_line, " \t") orelse o_line.len];
        if (!std.mem.eql(u8, indent, before)) {
            var ibuf: [256]u8 = undefined;
            const ind = ibuf[0..@min(indent.len, ibuf.len)];
            @memcpy(ind, indent[0..ind.len]);
            try ed.deleteRangeKeepCursor(ls, pos - 1);
            try ed.insertAt(ls, ind);
            at = ls + ind.len + 1;
            ed.setCursor(at);
        }
    }
    try ed.insertText(rest);
    return true;
}

/// The innermost element opened in `src` and not closed (names matched
/// leniently: a stray closing tag closes the nearest of its name).
fn innermostOpen(ed: *Editor, kind: Kind, src: []const u8) ?Open {
    var stack: [128]Open = undefined;
    var depth: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, src, i, '<')) |lt| {
        i = lt + 1;
        const tk = scanTag(src, lt) orelse continue;
        if (kind == .jsx and !jsxCanStart(src, lt)) continue;
        i = tk.end;
        if (tk.closing) {
            var k = depth;
            while (k > 0) : (k -= 1) {
                if (std.mem.eql(u8, stack[k - 1].name, tk.name)) break;
            } else continue;
            depth = k - 1;
            continue;
        }
        if (tk.self_closing or (tk.name.len > 0 and isVoid(tk.name))) continue;
        if (depth == stack.len) return null;
        stack[depth] = .{ .lt = lt, .name = tk.name };
        depth += 1;
    }
    _ = ed;
    return if (depth > 0) stack[depth - 1] else null;
}

pub const Tag = struct { name: []const u8, end: usize, closing: bool, self_closing: bool };

/// The tag at `src[lt] == '<'` (also `<>` and `</>`), up to its `>`;
/// quoted values and `{...}` are skipped. Null if it isn't one.
pub fn scanTag(src: []const u8, lt: usize) ?Tag {
    var i = lt + 1;
    const closing = i < src.len and src[i] == '/';
    if (closing) i += 1;
    const name_start = i;
    while (i < src.len and isNameByte(src[i])) i += 1;
    const name = src[name_start..i];
    if (name.len > 0 and !std.ascii.isAlphabetic(name[0])) return null;
    if (name.len == 0 and (i >= src.len or src[i] != '>')) return null;
    var quote: u8 = 0;
    var depth: usize = 0;
    while (i < src.len) : (i += 1) {
        const b = src[i];
        if (quote != 0) {
            if (b == quote) quote = 0;
        } else if (b == '"' or b == '\'' or b == '`') {
            quote = b;
        } else if (b == '{') {
            depth += 1;
        } else if (b == '}') {
            depth -|= 1;
        } else if (depth == 0 and b == '>') {
            return .{ .name = name, .end = i + 1, .closing = closing, .self_closing = i > lt and src[i - 1] == '/' };
        } else if (depth == 0 and b == '<') return null;
    }
    return null;
}

/// <CR> between an opening tag and its closing tag: the content gets its
/// own, indented line.
pub fn splitTags(ed: *Editor) !bool {
    if (!ed.options.auto_pairs or kindOf(ed) == .none) return false;
    const t = ed.text();
    const pos = ed.view.cursor;
    if (pos == 0 or pos + 2 > t.len() or t.byteAt(pos - 1) != '>') return false;
    if (t.byteAt(pos) != '<' or t.byteAt(pos + 1) != '/') return false;
    const ls = t.lineStart(t.lineOf(pos));
    const line = t.slice(ls, pos);
    const lt = std.mem.lastIndexOfScalar(u8, line, '<') orelse return false;
    if (lt + 1 < line.len and line[lt + 1] == '/') return false; // `</a>|</b>`
    if (line.len >= 2 and line[line.len - 2] == '/') return false; // `<a />|`
    const indent = line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];
    var buf: [512]u8 = undefined;
    var unit_buf: [16]u8 = undefined;
    const unit = indenting.indentUnit(ed, &unit_buf);
    const text = std.fmt.bufPrint(&buf, "\n{s}{s}\n{s}", .{ indent, unit, indent }) catch return false;
    try ed.insertAt(pos, text);
    ed.setCursor(pos + 1 + indent.len + unit.len);
    return true;
}

// ---------------------------------------------------------------------------
// Renaming a tag renames its partner

/// The tag name being edited and its partner's, as byte ranges; `name` is
/// what both said when they last matched.
pub const Link = struct {
    buffer: *const anyopaque,
    a_start: usize,
    a_end: usize,
    b_start: usize,
    b_end: usize,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,

    fn name(l: *const Link) []const u8 {
        return l.name_buf[0..l.name_len];
    }

    fn setName(l: *Link, n: []const u8) bool {
        if (n.len > l.name_buf.len) return false;
        @memcpy(l.name_buf[0..n.len], n);
        l.name_len = n.len;
        return true;
    }
};

fn typeIs(n: ts.TSNode, ty: []const u8) bool {
    return !ts.ts_node_is_null(n) and std.mem.eql(u8, std.mem.span(ts.ts_node_type(n)), ty);
}

fn field(n: ts.TSNode, name: []const u8) ts.TSNode {
    return ts.ts_node_child_by_field_name(n, name.ptr, @intCast(name.len));
}

/// The tag name at `pos` (in it, or just after it) and its partner's.
fn linkAt(ed: *Editor, pos: usize) ?Link {
    const kind = kindOf(ed);
    if (kind == .none) return null;
    const syn = &(ed.buffer.syntax orelse return null);
    const t = ed.text();
    syn.update(t);
    const tree = syn.tree orelse return null;
    const root = ts.ts_tree_root_node(tree);
    for ([_]usize{ pos, pos -| 1 }) |p| {
        var node = ts.ts_node_descendant_for_byte_range(root, @intCast(p), @intCast(p));
        var up: usize = 0;
        while (!ts.ts_node_is_null(node) and up < 4) : ({
            node = ts.ts_node_parent(node);
            up += 1;
        }) {
            const tag = ts.ts_node_parent(node);
            if (ts.ts_node_is_null(tag)) break;
            const partner_name = partnerName(kind, node, tag) orelse continue;
            const a0 = ts.ts_node_start_byte(node);
            const a1 = ts.ts_node_end_byte(node);
            if (pos < a0 or pos > a1) continue;
            const b0 = ts.ts_node_start_byte(partner_name);
            const b1 = ts.ts_node_end_byte(partner_name);
            const name = t.slice(a0, a1);
            if (!std.mem.eql(u8, name, t.slice(b0, b1))) return null;
            var l: Link = .{ .buffer = ed.buffer, .a_start = a0, .a_end = a1, .b_start = b0, .b_end = b1 };
            if (!l.setName(name)) return null;
            return l;
        }
    }
    if (kind == .jsx) return emptyLink(root, pos, ed.buffer);
    return emptyHtmlLink(t, pos, ed.buffer);
}

/// HTML has no empty tags to parse: `<>` (a name deleted) pairs with the
/// nearest `</>` after it, and the other way round.
fn emptyHtmlLink(t: *const Text, pos: usize, buffer: *const anyopaque) ?Link {
    const src = t.slice(0, t.len());
    if (pos >= 1 and pos < src.len and src[pos - 1] == '<' and src[pos] == '>' and !(pos >= 2 and src[pos - 2] == '/')) {
        const close = std.mem.indexOfPos(u8, src, pos, "</>") orelse return null;
        return .{ .buffer = buffer, .a_start = pos, .a_end = pos, .b_start = close + 2, .b_end = close + 2 };
    }
    if (pos >= 2 and pos < src.len and src[pos - 2] == '<' and src[pos - 1] == '/' and src[pos] == '>') {
        const open = std.mem.lastIndexOf(u8, src[0 .. pos - 2], "<>") orelse return null;
        return .{ .buffer = buffer, .a_start = pos, .a_end = pos, .b_start = open + 1, .b_end = open + 1 };
    }
    return null;
}

/// A JSX tag with no name yet (`<>`, or one whose name was deleted), the
/// cursor right after its `<` / `</`, and a partner also without one: the
/// names to come are linked, empty for now, so typing fills in both.
fn emptyLink(root: ts.TSNode, pos: usize, buffer: *const anyopaque) ?Link {
    for ([_]usize{ pos, pos -| 1 }) |p| {
        var node = ts.ts_node_descendant_for_byte_range(root, @intCast(p), @intCast(p));
        var up: usize = 0;
        while (!ts.ts_node_is_null(node) and up < 3) : ({
            node = ts.ts_node_parent(node);
            up += 1;
        }) {
            const opening = typeIs(node, "jsx_opening_element");
            if (!opening and !typeIs(node, "jsx_closing_element")) continue;
            if (!ts.ts_node_is_null(field(node, "name"))) return null;
            // Right after `<` (opening) or `</` (closing).
            const name_at = ts.ts_node_start_byte(node) + @as(u32, if (opening) 1 else 2);
            if (pos != name_at) return null;
            const elem = ts.ts_node_parent(node);
            if (!typeIs(elem, "jsx_element")) return null;
            const other = field(elem, if (opening) "close_tag" else "open_tag");
            if (ts.ts_node_is_null(other) or !ts.ts_node_is_null(field(other, "name"))) return null;
            const b = ts.ts_node_start_byte(other) + @as(u32, if (opening) 2 else 1);
            return .{ .buffer = buffer, .a_start = pos, .a_end = pos, .b_start = b, .b_end = b };
        }
    }
    return null;
}

/// When `node` is the name of tag `tag`: the name node of its partner.
fn partnerName(kind: Kind, node: ts.TSNode, tag: ts.TSNode) ?ts.TSNode {
    const elem = ts.ts_node_parent(tag);
    if (ts.ts_node_is_null(elem)) return null;
    switch (kind) {
        .none => return null,
        .html => {
            if (!typeIs(node, "tag_name")) return null;
            const other_ty: []const u8 = if (typeIs(tag, "start_tag")) "end_tag" else if (typeIs(tag, "end_tag")) "start_tag" else return null;
            var i: u32 = ts.ts_node_child_count(elem);
            while (i > 0) {
                i -= 1;
                const ch = ts.ts_node_child(elem, i);
                if (!typeIs(ch, other_ty)) continue;
                var k: u32 = 0;
                while (k < ts.ts_node_child_count(ch)) : (k += 1) {
                    const n = ts.ts_node_child(ch, k);
                    if (typeIs(n, "tag_name")) return n;
                }
            }
            return null;
        },
        .jsx => {
            const own = field(tag, "name");
            if (ts.ts_node_is_null(own) or !ts.ts_node_eq(own, node)) return null;
            if (!typeIs(elem, "jsx_element")) return null;
            const other = if (typeIs(tag, "jsx_opening_element")) field(elem, "close_tag") else if (typeIs(tag, "jsx_closing_element")) field(elem, "open_tag") else return null;
            if (ts.ts_node_is_null(other)) return null;
            const n = field(other, "name");
            return if (ts.ts_node_is_null(n)) null else n;
        },
    }
}

/// Before an edit replacing `[start, end)` with `inserted` bytes (an insert
/// has start == end, a delete inserts nothing): if it is in a tag name,
/// remember that name and its partner's, and keep their places right.
pub fn beforeEdit(ed: *Editor, start: usize, end: usize, inserted: usize) void {
    if (ed.tag_mirroring or ed.replaying or ed.cursors.items.len > 0) return;
    var keep = false;
    if (ed.tag_link) |l| {
        keep = l.buffer == @as(*const anyopaque, ed.buffer) and start >= l.a_start and end <= l.a_end and valid(ed, l);
        if (!keep) ed.tag_link = null;
    }
    if (!keep) {
        if (kindOf(ed) == .none or !ed.options.auto_pairs) return;
        const l = linkAt(ed, start) orelse return;
        if (end > l.a_end) return;
        ed.tag_link = l;
    }
    // The edit is inside the edited name: it grows or shrinks, and a
    // partner after it moves.
    const l = &ed.tag_link.?;
    const removed = end - start;
    l.a_end = l.a_end + inserted - removed;
    if (l.b_start >= end) {
        l.b_start = l.b_start + inserted - removed;
        l.b_end = l.b_end + inserted - removed;
    }
}

/// The link still describes the text: both names where it says, the
/// partner still the name they last shared.
fn valid(ed: *Editor, l: Link) bool {
    const t = ed.text();
    if (l.b_end > t.len() or l.a_end > t.len()) return false;
    if (l.a_start == 0 or l.b_start == 0) return false;
    if (!std.mem.eql(u8, t.slice(l.b_start, l.b_end), l.name())) return false;
    return isTagStart(t, l.a_start) and isTagStart(t, l.b_start);
}

fn isTagStart(t: *const Text, name_start: usize) bool {
    const b = t.byteAt(name_start - 1);
    return b == '<' or (b == '/' and name_start >= 2 and t.byteAt(name_start - 2) == '<');
}

/// After a key: the partner takes the edited name.
pub fn sync(ed: *Editor) void {
    var l = ed.tag_link orelse return;
    if (l.buffer != @as(*const anyopaque, ed.buffer)) {
        ed.tag_link = null;
        return;
    }
    const t = ed.text();
    // The partner must still be the old name, else something else (undo,
    // say) changed the text: let go.
    if (l.b_end > t.len() or l.a_start > t.len() or !std.mem.eql(u8, t.slice(l.b_start, l.b_end), l.name()) or
        l.a_start == 0 or !isTagStart(t, l.a_start))
    {
        ed.tag_link = null;
        return;
    }
    var e = l.a_start;
    while (e < t.len() and isNameByte(t.byteAt(e))) e += 1;
    l.a_end = e;
    var name_buf: [64]u8 = undefined;
    const now = t.slice(l.a_start, e);
    if (now.len > name_buf.len) {
        ed.tag_link = null;
        return;
    }
    const name = name_buf[0..now.len];
    @memcpy(name, now);
    if (!std.mem.eql(u8, name, l.name())) {
        ed.tag_mirroring = true;
        defer ed.tag_mirroring = false;
        const old_len = l.b_end - l.b_start;
        const before_cursor = l.b_start < ed.view.cursor;
        ed.deleteRangeKeepCursor(l.b_start, l.b_end) catch {};
        ed.insertAt(l.b_start, name) catch {};
        if (before_cursor) ed.view.cursor += name.len;
        if (l.b_start < l.a_start) {
            l.a_start = l.a_start + name.len - old_len;
            l.a_end = l.a_start + name.len;
        }
        l.b_end = l.b_start + name.len;
        _ = l.setName(name);
    }
    // Done once the cursor is off the name in normal mode.
    if (ed.mode != .insert and (ed.view.cursor < l.a_start or ed.view.cursor > l.a_end)) {
        ed.tag_link = null;
        return;
    }
    ed.tag_link = l;
}
