//! Edits from mini.nvim beyond vim's own operators: comment toggling
//! (mini.comment), replace / exchange / sort / multiply (mini.operators),
//! align (mini.align), split / join of argument lists (mini.splitjoin) and
//! trailing whitespace (mini.trailspace). Each acts on a range the operator
//! machinery already produced, through the editor's undo-recording edits.

const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("core/Text.zig");
const motions = @import("core/motions.zig");
const textobjects = @import("core/textobjects.zig");
const comment = @import("core/comment.zig");
const operators = @import("operators.zig");
const ts = @import("tree_sitter");
const config = @import("config/config.zig");

const Range = textobjects.Range;

// ---------------------------------------------------------------------------
// Comments

pub fn commentPrefix(ed: *Editor) []const u8 {
    return comment.prefixFor(ed.buffer.path);
}

/// How `line` is commented: the file's style, except among JSX children,
/// where only `{/* */}` is a comment.
pub fn commentStyle(ed: *Editor, line: usize) comment.Style {
    var st = comment.styleFor(ed.buffer.path);
    if (ed.buffer.syntax) |syn| if (config.settingsFor(syn.lang.name)) |cfg| if (cfg.comment) |own| {
        st = own;
    };
    if (inJsxChildren(ed, line)) return comment.Style.jsx;
    return st;
}

/// Whether `line` starts inside a JSX element's children (not at the
/// element that is the expression itself, where `//` still works).
fn inJsxChildren(ed: *Editor, line: usize) bool {
    const syn = &(ed.buffer.syntax orelse return false);
    const name = syn.lang.name;
    if (!std.mem.eql(u8, name, "tsx") and !std.mem.eql(u8, name, "javascript")) return false;
    const t = ed.text();
    syn.update(t);
    const tree = syn.tree orelse return false;
    const at: u32 = @intCast(motions.firstNonBlank(t, line));
    var node = ts.ts_node_descendant_for_byte_range(ts.ts_tree_root_node(tree), at, at);
    while (!ts.ts_node_is_null(node)) : (node = ts.ts_node_parent(node)) {
        const ty = std.mem.span(ts.ts_node_type(node));
        // A line in an attribute's `{...}` or any other JS inside JSX.
        if (std.mem.eql(u8, ty, "jsx_expression")) return ts.ts_node_start_byte(node) == at and parentIs(node, "jsx_element");
        if (std.mem.eql(u8, ty, "jsx_opening_element") or std.mem.eql(u8, ty, "jsx_closing_element")) return parentIs(ts.ts_node_parent(node), "jsx_element");
        if (std.mem.eql(u8, ty, "jsx_element") or std.mem.eql(u8, ty, "jsx_self_closing_element") or std.mem.eql(u8, ty, "jsx_text")) {
            return parentIs(node, "jsx_element");
        }
    }
    return false;
}

fn parentIs(node: ts.TSNode, ty: []const u8) bool {
    const p = ts.ts_node_parent(node);
    return !ts.ts_node_is_null(p) and std.mem.eql(u8, std.mem.span(ts.ts_node_type(p)), ty);
}

/// Comments lines `first..last` (inclusive), or uncomments them when every
/// non-blank one already is a comment. The prefix goes at the block's
/// smallest indentation, so the code keeps its shape.
pub fn toggleComment(ed: *Editor, first: usize, last: usize) !void {
    const t = ed.text();
    const st = commentStyle(ed, first);
    var all = true;
    var min_indent: ?usize = null;
    for (first..last + 1) |line| {
        const bytes = t.lineSlice(line);
        const fnb = std.mem.indexOfNone(u8, bytes, " \t") orelse continue;
        min_indent = @min(min_indent orelse fnb, fnb);
        if (!comment.isComment(bytes, st)) all = false;
    }
    const indent = min_indent orelse return; // only blank lines
    var buf: [16]u8 = undefined;
    const open = std.fmt.bufPrint(&buf, "{s} ", .{st.open}) catch st.open;
    var cbuf: [16]u8 = undefined;
    const close = if (st.close.len > 0) std.fmt.bufPrint(&cbuf, " {s}", .{st.close}) catch st.close else "";
    // Bottom-up, so earlier line positions stay valid.
    var line = last + 1;
    while (line > first) {
        line -= 1;
        const bytes = t.lineSlice(line);
        const fnb = std.mem.indexOfNone(u8, bytes, " \t") orelse continue;
        const ls = t.lineStart(line);
        if (all) {
            // The closer first (it is after the opener).
            if (st.close.len > 0) {
                const end = std.mem.trimEnd(u8, bytes, " \t").len;
                var n = st.close.len;
                if (end >= n + 1 and bytes[end - n - 1] == ' ') n += 1;
                try ed.deleteRangeKeepCursor(ls + end - n, ls + end);
            }
            var n = st.open.len;
            if (fnb + n < bytes.len and bytes[fnb + n] == ' ') n += 1;
            try ed.deleteRangeKeepCursor(ls + fnb, ls + fnb + n);
        } else {
            if (close.len > 0) try ed.insertAt(ls + std.mem.trimEnd(u8, bytes, " \t").len, close);
            try ed.insertAt(ls + indent, open);
        }
    }
    ed.setCursor(motions.firstNonBlank(t, first));
}

