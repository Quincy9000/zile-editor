//! State files, visits, sessions, themes: what is kept between runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const Lsp = @import("../lsp/Lsp.zig");
const StoredData = @import("../StoredData.zig");
const config = @import("../config/config.zig");
const ZigCheck = @import("../ZigCheck.zig");
const History = @import("../core/History.zig");
const Project = @import("../core/Project.zig");
const RunMemory = @import("../terminal/RunMemory.zig");
const Visits = @import("../Visits.zig");
const Session = @import("../Session.zig");
const Editor = @import("../Editor.zig");
const lsp_ops = @import("lsp_ops.zig");
const testing = std.testing;
const testEditor = @import("../tests/support.zig").testEditor;

/// `$XDG_STATE_HOME/zile/<name>` (or under `state_dir`). Caller frees. Null
/// when there is nowhere to keep state (and always in tests without a
/// `state_dir`, so they never touch the real one).
pub fn statePath(ed: *Editor, name: []const u8) ?[]u8 {
    if (ed.state_dir) |d| return std.fs.path.join(ed.gpa, &.{ d, name }) catch null;
    if (@import("builtin").is_test) return null;
    return RunMemory.statePath(ed.gpa, name);
}

pub fn unixNow(ed: *Editor) i64 {
    return Io.Timestamp.now(ed.io, .real).toSeconds();
}

/// The visit history, read from disk the first time.
pub fn loadedVisits(ed: *Editor) *Visits {
    if (!ed.visits.loaded) {
        ed.visits.loaded = true;
        if (statePath(ed, "visits")) |p| {
            defer ed.gpa.free(p);
            ed.visits.load(ed.gpa, ed.io, p);
        }
    }
    return &ed.visits;
}

pub fn freeDiagnosticList(gpa: Allocator, list: []Lsp.Diagnostic) void {
    for (list) |d| gpa.free(d.message);
    gpa.free(list);
}

/// Standalone Zig files (no build.zig): compile-checked when opened and
/// saved; finished checks become the file's diagnostics.
pub fn tickZigChecks(ed: *Editor) void {
    var i: usize = 0;
    while (i < ed.zig_checks.items.len) {
        const zc = ed.zig_checks.items[i];
        if (!zc.job.done.load(.acquire)) {
            i += 1;
            continue;
        }
        _ = ed.zig_checks.swapRemove(i);
        defer zc.job.destroy();
        if (!bufferAlive(ed, zc.buffer)) continue;
        const diags = zc.job.diagnostics.toOwnedSlice(ed.gpa) catch continue;
        Lsp.sortDiagnostics(diags);
        for (ed.check_results.items) |*r| if (r.buffer == zc.buffer) {
            freeDiagnosticList(ed.gpa, r.diags);
            r.diags = diags;
            r.libc = zc.job.needed_libc;
            break;
        } else ed.check_results.append(ed.gpa, .{ .buffer = zc.buffer, .diags = diags, .libc = zc.job.needed_libc }) catch freeDiagnosticList(ed.gpa, diags);
    }
    // Results of closed buffers go.
    var k: usize = 0;
    while (k < ed.check_results.items.len) {
        if (bufferAlive(ed, ed.check_results.items[k].buffer)) {
            k += 1;
        } else freeDiagnosticList(ed.gpa, ed.check_results.swapRemove(k).diags);
    }
    for (ed.buffers.items) |b| {
        if (b.checked == b.saves) continue;
        const path = b.path orelse continue;
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        const running = for (ed.zig_checks.items) |zc| {
            if (zc.buffer == b) break true;
        } else false;
        if (running) continue; // the next tick after it, for the newer save
        b.checked = b.saves;
        const abs = ed.absolutePath(path) catch continue;
        defer ed.gpa.free(abs);
        if (!ZigCheck.wanted(ed.io, abs)) continue;
        const libc = for (ed.check_results.items) |r| {
            if (r.buffer == b) break r.libc;
        } else false;
        // The file as it is on disk is what the compiler reads.
        const job = ZigCheck.start(ed.gpa, ed.io, abs, b.text.slice(0, b.text.len()), libc, ed.wake_fn) catch continue;
        ed.zig_checks.append(ed.gpa, .{ .buffer = b, .job = job }) catch job.destroy();
    }
}

/// Leaving `b` (for another buffer or window): it is saved if modified
/// (autosave) and its cursor position remembered.
pub fn leaveBuffer(ed: *Editor, b: *Buffer) void {
    rememberPosition(ed, b);
    autosave(ed, b);
}

/// zile lost focus: every modified file is saved.
pub fn focusLost(ed: *Editor) void {
    for (ed.buffers.items) |b| autosave(ed, b);
}

