//! Formatting (`SPC l f`, and on save): the language server's, else the language's formatter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const Text = @import("../core/Text.zig");
const diff = @import("../git/diff.zig");
const Lsp = @import("../lsp/Lsp.zig");
const format = @import("../format.zig");
const Editor = @import("../Editor.zig");
const file_ops = @import("file_ops.zig");
const notifications = @import("notifications.zig");
const project_ops = @import("project_ops.zig");
const prompts = @import("prompts.zig");
const lsp_ops = @import("lsp_ops.zig");

/// Formats the current buffer (lines `range`, inclusive, if the server can
/// format ranges), then saves it if `then_save`.
pub fn formatBuffer(ed: *Editor, range: ?[2]usize, then_save: bool) !void {
    const b = ed.buffer;
    const lang = if (b.syntax) |sx| sx.lang.name else "";
    if (!format.preferred(lang)) if (lsp_ops.lspFor(ed, b)) |l| if (l.can_format) {
        l.requestFormat(ed, range, then_save) catch |err| {
            ed.setMessage(.err, "could not format: {s}", .{@errorName(err)});
            if (then_save) file_ops.saveBufferNow(ed, b);
            return;
        };
        if (!then_save) ed.setMessage(.info, "formatting...", .{});
        return;
    };
    try formatExternal(ed, then_save);
}

pub fn formatExternal(ed: *Editor, then_save: bool) !void {
    const b = ed.buffer;
    defer if (then_save) file_ops.saveBufferNow(ed, b);
    const lang = if (b.syntax) |sx| sx.lang.name else "";
    const t = ed.text();
    // The buffer as the file would be written (final newline included).
    const src = try std.mem.concat(ed.gpa, u8, &.{ t.slice(0, t.len()), if (b.final_newline and t.len() > 0) "\n" else "" });
    defer ed.gpa.free(src);
    const abs = if (b.path) |p| try ed.absolutePath(p) else null;
    defer if (abs) |a| ed.gpa.free(a);
    switch (try format.run(ed.gpa, ed.io, lang, src, project_ops.projectRoot(ed), abs)) {
        .none => if (!then_save) {
            if (format.name(lang)) |n| ed.setMessage(.err, "{s} isn't installed", .{n}) else ed.setMessage(.info, "no formatter for this file", .{});
        } else if (format.name(lang)) |n| {
            // On save: said once, then saving just goes on unformatted.
            if (!ed.format_missing_told.contains(n)) {
                ed.format_missing_told.put(ed.gpa, n, {}) catch {};
                notifications.notify(ed, .err, "{s} isn't installed: saved without formatting", .{n});
            }
        },
        .failed => |m| {
            defer ed.gpa.free(m);
            ed.setMessage(.err, "{s}: {s}", .{ format.name(lang).?, m });
        },
        .ok => |out| {
            defer ed.gpa.free(out);
            const body = if (b.final_newline and out.len > 0 and out[out.len - 1] == '\n') out[0 .. out.len - 1] else out;
            try replaceTextKeepingCursor(ed, body);
        },
    }
}

/// Replaces the buffer's text with `new`, changing only the lines that
/// differ (one undo step), the cursor staying on its line and column.
pub fn replaceTextKeepingCursor(ed: *Editor, new: []const u8) !void {
    const t = ed.text();
    if (std.mem.eql(u8, t.slice(0, t.len()), new)) return;
    const new_text = try Text.init(ed.gpa, new);
    var nt = new_text;
    defer nt.deinit(ed.gpa);
    const lines = struct {
        fn of(gpa: Allocator, x: *const Text) ![][]const u8 {
            const n = if (x.len() == 0) 0 else x.lineCount();
            const out = try gpa.alloc([]const u8, n);
            for (out, 0..) |*l, i| l.* = x.lineSlice(i);
            return out;
        }
    }.of;
    const old_lines = try lines(ed.gpa, t);
    defer ed.gpa.free(old_lines);
    const new_lines = try lines(ed.gpa, &nt);
    defer ed.gpa.free(new_lines);
    var hunks: std.ArrayList(diff.Hunk) = .empty;
    defer hunks.deinit(ed.gpa);
    try diff.diffLines(ed.gpa, old_lines, new_lines, &hunks);
    const line = ed.cursorLine();
    const col = ed.view.cursor - t.lineStart(line);
    // Last hunk first, so earlier line numbers stay valid.
    var i = hunks.items.len;
    while (i > 0) {
        i -= 1;
        const h = hunks.items[i];
        var repl: std.ArrayList(u8) = .empty;
        defer repl.deinit(ed.gpa);
        for (0..h.new_count) |k| {
            if (k > 0) try repl.append(ed.gpa, '\n');
            try repl.appendSlice(ed.gpa, new_lines[h.new_start + k]);
        }
        const total = t.lineCount();
        if (h.old_count == 0) {
            // Inserted lines: before line old_start (or after the last).
            if (h.old_start < total and t.len() > 0) {
                try repl.append(ed.gpa, '\n');
                try ed.insertAt(t.lineStart(h.old_start), repl.items);
            } else {
                if (t.len() > 0) try repl.insert(ed.gpa, 0, '\n');
                try ed.insertAt(t.len(), repl.items);
            }
        } else {
            var start = t.lineStart(h.old_start);
            var end = t.lineEnd(h.old_start + h.old_count - 1);
            if (h.new_count == 0) {
                // Removed lines, with one of their line breaks.
                if (end < t.len()) end += 1 else if (start > 0) start -= 1;
            }
            try ed.deleteRangeKeepCursor(start, end);
            try ed.insertAt(start, repl.items);
        }
    }
    try ed.buffer.history.commit(ed.gpa);
    const l = @min(line, t.lineCount() - 1);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
}