// ---------------------------------------------------------------------------
// mini.operators

/// `gr`: replaces the range with a register's text (the register is kept).
pub fn replaceWithRegister(ed: *Editor, r: Range, register: ?u8) !void {
    const v = ed.registers.get(register) orelse return ed.setMessage(.err, "nothing to replace with", .{});
    var body = v.text;
    if (v.linewise and std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];
    const text = try ed.gpa.dupe(u8, body);
    defer ed.gpa.free(text);
    try ed.deleteRange(r.start, r.end);
    try ed.insertAt(r.start, text);
    ed.setCursor(r.start);
}

/// `gx`: the first use marks a range, the second swaps the two.
pub fn exchange(ed: *Editor, r: Range) !void {
    const b = ed.buffer;
    const mark = ed.exchange_mark;
    ed.exchange_mark = null;
    const m = if (mark) |m| (if (m.buffer == b and m.version == b.edit_version) m else null) else null;
    const first = m orelse {
        ed.exchange_mark = .{ .buffer = b, .version = b.edit_version, .range = r };
        return ed.setMessage(.info, "exchange: gx on the other text swaps them (Esc cancels)", .{});
    };
    const lo = if (first.range.start <= r.start) first.range else r;
    const hi = if (first.range.start <= r.start) r else first.range;
    if (lo.end > hi.start) return ed.setMessage(.err, "exchange: the two texts overlap", .{});
    const t = ed.text();
    const lo_text = try ed.gpa.dupe(u8, t.slice(lo.start, lo.end));
    defer ed.gpa.free(lo_text);
    const hi_text = try ed.gpa.dupe(u8, t.slice(hi.start, hi.end));
    defer ed.gpa.free(hi_text);
    // The later one first, so the earlier range stays where it is.
    try ed.deleteRangeKeepCursor(hi.start, hi.end);
    try ed.insertAt(hi.start, lo_text);
    try ed.deleteRangeKeepCursor(lo.start, lo.end);
    try ed.insertAt(lo.start, hi_text);
    ed.setCursor(lo.start);
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `gs`: sorts the range's lines, or, inside one line, its comma- (else
/// semicolon-, else space-) separated parts.
pub fn sort(ed: *Editor, r: Range) !void {
    const gpa = ed.gpa;
    const t = ed.text();
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const first = t.lineOf(r.start);
    const last = operators.lastLine(t, r);
    var start = r.start;
    var end = r.end;
    if (r.linewise or last > first) {
        start = t.lineStart(first);
        end = t.lineEnd(last);
        for (first..last + 1) |line| try parts.append(gpa, t.lineSlice(line));
        std.mem.sort([]const u8, parts.items, {}, lessThanBytes);
        for (parts.items, 0..) |p, i| {
            if (i > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, p);
        }
    } else {
        const text = t.slice(start, end);
        const delim: u8 = if (std.mem.indexOfScalar(u8, text, ',') != null) ',' else if (std.mem.indexOfScalar(u8, text, ';') != null) ';' else ' ';
        const lead = text.len - std.mem.trimStart(u8, text, " \t").len;
        const trail = text.len - std.mem.trimEnd(u8, text, " \t").len;
        const spaced = delim != ' ' and std.mem.indexOf(u8, text, &.{ delim, ' ' }) != null;
        var it = std.mem.splitScalar(u8, text, delim);
        while (it.next()) |p| {
            const part = std.mem.trim(u8, p, " \t");
            if (part.len > 0) try parts.append(gpa, part);
        }
        std.mem.sort([]const u8, parts.items, {}, lessThanBytes);
        try out.appendSlice(gpa, text[0..lead]);
        for (parts.items, 0..) |p, i| {
            if (i > 0) {
                try out.append(gpa, delim);
                if (spaced) try out.append(gpa, ' ');
            }
            try out.appendSlice(gpa, p);
        }
        try out.appendSlice(gpa, text[text.len - trail ..]);
    }
    if (!std.mem.eql(u8, out.items, t.slice(start, end))) {
        // `parts` points into the text: it is not used past this point.
        try ed.deleteRange(start, end);
        try ed.insertAt(start, out.items);
    }
    ed.setCursor(start);
}

/// `gm`: duplicates the range `count` times (lines below, text right after).
pub fn multiply(ed: *Editor, r: Range, count: usize) !void {
    const gpa = ed.gpa;
    const t = ed.text();
    const text = try gpa.dupe(u8, t.slice(r.start, r.end));
    defer gpa.free(text);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..@max(count, 1)) |_| {
        if (r.linewise) try out.append(gpa, '\n');
        try out.appendSlice(gpa, text);
    }
    try ed.insertAt(r.end, out.items);
    if (r.linewise) {
        ed.setCursor(motions.firstNonBlank(t, t.lineOf(r.end) + 1));
    } else ed.setCursor(r.end);
}

