//! Window layout: a tree of splits whose leaves are windows. Each window
//! shows a buffer with its own view (cursor, scroll). Geometry is computed by
//! `layout` (the UI calls it every frame); everything else is pure tree work.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("Editor.zig");
const Buffer = @import("core/Buffer.zig");

const Windows = @This();

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// `horizontal`: side by side (a vertical divider). `vertical`: stacked.
pub const Axis = enum { horizontal, vertical };

pub const Dir = enum {
    left,
    down,
    up,
    right,

    fn axis(d: Dir) Axis {
        return if (d == .left or d == .right) .horizontal else .vertical;
    }

    /// The new/target window comes after the current one (right, below).
    fn after(d: Dir) bool {
        return d == .right or d == .down;
    }
};

pub const Window = struct {
    /// For the focused window these are stale: the live ones are
    /// `Editor.buffer` and `Editor.view`.
    buffer: *Buffer,
    view: Editor.View,
    /// Screen area, from the last `layout`.
    rect: Rect = .{},
    node: *Node,
    /// Shows this terminal instead of the buffer (borrowed: the editor owns
    /// it, and closing the window only hides it).
    term: ?*Editor.Terminal = null,
    /// Esc Esc put the terminal in normal mode: keys go to the editor
    /// (SPC commands), not the program, until i/a.
    term_normal: bool = false,
    /// When it last had focus (`Editor.use_counter`): the windows picker
    /// lists the last used first.
    used: u64 = 0,
};

pub const Node = struct {
    parent: ?*Node = null,
    kind: union(enum) {
        window: *Window,
        split: Split,
    },
};

pub const Split = struct {
    axis: Axis,
    /// Share of the space given to `first`.
    ratio: f32 = 0.5,
    first: *Node,
    second: *Node,
    /// Where the last `layout` put it: its area, and the border's position
    /// (x for side by side, y for stacked).
    rect: Rect = .{},
    border: f32 = 0,
};

gpa: Allocator,
root: *Node,
/// The cell size of the last `layout` (border moves are in cells).
cell: [2]f32 = .{ 8, 16 },

pub fn init(gpa: Allocator, buffer: *Buffer) !Windows {
    const w = try gpa.create(Window);
    errdefer gpa.destroy(w);
    const node = try gpa.create(Node);
    w.* = .{ .buffer = buffer, .view = .{}, .node = node };
    node.* = .{ .kind = .{ .window = w } };
    return .{ .gpa = gpa, .root = node };
}

pub fn deinit(ws: *Windows) void {
    ws.freeNode(ws.root);
}

fn freeNode(ws: *Windows, n: *Node) void {
    switch (n.kind) {
        .window => |w| ws.gpa.destroy(w),
        .split => |s| {
            ws.freeNode(s.first);
            ws.freeNode(s.second);
        },
    }
    ws.gpa.destroy(n);
}

/// Windows in reading order (left to right, top to bottom within splits).
pub fn list(ws: *const Windows, out: *std.ArrayList(*Window)) !void {
    out.clearRetainingCapacity();
    try collect(ws.gpa, ws.root, out);
}

fn collect(gpa: Allocator, n: *Node, out: *std.ArrayList(*Window)) !void {
    switch (n.kind) {
        .window => |w| try out.append(gpa, w),
        .split => |s| {
            try collect(gpa, s.first, out);
            try collect(gpa, s.second, out);
        },
    }
}

pub fn count(ws: *const Windows) usize {
    return leaves(ws.root);
}

fn leaves(n: *const Node) usize {
    return switch (n.kind) {
        .window => 1,
        .split => |s| leaves(s.first) + leaves(s.second),
    };
}

/// Splits `w` in half; the new window (showing the same buffer and view)
/// goes on side `dir`.
pub fn split(ws: *Windows, w: *Window, dir: Dir, view: Editor.View, buffer: *Buffer) !*Window {
    const gpa = ws.gpa;
    const nw = try gpa.create(Window);
    errdefer gpa.destroy(nw);
    const new_leaf = try gpa.create(Node);
    errdefer gpa.destroy(new_leaf);
    const old_leaf = try gpa.create(Node);
    nw.* = .{ .buffer = buffer, .view = view, .node = new_leaf, .rect = w.rect };

    // `w.node` becomes the split; `w` moves to a fresh leaf under it.
    const here = w.node;
    old_leaf.* = .{ .parent = here, .kind = .{ .window = w } };
    new_leaf.* = .{ .parent = here, .kind = .{ .window = nw } };
    w.node = old_leaf;
    here.kind = .{ .split = .{
        .axis = dir.axis(),
        .first = if (dir.after()) old_leaf else new_leaf,
        .second = if (dir.after()) new_leaf else old_leaf,
    } };
    // Halve the old area now, so moving between them works before the next
    // frame lays everything out on whole cells.
    layoutNode(here, w.rect, 1, 1);
    return nw;
}