/// The server's formatting edits for `b` arrived: apply them (one undo
/// step, cursor kept on its line), then save if asked.
pub fn applyFormatEdits(ed: *Editor, b: *Buffer, edits: []const Lsp.TextEdit, then_save: bool) !void {
    defer if (then_save) file_ops.saveBufferNow(ed, b);
    if (edits.len == 0) {
        if (!then_save) ed.setMessage(.info, "already formatted", .{});
        return;
    }
    if (b != ed.buffer) return; // switched away meanwhile: leave it
    const t = ed.text();
    const line = ed.cursorLine();
    const col = ed.view.cursor - t.lineStart(line);
    const sorted = try ed.gpa.dupe(Lsp.TextEdit, edits);
    defer ed.gpa.free(sorted);
    std.mem.sort(Lsp.TextEdit, sorted, {}, struct {
        fn later(_: void, a: Lsp.TextEdit, c: Lsp.TextEdit) bool {
            return if (a.start_line != c.start_line) a.start_line > c.start_line else a.start_col > c.start_col;
        }
    }.later);
    for (sorted) |e| {
        const start = prompts.offsetOf(ed, e.start_line, e.start_col);
        const end = prompts.offsetOf(ed, e.end_line, e.end_col);
        try ed.deleteRangeKeepCursor(start, @max(start, end));
        try ed.insertAt(start, e.text);
    }
    try ed.buffer.history.commit(ed.gpa);
    ed.buffer.modified = ed.buffer.history.isModified();
    const l = @min(line, t.lineCount() - 1);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
    if (!then_save) ed.setMessage(.info, "formatted", .{});
}

pub fn fileExists(ed: *Editor, path: []const u8) bool {
    Io.Dir.cwd().access(ed.io, path, .{}) catch return false;
    return true;
}

pub fn findBuffer(ed: *Editor, path: []const u8) ?*Buffer {
    for (ed.buffers.items) |b| if (b.path) |p| if (std.mem.eql(u8, p, path)) return b;
    return null;
}

/// `SPC b e`: a new empty scratch buffer.
pub fn newBuffer(ed: *Editor) !void {
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try ed.buffers.append(ed.gpa, b);
    ed.switchTo(b);
}

/// `SPC b b`: back to the previous buffer (the most recently used other one).
pub fn lastBuffer(ed: *Editor) !void {
    const order = try buffersByRecency(ed, ed.gpa);
    defer ed.gpa.free(order);
    if (order.len < 2) return ed.setMessage(.info, "no other buffer", .{});
    ed.switchTo(order[0]);
}

/// `SPC b o`: kills every other buffer without unsaved changes.
pub fn killOtherBuffers(ed: *Editor) !void {
    var kept: usize = 0;
    var i: usize = 0;
    while (i < ed.buffers.items.len) {
        const b = ed.buffers.items[i];
        if (b == ed.buffer) {
            i += 1;
        } else if (b.modified) {
            kept += 1;
            i += 1;
        } else try ed.killBuffer(b);
    }
    if (kept > 0) ed.setMessage(.info, "kept {d} buffer(s) with unsaved changes", .{kept}) else ed.setMessage(.info, "killed other buffers", .{});
}

/// `SPC b a`: saves every modified buffer that has a file.
pub fn saveAll(ed: *Editor) void {
    var n: usize = 0;
    for (ed.buffers.items) |b| if (b.modified and b.path != null) {
        _ = b.save(ed.gpa, ed.io) catch |err| {
            ed.setMessage(.err, "could not save \"{s}\": {s}", .{ b.displayName(), @errorName(err) });
            return;
        };
        if (lsp_ops.lspFor(ed, b)) |l| l.didSave(b);
        n += 1;
    };
    ed.setMessage(.info, "saved {d} buffer(s)", .{n});
}

pub fn bufferIndex(ed: *const Editor, b: *const Buffer) usize {
    for (ed.buffers.items, 0..) |o, i| if (o == b) return i;
    unreachable;
}

/// Cycles through buffers in list order.
pub fn cycleBuffer(ed: *Editor, delta: isize) void {
    // The command editor's buffer isn't one of the list.
    if (ed.cmd_float != null) return ed.setMessage(.info, "close the command editor first (<Esc> in normal mode)", .{});
    const n: isize = @intCast(ed.buffers.items.len);
    const i: isize = @intCast(bufferIndex(ed, ed.buffer));
    ed.switchTo(ed.buffers.items[@intCast(@mod(i + delta, n))]);
}

/// Most recently used first, the current buffer last (so the top entry is
/// "the buffer before this one"). Caller frees the slice.
pub fn buffersByRecency(ed: *Editor, gpa: Allocator) Allocator.Error![]*Buffer {
    const out = try gpa.dupe(*Buffer, ed.buffers.items);
    std.mem.sort(*Buffer, out, ed.buffer, struct {
        fn lessThan(current: *Buffer, a: *Buffer, b: *Buffer) bool {
            if (a == current) return false;
            if (b == current) return true;
            return a.last_used > b.last_used;
        }
    }.lessThan);
    return out;
}

/// Where `b`'s cursor is (live for the current buffer, saved for others).
pub fn cursorOf(ed: *const Editor, b: *const Buffer) usize {
    return if (b == ed.buffer) ed.view.cursor else b.saved.cursor;
}
