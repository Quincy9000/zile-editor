//! Undo tree for one buffer.
//!
//! Edits are recorded as insert/delete operations into an open group; the
//! editor commits the group once a command finishes (an insert-mode session is
//! one group). Each committed group is a node whose parent is the state it was
//! made from, so undoing and then editing starts a new branch instead of
//! discarding the old one. Redo follows the most recently visited child.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Text = @import("Text.zig");

const History = @This();

pub const Op = struct {
    kind: enum { insert, delete },
    pos: usize,
    text: []u8,
};

const Node = struct {
    parent: u32,
    ops: []Op,
    /// Cursor before the change; undo restores it.
    cursor: usize,
    /// Where redo goes from here.
    redo_child: ?u32 = null,
};

/// `nodes[0]` is the root: the text as loaded.
nodes: std.ArrayList(Node) = .empty,
current: u32 = 0,
/// The node that matches the file on disk.
saved: u32 = 0,
pending: std.ArrayList(Op) = .empty,
pending_cursor: usize = 0,

pub fn init(gpa: Allocator) Allocator.Error!History {
    var h: History = .{};
    try h.nodes.append(gpa, .{ .parent = 0, .ops = &.{}, .cursor = 0 });
    return h;
}

pub fn deinit(h: *History, gpa: Allocator) void {
    for (h.nodes.items) |n| freeOps(gpa, n.ops);
    h.nodes.deinit(gpa);
    for (h.pending.items) |op| gpa.free(op.text);
    h.pending.deinit(gpa);
    h.* = undefined;
}

fn freeOps(gpa: Allocator, ops: []Op) void {
    for (ops) |op| gpa.free(op.text);
    gpa.free(ops);
}

/// Records an insertion of `bytes` at `pos` (call before applying it).
pub fn recordInsert(h: *History, gpa: Allocator, pos: usize, bytes: []const u8, cursor: usize) Allocator.Error!void {
    if (h.pending.items.len == 0) h.pending_cursor = cursor;
    // Typing continues the previous insert: extend it.
    if (h.lastPending(.insert)) |last| {
        if (last.pos + last.text.len == pos) {
            const old = last.text.len;
            last.text = try gpa.realloc(last.text, old + bytes.len);
            @memcpy(last.text[old..], bytes);
            return;
        }
    }
    try h.pending.append(gpa, .{ .kind = .insert, .pos = pos, .text = try gpa.dupe(u8, bytes) });
}

/// Records deleting `bytes` (the current text) at `pos` (call before applying it).
pub fn recordDelete(h: *History, gpa: Allocator, pos: usize, bytes: []const u8, cursor: usize) Allocator.Error!void {
    if (h.pending.items.len == 0) h.pending_cursor = cursor;
    if (h.lastPending(.delete)) |last| {
        if (pos + bytes.len == last.pos) {
            // Backspacing: the new bytes come before the previous ones.
            const merged = try std.mem.concat(gpa, u8, &.{ bytes, last.text });
            gpa.free(last.text);
            last.text = merged;
            last.pos = pos;
            return;
        }
        if (pos == last.pos) {
            // Forward delete at the same spot.
            const old = last.text.len;
            last.text = try gpa.realloc(last.text, old + bytes.len);
            @memcpy(last.text[old..], bytes);
            return;
        }
    }
    try h.pending.append(gpa, .{ .kind = .delete, .pos = pos, .text = try gpa.dupe(u8, bytes) });
}

fn lastPending(h: *History, kind: @FieldType(Op, "kind")) ?*Op {
    const items = h.pending.items;
    if (items.len == 0 or items[items.len - 1].kind != kind) return null;
    return &items[items.len - 1];
}

/// Closes the open group, if any, as a new node.
pub fn commit(h: *History, gpa: Allocator) Allocator.Error!void {
    if (h.pending.items.len == 0) return;
    try h.nodes.ensureUnusedCapacity(gpa, 1);
    const ops = try h.pending.toOwnedSlice(gpa);
    const index: u32 = @intCast(h.nodes.items.len);
    h.nodes.appendAssumeCapacity(.{ .parent = h.current, .ops = ops, .cursor = h.pending_cursor });
    h.nodes.items[h.current].redo_child = index;
    h.current = index;
}

pub fn isModified(h: *const History) bool {
    return h.pending.items.len > 0 or h.current != h.saved;
}

pub fn markSaved(h: *History) void {
    h.saved = h.current;
}

/// Reverts the current node. Returns the cursor to restore, or null at the root.
/// `target` is anything with `insert(gpa, pos, bytes)` and `delete(start, end)`
/// (a `Text`, or a `Buffer` that also updates its syntax tree).
pub fn undo(h: *History, gpa: Allocator, target: anytype) Allocator.Error!?usize {
    if (h.current == 0) return null;
    const index = h.current;
    const node = h.nodes.items[index];
    var i = node.ops.len;
    while (i > 0) {
        i -= 1;
        const op = node.ops[i];
        switch (op.kind) {
            .insert => target.delete(op.pos, op.pos + op.text.len),
            .delete => try target.insert(gpa, op.pos, op.text),
        }
    }
    h.nodes.items[node.parent].redo_child = index;
    h.current = node.parent;
    return node.cursor;
}

