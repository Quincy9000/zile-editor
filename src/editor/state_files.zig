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
const jumplist = @import("jumplist.zig");
const project_ops = @import("project_ops.zig");
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

// Places: bookmarks and the jumplist, kept between runs.
//
// A project's are in `.zilehistory` in its root (kept out of git by a line in
// `.git/info/exclude`), read when the project is entered, so its bookmarks
// are all there from the start:
//
//   .{
//       .marks = .{ .{ .name = 'x', .path = "src/main.zig", .pos = 120 } },
//       .jumps = .{ .{ .path = "src/main.zig", .pos = 40 } },
//   }
//
// A file outside any project (or in a cache) has its own in the state
// folder, `places/<hash of the path>`, the same without the paths, read when
// it is opened. `pos` is a byte offset; a bookmark without a name has name 0.
// Both are written when a bookmark is set or removed, when a file is closed
// and on the way out.

pub const history_name = ".zilehistory";

const FilePlaces = struct {
    marks: []const struct { name: u21, pos: usize } = &.{},
    jumps: []const usize = &.{},
};

const ProjectPlaces = struct {
    marks: []const struct { name: u21, path: []const u8, pos: usize } = &.{},
    jumps: []const struct { path: []const u8, pos: usize } = &.{},
};

/// Tests write nothing unless they name a state folder.
fn placesKept(ed: *const Editor) bool {
    return !@import("builtin").is_test or ed.state_dir != null;
}

/// The project whose `.zilehistory` keeps a file's places, if it has one.
fn historyProject(p: ?*const Project) ?*const Project {
    const proj = p orelse return null;
    return if (project_ops.isCache(proj.root)) null else proj;
}

fn placesPath(ed: *Editor, abs: []const u8) ?[]u8 {
    var name: [32]u8 = undefined;
    const n = std.fmt.bufPrint(&name, "places/{x:0>16}", .{std.hash.Wyhash.hash(0, abs)}) catch return null;
    return statePath(ed, n);
}

fn samePath(a: ?[]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, a.?, b);
}

fn parseZon(T: type, ed: *Editor, arena: Allocator, file: []const u8) ?T {
    const data = Io.Dir.cwd().readFileAlloc(ed.io, file, arena, .limited(4 << 20)) catch return null;
    const source = arena.allocSentinel(u8, data.len, 0) catch return null;
    @memcpy(source, data);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{ .gpa = ed.gpa, .arena = arena, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch null;
}

fn writeZon(ed: *Editor, arena: Allocator, file: []const u8, value: anytype) void {
    var out: Io.Writer.Allocating = .init(arena);
    std.zon.stringify.serialize(value, .{ .emit_codepoint_literals = .always }, &out.writer) catch return;
    out.writer.writeByte('\n') catch return;
    if (std.fs.path.dirname(file)) |dir| Io.Dir.cwd().createDirPath(ed.io, dir) catch return;
    Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = file, .data = out.written() }) catch {};
}

/// Writes the places of the file at `path` (a buffer's path, in `project`),
/// open or not: its project's `.zilehistory`, or its own file.
pub fn savePlaces(ed: *Editor, path: []const u8, project: ?*const Project) void {
    if (!placesKept(ed)) return;
    if (historyProject(project)) |p| return saveProjectPlaces(ed, p);
    var arena_state: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    const file = placesPath(ed, abs) orelse return;
    defer ed.gpa.free(file);
    var marks: std.ArrayList(@typeInfo(@FieldType(FilePlaces, "marks")).pointer.child) = .empty;
    var jumps: std.ArrayList(usize) = .empty;
    for (ed.marks.items) |m| if (samePath(m.path, path)) {
        marks.append(arena, .{ .name = m.name, .pos = m.pos }) catch return;
    };
    for (ed.jumps.items) |j| if (samePath(j.path, path)) {
        jumps.append(arena, j.pos) catch return;
    };
    if (marks.items.len == 0 and jumps.items.len == 0) return Io.Dir.cwd().deleteFile(ed.io, file) catch {};
    writeZon(ed, arena, file, FilePlaces{ .marks = marks.items, .jumps = jumps.items });
}

