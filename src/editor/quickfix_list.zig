//! Quickfix: one list of places, filled by runs and pickers, stepped through.

const std = @import("std");
const Io = std.Io;
const sources = @import("../picker/sources.zig");
const debugging = @import("../debugging.zig");
const picker_query = @import("picker_query.zig");
const Editor = @import("../Editor.zig");
const run_popup = @import("run_popup.zig");

pub fn clearQuickfix(ed: *Editor) void {
    for (ed.quickfix.items) |q| q.deinit(ed.gpa);
    ed.quickfix.clearRetainingCapacity();
    ed.quickfix_title.clearRetainingCapacity();
    ed.quickfix_index = null;
    ed.quickfix_origin = .none;
}

/// Without a list of your own, the list is the project's errors and
/// warnings as the language servers report them now: the current file's
/// first (in line order), then the other files'.
pub fn refreshLiveQuickfix(ed: *Editor) void {
    if (ed.quickfix_origin == .run or ed.quickfix_origin == .picked) return;
    newQuickfix(ed, "Errors") catch return;
    ed.quickfix_origin = .live;
    const current: []const u8 = ed.buffer.path orelse "";
    for ([_]bool{ true, false }) |own_file| {
        if (ed.live_errors_override) |items| {
            for (items) |q| if (std.mem.eql(u8, q.path, current) == own_file) {
                addQuickfix(ed, q.path, q.line, q.col, q.text) catch return;
            };
            continue;
        }
        for (ed.lsps.items) |l| for (l.diagnostics.keys(), l.diagnostics.values()) |path, list| {
            if (std.mem.eql(u8, path, current) != own_file) continue;
            for (list) |d| {
                if (d.severity != .err and d.severity != .warning) continue;
                addQuickfix(ed, path, d.line, d.col, std.mem.sliceTo(d.message, '\n')) catch return;
            }
        };
    }
}

/// `]q` / `[q` through live errors go by where the cursor is, not by a
/// remembered place in a list that changes as you fix things: the next
/// error below the cursor in this file, then on into the other files (and
/// around); the previous one above the cursor, else the last of all.
pub fn liveQuickfixTarget(ed: *Editor, forward: bool) usize {
    const items = ed.quickfix.items;
    const current: []const u8 = ed.buffer.path orelse "";
    const line = ed.cursorLine();
    if (forward) {
        for (items, 0..) |q, i| {
            if (!std.mem.eql(u8, q.path, current) or q.line > line) return i;
        }
        return 0;
    }
    var target: usize = items.len - 1;
    for (items, 0..) |q, i| {
        if (!std.mem.eql(u8, q.path, current) or q.line >= line) break;
        target = i;
    }
    return target;
}

/// `x in the quickfix picker`: drops a run's or picker's list, so the list is the
/// project's errors again.
pub fn resetQuickfix(ed: *Editor) void {
    clearQuickfix(ed);
    ed.setMessage(.info, "quickfix cleared: it lists the project's errors again", .{});
}

/// Starts a new list named `title` (add entries with `addQuickfix`).
pub fn newQuickfix(ed: *Editor, title: []const u8) !void {
    clearQuickfix(ed);
    ed.quickfix_origin = .picked;
    try ed.quickfix_title.appendSlice(ed.gpa, title);
}

/// Adds a place; `path` and `text` are copied.
pub fn addQuickfix(ed: *Editor, path: []const u8, line: usize, col: usize, message: []const u8) !void {
    const p = try ed.normalizePath(path);
    errdefer ed.gpa.free(p);
    const t = try ed.gpa.dupe(u8, std.mem.trim(u8, message, " \t"));
    errdefer ed.gpa.free(t);
    try ed.quickfix.append(ed.gpa, .{ .path = p, .line = line, .col = col, .text = t });
}

pub fn quickfixFromRunErrors(ed: *Editor) void {
    newQuickfix(ed, ed.run_command orelse "run") catch return;
    ed.quickfix_origin = .run;
    for (ed.run_errors.items) |e| addQuickfix(ed, e.path, e.line - 1, e.col - 1, e.message) catch return;
}

/// Goes to quickfix entry `i` (a jump, unless moving within the panel).
pub fn goQuickfix(ed: *Editor, i: usize) !void {
    if (i >= ed.quickfix.items.len) return;
    const q = ed.quickfix.items[i];
    ed.quickfix_index = i;
    try ed.jumpTo(q.path, q.line, q.col);
    ed.setMessage(.info, "({d}/{d}) {s}", .{ i + 1, ed.quickfix.items.len, q.text });
}

/// `]q` / `[q`: the next / previous entry (`count` of them).
pub fn stepQuickfix(ed: *Editor, forward: bool, count: usize) !void {
    refreshLiveQuickfix(ed);
    const n = ed.quickfix.items.len;
    if (n == 0) return ed.setMessage(.info, "no errors in the project (a run's errors, or Ctrl-q in a picker, also fill the quickfix list)", .{});
    if (ed.quickfix_origin == .live) {
        const first = liveQuickfixTarget(ed, forward);
        const extra = count - 1;
        return goQuickfix(ed, if (forward) @min(first + extra, n - 1) else first -| extra);
    }
    const i: usize = if (ed.quickfix_index) |cur| blk: {
        if (forward) {
            if (cur + 1 >= n) return ed.setMessage(.info, "last quickfix entry ({d}/{d})", .{ n, n });
            break :blk @min(cur + count, n - 1);
        }
        if (cur == 0) return ed.setMessage(.info, "first quickfix entry (1/{d})", .{n});
        break :blk cur -| count;
    } else if (forward) @min(count - 1, n - 1) else n - 1;
    try goQuickfix(ed, i);
}

