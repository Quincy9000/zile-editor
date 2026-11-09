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

const Buffer = @This();

text: Text,
history: History,
/// Null for files without a known language.
syntax: ?Syntax = null,
/// The project the file belongs to (owned by the editor), if any.
project: ?*const Project = null,
/// Bumped on every edit (for syncing with the language server).
edit_version: u64 = 0,
/// Closed folds.
folds: Folds = .{},
/// Diff against the file's git HEAD version (null outside a repo or for
/// untracked files).
git: ?diff.State = null,
/// Owned. Relative to the cwd or absolute; null for a scratch buffer.
path: ?[]u8 = null,
modified: bool = false,
/// The file ended with a newline (vim's 'eol'); restored on save. New files get one.
final_newline: bool = true,
/// The file used CRLF line endings; stored as LF, restored on save.
crlf: bool = false,
/// View state while this buffer is not shown.
saved: struct { cursor: usize = 0, top: usize = 0, left: usize = 0 } = .{},
/// Editor.use_counter when last shown, for most-recently-used ordering.
last_used: u64 = 0,

const max_file_size = 512 * 1024 * 1024;

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
    return .{
        .text = text,
        .history = try .init(gpa),
        .syntax = Syntax.forPath(path),
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

pub fn deinit(b: *Buffer, gpa: Allocator) void {
    b.text.deinit(gpa);
    b.history.deinit(gpa);
    if (b.syntax) |*s| s.deinit(gpa);
    b.folds.deinit(gpa);
    if (b.git) |*g| g.deinit(gpa);
    if (b.path) |p| gpa.free(p);
    b.* = undefined;
}

/// Inserts text, keeping the syntax tree in step. (Undo recording is the
/// editor's job; History replays through these too.)
pub fn insert(b: *Buffer, gpa: Allocator, pos: usize, bytes: []const u8) Allocator.Error!void {
    if (b.syntax) |*s| s.noteInsert(&b.text, pos, bytes);
    b.folds.noteInsert(pos, bytes.len);
    try b.text.insert(gpa, pos, bytes);
    b.edit_version += 1;
}

pub fn delete(b: *Buffer, start: usize, end: usize) void {
    if (b.syntax) |*s| s.noteDelete(&b.text, start, end);
    b.folds.noteDelete(start, end);
    b.text.delete(start, end);
    b.edit_version += 1;
}

pub fn displayName(b: *const Buffer) []const u8 {
    return b.path orelse "[scratch]";
}

pub const SaveError = error{NoPath} || Allocator.Error || Io.Dir.CreateFileAtomicError ||
    Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

/// Writes the buffer atomically (temp file + rename), keeping the file's
/// permissions. Returns the number of bytes written.
pub fn save(b: *Buffer, gpa: Allocator, io: Io) SaveError!usize {
    const path = b.path orelse return error.NoPath;
    const dir = Io.Dir.cwd();

    const permissions: Io.File.Permissions = if (dir.statFile(io, path, .{})) |st|
        st.permissions
    else |_|
        .default_file;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const body = b.text.slice(0, b.text.len());
    if (b.crlf) {
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
