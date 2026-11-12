//! A text buffer: contents plus its file association.
//! Undo history, syntax tree and LSP document version will live here too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Text = @import("Text.zig");
const History = @import("History.zig");
const Syntax = @import("../syntax/Syntax.zig");
const Project = @import("Project.zig");
const Folds = @import("Folds.zig");
const diff = @import("../git/diff.zig");
const indent = @import("indent.zig");
const hexdump = @import("hex.zig");

const Buffer = @This();

/// A label to draw before the text at byte offset `pos`; `text` is owned
/// (padding included).
pub const Hint = struct {
    pos: usize,
    text: []u8,
};

text: Text,
history: History,
/// Null for files without a known language.
syntax: ?Syntax = null,
/// The project the file belongs to (owned by the editor), if any.
project: ?*const Project = null,
/// A name for buffers without a file (owned), e.g. a proposed edit.
label: ?[]u8 = null,
/// Its lines are never wrapped, whatever the option says (a table: rows
/// that are cut into pieces can't be read down a column).
no_wrap: bool = false,
/// The file's modification time when last read or written (to notice
/// changes made by other programs).
disk_mtime: ?Io.Timestamp = null,
/// Bumped on every edit (for syncing with the language server).
edit_version: u64 = 0,
/// Closed folds.
folds: Folds = .{},
/// Inlay hints from the language server (type and parameter labels drawn
/// inside the code): sorted by position, kept in place through edits until
/// the server's next answer replaces them.
hints: std.ArrayList(Hint) = .empty,
/// The `edit_version` the hints were asked for (max: never), the lines they
/// cover, whether a request is out, and when the text last changed (hints
/// are asked for again once it has been still for a moment).
hint_version: u64 = std.math.maxInt(u64),
hint_range: [2]usize = .{ 1, 0 },
hint_pending: bool = false,
hint_seen: u64 = 0,
hint_changed: Io.Timestamp = .zero,
/// How the file is indented, worked out when it was read (null: nothing in
/// it is indented, so the editor's defaults apply).
indent_style: ?indent.Style = null,
/// Diff against the file's git HEAD version (null outside a repo or for
/// untracked files).
git: ?diff.State = null,
/// Owned. Relative to the cwd or absolute; null for a scratch buffer.
path: ?[]u8 = null,
modified: bool = false,
/// A binary file, shown as a hex dump (`core/hex.zig`): saving writes the
/// bytes the hex stands for.
hex: bool = false,
/// The file ended with a newline (vim's 'eol'); restored on save. New files get one.
final_newline: bool = true,
/// The file used CRLF line endings; stored as LF, restored on save.
crlf: bool = false,
/// View state while this buffer is not shown.
saved: struct { cursor: usize = 0, top: usize = 0, left: usize = 0 } = .{},
/// Just opened: the first time it is shown its cursor's line is centred
/// (the window's height is known only then).
center_on_show: bool = false,
/// Times written to disk; the editor keeps the undo history on disk in
/// step (`undo_kept` is the count it last did that for).
saves: u64 = 0,
undo_kept: u64 = 0,
/// Code lens: a line of the server's notes (`3 references`) shown above a
/// line, sorted by line. Kept until the next answer replaces them.
lenses: std.ArrayList(Lens) = .empty,
/// The text version lenses were last asked for, and whether an answer is due.
lens_version: u64 = std.math.maxInt(u64),
lens_pending: bool = false,
/// Told when lines are added or removed, so marks kept by line number
/// outside the buffer (breakpoints) stay on their lines.
line_listener: ?LineListener = null,
/// The save count the last compile check (standalone Zig) was for.
checked: u64 = std.math.maxInt(u64),
/// Editor.use_counter when last shown, for most-recently-used ordering.
last_used: u64 = 0,

const max_file_size = 512 * 1024 * 1024;
/// Binary files larger than this aren't opened as hex (the dump is four
/// times the size).
const max_hex_size = 16 * 1024 * 1024;

pub fn initEmpty(gpa: Allocator) Allocator.Error!Buffer {
    var text = try Text.init(gpa, "");
    errdefer text.deinit(gpa);
    return .{ .text = text, .history = try .init(gpa) };
}