/// Removes `w`; its sibling takes the space. Returns the window that should
/// get focus (nearest in the sibling's subtree), or null if `w` is the last.
pub fn close(ws: *Windows, w: *Window) ?*Window {
    const leaf = w.node;
    const parent = leaf.parent orelse return null;
    const s = parent.kind.split;
    const sibling = if (s.first == leaf) s.second else s.first;
    // The sibling replaces the parent in place.
    parent.kind = sibling.kind;
    switch (parent.kind) {
        .window => |sw| sw.node = parent,
        .split => |ss| {
            ss.first.parent = parent;
            ss.second.parent = parent;
        },
    }
    ws.gpa.destroy(sibling);
    ws.gpa.destroy(leaf);
    ws.gpa.destroy(w);
    // Focus: the leaf of the sibling nearest where `w` was.
    var n = parent;
    const took_first = s.first != leaf; // sibling was first: `w` was after it
    while (true) switch (n.kind) {
        .window => |fw| return fw,
        .split => |sp| n = if (took_first) sp.second else sp.first,
    };
}

/// Closes every window but `keep`.
pub fn only(ws: *Windows, keep: *Window) !void {
    var all: std.ArrayList(*Window) = .empty;
    defer all.deinit(ws.gpa);
    try ws.list(&all);
    for (all.items) |w| if (w != keep) {
        _ = ws.close(w);
    };
}

/// Sizes every split so windows along an axis get equal space.
pub fn balance(ws: *Windows) void {
    balanceNode(ws.root);
}

fn balanceNode(n: *Node) void {
    switch (n.kind) {
        .window => {},
        .split => |*s| {
            const a: f32 = @floatFromInt(span(s.first, s.axis));
            const b: f32 = @floatFromInt(span(s.second, s.axis));
            s.ratio = a / (a + b);
            balanceNode(s.first);
            balanceNode(s.second);
        },
    }
}

/// How many windows sit side by side along `axis` in `n`.
fn span(n: *const Node, axis: Axis) usize {
    return switch (n.kind) {
        .window => 1,
        .split => |s| if (s.axis == axis) span(s.first, axis) + span(s.second, axis) else @max(span(s.first, axis), span(s.second, axis)),
    };
}

/// Moves a border of `w` by `cells` cells toward `dir` (the border on that
/// side if `w` has one, else its other border): `l` moves a border right
/// whichever window is focused. False when `w` has no border that way.
pub fn moveBorder(ws: *Windows, w: *Window, dir: Dir, cells: f32) bool {
    const axis = dir.axis();
    // The nearest borders after (right/below) and before (left/above) `w`.
    var after: ?*Node = null;
    var before: ?*Node = null;
    var child = w.node;
    var n = child.parent;
    while (n) |p| : ({
        child = p;
        n = p.parent;
    }) {
        const s = p.kind.split;
        if (s.axis != axis) continue;
        if (s.first == child and after == null) after = p;
        if (s.second == child and before == null) before = p;
    }
    const target = (if (dir.after()) after orelse before else before orelse after) orelse return false;
    const extent = nodeExtent(target, axis);
    if (extent <= 0) return false;
    const unit = cells * (if (axis == .horizontal) ws.cell[0] else ws.cell[1]) / extent;
    const s = &target.kind.split;
    s.ratio = std.math.clamp(s.ratio + (if (dir.after()) unit else -unit), 0.05, 0.95);
    return true;
}

/// The size along `axis` of the area `n` covers (its windows' rectangles).
fn nodeExtent(n: *const Node, axis: Axis) f32 {
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    extentOf(n, axis, &lo, &hi);
    return hi - lo;
}

fn extentOf(n: *const Node, axis: Axis, lo: *f32, hi: *f32) void {
    switch (n.kind) {
        .window => |w| {
            const a = if (axis == .horizontal) w.rect.x else w.rect.y;
            const b = a + (if (axis == .horizontal) w.rect.w else w.rect.h);
            lo.* = @min(lo.*, a);
            hi.* = @max(hi.*, b);
        },
        .split => |s| {
            extentOf(s.first, axis, lo, hi);
            extentOf(s.second, axis, lo, hi);
        },
    }
}