// ---------------------------------------------------------------------------
// mini.align

/// Where the delimiter `needle` starts in `line`, if it has one. For `=` an
/// operator in front of it (`+=`, `!=`, `<=`...) belongs to the delimiter.
fn delimiterAt(line: []const u8, needle: []const u8) ?[2]usize {
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    var start = at;
    if (needle.len == 1 and needle[0] == '=') {
        while (start > 0 and std.mem.indexOfScalar(u8, "+-*/%!<>&|^~:", line[start - 1]) != null) start -= 1;
    }
    return .{ start, at + needle.len };
}

/// `ga{motion}{char}`: lines up the first `char` of each line in the range.
/// For `,` and `:` the text after it is lined up instead (`a:  1`), as those
/// stay attached to what precedes them.
pub fn alignLines(ed: *Editor, r: Range, char: u21) !void {
    const t = ed.text();
    var enc: [4]u8 = undefined;
    const needle = enc[0 .. std.unicode.utf8Encode(char, &enc) catch return];
    const after = char == ',' or char == ':';
    const tab = ed.options.tab_width;
    const first = t.lineOf(r.start);
    const last = operators.lastLine(t, r);

    // The column everything moves to: one past the widest left part.
    var target: usize = 0;
    var found: usize = 0;
    for (first..last + 1) |line| {
        const bytes = t.lineSlice(line);
        const d = delimiterAt(bytes, needle) orelse continue;
        found += 1;
        const left_end = if (after) d[1] else std.mem.trimEnd(u8, bytes[0..d[0]], " \t").len;
        target = @max(target, motions.displayCol(bytes, left_end, tab) + 1);
    }
    if (found < 2) return ed.setMessage(.info, "nothing to align on '{s}'", .{needle});

    const spaces: [256]u8 = @splat(' ');
    var line = last + 1;
    while (line > first) {
        line -= 1;
        const bytes = t.lineSlice(line);
        const d = delimiterAt(bytes, needle) orelse continue;
        const ls = t.lineStart(line);
        // The run of blanks to resize: before the delimiter, or after it.
        var gap_start: usize = undefined;
        var gap_end: usize = undefined;
        if (after) {
            gap_start = d[1];
            gap_end = d[1];
            while (gap_end < bytes.len and (bytes[gap_end] == ' ' or bytes[gap_end] == '\t')) gap_end += 1;
            if (gap_end == bytes.len) continue; // nothing follows
        } else {
            gap_end = d[0];
            gap_start = std.mem.trimEnd(u8, bytes[0..d[0]], " \t").len;
        }
        const want = @min(target - motions.displayCol(bytes, gap_start, tab), spaces.len);
        if (gap_end - gap_start == want and std.mem.indexOfScalar(u8, bytes[gap_start..gap_end], '\t') == null) continue;
        try ed.deleteRangeKeepCursor(ls + gap_start, ls + gap_end);
        try ed.insertAt(ls + gap_start, spaces[0..want]);
    }
    ed.setCursor(motions.firstNonBlank(t, first));
}

// ---------------------------------------------------------------------------
// mini.splitjoin