/// A path inside `root`, relative to it (else null).
fn relativeTo(ed: *Editor, arena: Allocator, root: []const u8, path: []const u8) ?[]const u8 {
    const abs = ed.absolutePath(path) catch return null;
    defer ed.gpa.free(abs);
    if (abs.len <= root.len + 1 or !std.mem.startsWith(u8, abs, root) or abs[root.len] != '/') return null;
    return arena.dupe(u8, abs[root.len + 1 ..]) catch null;
}

/// Writes `p`'s `.zilehistory`: every bookmark and jump in its files.
pub fn saveProjectPlaces(ed: *Editor, p: *const Project) void {
    if (!placesKept(ed)) return;
    // What it holds from before is read first, not written over.
    loadProjectPlaces(ed, p);
    var arena_state: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = std.fs.path.join(arena, &.{ p.root, history_name }) catch return;
    var marks: std.ArrayList(@typeInfo(@FieldType(ProjectPlaces, "marks")).pointer.child) = .empty;
    var jumps: std.ArrayList(@typeInfo(@FieldType(ProjectPlaces, "jumps")).pointer.child) = .empty;
    for (ed.marks.items) |m| if (m.project == p) {
        const rel = relativeTo(ed, arena, p.root, m.path orelse continue) orelse continue;
        marks.append(arena, .{ .name = m.name, .path = rel, .pos = m.pos }) catch return;
    };
    for (ed.jumps.items) |j| if (j.project == p) {
        const rel = relativeTo(ed, arena, p.root, j.path orelse continue) orelse continue;
        jumps.append(arena, .{ .path = rel, .pos = j.pos }) catch return;
    };
    if (marks.items.len == 0 and jumps.items.len == 0) return Io.Dir.cwd().deleteFile(ed.io, file) catch {};
    const fresh = if (Io.Dir.cwd().access(ed.io, file, .{})) |_| false else |_| true;
    writeZon(ed, arena, file, ProjectPlaces{ .marks = marks.items, .jumps = jumps.items });
    if (fresh and p.git) excludeFromGit(ed, arena, p.root);
}

/// A line for `.zilehistory` in the repository's own ignore list
/// (`.git/info/exclude`: not shared, not committed), unless it has one.
fn excludeFromGit(ed: *Editor, arena: Allocator, root: []const u8) void {
    const info = std.fs.path.join(arena, &.{ root, ".git", "info" }) catch return;
    // (`.git` is a file in worktrees and submodules: nothing is done there.)
    Io.Dir.cwd().createDirPath(ed.io, info) catch return;
    const file = std.fs.path.join(arena, &.{ info, "exclude" }) catch return;
    const old = Io.Dir.cwd().readFileAlloc(ed.io, file, arena, .limited(1 << 20)) catch "";
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), history_name)) return;
    const sep: []const u8 = if (old.len > 0 and old[old.len - 1] != '\n') "\n" else "";
    const data = std.mem.concat(arena, u8, &.{ old, sep, history_name, "\n" }) catch return;
    Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = file, .data = data }) catch {};
}

/// On the way out: every project's places, and every other open file's.
pub fn saveAllPlaces(ed: *Editor) void {
    for (ed.projects.items) |p| if (p.places_loaded and historyProject(p) != null) saveProjectPlaces(ed, p);
    for (ed.buffers.items) |b| if (b.path) |p| {
        if (historyProject(b.project) == null) savePlaces(ed, p, null);
    };
}

fn openBuffer(ed: *Editor, path: []const u8) ?*Buffer {
    for (ed.buffers.items) |b| if (samePath(b.path, path)) return b;
    return null;
}