/// Grows (`delta` > 0) or shrinks `w` along `axis` by moving the divider of
/// its nearest split on that axis.
pub fn resize(w: *Window, axis: Axis, delta: f32) void {
    var child = w.node;
    var n = child.parent;
    while (n) |p| : ({
        child = p;
        n = p.parent;
    }) {
        const s = &p.kind.split;
        if (s.axis != axis) continue;
        const sign: f32 = if (s.first == child) 1 else -1;
        s.ratio = std.math.clamp(s.ratio + sign * delta, 0.1, 0.9);
        return;
    }
}

/// Lays the tree out in `area`, splitting on whole cells.
pub fn layout(ws: *Windows, area: Rect, cell_w: f32, cell_h: f32) void {
    ws.cell = .{ cell_w, cell_h };
    layoutNode(ws.root, area, cell_w, cell_h);
}

fn layoutNode(n: *Node, r: Rect, cw: f32, ch: f32) void {
    switch (n.kind) {
        .window => |w| w.rect = r,
        .split => |*s| switch (s.axis) {
            .horizontal => {
                const a = @max(@round(r.w * s.ratio / cw) * cw, cw);
                s.rect = r;
                s.border = r.x + a;
                layoutNode(s.first, .{ .x = r.x, .y = r.y, .w = a, .h = r.h }, cw, ch);
                layoutNode(s.second, .{ .x = r.x + a, .y = r.y, .w = @max(r.w - a, 0), .h = r.h }, cw, ch);
            },
            .vertical => {
                const a = @max(@round(r.h * s.ratio / ch) * ch, ch);
                s.rect = r;
                s.border = r.y + a;
                layoutNode(s.first, .{ .x = r.x, .y = r.y, .w = r.w, .h = a }, cw, ch);
                layoutNode(s.second, .{ .x = r.x, .y = r.y + a, .w = r.w, .h = @max(r.h - a, 0) }, cw, ch);
            },
        },
    }
}

/// The window next to `w` on side `dir` (by screen position, the one
/// overlapping `w` the most, then the nearest), if any.
pub fn neighbor(ws: *const Windows, w: *const Window, dir: Dir) ?*Window {
    var all: std.ArrayList(*Window) = .empty;
    defer all.deinit(ws.gpa);
    ws.list(&all) catch return null;
    const r = w.rect;
    const eps = 0.5;
    var best: ?*Window = null;
    var best_gap: f32 = std.math.inf(f32);
    var best_overlap: f32 = 0;
    for (all.items) |o| {
        if (o == w) continue;
        const q = o.rect;
        const gap: f32 = switch (dir) {
            .right => q.x - (r.x + r.w),
            .left => r.x - (q.x + q.w),
            .down => q.y - (r.y + r.h),
            .up => r.y - (q.y + q.h),
        };
        if (gap < -eps) continue;
        const overlap = switch (dir.axis()) {
            .horizontal => @min(r.y + r.h, q.y + q.h) - @max(r.y, q.y),
            .vertical => @min(r.x + r.w, q.x + q.w) - @max(r.x, q.x),
        };
        if (overlap <= 0) continue;
        if (gap < best_gap - eps or (@abs(gap - best_gap) <= eps and overlap > best_overlap)) {
            best = o;
            best_gap = gap;
            best_overlap = overlap;
        }
    }
    return best;
}

/// The window after `w` in reading order, wrapping around.
pub fn next(ws: *const Windows, w: *Window) *Window {
    var all: std.ArrayList(*Window) = .empty;
    defer all.deinit(ws.gpa);
    ws.list(&all) catch return w;
    for (all.items, 0..) |o, i| if (o == w) return all.items[(i + 1) % all.items.len];
    return w;
}

/// The split whose border is within `slop` of screen point (x, y): the
/// innermost one, if borders meet.
pub fn borderAt(ws: *const Windows, x: f32, y: f32, slop: f32) ?*Split {
    return borderIn(ws.root, x, y, slop);
}

fn borderIn(n: *Node, x: f32, y: f32, slop: f32) ?*Split {
    const s = switch (n.kind) {
        .window => return null,
        .split => |*s| s,
    };
    const r = s.rect;
    if (x < r.x - slop or x > r.x + r.w + slop or y < r.y - slop or y > r.y + r.h + slop) return null;
    if (borderIn(s.first, x, y, slop) orelse borderIn(s.second, x, y, slop)) |inner| return inner;
    const along = if (s.axis == .horizontal) x else y;
    return if (@abs(along - s.border) <= slop) s else null;
}