pub fn autosave(ed: *Editor, b: *Buffer) void {
    if (!ed.options.autosave or !b.modified or b.path == null or ed.replaying) return;
    // Claude's proposals are reviewed, not saved behind your back.
    if (ed.claude) |c| if (c.diffFor(b) != null) return;
    if (!bufferAlive(ed, b)) return;
    _ = b.save(ed.gpa, ed.io) catch return;
    if (lsp_ops.lspFor(ed, b)) |l| l.didSave(b);
}

pub fn bufferAlive(ed: *const Editor, b: *const Buffer) bool {
    return std.mem.indexOfScalar(*Buffer, ed.buffers.items, @constCast(b)) != null;
}

/// Notes where `b`'s cursor is (the reopen position).
pub fn rememberPosition(ed: *Editor, b: *Buffer) void {
    const path = b.path orelse return;
    const cursor = if (b == ed.buffer) ed.view.cursor else b.saved.cursor;
    const t = &b.text;
    const pos = @min(cursor, t.len());
    const line = t.lineOf(pos);
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    loadedVisits(ed).setPosition(abs, line, pos - t.lineStart(line));
}

/// A file just loaded: the cursor where it was left, and its undo history
/// from the last session (if the file is still as it was then).
pub fn restoreFileState(ed: *Editor, b: *Buffer) void {
    const path = b.path orelse return;
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    if (loadedVisits(ed).get(abs)) |e| {
        const t = &b.text;
        const line = @min(@as(usize, e.line), t.lineCount() - 1);
        const cursor = t.lineStart(line) + @min(@as(usize, e.col), t.lineLen(line));
        b.saved = .{ .cursor = cursor, .top = line -| 10 };
    }
    const undo_path = undoPath(ed, abs) orelse return;
    defer ed.gpa.free(undo_path);
    const data = Io.Dir.cwd().readFileAlloc(ed.io, undo_path, ed.gpa, .limited(64 << 20)) catch return;
    defer ed.gpa.free(data);
    const hash = std.hash.Wyhash.hash(0, b.text.slice(0, b.text.len()));
    const h = (History.deserialize(ed.gpa, data, hash) catch return) orelse return;
    b.history.deinit(ed.gpa);
    b.history = h;
}

/// `$XDG_STATE_HOME/zile/undo/<hash of the path>`. Caller frees.
pub fn undoPath(ed: *Editor, abs: []const u8) ?[]u8 {
    var name: [32]u8 = undefined;
    const n = std.fmt.bufPrint(&name, "undo/{x:0>16}", .{std.hash.Wyhash.hash(0, abs)}) catch return null;
    return statePath(ed, n);
}

/// Each frame: the undo history of every file saved since is written
/// out, so it survives closing the file.
pub fn keepUndoHistories(ed: *Editor) void {
    for (ed.buffers.items) |b| {
        if (b.saves == b.undo_kept) continue;
        const path = b.path orelse continue;
        const data = (b.history.serialize(ed.gpa, std.hash.Wyhash.hash(0, b.text.slice(0, b.text.len()))) catch continue) orelse continue;
        defer ed.gpa.free(data);
        b.undo_kept = b.saves;
        if (data.len > 32 << 20) continue;
        const abs = ed.absolutePath(path) catch continue;
        defer ed.gpa.free(abs);
        const undo_path = undoPath(ed, abs) orelse continue;
        defer ed.gpa.free(undo_path);
        if (std.fs.path.dirname(undo_path)) |d| Io.Dir.cwd().createDirPath(ed.io, d) catch continue;
        Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = undo_path, .data = data }) catch {};
    }
}

pub fn recordVisit(ed: *Editor, b: *const Buffer) void {
    const path = b.path orelse return;
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    const v = loadedVisits(ed);
    v.record(ed.gpa, abs, unixNow(ed)) catch return;
    if (v.unsaved >= 8) saveVisits(ed);
}

/// Where each open file's cursor is, for next time (on the way out, while
/// the buffers are still there).
pub fn rememberPositions(ed: *Editor) void {
    for (ed.buffers.items) |b| rememberPosition(ed, b);
}

/// Where a store is kept (`StoredData`). Caller frees.
pub fn storePath(ed: *Editor, store: StoredData.Store) ?[]u8 {
    if (store == .logs) {
        if (ed.state_dir) |d| return std.fs.path.join(ed.gpa, &.{ d, "logs" }) catch null;
        if (@import("builtin").is_test) return null;
        return config.dir(ed.gpa, .cache, "");
    }
    return statePath(ed, store.name());
}

/// The folders that grow a file per project or per file, kept to their
/// newest (at the start; `StoredData.prune`).
pub fn pruneStoredData(ed: *Editor) void {
    if (storePath(ed, .sessions)) |p| {
        defer ed.gpa.free(p);
        StoredData.prune(ed.gpa, ed.io, p, StoredData.max_sessions, std.math.maxInt(u64));
    }
    if (storePath(ed, .undo)) |p| {
        defer ed.gpa.free(p);
        StoredData.prune(ed.gpa, ed.io, p, StoredData.max_undo_files, StoredData.max_undo_bytes);
    }
}

