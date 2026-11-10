//! Sessions (mini.sessions): a project's open files, their cursors and the
//! window splits, saved when leaving (quit, `SPC p p`) and restored when
//! coming back. One file per project in `$XDG_STATE_HOME/zile/sessions/`.
//!
//!   zile-session 1
//!   buffer <cursor> <top> <absolute path>     (one per file)
//!   current <buffer index>
//!   split <h|v> <ratio> / leaf <buffer> <cursor> <top> <focused>   (preorder)

const std = @import("std");
const Io = std.Io;
const Editor = @import("Editor.zig");
const Buffer = @import("core/Buffer.zig");
const Windows = @import("Windows.zig");

/// Where `root`'s session is kept. Caller frees. Null when there is no state
/// directory.
pub fn pathFor(ed: *Editor, root: []const u8) ?[]u8 {
    var name: [64]u8 = undefined;
    const n = std.fmt.bufPrint(&name, "sessions/{x:0>16}", .{std.hash.Wyhash.hash(0, root)}) catch return null;
    return ed.statePath(n);
}

pub fn exists(ed: *Editor, root: []const u8) bool {
    const path = pathFor(ed, root) orelse return false;
    defer ed.gpa.free(path);
    Io.Dir.cwd().access(ed.io, path, .{}) catch return false;
    return true;
}

fn inRoot(abs: []const u8, root: []const u8) bool {
    return abs.len > root.len + 1 and std.mem.startsWith(u8, abs, root) and abs[root.len] == '/';
}

/// Saves the current project's session. Returns how many files it holds (0:
/// nothing to save, nothing written).
pub fn save(ed: *Editor) !usize {
    const gpa = ed.gpa;
    const root = ed.projectRoot();
    const path = pathFor(ed, root) orelse return 0;
    defer gpa.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "zile-session 1\n");
    // The project's files, in buffer order.
    var saved: std.ArrayList(*Buffer) = .empty;
    defer saved.deinit(gpa);
    for (ed.buffers.items) |b| {
        const p = b.path orelse continue;
        const abs = try ed.absolutePath(p);
        defer gpa.free(abs);
        if (!inRoot(abs, root)) continue;
        const top = if (b == ed.buffer) ed.view.top else b.saved.top;
        try out.print(gpa, "buffer {d} {d} {s}\n", .{ ed.cursorOf(b), top, abs });
        try saved.append(gpa, b);
    }
    if (saved.items.len == 0) return 0;
    if (std.mem.indexOfScalar(*Buffer, saved.items, ed.buffer)) |i| try out.print(gpa, "current {d}\n", .{i});

    // The splits, unless a terminal sits in one (those aren't restored).
    const plain = ed.cmd_float == null and for (ed.window_list.items) |w| {
        if (w.term != null) break false;
    } else true;
    if (plain and ed.window_list.items.len > 1) try writeNode(ed, ed.windows.root, saved.items, &out);

    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(ed.io, dir);
    try Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = path, .data = out.items });
    return saved.items.len;
}

fn writeNode(ed: *Editor, n: *const Windows.Node, saved: []const *Buffer, out: *std.ArrayList(u8)) !void {
    switch (n.kind) {
        .window => |w| {
            const v = ed.windowView(w);
            const index: isize = if (std.mem.indexOfScalar(*Buffer, saved, ed.windowBuffer(w))) |i| @intCast(i) else -1;
            try out.print(ed.gpa, "leaf {d} {d} {d} {d}\n", .{ index, v.cursor, v.top, @intFromBool(w == ed.window) });
        },
        .split => |s| {
            try out.print(ed.gpa, "split {s} {d:.4}\n", .{ if (s.axis == .horizontal) "h" else "v", s.ratio });
            try writeNode(ed, s.first, saved, out);
            try writeNode(ed, s.second, saved, out);
        },
    }
}

const Node = union(enum) {
    leaf: struct { buffer: isize, cursor: usize, top: usize, focused: bool },
    split: struct { axis: Windows.Axis, ratio: f32 },
};

