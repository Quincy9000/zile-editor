//! Vim keys on the picker's query (its normal mode, after <Esc>).

const std = @import("std");
const keys = @import("../input/keys.zig");
const KeyEvent = keys.KeyEvent;
const commands = @import("../commands.zig");
const Picker = @import("../picker/Picker.zig");
const LineInput = @import("../input/LineInput.zig");
const sources = @import("../picker/sources.zig");
const picker_ops = @import("picker_ops.zig");
const Editor = @import("../Editor.zig");
const prompts = @import("prompts.zig");
const opensPlaces = Editor.opensPlaces;
const Options = Editor.Options;
const OpenTarget = Editor.OpenTarget;

pub fn pickerQueryKey(ed: *Editor, ev: KeyEvent) !bool {
    const p = ed.picker orelse return false;
    if (ed.pending_len != 0) return false;
    const pending = ed.query_op != null;
    if (ev.mods.blocksText() or ev.key != .codepoint) {
        // <Esc> cancels a waiting operator (else it closes the picker).
        if (pending and ev.key == .special and ev.key.special == .escape) {
            ed.query_op = null;
            ed.query_obj = null;
            return true;
        }
        return false;
    }
    const cp = ev.key.codepoint;
    const q = &p.query;
    const len = q.items().len;

    if (ed.query_op) |op| {
        if (ed.query_obj) |obj| {
            ed.query_op = null;
            ed.query_obj = null;
            if (cp != 'w' and cp != 'W') return true;
            const r = q.wordObject(q.cursor, obj == 'a', cp == 'W');
            try queryApply(ed, op, r[0], r[1]);
            return true;
        }
        if (cp == 'i' or cp == 'a') {
            ed.query_obj = @intCast(cp);
            return true;
        }
        ed.query_op = null;
        if (cp == op) {
            try queryApply(ed, op, 0, len);
            return true;
        }
        const r = queryMotionRange(q, cp, op) orelse return true;
        try queryApply(ed, op, r[0], r[1]);
        return true;
    }

    // A menu row's key runs that row; a picker action's letter runs it.
    if (std.math.cast(u8, cp)) |b| {
        if (std.mem.indexOfScalar(u8, sources.rowKeys(p.kind), b)) |id| {
            try pickerRunRow(ed, p, @intCast(id));
            return true;
        }
        for (sources.itemActions(p.kind)) |*a| if (a.key == b) {
            try runPickerAction(ed, p, a);
            return true;
        };
    }
    const own = switch (p.kind) {
        .browse, .buffers, .runner, .quickfix => true,
        else => false,
    };
    if (own and std.mem.indexOfScalar(u8, "hlxdpyonrm", std.math.cast(u8, cp) orelse 0) != null) return false;
    const last = q.lastChar();
    switch (cp) {
        'h' => q.cursor = q.prev(q.cursor),
        'l' => q.cursor = @min(q.next(q.cursor), last),
        'w', 'W' => q.cursor = @min(q.wordForward(q.cursor, cp == 'W'), last),
        'b', 'B' => q.cursor = q.wordBackward(q.cursor, cp == 'B'),
        'e', 'E' => q.cursor = q.wordEnd(q.cursor, cp == 'E'),
        '0', '^' => q.cursor = 0,
        '$' => q.cursor = last,
        'x' => try queryApply(ed, 'd', q.cursor, q.next(q.cursor)),
        'X' => try queryApply(ed, 'd', q.prev(q.cursor), q.cursor),
        'D' => try queryApply(ed, 'd', q.cursor, len),
        'C' => try queryApply(ed, 'c', q.cursor, len),
        's' => try queryApply(ed, 'c', q.cursor, q.next(q.cursor)),
        'S' => try queryApply(ed, 'c', 0, len),
        'd', 'c', 'y' => ed.query_op = @intCast(cp),
        'p', 'P' => {
            const v = ed.registers.get(null) orelse return true;
            const yanked = std.mem.trimEnd(u8, std.mem.sliceTo(v.text, '\n'), "\r");
            if (yanked.len == 0) return true;
            try querySnapshot(ed);
            q.cursor = if (cp == 'p' and len > 0) q.next(q.cursor) else q.cursor;
            try q.insertSlice(ed.gpa, yanked);
            q.cursor = q.prev(q.cursor);
            try prompts.inputChanged(ed);
        },
        'u' => {
            const u = ed.query_undo.pop() orelse return true;
            defer ed.gpa.free(u.text);
            try q.set(ed.gpa, u.text);
            q.cursor = @min(u.cursor, q.lastChar());
            try prompts.inputChanged(ed);
        },
        'i' => ed.mode = .picker,
        'a' => {
            q.cursor = q.next(q.cursor);
            ed.mode = .picker;
        },
        'I' => {
            q.cursor = 0;
            ed.mode = .picker;
        },
        'A' => {
            q.cursor = len;
            ed.mode = .picker;
        },
        else => return false,
    }
    return true;
}