/// The "Stored data" picker's `x`: removes what `store` keeps, on disk and
/// here (so leaving doesn't write it back).
pub fn clearStore(ed: *Editor, store: StoredData.Store) void {
    switch (store) {
        .visits => {
            for (ed.visits.entries.items) |e| ed.gpa.free(e.path);
            ed.visits.entries.clearRetainingCapacity();
            ed.visits.loaded = true;
            ed.visits.unsaved = 0;
        },
        .projects => if (ed.known_projects) |*k| {
            for (k.items) |r| ed.gpa.free(r);
            k.clearRetainingCapacity();
        },
        else => {},
    }
    const p = storePath(ed, store) orelse return;
    defer ed.gpa.free(p);
    if (store == .logs) {
        // The language servers' folder and gdb's log.
        const lsp = std.fs.path.join(ed.gpa, &.{ p, "lsp" }) catch return;
        defer ed.gpa.free(lsp);
        StoredData.clear(ed.io, lsp);
    }
    StoredData.clear(ed.io, p);
}

pub fn saveVisits(ed: *Editor) void {
    if (ed.visits.unsaved == 0) return;
    const p = statePath(ed, "visits") orelse return;
    defer ed.gpa.free(p);
    ed.visits.save(ed.gpa, ed.io, p, unixNow(ed));
}

test "stored data: clearing a store empties it on disk and here; the folders are pruned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var ed = try testEditor("");
    defer ed.deinit();
    ed.state_dir = dir;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "visits", .data = "3\t100\t0\t0\t/x/a.zig\n" });
    try tmp.dir.createDirPath(testing.io, "undo");
    for (0..5) |i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "undo/{d}", .{i}), .data = "x" });
    }
    _ = loadedVisits(&ed);
    try testing.expectEqual(1, ed.visits.entries.items.len);
    clearStore(&ed, .visits);
    try testing.expectEqual(0, ed.visits.entries.items.len);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "visits", .{}));
    try ed.openPicker(.stored_data, "");
    const p = ed.picker.?;
    p.sync();
    try testing.expectEqual(std.enums.values(StoredData.Store).len, p.rowCount());
    // `x` twice on the undo row: asked, then cleared.
    for (0..p.rowCount()) |row| if (std.mem.startsWith(u8, p.itemAt(row).?.text, "Undo")) {
        p.selected = row;
    };
    var undo_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const undo_dir = try std.fmt.bufPrint(&undo_buf, "{s}/undo", .{dir});
    try ed.feed("x");
    try testing.expectEqual(5, StoredData.usage(testing.io, undo_dir).files);
    try ed.feed("x");
    try testing.expectEqual(0, StoredData.usage(testing.io, undo_dir).files);
}

/// Saves the current project's session (`SPC p s`, and on the way out).
pub fn saveSession(ed: *Editor, report: bool) void {
    const n = Session.save(ed) catch |err| {
        if (report) ed.setMessage(.err, "could not save the session: {s}", .{@errorName(err)});
        return;
    };
    if (!report) return;
    if (n == 0) ed.setMessage(.info, "no files of this project are open: nothing to save", .{}) else ed.setMessage(.info, "session saved: {d} file(s)", .{n});
}

/// Restores `root`'s session. False when it has none.
pub fn restoreSession(ed: *Editor, root: []const u8) bool {
    const n = Session.restore(ed, root) catch 0;
    if (n == 0) return false;
    ed.setMessage(.info, "session restored: {d} file(s)", .{n});
    return true;
}

pub fn hasBuffersIn(ed: *const Editor, p: *const Project) bool {
    for (ed.buffers.items) |b| if (b.project == p) return true;
    return false;
}

/// Picks colour scheme `i` and remembers it for the next start.
pub fn setTheme(ed: *Editor, i: usize) void {
    if (i >= ed.theme_names.len) return;
    ed.theme_index = i;
    ed.theme_before = i;
    const p = statePath(ed, "theme") orelse return;
    defer ed.gpa.free(p);
    if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(ed.io, dir) catch return;
    Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = p, .data = ed.theme_names[i] }) catch {};
}

/// The colour scheme chosen last time, if it still exists.
pub fn loadTheme(ed: *Editor) void {
    const p = statePath(ed, "theme") orelse return;
    defer ed.gpa.free(p);
    const data = Io.Dir.cwd().readFileAlloc(ed.io, p, ed.gpa, .limited(256)) catch return;
    defer ed.gpa.free(data);
    const name = std.mem.trim(u8, data, " \n");
    for (ed.theme_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
        ed.theme_index = i;
        ed.theme_before = i;
    };
}

/// The start screen (mini.starter): recent files and first steps.
pub fn openStarter(ed: *Editor) !void {
    try ed.openPicker(.start, "");
}