/// Reads `p`'s `.zilehistory`, once: its bookmarks and jumps join the lists
/// (before this run's own: they are older), of files open or not.
pub fn loadProjectPlaces(ed: *Editor, p: *const Project) void {
    if (p.places_loaded or !placesKept(ed) or historyProject(p) == null) return;
    @constCast(p).places_loaded = true;
    const gpa = ed.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = std.fs.path.join(arena, &.{ p.root, history_name }) catch return;
    const places = parseZon(ProjectPlaces, ed, arena, file) orelse return;
    var at: usize = 0;
    for (places.marks) |m| {
        // A name set again elsewhere since then stays where it is now.
        if (m.name != 0 and jumplist.findMark(ed, m.name) != null) continue;
        const path = placePath(ed, arena, p.root, m.path) orelse continue;
        ed.marks.insert(gpa, at, .{ .name = m.name, .buffer = openBuffer(ed, path), .path = path, .pos = m.pos, .project = p }) catch return gpa.free(path);
        at += 1;
    }
    at = 0;
    for (places.jumps) |j| {
        if (ed.jumps.items.len >= jumplist.max_jumps) break;
        const path = placePath(ed, arena, p.root, j.path) orelse continue;
        ed.jumps.insert(gpa, at, .{ .buffer = openBuffer(ed, path), .path = path, .pos = j.pos, .project = p }) catch return gpa.free(path);
        at += 1;
        ed.jump_index += 1;
    }
}

/// The buffer path (owned) of `rel` in `root`; null when the file is gone.
fn placePath(ed: *Editor, arena: Allocator, root: []const u8, rel: []const u8) ?[]u8 {
    const abs = std.fs.path.join(arena, &.{ root, rel }) catch return null;
    Io.Dir.cwd().access(ed.io, abs, .{}) catch return null;
    return ed.normalizePath(abs) catch null;
}

/// The current project's (for the pickers, before any of its files is open).
pub fn loadCurrentProjectPlaces(ed: *Editor) void {
    if (project_ops.project(ed)) |p| return loadProjectPlaces(ed, p);
    const probe = std.fs.path.join(ed.gpa, &.{ project_ops.projectRoot(ed), "x" }) catch return;
    defer ed.gpa.free(probe);
    if (project_ops.projectOf(ed, probe)) |p| loadProjectPlaces(ed, p);
}

/// `b` was just opened: its places are its own again. The ones held already
/// (from this run, or its project's `.zilehistory`) win over its own file's.
pub fn restorePlaces(ed: *Editor, b: *Buffer) void {
    const gpa = ed.gpa;
    const path = b.path orelse return;
    if (b.project) |p| loadProjectPlaces(ed, p);
    var have_marks = false;
    var have_jumps = false;
    for (ed.marks.items) |*m| if (samePath(m.path, path)) {
        if (m.buffer == null) m.buffer = b;
        m.project = b.project;
        have_marks = true;
    };
    for (ed.jumps.items) |*j| if (samePath(j.path, path)) {
        if (j.buffer == null) j.buffer = b;
        j.project = b.project;
        have_jumps = true;
    };
    if (!placesKept(ed) or (have_marks and have_jumps)) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const abs = ed.absolutePath(path) catch return;
    defer gpa.free(abs);
    const file = placesPath(ed, abs) orelse return;
    defer gpa.free(file);
    const places = parseZon(FilePlaces, ed, arena, file) orelse return;
    // Before this run's own: they are older.
    if (!have_marks) {
        var at: usize = 0;
        for (places.marks) |m| {
            if (m.name != 0 and jumplist.findMark(ed, m.name) != null) continue;
            const owned = gpa.dupe(u8, path) catch return;
            ed.marks.insert(gpa, at, .{ .name = m.name, .buffer = b, .path = owned, .pos = @min(m.pos, b.text.len()), .project = b.project }) catch return gpa.free(owned);
            at += 1;
        }
    }
    if (!have_jumps) {
        var at: usize = 0;
        for (places.jumps) |pos| {
            if (ed.jumps.items.len >= jumplist.max_jumps) break;
            const owned = gpa.dupe(u8, path) catch return;
            ed.jumps.insert(gpa, at, .{ .buffer = b, .path = owned, .pos = @min(pos, b.text.len()), .project = b.project }) catch return gpa.free(owned);
            at += 1;
            ed.jump_index += 1;
        }
    }
    // A project's file kept on its own (by an earlier zile): its places
    // move to the project's `.zilehistory`.
    if (historyProject(b.project)) |p| {
        Io.Dir.cwd().deleteFile(ed.io, file) catch {};
        saveProjectPlaces(ed, p);
    }
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
    if (storePath(ed, .places)) |p| {
        defer ed.gpa.free(p);
        StoredData.prune(ed.gpa, ed.io, p, StoredData.max_undo_files, std.math.maxInt(u64));
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
        .places => {
            for (ed.projects.items) |proj| if (proj.places_loaded and placesKept(ed)) {
                const file = std.fs.path.join(ed.gpa, &.{ proj.root, history_name }) catch continue;
                defer ed.gpa.free(file);
                Io.Dir.cwd().deleteFile(ed.io, file) catch {};
            };
            for (ed.marks.items) |m| if (m.path) |mp| ed.gpa.free(mp);
            ed.marks.clearRetainingCapacity();
            for (ed.jumps.items) |j| if (j.path) |jp| ed.gpa.free(jp);
            ed.jumps.clearRetainingCapacity();
            ed.jump_index = 0;
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

test "places: a file's bookmarks and jumps are kept, and come back when it is opened" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\nfour\n" });
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&path_buf, "{s}/a.txt", .{dir});
    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = dir;
        try ed.openFile(file);
        try ed.feed("jmxG"); // a bookmark on line 2, a jump left from it
        saveAllPlaces(&ed);
    }
    var ed = try testEditor("");
    defer ed.deinit();
    ed.state_dir = dir;
    try testing.expectEqual(0, ed.marks.items.len);
    try ed.openFile(file);
    try testing.expectEqual(1, ed.marks.items.len);
    try testing.expectEqual('x', ed.marks.items[0].name);
    try testing.expectEqual(1, ed.jumps.items.len);
    try ed.feed("gg'x");
    try testing.expectEqual(1, ed.cursorLine());
    // Removed: gone from the file's places too.
    try ed.feed("mx");
    try testing.expectEqual(0, ed.marks.items.len);
    clearStore(&ed, .places);
    var again = try testEditor("");
    defer again.deinit();
    again.state_dir = dir;
    try again.openFile(file);
    try testing.expectEqual(0, again.marks.items.len);
    try testing.expectEqual(0, again.jumps.items.len);
}

