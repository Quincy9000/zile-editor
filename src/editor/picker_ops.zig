//! What a picker's rows do: accepting one, its action menu, opening it somewhere.

const std = @import("std");
const Picker = @import("../picker/Picker.zig");
const sources = @import("../picker/sources.zig");
const window_ops = @import("window_ops.zig");
const jumplist = @import("jumplist.zig");
const Editor = @import("../Editor.zig");
const picker_query = @import("picker_query.zig");
const row_model = @import("row_model.zig");
const OpenTarget = Editor.OpenTarget;

/// `x` / `dd` in the buffer picker: closes the selected buffer, staying in
/// the list.
pub fn pickerKillBuffer(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .buffers) return;
    p.sync();
    const item = p.itemAt(p.selected) orelse return;
    if (item.id >= ed.buffers.items.len) return;
    const b = ed.buffers.items[item.id];
    if (b.modified) return ed.setMessage(.err, "\"{s}\" has unsaved changes: save it first", .{b.displayName()});
    try ed.killBuffer(b);
    try p.restart(null);
    ed.mode = .picker_normal;
}

/// Accepts the selected row: closes the picker, then acts on the choice
/// (which may open another picker).
pub fn acceptPicker(ed: *Editor) !void {
    return acceptPickerAs(ed, .here);
}

/// Ctrl-Enter: the picker's other way to accept, if it has one (the
/// runner: run the command under the debugger).
pub fn acceptPickerAlt(ed: *Editor) !void {
    const p = ed.picker orelse return;
    const alt = sources.altAccept(p.kind) orelse return acceptPicker(ed);
    const choice = try p.choice();
    defer choice.deinit(ed.gpa);
    const row: []const u8 = switch (choice) {
        .none => return,
        .item => |c| c.item.text,
        .create => |c| c.query,
    };
    picker_query.closePicker(ed);
    try alt.run(ed, row);
}

/// Accepts the selection, opening it in `target` (<C-v>: a split to the
/// right, <C-s>: below).
pub fn acceptPickerAs(ed: *Editor, target: OpenTarget) !void {
    const p = ed.picker orelse return;
    const choice = try p.choice();
    defer choice.deinit(ed.gpa);
    // The toggles: flip the row, list them again with the new states.
    if (sources.staysOpen(p.kind)) {
        switch (choice) {
            .item => |c| try sources.accept(c.kind, ed, c.item),
            else => {},
        }
        if (ed.picker == p) try p.refill();
        return;
    }
    const deferred = ed.deferred_target;
    ed.deferred_target = null;
    picker_query.closePicker(ed);
    try runChoice(ed, choice, if (target == .here) deferred orelse .here else target);
}

/// Sources whose choices open something somewhere (files, places).
pub fn opensPlaces(kind: Picker.Kind) bool {
    return switch (kind) {
        .files, .buffers, .lines, .grep, .locations, .diagnostics, .symbols, .git_changes, .browse, .jumps, .run_errors, .projects, .recent, .frecent, .todos, .quickfix, .files_anywhere, .workspace_symbols, .marks => true,
        else => false,
    };
}

/// <Tab> in a picker: asks where to open the selection.
pub fn pickerOpenMenu(ed: *Editor) !void {
    const p = ed.picker orelse return;
    const has_actions = sources.itemActions(p.kind).len > 0;
    if (!opensPlaces(p.kind) and !has_actions) return;
    const choice = try p.choice();
    if (choice == .none and !has_actions) return;
    if (ed.pending_choice) |old| old.deinit(ed.gpa);
    ed.pending_choice = choice;
    ed.action_origin = p.kind;
    ed.action_query.clearRetainingCapacity();
    try ed.action_query.appendSlice(ed.gpa, p.query.items());
    picker_query.closePicker(ed);
    try ed.openPicker(.open_in, "");
}

/// The <Tab> menu ran action `i` of the picker it came from, on the row
/// waiting in `pending_choice`; one that keeps that picker open brings it
/// back.
pub fn runPendingAction(ed: *Editor, i: usize) !void {
    const origin = ed.action_origin orelse return;
    const list = sources.itemActions(origin);
    if (i >= list.len) return;
    const a = &list[i];
    const choice = ed.pending_choice orelse Picker.Choice.none;
    ed.pending_choice = null;
    defer choice.deinit(ed.gpa);
    const item: ?Picker.ItemsStore.Item = switch (choice) {
        .item => |c| c.item,
        else => null,
    };
    if (item == null and !a.any) return;
    if (a.stay) {
        // Its rows are needed (a buffer's index): reopen it, then act.
        const query = try ed.gpa.dupe(u8, ed.action_query.items);
        defer ed.gpa.free(query);
        try a.run(ed, item);
        try ed.openPicker(origin, query);
        if (ed.picker) |np| np.selected = 0;
        if (!sources.startsNormal(origin)) ed.mode = .picker_normal;
        return;
    }
    try a.run(ed, item);
}

/// The "Open in..." menu picked `target` for the waiting choice.
pub fn openPendingIn(ed: *Editor, target: OpenTarget) !void {
    const choice = ed.pending_choice orelse return;
    ed.pending_choice = null;
    defer choice.deinit(ed.gpa);
    try runChoice(ed, choice, target);
}

pub fn runChoice(ed: *Editor, choice: Picker.Choice, target_in: OpenTarget) anyerror!void {
    const kind: ?Picker.Kind = switch (choice) {
        .none => null,
        .item => |c| c.kind,
        .create => |c| c.kind,
    };
    var target = target_in;
    if (kind) |k| {
        if (!opensPlaces(k)) target = .here;
        // A project opens into a split once a file is picked in it.
        if (k == .projects and target != .here) {
            ed.deferred_target = target;
            target = .here;
        }
        // Entering a folder in the explorer isn't opening anything yet.
        if (k == .browse and choice == .item and std.mem.endsWith(u8, choice.item.item.text, "/")) {
            if (target != .here) ed.deferred_target = target;
            target = .here;
        }
    }
    // Pickers that take you somewhere are jumps.
    if (kind) |k| switch (k) {
        .files, .buffers, .lines, .grep, .locations, .diagnostics, .symbols, .git_changes, .recent, .frecent, .todos => jumplist.pushJump(ed),
        else => {},
    };
    if (target.dir()) |d| try window_ops.splitWindow(ed, d);
    switch (choice) {
        .none => {},
        .item => |c| try @import("../picker/sources.zig").accept(c.kind, ed, c.item),
        .create => |c| try @import("../picker/sources.zig").create(c.kind, ed, c.query),
    }
    // A picker that took you to a line shows it in the middle of the window,
    // with its surroundings (pickers that open a file leave its view as it was).
    if (choice == .item) switch (choice.item.kind) {
        .lines, .grep, .todos, .locations, .diagnostics, .symbols, .workspace_symbols, .jumps, .marks, .quickfix, .run_errors => centerCursor(ed),
        else => {},
    };
}

/// Scrolls so the cursor's row is in the middle of the window (`zz`).
pub fn centerCursor(ed: *Editor) void {
    row_model.setTop(ed, row_model.stepRows(ed, row_model.cursorRow(ed), -@as(isize, @intCast(ed.view.rows / 2))));
}