/// Moves `s`'s border to screen position `pos` (x or y, by its axis).
pub fn dragBorder(s: *Split, pos: f32) void {
    const start, const size = if (s.axis == .horizontal) .{ s.rect.x, s.rect.w } else .{ s.rect.y, s.rect.h };
    if (size <= 0) return;
    s.ratio = std.math.clamp((pos - start) / size, 0.05, 0.95);
}

/// The window containing screen point (x, y).
pub fn at(ws: *const Windows, x: f32, y: f32) ?*Window {
    var all: std.ArrayList(*Window) = .empty;
    defer all.deinit(ws.gpa);
    ws.list(&all) catch return null;
    for (all.items) |o| {
        const r = o.rect;
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return o;
    }
    return null;
}

const testing = std.testing;

test "split, navigate, close" {
    var b: Buffer = undefined;
    var ws = try Windows.init(testing.allocator, &b);
    defer ws.deinit();
    const a = ws.root.kind.window;
    const right = try ws.split(a, .right, .{}, &b);
    const below = try ws.split(right, .down, .{}, &b);
    try testing.expectEqual(3, ws.count());
    ws.layout(.{ .w = 100, .h = 100 }, 1, 1);
    try testing.expectEqual(@as(f32, 50), right.rect.x);
    try testing.expectEqual(@as(f32, 50), below.rect.y);

    try testing.expectEqual(right, ws.neighbor(a, .right).?);
    try testing.expectEqual(a, ws.neighbor(below, .left).?);
    try testing.expectEqual(below, ws.neighbor(right, .down).?);
    try testing.expectEqual(null, ws.neighbor(a, .left));
    try testing.expectEqual(right, ws.next(a));
    try testing.expectEqual(a, ws.next(below));

    // Closing the bottom-right one gives its space back to the top-right.
    try testing.expectEqual(right, ws.close(below).?);
    ws.layout(.{ .w = 100, .h = 100 }, 1, 1);
    try testing.expectEqual(@as(f32, 100), right.rect.h);
    try testing.expectEqual(a, ws.close(right).?);
    try testing.expectEqual(null, ws.close(a));
    try testing.expectEqual(1, ws.count());
}

test "moveBorder: the border moves the way of the key, from either side" {
    var b: Buffer = undefined;
    var ws = try Windows.init(testing.allocator, &b);
    defer ws.deinit();
    const left = ws.root.kind.window;
    const right = try ws.split(left, .right, .{}, &b);
    ws.layout(.{ .w = 100, .h = 10 }, 1, 1);
    // From the left window, l moves its right border right: it grows.
    try testing.expect(ws.moveBorder(left, .right, 10));
    ws.layout(.{ .w = 100, .h = 10 }, 1, 1);
    try testing.expectEqual(@as(f32, 60), left.rect.w);
    // From the right window, l moves its (left) border right too: it shrinks.
    try testing.expect(ws.moveBorder(right, .right, 10));
    ws.layout(.{ .w = 100, .h = 10 }, 1, 1);
    try testing.expectEqual(@as(f32, 30), right.rect.w);
    // h from the right window: border left, it grows back.
    try testing.expect(ws.moveBorder(right, .left, 20));
    ws.layout(.{ .w = 100, .h = 10 }, 1, 1);
    try testing.expectEqual(@as(f32, 50), right.rect.w);
    // No stacked split: j/k have no border to move.
    try testing.expect(!ws.moveBorder(left, .down, 1));
}

test "balance: three side by side get a third each" {
    var b: Buffer = undefined;
    var ws = try Windows.init(testing.allocator, &b);
    defer ws.deinit();
    const a = ws.root.kind.window;
    const c = try ws.split(a, .right, .{}, &b);
    _ = try ws.split(c, .right, .{}, &b);
    ws.balance();
    ws.layout(.{ .w = 90, .h = 10 }, 1, 1);
    try testing.expectEqual(@as(f32, 30), a.rect.w);
    try testing.expectEqual(@as(f32, 30), c.rect.w);
}

test "a border found by position and dragged" {
    var b: Buffer = undefined;
    var ws = try Windows.init(testing.allocator, &b);
    defer ws.deinit();
    const a = ws.root.kind.window;
    const right = try ws.split(a, .right, .{}, &b);
    _ = right;
    ws.layout(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 10, 20);
    try testing.expectEqual(null, ws.borderAt(200, 100, 4));
    const s = ws.borderAt(402, 100, 4).?;
    dragBorder(s, 200);
    ws.layout(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 10, 20);
    try testing.expectEqual(200, a.rect.w);
}
