//! SQL buffers: completion from the schema, running queries, the result grid.

const std = @import("std");
const motions = @import("../core/motions.zig");
const keys = @import("../input/keys.zig");
const KeyEvent = keys.KeyEvent;
const ResultGrid = @import("../ResultGrid.zig");
const sql = @import("../sql.zig");
const inlay = @import("inlay.zig");
const completion_ops = @import("completion_ops.zig");
const after_typing = @import("after_typing.zig");
const Editor = @import("../Editor.zig");

pub fn isSql(ed: *const Editor) bool {
    const syn = ed.buffer.syntax orelse return false;
    return std.mem.eql(u8, syn.lang.name, "sql");
}

/// SQL completion, built here: keywords, the database's tables and columns
/// (after `name.` that table's columns), and the file's words.
pub fn sqlCompletion(ed: *Editor, start: usize) void {
    const t = ed.text();
    const tables: []const sql.Table = if (ed.sql_schema) |sc| (if (sc.done.load(.acquire)) sc.tables else &.{}) else &.{};
    const json = sql.completionJson(ed.gpa, tables, t.slice(0, t.len()), start) catch return;
    defer ed.gpa.free(json);
    var parsed = std.json.parseFromSlice(std.json.Value, ed.gpa, json, .{}) catch return;
    defer parsed.deinit();
    completion_ops.showCompletion(ed, ed.buffer, start, parsed.value) catch {};
}

/// A statement's results arrived: its rows in the results picker; an error
/// in a box at the cursor (it points into the statement there).
pub fn tickSqlResults(ed: *Editor) void {
    const r = ed.sql_results orelse return;
    if (ed.sql_results_seen or !r.done.load(.acquire)) return;
    ed.sql_results_seen = true;
    // Tables may have changed: completion reloads them.
    for ([_][]const u8{ "create", "alter", "drop", "rename" }) |w| {
        if (motions.indexOfFold(r.statement, 0, w) != null) {
            ed.sql_fresh = false;
            ed.sql_checked = null;
        }
    }
    if (r.failed) {
        if (ed.hover) |h| ed.gpa.free(h);
        ed.hover = ed.gpa.dupe(u8, r.err) catch null;
        return ed.setMessage(.err, "{s}", .{std.mem.sliceTo(r.err, '\n')});
    }
    if (r.columns.len == 0) return ed.setMessage(.info, "ran: no rows came back", .{});
    if (r.rows.len == 0) return ed.setMessage(.info, "0 rows", .{});
    // Not over what you're in the middle of (typing, another picker).
    if (ed.mode != .normal or ed.picker != null or ed.popup != null)
        return ed.setMessage(.info, "{d} row{s}: \"SQL results\" in the command picker shows them", .{ r.rows.len, if (r.rows.len == 1) "" else "s" });
    openGrid(ed) catch {};
}

pub fn openGrid(ed: *Editor) !void {
    const r = ed.sql_results orelse return;
    closeGrid(ed);
    ed.grid = try ResultGrid.init(ed.gpa, r.columns, r.rows);
    ed.setMessage(.info, "{d} row{s}, {d} column{s}", .{ r.rows.len, if (r.rows.len == 1) "" else "s", r.columns.len, if (r.columns.len == 1) "" else "s" });
}

pub fn closeGrid(ed: *Editor) void {
    if (ed.grid) |*g| g.deinit();
    ed.grid = null;
}

/// Keys while the results grid is open: all of them are its.
pub fn gridKey(ed: *Editor, ev: KeyEvent) bool {
    const g = &(ed.grid orelse return false);
    const out = g.key(ev) catch return true;
    switch (out) {
        .stay => {},
        .close => closeGrid(ed),
        .not_found => ed.setMessage(.info, "not found: {s}", .{g.search.items}),
        .yank => |y| {
            defer ed.gpa.free(y.text);
            ed.registers.store(null, .yank, y.text, false) catch {};
            if (y.n == 1 and std.mem.eql(u8, y.what, "the cell")) {
                const name = if (g.col < g.columns.len) g.columns[g.col] else "the cell";
                ed.setMessage(.info, "yanked {s}", .{name});
            } else ed.setMessage(.info, "yanked {d} {s} (tabs between)", .{ y.n, y.what });
        },
        .table => {
            closeGrid(ed);
            inlay.openSqlTable(ed) catch {};
        },
    }
    return true;
}

/// The command picker's "SQL results": the last statement's rows again.
pub fn showSqlResults(ed: *Editor) !void {
    const r = ed.sql_results orelse return ed.setMessage(.info, "no SQL has run yet (Ctrl-Enter in a SQL file)", .{});
    if (!r.done.load(.acquire)) return ed.setMessage(.info, "the statement is still running", .{});
    if (r.failed) return ed.setMessage(.err, "{s}", .{std.mem.sliceTo(r.err, '\n')});
    if (r.rows.len == 0) return ed.setMessage(.info, "it returned no rows", .{});
    try openGrid(ed);
}

/// The schema for SQL completion: loaded (in the background) when a SQL
/// file is first shown, from the database it would run on; again after a
/// statement that changes tables has run.
pub fn tickSqlSchema(ed: *Editor) void {
    if (ed.sql_reload and ed.run_reported) {
        ed.sql_reload = false;
        ed.sql_checked = null;
    }
    if (!isSql(ed) or ed.sql_checked == ed.buffer) return;
    // A load still running finishes first.
    if (ed.sql_schema) |sc| if (!sc.done.load(.acquire)) return;
    ed.sql_checked = ed.buffer;
    const folder = after_typing.fileFolder(ed) catch return;
    defer ed.gpa.free(folder);
    const found = sql.findUrl(ed.gpa, ed.io, folder, ed.cwd) orelse return;
    defer ed.gpa.free(found.url);
    defer ed.gpa.free(found.from);
    if (ed.sql_schema) |sc| {
        if (std.mem.eql(u8, sc.url, found.url) and !sc.failed and ed.sql_fresh) return;
        sc.destroy(ed.gpa);
        ed.sql_schema = null;
    }
    ed.sql_schema = sql.Schema.load(ed.gpa, ed.io, found.url, ed.wake_fn) catch null;
    ed.sql_fresh = true;
}