/// Opens `path`. A missing file gives an empty buffer that will create it on save.
pub fn load(gpa: Allocator, io: Io, path: []const u8) !Buffer {
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);

    const raw = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => {
            var b = try initEmpty(gpa);
            b.path = owned_path;
            b.syntax = Syntax.forPath(path);
            return b;
        },
        else => return err,
    };
    defer gpa.free(raw);

    // A binary file: its hex dump to edit.
    if (hexdump.isBinary(raw)) {
        if (raw.len > max_hex_size) return error.TooBigForHexView;
        const d = try hexdump.dump(gpa, raw);
        defer gpa.free(d);
        var text = try Text.init(gpa, d);
        errdefer text.deinit(gpa);
        const mtime: ?Io.Timestamp = if (Io.Dir.cwd().statFile(io, path, .{})) |st| st.mtime else |_| null;
        return .{ .disk_mtime = mtime, .text = text, .history = try .init(gpa), .path = owned_path, .final_newline = false, .hex = true };
    }

    var content: []const u8 = raw;
    var crlf = false;
    var normalized: ?[]u8 = null;
    defer if (normalized) |n| gpa.free(n);
    if (std.mem.indexOfScalar(u8, raw, '\n')) |first_nl| {
        if (first_nl > 0 and raw[first_nl - 1] == '\r') {
            crlf = true;
            normalized = try stripCr(gpa, raw);
            content = normalized.?;
        }
    }

    const final_newline = content.len > 0 and content[content.len - 1] == '\n';
    if (final_newline) content = content[0 .. content.len - 1];

    var text = try Text.init(gpa, content);
    errdefer text.deinit(gpa);
    const mtime: ?Io.Timestamp = if (Io.Dir.cwd().statFile(io, path, .{})) |st| st.mtime else |_| null;
    return .{
        .disk_mtime = mtime,
        .indent_style = indent.detect(&text),
        .text = text,
        .history = try .init(gpa),
        .syntax = Syntax.forFile(path, content),
        .path = owned_path,
        // An empty file has no final newline, but saving it after adding text
        // should produce one, as vim's 'fixeol' does.
        .final_newline = final_newline or content.len == 0,
        .crlf = crlf,
    };
}

fn stripCr(gpa: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, raw.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') continue;
        out.appendAssumeCapacity(raw[i]);
    }
    return out.toOwnedSlice(gpa);
}

/// `stale`: the previous answer's title, kept while the new one is resolved
/// (so the row doesn't vanish and come back).
/// `gone`: its line was deleted (not shown; dropped at the next answer).
pub const Lens = struct { line: u32, text: []u8, stale: bool = false, gone: bool = false };

pub fn clearLenses(b: *Buffer, gpa: Allocator) void {
    for (b.lenses.items) |l| gpa.free(l.text);
    b.lenses.clearRetainingCapacity();
}

pub fn deinit(b: *Buffer, gpa: Allocator) void {
    b.clearLenses(gpa);
    b.lenses.deinit(gpa);
    b.text.deinit(gpa);
    b.history.deinit(gpa);
    if (b.syntax) |*s| s.deinit(gpa);
    b.folds.deinit(gpa);
    for (b.hints.items) |h| gpa.free(h.text);
    b.hints.deinit(gpa);
    if (b.git) |*g| g.deinit(gpa);
    if (b.path) |p| gpa.free(p);
    if (b.label) |l| gpa.free(l);
    b.* = undefined;
}

/// Inserts text, keeping the syntax tree in step. (Undo recording is the
/// editor's job; History replays through these too.)
pub fn insert(b: *Buffer, gpa: Allocator, pos: usize, bytes: []const u8) Allocator.Error!void {
    if (b.syntax) |*s| s.noteInsert(&b.text, pos, bytes);
    b.folds.noteInsert(pos, bytes.len);
    // A hint belongs to the text after it: typing in front of it moves it on.
    for (b.hints.items) |*h| if (h.pos >= pos) {
        h.pos += bytes.len;
    };
    b.shiftLensesForInsert(pos, bytes);
    try b.text.insert(gpa, pos, bytes);
    b.edit_version += 1;
}

pub fn delete(b: *Buffer, start: usize, end: usize) void {
    if (b.syntax) |*s| s.noteDelete(&b.text, start, end);
    b.folds.noteDelete(start, end);
    for (b.hints.items) |*h| {
        if (h.pos >= end) h.pos -= end - start else if (h.pos > start) h.pos = start;
    }
    b.shiftLensesForDelete(start, end);
    b.text.delete(start, end);
    b.edit_version += 1;
}

/// A change in which line is which.
pub const LineEdit = union(enum) {
    /// `added` lines after `line` (before it, with `at_start`: a newline at
    /// the very start of a line moves that line down).
    insert: struct { line: u32, at_start: bool, added: u32 },
    /// Lines `first + 1 ..= last` are gone, joined into `first`.
    delete: struct { first: u32, last: u32 },

    /// Where a mark on `line` is after the edit (on `first`, if its line
    /// was deleted).
    pub fn apply(e: LineEdit, line: u32) u32 {
        return switch (e) {
            .insert => |i| if (line > i.line or (line == i.line and i.at_start)) line + i.added else line,
            .delete => |d| if (line > d.last) line - (d.last - d.first) else if (line > d.first) d.first else line,
        };
    }
};

