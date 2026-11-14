//! Find and replace across the project (`SPC c`; `<C-r>` in the grep picker).

const std = @import("std");
const Replace = @import("../Replace.zig");
const state_files = @import("state_files.zig");
const picker_query = @import("picker_query.zig");
const Editor = @import("../Editor.zig");
const prompts = @import("prompts.zig");
const code_motion = @import("code_motion.zig");
const project_ops = @import("project_ops.zig");
const sources = @import("../picker/sources.zig");

/// `<C-r>` in the grep picker: its query is what to find, and the
/// replacement is asked for.
pub fn startReplace(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .grep) return ed.setMessage(.info, "<C-r> replaces from the grep picker (SPC /)", .{});
    const find = try ed.gpa.dupe(u8, p.activeQuery());
    defer ed.gpa.free(find);
    const root = ed.picker_root;
    if (!sources.haveRg(ed.io)) return ed.setMessage(.err, "replacing needs ripgrep (rg)", .{});
    picker_query.closePicker(ed);
    try open(ed, find, root, true);
}

/// `SPC c`: find and replace across the project. From a selection within
/// one line, that is what to find.
pub fn replaceProject(ed: *Editor) !void {
    if (!sources.haveRg(ed.io)) return ed.setMessage(.err, "replacing needs ripgrep (rg)", .{});
    var find: []u8 = &.{};
    defer ed.gpa.free(find);
    if (ed.mode == .visual) {
        const range = code_motion.visualRange(ed);
        const t = ed.text();
        if (!ed.visual_line and t.lineOf(range.start) == t.lineOf(range.end -| 1)) find = try ed.gpa.dupe(u8, t.slice(range.start, range.end));
        code_motion.exitVisual(ed);
    }
    try open(ed, find, project_ops.projectRoot(ed), false);
}

fn open(ed: *Editor, find: []const u8, root: []const u8, from_grep: bool) !void {
    const r = try Replace.create(ed.gpa, ed.io, root, ed.wake_fn);
    errdefer r.destroy();
    r.options = ed.replace_options;
    r.from_grep = from_grep;
    try r.find.set(ed.gpa, find);
    // With something to find already, the replacement is typed next.
    r.field = if (find.len > 0) .with else .find;
    try r.search("");
    if (ed.replace) |old| old.destroy();
    ed.replace = r;
    ed.replace_root = root;
    prompts.startSearch(ed, true, .replace);
}

/// Either field was typed into, or an option changed: search again.
pub fn changed(ed: *Editor) !void {
    const r = ed.replace orelse return;
    const sp = ed.search_prompt orelse return;
    try r.search(sp.input.items());
}

pub const Option = enum { regex, word };

/// `<C-r>` / `<C-b>` in the form. Kept for the next time it is opened.
pub fn toggleOption(ed: *Editor, option: Option) !void {
    const r = ed.replace orelse return;
    switch (option) {
        .regex => r.options.regex = !r.options.regex,
        .word => r.options.word = !r.options.word,
    }
    ed.replace_options = r.options;
    try changed(ed);
}

/// `<Tab>`: the other field.
pub fn otherField(ed: *Editor) void {
    const r = ed.replace orelse return;
    r.field = if (r.field == .find) .with else .find;
}

/// `<Esc>`: closes it; back to the grep picker if it came from there, with
/// the search as its query.
pub fn cancelReplace(ed: *Editor) void {
    const r = ed.replace orelse return;
    ed.replace = null;
    defer r.destroy();
    if (!r.from_grep) return;
    ed.next_picker_root = ed.replace_root;
    ed.openPicker(.grep, r.find.items()) catch {};
}

/// `<CR>`: from what to find, on to the replacement; there, replaces every
/// match not skipped. Each file is opened and changed as one undo step; a
/// match whose text changed since the search is left.
pub fn finishReplace(ed: *Editor) !void {
    const r = ed.replace orelse return prompts.cancelSearch(ed);
    if (r.field == .find) {
        if (r.find.items().len > 0) r.field = .with;
        return;
    }
    // The matches for what is typed now.
    try changed(ed);
    r.wait();
    if (r.complaintOf()) |said| return ed.setMessage(.err, "can't search for that: {s}", .{said});
    if (r.counts().matches == 0) return ed.setMessage(.info, "nothing to replace", .{});
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.replace = null;
    defer r.destroy();

    const home = ed.buffer;
    const home_cursor = sp.origin;
    var replaced: usize = 0;
    var files: usize = 0;
    var stale: usize = 0;
    const rows = r.matches();
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
            for (rows[i..j]) |m| stale += if (m.skip) 0 else m.subs.len;
            continue;
        };
        const t = ed.text();
        var did = false;
        // Bottom up, right to left: earlier positions stay valid.
        var k = j;
        while (k > i) {
            k -= 1;
            const m = rows[k];
            if (m.skip) continue;
            if (m.line >= t.lineCount()) {
                stale += m.subs.len;
                continue;
            }
            const ls = t.lineStart(m.line);
            var c = m.subs.len;
            while (c > 0) {
                c -= 1;
                const s = m.subs[c];
                if (!Replace.stillThere(m, s, t.slice(ls, t.lineEnd(m.line)))) {
                    stale += 1;
                    continue;
                }
                try ed.deleteRangeKeepCursor(ls + s.start, ls + s.end);
                try ed.insertAt(ls + s.start, s.with);
                replaced += 1;
                did = true;
            }
        }
        if (did) {
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
