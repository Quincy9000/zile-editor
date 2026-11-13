//! Search and replace across the project (`<C-r>` in the grep picker).

const std = @import("std");
const Replace = @import("../Replace.zig");
const state_files = @import("state_files.zig");
const picker_query = @import("picker_query.zig");
const Editor = @import("../Editor.zig");
const prompts = @import("prompts.zig");

/// `<C-r>` in the grep picker: its query becomes the search (exact, smart
/// case), and a prompt asks for the replacement.
pub fn startReplace(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .grep) return ed.setMessage(.info, "<C-r> replaces from the grep picker (SPC /)", .{});
    const needle = try ed.gpa.dupe(u8, p.activeQuery());
    defer ed.gpa.free(needle);
    if (needle.len == 0) return ed.setMessage(.info, "type what to replace first", .{});
    if (!@import("../picker/sources.zig").haveRg(ed.io)) return ed.setMessage(.err, "replacing needs ripgrep (rg)", .{});
    const root = ed.picker_root;
    const r = try Replace.start(ed.gpa, ed.io, needle, root, ed.wake_fn);
    picker_query.closePicker(ed);
    if (ed.replace) |old| old.destroy();
    ed.replace = r;
    ed.replace_root = root;
    prompts.startSearch(ed, true, .replace);
}

/// `<Esc>`: back to the grep picker, with the search as its query.
pub fn cancelReplace(ed: *Editor) void {
    const r = ed.replace orelse return;
    ed.replace = null;
    defer r.destroy();
    ed.next_picker_root = ed.replace_root;
    ed.openPicker(.grep, r.needle) catch {};
}

/// `<CR>`: replaces every match not skipped. Each file is opened and changed
/// as one undo step; a match whose text changed since the search is left.
pub fn finishReplace(ed: *Editor) !void {
    const r = ed.replace orelse return prompts.cancelSearch(ed);
    if (!r.isDone()) return ed.setMessage(.info, "still searching...", .{});
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.replace = null;
    defer r.destroy();
    const replacement = sp.input.items();

    const home = ed.buffer;
    const home_cursor = sp.origin;
    var replaced: usize = 0;
    var files: usize = 0;
    var stale: usize = 0;
    const rows = r.matches.items;
    var i: usize = 0;
    while (i < rows.len) {
        const path = rows[i].path;
        var j = i;
        var wanted = false;
        while (j < rows.len and std.mem.eql(u8, rows[j].path, path)) : (j += 1) wanted = wanted or !rows[j].skip;
        defer i = j;
        if (!wanted) continue;
        const abs = try std.fs.path.join(ed.gpa, &.{ r.root, path });
        defer ed.gpa.free(abs);
        ed.openFile(abs) catch {
            for (rows[i..j]) |m| stale += if (m.skip) 0 else m.cols.len;
            continue;
        };
        const t = ed.text();
        var changed = false;
        // Bottom up, right to left: earlier positions stay valid.
        var k = j;
        while (k > i) {
            k -= 1;
            const m = rows[k];
            if (m.skip) continue;
            if (m.line >= t.lineCount()) {
                stale += m.cols.len;
                continue;
            }
            const ls = t.lineStart(m.line);
            var c = m.cols.len;
            while (c > 0) {
                c -= 1;
                const at = ls + m.cols[c];
                if (!r.matchesAt(t.slice(ls, t.lineEnd(m.line)), m.cols[c])) {
                    stale += 1;
                    continue;
                }
                try ed.deleteRangeKeepCursor(at, at + r.needle.len);
                try ed.insertAt(at, replacement);
                replaced += 1;
                changed = true;
            }
        }
        if (changed) {
            try ed.buffer.history.commit(ed.gpa);
            ed.buffer.modified = ed.buffer.history.isModified();
            files += 1;
        }
    }
    if (state_files.bufferAlive(ed, home)) ed.switchTo(home);
    ed.setCursor(@min(home_cursor, ed.text().len()));
    // With autosave, leaving each file wrote it.
    const after = if (ed.options.autosave) "saved; u in a file undoes it" else "SPC b a saves all; u in a file undoes it";
    if (stale > 0) {
        ed.setMessage(.info, "replaced {d} in {d} file(s) ({s}); {d} had changed since the search and were left alone", .{ replaced, files, after, stale });
    } else {
        ed.setMessage(.info, "replaced {d} in {d} file(s) ({s})", .{ replaced, files, after });
    }
}