/// Opens `root`'s session: its files, then its splits. Returns how many
/// files opened (0 when there is no session).
pub fn restore(ed: *Editor, root: []const u8) !usize {
    const gpa = ed.gpa;
    const path = pathFor(ed, root) orelse return 0;
    defer gpa.free(path);
    const data = Io.Dir.cwd().readFileAlloc(ed.io, path, gpa, .limited(4 << 20)) catch return 0;
    defer gpa.free(data);

    var buffers: std.ArrayList(?*Buffer) = .empty;
    defer buffers.deinit(gpa);
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(gpa);
    var current: ?usize = null;
    var opened: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "zile-session 1")) return 0;
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, line, ' ');
        const what = it.next() orelse continue;
        if (std.mem.eql(u8, what, "buffer")) {
            const cursor = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
            const top = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
            const file = it.rest();
            // A file deleted since then is skipped (its slot stays, so
            // indexes still line up).
            const there = if (Io.Dir.cwd().access(ed.io, file, .{})) |_| true else |_| false;
            if (!there or file.len == 0) {
                try buffers.append(gpa, null);
                continue;
            }
            ed.openFile(file) catch {
                try buffers.append(gpa, null);
                continue;
            };
            place(ed, cursor, top);
            try buffers.append(gpa, ed.buffer);
            opened += 1;
        } else if (std.mem.eql(u8, what, "current")) {
            current = std.fmt.parseInt(usize, it.rest(), 10) catch null;
        } else if (std.mem.eql(u8, what, "leaf")) {
            const b = std.fmt.parseInt(isize, it.next() orelse continue, 10) catch continue;
            const cursor = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
            const top = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
            try nodes.append(gpa, .{ .leaf = .{ .buffer = b, .cursor = cursor, .top = top, .focused = std.mem.eql(u8, it.rest(), "1") } });
        } else if (std.mem.eql(u8, what, "split")) {
            const axis = it.next() orelse continue;
            const ratio = std.fmt.parseFloat(f32, it.rest()) catch 0.5;
            try nodes.append(gpa, .{ .split = .{
                .axis = if (std.mem.eql(u8, axis, "h")) .horizontal else .vertical,
                .ratio = std.math.clamp(ratio, 0.05, 0.95),
            } });
        }
    }
    if (opened == 0) return 0;

    if (nodes.items.len > 1) {
        ed.focusEditorWindow();
        try ed.onlyWindow();
        var i: usize = 0;
        var focus: ?*Windows.Window = null;
        build(ed, nodes.items, &i, buffers.items, &focus) catch {};
        if (focus) |w| ed.focusWindow(w);
    } else if (current) |c| {
        if (c < buffers.items.len) if (buffers.items[c]) |b| ed.switchTo(b);
    }
    return opened;
}

fn place(ed: *Editor, cursor: usize, top: usize) void {
    const t = ed.text();
    ed.setCursor(@min(cursor, t.len()));
    ed.view.top = @min(top, t.lineCount() - 1);
    ed.view.top_ghost = null;
    ed.scrollToCursor();
}

/// Rebuilds the subtree at `nodes[i]` inside the focused window.
fn build(ed: *Editor, nodes: []const Node, i: *usize, buffers: []const ?*Buffer, focus: *?*Windows.Window) !void {
    if (i.* >= nodes.len) return error.BadSession;
    const n = nodes[i.*];
    i.* += 1;
    switch (n) {
        .leaf => |l| {
            if (l.buffer >= 0 and l.buffer < buffers.len) if (buffers[@intCast(l.buffer)]) |b| {
                ed.switchTo(b);
                place(ed, l.cursor, l.top);
            };
            if (l.focused) focus.* = ed.window;
        },
        .split => |s| {
            const old = ed.window;
            try ed.splitWindow(if (s.axis == .horizontal) .right else .down);
            const new = ed.window;
            if (new.node.parent) |p| switch (p.kind) {
                .split => |*sp| sp.ratio = s.ratio,
                .window => {},
            };
            ed.focusWindow(old);
            try build(ed, nodes, i, buffers, focus);
            ed.focusWindow(new);
            try build(ed, nodes, i, buffers, focus);
        },
    }
}