/// The bytes `op` + motion `cp` covers, from the query's cursor.
pub fn queryMotionRange(q: *const LineInput, cp: u21, op: u8) ?[2]usize {
    const c = q.cursor;
    const len = q.items().len;
    return switch (cp) {
        // `cw` on a word changes to its end, like vim.
        'w', 'W' => if (op == 'c' and c < len and q.items()[c] != ' ') .{ c, q.next(q.wordEnd(c, cp == 'W')) } else .{ c, q.wordForward(c, cp == 'W') },
        'b', 'B' => .{ q.wordBackward(c, cp == 'B'), c },
        'e', 'E' => .{ c, q.next(q.wordEnd(c, cp == 'E')) },
        'h' => .{ q.prev(c), c },
        'l', ' ' => .{ c, q.next(c) },
        '0', '^' => .{ 0, c },
        '$' => .{ c, len },
        else => null,
    };
}

/// `C-t`: the picker's next scope (Files: project, open, recent, disk...),
/// with the same query and mode. A scope that can't open now (no run yet)
/// is passed over.
pub fn pickerNextScope(ed: *Editor) !void {
    const p = ed.picker orelse return;
    const group = sources.scopeGroup(p.kind) orelse return;
    var at: usize = 0;
    for (group, 0..) |sc, i| if (sc.kind == p.kind) {
        at = i;
    };
    const query = try ed.gpa.dupe(u8, p.activeQuery());
    defer ed.gpa.free(query);
    const mode = ed.mode;
    for (1..group.len) |step| {
        const next = group[(at + step) % group.len];
        closePicker(ed);
        const cmd = commands.find(next.command) orelse continue;
        ed.runCommand(cmd) catch {};
        const np = ed.picker orelse continue;
        if (np.kind != next.kind) continue;
        try np.query.set(ed.gpa, query);
        ed.mode = mode;
        try prompts.inputChanged(ed);
        return;
    }
}

/// The <Tab> menu: the keys shown beside its rows run them, as they do in
/// the picker it came from (a letter in normal mode, Ctrl + one in either;
/// Ctrl-v / Ctrl-s open the row in a split).
pub fn openInKey(ed: *Editor, ev: KeyEvent) !bool {
    const p = ed.picker orelse return false;
    if (p.kind != .open_in or ev.key != .codepoint or ev.mods.alt or ed.pending_len != 0) return false;
    if (!ev.mods.ctrl and (ed.mode != .picker_normal or ev.mods.blocksText())) return false;
    const origin = ed.action_origin orelse return false;
    const b = std.math.cast(u8, ev.key.codepoint) orelse return false;
    // Its own keys (the bar shows them) win over an action's letter.
    if (!ev.mods.ctrl and std.mem.indexOfScalar(u8, sources.open_in_keys, b) != null) return false;
    const has_row = if (ed.pending_choice) |c| c != .none else false;
    for (sources.itemActions(origin), 0..) |a, i| {
        if (!has_row and !a.any) continue;
        if ((if (ev.mods.ctrl) a.ctrl else a.key) != b) continue;
        closePicker(ed);
        try picker_ops.runPendingAction(ed, i);
        return true;
    }
    if (!ev.mods.ctrl or !has_row or !opensPlaces(origin)) return false;
    const target: OpenTarget = switch (b) {
        'v' => .right,
        's' => .below,
        else => return false,
    };
    closePicker(ed);
    try picker_ops.openPendingIn(ed, target);
    return true;
}