/// Re-applies the most recently undone child. Returns where the change starts.
pub fn redo(h: *History, gpa: Allocator, target: anytype) Allocator.Error!?usize {
    const child = h.nodes.items[h.current].redo_child orelse return null;
    const node = h.nodes.items[child];
    for (node.ops) |op| switch (op.kind) {
        .insert => try target.insert(gpa, op.pos, op.text),
        .delete => target.delete(op.pos, op.pos + op.text.len),
    };
    h.current = child;
    return if (node.ops.len > 0) node.ops[0].pos else node.cursor;
}

/// Moves to any state in the tree: undoes up to where the two histories
/// meet, then redoes down to `node`. Returns the cursor to restore, or null
/// if already there.
pub fn goTo(h: *History, gpa: Allocator, node: u32, target: anytype) Allocator.Error!?usize {
    if (node >= h.nodes.items.len or node == h.current) return null;
    // The way from `node` up to the root.
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(gpa);
    var n = node;
    while (true) {
        try path.append(gpa, n);
        if (n == 0) break;
        n = h.nodes.items[n].parent;
    }
    var cursor: ?usize = null;
    // Up, until we stand on that way...
    while (std.mem.indexOfScalar(u32, path.items, h.current) == null) cursor = try h.undo(gpa, target);
    // ...then down it.
    var at = std.mem.indexOfScalar(u32, path.items, h.current).?;
    while (at > 0) {
        at -= 1;
        h.nodes.items[h.current].redo_child = path.items[at];
        cursor = try h.redo(gpa, target);
    }
    return cursor;
}

const testing = std.testing;

test "goTo reaches a state on another branch" {
    const gpa = testing.allocator;
    var t = try Text.init(gpa, "");
    defer t.deinit(gpa);
    var h = try History.init(gpa);
    defer h.deinit(gpa);
    try apply(&h, &t, .ins, 0, "a");
    try h.commit(gpa); // node 1: "a"
    try apply(&h, &t, .ins, 1, "b");
    try h.commit(gpa); // node 2: "ab"
    _ = try h.undo(gpa, &t);
    try apply(&h, &t, .ins, 1, "c");
    try h.commit(gpa); // node 3: "ac", a second branch
    _ = try h.goTo(gpa, 2, &t);
    try testing.expectEqualStrings("ab", t.slice(0, t.len()));
    _ = try h.goTo(gpa, 0, &t);
    try testing.expectEqualStrings("", t.slice(0, t.len()));
    _ = try h.goTo(gpa, 3, &t);
    try testing.expectEqualStrings("ac", t.slice(0, t.len()));
}

fn apply(h: *History, t: *Text, kind: enum { ins, del }, pos: usize, s: []const u8) !void {
    const gpa = testing.allocator;
    switch (kind) {
        .ins => {
            try h.recordInsert(gpa, pos, s, pos);
            try t.insert(gpa, pos, s);
        },
        .del => {
            try h.recordDelete(gpa, pos, t.slice(pos, pos + s.len), pos);
            t.delete(pos, pos + s.len);
        },
    }
}

fn expectText(t: *const Text, s: []const u8) !void {
    try testing.expectEqualStrings(s, t.slice(0, t.len()));
}

test "undo, redo, and branching keeps both histories reachable" {
    const gpa = testing.allocator;
    var t = try Text.init(gpa, "abc");
    defer t.deinit(gpa);
    var h = try History.init(gpa);
    defer h.deinit(gpa);

    // Typing merges into one insert op; one commit = one undo step.
    try apply(&h, &t, .ins, 3, "d");
    try apply(&h, &t, .ins, 4, "e");
    try h.commit(gpa);
    try expectText(&t, "abcde");
    try testing.expectEqual(1, h.nodes.items[1].ops.len);

    try apply(&h, &t, .del, 0, "a");
    try h.commit(gpa);
    try expectText(&t, "bcde");

    _ = try h.undo(gpa, &t);
    try expectText(&t, "abcde");
    _ = try h.undo(gpa, &t);
    try expectText(&t, "abc");
    try testing.expect(!h.isModified());
    try testing.expectEqual(null, try h.undo(gpa, &t));

    _ = try h.redo(gpa, &t);
    try expectText(&t, "abcde");

    // A new edit branches off "abcde"; redo now follows the new branch.
    try apply(&h, &t, .ins, 0, "X");
    try h.commit(gpa);
    _ = try h.undo(gpa, &t);
    _ = try h.redo(gpa, &t);
    try expectText(&t, "Xabcde");
}

test "backspace runs merge into one delete" {
    const gpa = testing.allocator;
    var t = try Text.init(gpa, "hello");
    defer t.deinit(gpa);
    var h = try History.init(gpa);
    defer h.deinit(gpa);
    try apply(&h, &t, .del, 4, "o");
    try apply(&h, &t, .del, 3, "l");
    try h.commit(gpa);
    try testing.expectEqual(1, h.nodes.items[1].ops.len);
    _ = try h.undo(gpa, &t);
    try expectText(&t, "hello");
}
