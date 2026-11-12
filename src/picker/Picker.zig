//! An open picker: the query, the active source and its engine, the
//! selection, and the preview. Main thread only; owned by `Editor`.
//!
//! The first byte of the query can switch sources (`>` -> commands), so any
//! picker can become any other.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("../Editor.zig");
const Engine = @import("Engine.zig");
const Items = @import("Items.zig");
const fuzzy = @import("fuzzy.zig");
const sources = @import("sources.zig");
const LineInput = @import("../input/LineInput.zig");

const Picker = @This();

pub const Kind = sources.Kind;
pub const ItemsStore = Items;

ed: *Editor,
/// The source this picker was opened as.
base: Kind,
/// The active source (differs from `base` when switched by prefix).
kind: Kind,
query: LineInput = .{},
/// The engine receiving queries.
engine: *Engine,
/// The engine whose results are displayed. Differs from `engine` briefly
/// after a restart (source switch, or a query-driven source like rg), so the
/// list keeps showing old results until new ones arrive instead of flashing.
shown: *Engine,
/// Generation of the latest query sent to the engine.
want_gen: u64 = 0,
snap: Engine.Snapshot = .{},
selected: usize = 0,
/// First visible row (maintained by the view).
top: usize = 0,
preview: sources.Preview = .{},
/// Item index the preview currently shows.
preview_for: ?u32 = null,
/// For match highlighting in the view.
pos_scratch: fuzzy.PositionScratch = .{},
/// Item text to select once the results arrive (owned), e.g. the folder the
/// file browser just came up from.
want_select: ?[]u8 = null,
/// Item id to select once the results arrive (e.g. the current quickfix
/// entry).
want_id: ?u32 = null,
/// The explorer's second search, files elsewhere (`files_global`), run per
/// query and listed under its own rows; `global_shown` keeps showing the
/// last answer until the new one comes, like `shown`.
global: ?*Engine = null,
global_shown: ?*Engine = null,
gsnap: Engine.Snapshot = .{},

pub fn create(ed: *Editor, kind: Kind, query: []const u8) !*Picker {
    const gpa = ed.gpa;
    const p = try gpa.create(Picker);
    errdefer gpa.destroy(p);
    p.* = .{ .ed = ed, .base = kind, .kind = kind, .engine = undefined, .shown = undefined };
    errdefer p.query.deinit(gpa);
    try p.query.set(gpa, query);
    p.kind = p.kindForQuery();
    p.engine = try p.startEngine(p.kind, p.activeQuery());
    p.shown = p.engine;
    try p.restartGlobal();
    return p;
}

/// A new search elsewhere for the current query (the explorer only).
fn restartGlobal(p: *Picker) !void {
    if (p.kind != .browse) return p.dropGlobal();
    const e = try Engine.create(p.ed.gpa, p.ed.io, p.ed.wake_fn);
    errdefer e.destroy();
    const producer = try sources.setup(.files_global, p.ed, e);
    _ = e.setQuery(p.activeQuery());
    try e.start(producer);
    if (p.global) |g| if (p.global != p.global_shown) g.destroy();
    p.global = e;
    if (p.global_shown == null) p.global_shown = e;
}

fn dropGlobal(p: *Picker) void {
    if (p.global_shown) |g| if (p.global_shown != p.global) g.destroy();
    if (p.global) |g| g.destroy();
    p.global = null;
    p.global_shown = null;
    p.gsnap = .{};
}

/// Rows found elsewhere (after the local ones).
pub fn globalLen(p: *const Picker) usize {
    if (p.global_shown == null or p.activeQuery().len == 0) return 0;
    return p.gsnap.len;
}

pub fn destroy(p: *Picker) void {
    const gpa = p.ed.gpa;
    if (p.shown != p.engine) p.shown.destroy();
    p.engine.destroy();
    p.dropGlobal();
    p.query.deinit(gpa);
    if (p.want_select) |w| gpa.free(w);
    p.preview.text.deinit(gpa);
    p.preview.styles.deinit(gpa);
    gpa.destroy(p);
}

fn startEngine(p: *Picker, kind: Kind, query: []const u8) !*Engine {
    const e = try Engine.create(p.ed.gpa, p.ed.io, p.ed.wake_fn);
    errdefer e.destroy();
    e.root = p.ed.picker_root;
    const producer = try sources.setup(kind, p.ed, e);
    p.want_gen = e.setQuery(query);
    try e.start(producer);
    return e;
}

fn kindForQuery(p: *const Picker) Kind {
    const q = p.query.items();
    if (q.len > 0) {
        if (sources.byPrefix(q[0])) |k| return k;
    }
    return p.base;
}