/// Ctrl + an action's letter, typing or not.
pub fn pickerCtrlAction(ed: *Editor, ev: KeyEvent) !bool {
    const p = ed.picker orelse return false;
    if (!ev.mods.ctrl or ev.mods.alt or ev.key != .codepoint or ed.pending_len != 0) return false;
    const b = std.math.cast(u8, ev.key.codepoint) orelse return false;
    for (sources.itemActions(p.kind)) |*a| if (a.ctrl == b) {
        try runPickerAction(ed, p, a);
        return true;
    };
    return false;
}

/// Runs `a` on the picker's selected row (a copy: the picker may close).
pub fn runPickerAction(ed: *Editor, p: *Picker, a: *const sources.Action) !void {
    p.sync();
    const live = p.itemAt(p.selected);
    if (live == null and !a.any) return;
    var row_text: ?[]u8 = null;
    var row_detail: ?[]u8 = null;
    defer if (row_text) |x| ed.gpa.free(x);
    defer if (row_detail) |x| ed.gpa.free(x);
    var item: ?Picker.ItemsStore.Item = null;
    if (live) |it| {
        row_text = try ed.gpa.dupe(u8, it.text);
        row_detail = try ed.gpa.dupe(u8, it.detail);
        item = .{ .text = row_text.?, .detail = row_detail.?, .id = it.id };
    }
    if (a.stay) {
        try a.run(ed, item);
        if (ed.picker == p and !a.keep_rows) try p.refill();
        return;
    }
    closePicker(ed);
    try a.run(ed, item);
}

/// A menu row's key: that row, as if picked.
pub fn pickerRunRow(ed: *Editor, p: *Picker, id: u32) !void {
    p.sync();
    for (p.snap.slice(), 0..) |r, row| {
        if (p.shown.items.get(r.index).id != id) continue;
        p.selected = row;
        return picker_ops.acceptPicker(ed);
    }
}

/// Remembers the query for `u` (the last 50 changes).
pub fn querySnapshot(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (ed.query_undo.items.len >= 50) ed.gpa.free(ed.query_undo.orderedRemove(0).text);
    try ed.query_undo.append(ed.gpa, .{ .text = try ed.gpa.dupe(u8, p.query.items()), .cursor = p.query.cursor });
}

/// `d` / `c` / `y` on query bytes `[start, end)`.
pub fn queryApply(ed: *Editor, op: u8, start: usize, end: usize) !void {
    const p = ed.picker orelse return;
    const q = &p.query;
    if (op == 'y') {
        try ed.registers.store(null, .yank, q.items()[start..@min(end, q.items().len)], false);
        q.cursor = start;
        return;
    }
    if (start >= end and op == 'd') return;
    try querySnapshot(ed);
    q.delete(start, end);
    q.cursor = start;
    if (op == 'c') {
        ed.mode = .picker;
    } else q.cursor = @min(q.cursor, q.lastChar());
    try prompts.inputChanged(ed);
}

/// A menu row from a picker opened in visual mode: the selection is back
/// for it (the view kept its anchor and cursor meanwhile).
pub fn restorePickerVisual(ed: *Editor) void {
    const v = ed.picker_visual orelse return;
    ed.picker_visual = null;
    ed.mode = .visual;
    ed.visual_line = v.line;
}

/// Whether boolean option `name` is on (null: there is no such option).
pub fn optionState(ed: *const Editor, name: []const u8) ?bool {
    const info = @typeInfo(Options).@"struct";
    inline for (info.field_names, info.field_types) |field_name, T| {
        if (T == bool and std.mem.eql(u8, field_name, name)) return @field(ed.options, field_name);
    }
    return null;
}

pub fn closePicker(ed: *Editor) void {
    const p = ed.picker orelse return;
    // Closing without picking cancels a split waiting for a file.
    ed.deferred_target = null;
    // `SPC '` resumes a picker you searched in, not a menu on the way to it.
    if (sources.rowKeys(p.base).len == 0 and p.base != .open_in) {
        ed.resume_kind = p.base;
        ed.resume_query.clearRetainingCapacity();
        ed.resume_query.appendSlice(ed.gpa, p.query.items()) catch {};
    }
    // Moving through the themes previews them; only Enter keeps one.
    if (p.base == .themes) ed.theme_index = ed.theme_before;
    p.destroy();
    ed.picker = null;
    ed.mode = .normal;
}