test "places: a project's are in its .zilehistory, out of git's sight, there before its files are open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.createDirPath(testing.io, "proj/.git");
    try tmp.dir.createDirPath(testing.io, "proj/src");
    try tmp.dir.createDirPath(testing.io, "state");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/src/a.txt", .data = "one\ntwo\nthree\nfour\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/b.txt", .data = "bee\n" });
    var a_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "{s}/proj/src/a.txt", .{dir});
    var b_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const b = try std.fmt.bufPrint(&b_buf, "{s}/proj/b.txt", .{dir});
    var state_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const state = try std.fmt.bufPrint(&state_buf, "{s}/state", .{dir});
    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = state;
        try ed.openFile(a);
        try ed.feed("jmxG"); // a bookmark on line 2, a jump left from it
        saveAllPlaces(&ed);
    }
    const history = try tmp.dir.readFileAlloc(testing.io, "proj/.zilehistory", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(history);
    try testing.expect(std.mem.indexOf(u8, history, ".path = \"src/a.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, history, ".name = 'x'") != null);
    const exclude = try tmp.dir.readFileAlloc(testing.io, "proj/.git/info/exclude", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(exclude);
    try testing.expectEqualStrings(".zilehistory\n", exclude);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "state/places", .{})); // nothing of it in the state folder

    // Another file of the project: the bookmark is there, its file not open.
    var ed = try testEditor("");
    defer ed.deinit();
    ed.state_dir = state;
    try ed.openFile(b);
    try testing.expectEqual(1, ed.marks.items.len);
    try testing.expectEqual(null, ed.marks.items[0].buffer);
    try testing.expectEqual(1, ed.jumps.items.len);
    try ed.feed("'x");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/a.txt"));
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expectEqual(ed.buffer, ed.marks.items[0].buffer.?);
    // The last one removed: the file goes.
    try ed.feed("mx");
    clearStore(&ed, .places);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "proj/.zilehistory", .{}));
}