/// `SPC f q`: the quickfix list as a picker (every entry with its file and
/// line number, previewed), in normal mode at the current entry. Nothing
/// moves until one is picked.
pub fn showQuickfix(ed: *Editor) !void {
    refreshLiveQuickfix(ed);
    if (ed.quickfix.items.len == 0) return ed.setMessage(.info, "no errors in the project (a run's errors, or Ctrl-q in a picker, also fill the quickfix list)", .{});
    // Live errors: start on the one at or after the cursor.
    const start = if (ed.quickfix_origin == .live) blk: {
        const next = liveQuickfixTarget(ed, true);
        const here = if (next > 0) next - 1 else 0;
        const q = ed.quickfix.items[here];
        const on_it = std.mem.eql(u8, q.path, ed.buffer.path orelse "") and q.line == ed.cursorLine();
        break :blk if (on_it) here else next;
    } else ed.quickfix_index orelse 0;
    picker_query.closePicker(ed);
    ed.popup = null;
    try ed.openPicker(.quickfix, "");
    ed.picker.?.want_id = @intCast(start);
}

/// `<C-q>` in a picker of places: every current match becomes the list.
pub fn pickerToQuickfix(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (!sources.hasLocations(p.kind)) return ed.setMessage(.info, "these results aren't places", .{});
    p.sync();
    var title_buf: [128]u8 = undefined;
    const q = p.activeQuery();
    const title = if (q.len > 0) std.fmt.bufPrint(&title_buf, "{s}: {s}", .{ sources.title(p.kind), q }) catch sources.title(p.kind) else sources.title(p.kind);
    try newQuickfix(ed, title);
    var row: usize = 0;
    while (row < p.snap.len) : (row += 1) {
        const item = p.itemAt(row) orelse continue;
        const loc = (try sources.location(p.kind, ed, item.*)) orelse continue;
        defer ed.gpa.free(loc.path);
        try addQuickfix(ed, loc.path, loc.line, loc.col, item.text);
    }
    const n = ed.quickfix.items.len;
    picker_query.closePicker(ed);
    if (n == 0) return ed.setMessage(.info, "no places to add", .{});
    try showQuickfix(ed);
}

/// `SPC r e` (or `e` in a finished run): the last run's errors in the
/// quickfix panel.
pub fn showRunErrors(ed: *Editor) !void {
    if (ed.run == null) return ed.setMessage(.info, "nothing has been run yet (SPC r r)", .{});
    if (ed.run_errors.items.len == 0) return ed.setMessage(.info, "no errors in the last run", .{});
    quickfixFromRunErrors(ed);
    try showQuickfix(ed);
}

/// Seconds since the run started (or how long it took, once reported).
pub fn runSeconds(ed: *Editor) f64 {
    const ns = ed.run_started.durationTo(Io.Timestamp.now(ed.io, .awake)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

/// Notices finished programs: a run prints how it ended; an exited shell
/// closes its popup.
pub fn pollTerminals(ed: *Editor) void {
    if (ed.run) |t| if (!ed.run_reported and !t.isRunning()) {
        ed.run_reported = true;
        const secs = runSeconds(ed);
        run_popup.collectRunErrors(ed, t);
        const n = ed.run_errors.items.len;
        // A run without errors retires the last run's list: the quickfix
        // list is the project's live errors again.
        if (n > 0) quickfixFromRunErrors(ed) else if (ed.quickfix_origin == .run) clearQuickfix(ed);
        var buf: [160]u8 = undefined;
        const ok = t.exit_code == 0;
        var errs_buf: [48]u8 = undefined;
        const errs: []const u8 = if (n > 0) std.fmt.bufPrint(&errs_buf, "   e: {d} error{s}", .{ n, if (n == 1) "" else "s" }) catch "" else "";
        const line = std.fmt.bufPrint(&buf, "\r\n\x1b[1;{s}m{s} exited {d}\x1b[0;2m in {d:.2}s{s}   r: run again   y: yank errors   q: close\x1b[0m", .{
            if (ok) "32" else "31", if (ok) "✓" else "✗", t.exit_code, secs, errs,
        }) catch "";
        t.print(line);
        if (n > 0) {
            ed.setMessage(if (ok) .info else .err, "{s}: exited {d} in {d:.2}s, {d} error{s} (SPC r e lists them)", .{ ed.run_command orelse "", t.exit_code, secs, n, if (n == 1) "" else "s" });
        } else {
            ed.setMessage(if (ok) .info else .err, "{s}: exited {d} in {d:.2}s (SPC r o shows the output)", .{ ed.run_command orelse "", t.exit_code, secs });
        }
        // A build for the debugger: the program starts once it's built.
        if (ed.dbg.plan) |pl| {
            ed.dbg.plan = null;
            defer pl.deinit(ed.gpa);
            if (ok) debugging.launch(ed, pl) catch |err| ed.setMessage(.err, "could not start gdb: {s}", .{@errorName(err)});
        }
    };
    if (ed.shell) |t| if (!t.isRunning()) {
        t.destroy();
        ed.shell = null;
        if (ed.popup == .shell) ed.popup = null;
    };
}