/// The query without the source-switching prefix.
pub fn activeQuery(p: *const Picker) []const u8 {
    const q = p.query.items();
    if (q.len > 0 and sources.prefix(p.kind) == q[0]) return q[1..];
    return q;
}

pub fn title(p: *const Picker) []const u8 {
    if (p.kind == .browse) return p.ed.browse_label.items;
    if (p.kind == .debug) return sources.debugTitle(p.ed);
    return sources.title(p.kind);
}

/// Refills the source from scratch with an empty query (the file browser
/// changed folder), then selects the item `select`, if given.
pub fn restart(p: *Picker, select: ?[]const u8) !void {
    p.query.clear();
    p.kind = p.base;
    const e = try p.startEngine(p.kind, "");
    // Keep showing the current results until the new engine has some.
    if (p.engine != p.shown) p.engine.destroy();
    p.engine = e;
    p.selected = 0;
    p.top = 0;
    if (p.want_select) |w| p.ed.gpa.free(w);
    p.want_select = if (select) |s| try p.ed.gpa.dupe(u8, s) else null;
    try p.restartGlobal();
}

fn applyWantSelect(p: *Picker) void {
    if (p.want_id) |id| if (p.isCurrent() and p.snap.done) {
        p.want_id = null;
        for (p.snap.slice(), 0..) |r, row| {
            if (p.shown.items.get(r.index).id == id) {
                p.selected = row;
                break;
            }
        }
    };
    const want = p.want_select orelse return;
    if (!p.isCurrent() or !p.snap.done) return;
    for (p.snap.slice(), 0..) |r, row| {
        if (std.mem.eql(u8, p.shown.items.get(r.index).text, want)) {
            p.selected = row;
            break;
        }
    }
    p.ed.gpa.free(want);
    p.want_select = null;
}

// ---------------------------------------------------------------------------
// Query editing: the editor edits `query` (a LineInput) and then calls this.

/// Switches source if the prefix changed and sends the query to the engine.
pub fn queryChanged(p: *Picker) !void {
    const k = p.kindForQuery();
    if (k != p.kind or sources.queryDriven(k, p.ed.io)) {
        // A new engine: for another source, or because the source itself
        // depends on the query (rg runs once per query).
        const old_kind = p.kind;
        p.kind = k;
        const e = p.startEngine(k, p.activeQuery()) catch |err| {
            p.kind = old_kind;
            return err;
        };
        // Keep showing the current results until the new engine has some.
        if (p.engine != p.shown) p.engine.destroy();
        p.engine = e;
    } else {
        p.want_gen = p.engine.setQuery(p.activeQuery());
    }
    p.selected = 0;
    p.top = 0;
    try p.restartGlobal();
}

/// Lists the source again, keeping the query (its items changed: a language
/// server answered).
pub fn refill(p: *Picker) !void {
    const e = try p.startEngine(p.kind, p.activeQuery());
    if (p.engine != p.shown) p.engine.destroy();
    p.engine = e;
    p.preview_for = null;
}

// ---------------------------------------------------------------------------
// Results

/// Picks up new results from the engine.
pub fn poll(p: *Picker) void {
    p.pollGlobal();
    if (p.shown != p.engine) {
        // Switch over once the new engine has published something.
        var fresh: Engine.Snapshot = .{};
        if (!p.engine.poll(&fresh)) return;
        p.shown.destroy();
        p.shown = p.engine;
        p.snap = fresh;
        p.preview_for = null;
        if (p.selected >= p.rowCount()) p.selected = p.rowCount() -| 1;
        p.applyWantSelect();
        return;
    }
    if (p.engine.poll(&p.snap)) {
        const rows = p.rowCount();
        if (p.selected >= rows) p.selected = rows -| 1;
    }
    p.applyWantSelect();
}

fn pollGlobal(p: *Picker) void {
    const g = p.global orelse return;
    if (p.global_shown != g) {
        var fresh: Engine.Snapshot = .{};
        if (!g.poll(&fresh)) return;
        if (p.global_shown) |old| old.destroy();
        p.global_shown = g;
        p.gsnap = fresh;
        return;
    }
    _ = g.poll(&p.gsnap);
}

/// Blocks until results reflect the current query (used before accepting).
pub fn sync(p: *Picker) void {
    p.engine.waitFor(p.want_gen);
    p.poll();
}

/// Results for the current query have arrived.
pub fn isCurrent(p: *const Picker) bool {
    return p.snap.query_gen == p.want_gen;
}

pub fn rowCount(p: *const Picker) usize {
    return p.snap.len + p.globalLen() + @intFromBool(p.createRow() != null);
}