/// Splits `inner` at its top-level commas (not inside nested brackets or
/// strings). Parts are trimmed; empty ones (a trailing comma) are dropped.
pub fn splitArguments(gpa: std.mem.Allocator, inner: []const u8, out: *std.ArrayList([]const u8)) !void {
    var depth: usize = 0;
    var quote: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        const at_end = i == inner.len;
        const b = if (at_end) ',' else inner[i];
        if (!at_end) {
            if (quote != 0) {
                if (b == '\\') i += 1 else if (b == quote) quote = 0;
                continue;
            }
            switch (b) {
                '"', '`' => quote = b,
                // A character literal, not a Rust lifetime: it closes soon.
                '\'' => if (std.mem.indexOfScalarPos(u8, inner[0..@min(inner.len, i + 5)], i + 1, '\'') != null) {
                    quote = b;
                },
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                else => {},
            }
        }
        if (b == ',' and depth == 0 and quote == 0 or at_end) {
            const part = std.mem.trim(u8, inner[start..@min(i, inner.len)], " \t\n");
            if (part.len > 0) try out.append(gpa, part);
            start = i + 1;
        }
    }
}

/// Languages where a list may end with a comma (so a split list gets one,
/// which is also what keeps formatters from joining it again).
fn allowsTrailingComma(path: ?[]const u8) bool {
    const p = path orelse return false;
    const dot = std.mem.lastIndexOfScalar(u8, p, '.') orelse return false;
    const ext = p[dot + 1 ..];
    for ([_][]const u8{ "zig", "zon", "rs", "py", "go" }) |e| if (std.mem.eql(u8, ext, e)) return true;
    return false;
}

/// `gS`: the bracketed list around (or after) the cursor goes from one line
/// to one argument per line, or back.
pub fn splitJoin(ed: *Editor) !void {
    const gpa = ed.gpa;
    const t = ed.text();
    const around = textobjects.anyBracket(t, ed.view.cursor, .around, 1) orelse
        return ed.setMessage(.info, "no brackets here to split or join", .{});
    const open = around.start;
    const close = around.end - 1;
    const inner = t.slice(open + 1, close);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    try splitArguments(gpa, inner, &parts);
    if (parts.items.len == 0) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const brace = t.byteAt(open) == '{';
    if (std.mem.indexOfScalar(u8, inner, '\n') != null) {
        // Join.
        if (brace) try out.append(gpa, ' ');
        for (parts.items, 0..) |p, i| {
            if (i > 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, p);
        }
        if (brace) try out.append(gpa, ' ');
    } else {
        const line = t.lineOf(open);
        const indent = t.slice(t.lineStart(line), motions.firstNonBlank(t, line));
        var unit_buf: [16]u8 = undefined;
        const unit = ed.indentUnit(&unit_buf);
        const trailing = allowsTrailingComma(ed.buffer.path);
        for (parts.items, 0..) |p, i| {
            try out.append(gpa, '\n');
            try out.appendSlice(gpa, indent);
            try out.appendSlice(gpa, unit);
            try out.appendSlice(gpa, p);
            if (i + 1 < parts.items.len or trailing) try out.append(gpa, ',');
        }
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, indent);
    }
    // `parts` and `inner` point into the text: `out` is complete before it changes.
    try ed.deleteRange(open + 1, close);
    try ed.insertAt(open + 1, out.items);
    ed.setCursor(open);
}

// ---------------------------------------------------------------------------
// mini.trailspace

/// Removes trailing spaces and tabs from every line. Returns how many lines
/// changed.
pub fn trimTrailing(ed: *Editor) !usize {
    const t = ed.text();
    var changed: usize = 0;
    var line = t.lineCount();
    while (line > 0) {
        line -= 1;
        const bytes = t.lineSlice(line);
        const keep = std.mem.trimEnd(u8, bytes, " \t").len;
        if (keep == bytes.len) continue;
        const ls = t.lineStart(line);
        try ed.deleteRangeKeepCursor(ls + keep, ls + bytes.len);
        changed += 1;
    }
    return changed;
}

const testing = std.testing;

test "arguments split at top-level commas only" {
    const gpa = testing.allocator;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    try splitArguments(gpa, "a, f(b, c), \"d, e\", &'a x, 'y',", &parts);
    try testing.expectEqual(5, parts.items.len);
    try testing.expectEqualStrings("f(b, c)", parts.items[1]);
    try testing.expectEqualStrings("\"d, e\"", parts.items[2]);
    try testing.expectEqualStrings("&'a x", parts.items[3]);
    try testing.expectEqualStrings("'y'", parts.items[4]);
}