pub const LineListener = struct {
    ctx: *anyopaque,
    /// Called before the text changes.
    changed: *const fn (ctx: *anyopaque, b: *const Buffer, edit: LineEdit) void,
};

/// Lenses (and the listener's marks) stay on their lines as lines are added
/// above them.
fn shiftLensesForInsert(b: *Buffer, pos: usize, bytes: []const u8) void {
    if (b.lenses.items.len == 0 and b.line_listener == null) return;
    const added: u32 = @intCast(std.mem.count(u8, bytes, "\n"));
    if (added == 0) return;
    const line = b.text.lineOf(pos);
    const edit: LineEdit = .{ .insert = .{ .line = @intCast(line), .at_start = pos == b.text.lineStart(line), .added = added } };
    for (b.lenses.items) |*l| l.line = edit.apply(l.line);
    if (b.line_listener) |l| l.changed(l.ctx, b, edit);
}

/// And as lines are deleted; a lens on a deleted line goes with it.
fn shiftLensesForDelete(b: *Buffer, start: usize, end: usize) void {
    if (b.lenses.items.len == 0 and b.line_listener == null) return;
    const first = b.text.lineOf(start);
    const last = b.text.lineOf(end);
    if (last == first) return;
    const edit: LineEdit = .{ .delete = .{ .first = @intCast(first), .last = @intCast(last) } };
    for (b.lenses.items) |*l| {
        if (l.line > first and l.line <= last) l.gone = true;
        l.line = edit.apply(l.line);
    }
    if (b.line_listener) |l| l.changed(l.ctx, b, edit);
}

pub fn displayName(b: *const Buffer) []const u8 {
    return b.path orelse b.label orelse "[scratch]";
}

pub const SaveError = error{ NoPath, InvalidHex } || Allocator.Error || Io.Dir.CreateFileAtomicError ||
    Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

/// Writes the buffer atomically (temp file + rename), keeping the file's
/// permissions. Returns the number of bytes written.
pub fn save(b: *Buffer, gpa: Allocator, io: Io) SaveError!usize {
    const path = b.path orelse return error.NoPath;
    defer b.saves += 1;
    const dir = Io.Dir.cwd();

    const permissions: Io.File.Permissions = if (dir.statFile(io, path, .{})) |st|
        st.permissions
    else |_|
        .default_file;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const body = b.text.slice(0, b.text.len());
    if (b.hex) {
        // The bytes the hex stands for.
        const bytes = try hexdump.parse(gpa, body);
        defer gpa.free(bytes);
        try out.appendSlice(gpa, bytes);
    } else if (b.crlf) {
        try out.ensureTotalCapacity(gpa, body.len + b.text.lineCount() + 2);
        for (body) |c| {
            if (c == '\n') out.appendAssumeCapacity('\r');
            out.appendAssumeCapacity(c);
        }
    } else {
        try out.appendSlice(gpa, body);
    }
    if (b.final_newline and b.text.len() > 0) {
        try out.appendSlice(gpa, if (b.crlf) "\r\n" else "\n");
    }

    var af = try dir.createFileAtomic(io, path, .{
        .permissions = permissions,
        .make_path = true,
        .replace = true,
    });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, out.items);
    try af.replace(io);

    b.modified = false;
    b.history.markSaved();
    b.disk_mtime = if (dir.statFile(io, path, .{})) |st| st.mtime else |_| null;
    return out.items.len;
}

const testing = std.testing;

test "load strips final newline and CRLF, save restores them" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\r\ntwo\r\n" });
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{path_buf[0..dir_len]});
    defer gpa.free(path);

    var b = try load(gpa, io, path);
    defer b.deinit(gpa);
    try testing.expect(b.crlf);
    try testing.expect(b.final_newline);
    try testing.expectEqual(2, b.text.lineCount());
    try testing.expectEqualStrings("two", b.text.lineSlice(1));

    try b.text.insert(gpa, b.text.len(), "\nthree");
    _ = try b.save(gpa, io);

    const saved = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(1024));
    defer gpa.free(saved);
    try testing.expectEqualStrings("one\r\ntwo\r\nthree\r\n", saved);
}

test "missing file opens empty" {
    const gpa = testing.allocator;
    var b = try load(gpa, testing.io, "/nonexistent-dir-for-edit-test/new.txt");
    defer b.deinit(gpa);
    try testing.expectEqual(1, b.text.lineCount());
    try testing.expectEqual(0, b.text.len());
}