/// Row index of the "Create <query>" row: first when nothing matches, else last.
pub fn createRow(p: *const Picker) ?usize {
    if (!sources.canCreate(p.kind)) return null;
    const q = p.activeQuery();
    if (q.len == 0 or !p.isCurrent()) return null;
    for (p.snap.slice()[0..@min(p.snap.len, 64)]) |r| {
        if (std.mem.eql(u8, p.shown.items.get(r.index).text, q)) return null;
    }
    if (sources.createFirst(p.kind)) return 0;
    // The Debug picker: a program with arguments typed after it.
    if (p.kind == .debug and std.mem.indexOfScalar(u8, q, ' ') != null) return 0;
    // The explorer: after everything found here and elsewhere (Enter on
    // something that matched opens it), or the only row.
    return p.snap.len + p.globalLen();
}

/// Which result `row` shows, or null for the create row (it may be the
/// first row, with the results after it).
fn resultAt(p: *const Picker, row: usize) ?usize {
    var i = row;
    if (p.createRow()) |c| if (c == 0 and p.snap.len > 0) {
        if (row == 0) return null;
        i = row - 1;
    };
    return if (i < p.snap.len) i else null;
}

/// Which of the rows found elsewhere `row` is, if it's one.
fn globalAt(p: *const Picker, row: usize) ?usize {
    if (p.createRow()) |c| if (c == 0 and p.snap.len + p.globalLen() > 0) return null;
    if (row < p.snap.len) return null;
    const g = row - p.snap.len;
    return if (g < p.globalLen()) g else null;
}

/// The item at `row`, or null for the create row.
pub fn itemAt(p: *const Picker, row: usize) ?*const Items.Item {
    if (p.resultAt(row)) |i| return p.shown.items.get(p.snap.results[i].index);
    const g = p.globalAt(row) orelse return null;
    return p.global_shown.?.items.get(p.gsnap.results[g].index);
}

/// Whether `row` is one found elsewhere (drawn under a line).
pub fn isGlobalRow(p: *const Picker, row: usize) bool {
    return p.globalAt(row) != null;
}

pub fn move(p: *Picker, delta: isize) void {
    const rows = p.rowCount();
    if (rows == 0) return;
    const n: isize = @intCast(rows);
    p.selected = @intCast(@mod(@as(isize, @intCast(p.selected)) + delta, n));
}

/// Moves by `delta` without wrapping (page up/down).
pub fn moveClamped(p: *Picker, delta: isize) void {
    const rows = p.rowCount();
    if (rows == 0) return;
    const max: isize = @intCast(rows - 1);
    p.selected = @intCast(std.math.clamp(@as(isize, @intCast(p.selected)) + delta, 0, max));
}

/// Recomputes the preview when the selection changed.
pub fn updatePreview(p: *Picker) void {
    const item = p.itemAt(p.selected) orelse {
        p.preview.clear();
        p.preview_for = null;
        return;
    };
    const index = if (p.resultAt(p.selected)) |i| p.snap.results[i].index else (1 << 31) | p.gsnap.results[p.globalAt(p.selected).?].index;
    if (p.preview_for == index) return;
    p.preview_for = index;
    sources.preview(p.kind, p.ed, item, &p.preview) catch |err| {
        p.preview.clear();
        p.preview.text.print(p.ed.gpa, "(preview failed: {s})", .{@errorName(err)}) catch {};
    };
}

/// What accepting the current selection does. Strings are owned by the caller.
pub const Choice = union(enum) {
    none,
    item: struct { kind: Kind, item: Items.Item },
    create: struct { kind: Kind, query: []u8 },

    pub fn deinit(c: Choice, gpa: Allocator) void {
        switch (c) {
            .none => {},
            .item => |i| {
                gpa.free(i.item.text);
                gpa.free(i.item.detail);
            },
            .create => |cr| gpa.free(cr.query),
        }
    }
};

/// Snapshots the selection so it survives closing the picker.
pub fn choice(p: *Picker) Allocator.Error!Choice {
    p.sync();
    const gpa = p.ed.gpa;
    if (p.createRow()) |row| {
        if (row == p.selected) return .{ .create = .{ .kind = p.kind, .query = try gpa.dupe(u8, p.activeQuery()) } };
    }
    const item = p.itemAt(p.selected) orelse return .none;
    const text = try gpa.dupe(u8, item.text);
    errdefer gpa.free(text);
    return .{ .item = .{ .kind = p.kind, .item = .{
        .text = text,
        .detail = try gpa.dupe(u8, item.detail),
        .id = item.id,
    } } };
}
