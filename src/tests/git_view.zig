//! Editor tests: the git pickers (changes, files, history, a commit's
//! files) and a file side by side with an older version of itself.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Editor = @import("../Editor.zig");
const compare = @import("../editor/compare.zig");
const row_model = @import("../editor/row_model.zig");
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;

/// A repository in /tmp (not under the checkout the tests run in) with one
/// commit: `a.txt` (five lines) and `b.txt`.
const Repo = struct {
    dir: []u8,

    fn init(name: []const u8) !Repo {
        const gpa = testing.allocator;
        const io = testing.io;
        const dir = try std.fmt.allocPrint(gpa, "/tmp/zile-test-{s}-{d}", .{ name, Io.Timestamp.now(io, .real).nanoseconds });
        errdefer gpa.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
        const r: Repo = .{ .dir = dir };
        try r.write("a.txt", "one\ntwo\nthree\nfour\nfive\n");
        try r.write("b.txt", "bee\n");
        for ([_][]const []const u8{
            &.{ "init", "-q", "-b", "main" },
            &.{ "config", "user.email", "test@example.com" },
            &.{ "config", "user.name", "Test" },
            &.{ "add", "." },
            &.{ "commit", "-q", "-m", "first things" },
        }) |args| try r.git(args);
        return r;
    }

    fn deinit(r: Repo) void {
        Io.Dir.cwd().deleteTree(testing.io, r.dir) catch {};
        testing.allocator.free(r.dir);
    }

    fn git(r: Repo, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ "git", "-C", r.dir });
        try argv.appendSlice(testing.allocator, args);
        const out = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items });
        testing.allocator.free(out.stderr);
        testing.allocator.free(out.stdout);
    }

    fn write(r: Repo, name: []const u8, data: []const u8) !void {
        const file = try r.path(name);
        defer testing.allocator.free(file);
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = data });
    }

    fn path(r: Repo, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ r.dir, name });
    }
};

test "SPC g: a row for each change with its diff; r restores one; C-t goes on to files, history, a commit's files" {
    const repo = try Repo.init("gitview");
    defer repo.deinit();
    // Two changes to a.txt (a line changed, two added at the end), a new file.
    try repo.write("a.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\n");
    try repo.write("c.txt", "sea\n");
    const a = try repo.path("a.txt");
    defer testing.allocator.free(a);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(a);
    try ed.feed("<cmd:git_changes>");
    support.settlePicker(&ed);
    const p = ed.picker.?;
    try testing.expectEqual(.git_hunks, p.kind);
    try testing.expectEqual(3, p.rowCount());
    try testing.expect(std.mem.endsWith(u8, p.itemAt(0).?.text, "a.txt:2"));
    try testing.expectEqualStrings("+1 -1", p.itemAt(0).?.detail);
    try testing.expect(std.mem.endsWith(u8, p.itemAt(1).?.text, "a.txt:6"));
    try testing.expectEqualStrings("+2", p.itemAt(1).?.detail);
    try testing.expectEqualStrings("new file", p.itemAt(2).?.detail);
    // The preview is the change, with the lines around it.
    p.updatePreview();
    try testing.expect(p.preview.diff);
    try testing.expect(std.mem.indexOf(u8, p.preview.text.items, "-two\n+TWO") != null);
    try testing.expect(std.mem.indexOf(u8, p.preview.text.items, " one\n") != null);
    // r: HEAD's line is back (in the buffer, undoable).
    try ed.feed("r");
    try testing.expectEqual(null, ed.picker);
    try expectText(&ed, "one\ntwo\nthree\nfour\nfive\nsix\nseven");
    try ed.feed("u");
    try expectText(&ed, "one\nTWO\nthree\nfour\nfive\nsix\nseven");

    // Enter on the second change goes there.
    try ed.feed("gg<cmd:git_changes>");
    support.settlePicker(&ed);
    try ed.feed("j<CR>");
    try testing.expectEqual(5, ed.cursorLine());

    // C-t: the changed files, then the history.
    try ed.feed("<cmd:git_changes>");
    support.settlePicker(&ed);
    try ed.feed("<C-t>");
    support.settlePicker(&ed);
    try testing.expectEqual(.git_changes, ed.picker.?.kind);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    ed.picker.?.updatePreview();
    try testing.expect(ed.picker.?.preview.diff);
    try ed.feed("<C-t>");
    support.settlePicker(&ed);
    try testing.expectEqual(.git_log, ed.picker.?.kind);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    try testing.expect(std.mem.endsWith(u8, ed.picker.?.itemAt(0).?.text, " first things"));
    ed.picker.?.updatePreview();
    try testing.expect(std.mem.indexOf(u8, ed.picker.?.preview.text.items, "+bee") != null);
    // Enter: the commit's files; Enter on one: it side by side with before.
    try ed.feed("<CR>");
    support.settlePicker(&ed);
    try testing.expectEqual(.git_commit_files, ed.picker.?.kind);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    try testing.expectEqualStrings("a.txt", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(ed.comparing != null);
    try testing.expectEqual(2, ed.window_list.items.len);
    try expectText(&ed, "one\ntwo\nthree\nfour\nfive"); // after, on the right
    try testing.expectEqual(0, ed.comparing.?.old.text.len()); // before: it wasn't there
    try testing.expect(ed.buffer.read_only);
    // q closes it: one window, the file again, our buffers gone.
    const buffers = ed.buffers.items.len;
    try ed.feed("q");
    try testing.expectEqual(null, ed.comparing);
    try testing.expectEqual(1, ed.window_list.items.len);
    try testing.expectEqual(buffers - 2, ed.buffers.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "a.txt"));

    // Enter on a changed file: at its first change, not where the cursor was.
    try ed.feed("G<cmd:git_changed_files>");
    support.settlePicker(&ed);
    try testing.expect(std.mem.endsWith(u8, ed.picker.?.itemAt(0).?.text, "a.txt"));
    try ed.feed("<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(1, ed.cursorLine());
}

test "side by side with HEAD: two windows that show the same rows; the left follows what is typed; again closes it" {
    const repo = try Repo.init("compare");
    defer repo.deinit();
    // "two" became three lines; "five" is gone.
    try repo.write("a.txt", "one\n2a\n2b\n2c\nthree\nfour\n");
    const a = try repo.path("a.txt");
    defer testing.allocator.free(a);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile(a);
    try ed.feed("<cmd:git_compare>");
    const c = ed.comparing.?;
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expectEqual(c.right, ed.window);
    try testing.expectEqual(c.new, ed.buffer);
    try testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive", c.old.text.slice(0, c.old.text.len()));
    try testing.expect(c.old.read_only and c.old.compare == .old and ed.buffer.compare == .new);
    // The cursor is on the first change.
    try testing.expectEqual(1, ed.cursorLine());

    // The right side is short by "five": a blank row after its last line.
    // Rows: one, 2a, 2b, 2c, three, four, [blank]
    try testing.expect(row_model.hasGhosts(&ed));
    try testing.expectEqualStrings("", row_model.ghostText(&ed, 6, 0));
    // The left is short by two beside 2b and 2c.
    // Rows: one, two, [blank], [blank], three, four, five
    {
        const peek = ed.peekWindow(c.left);
        defer ed.unpeekWindow(peek);
        @import("../editor/git_ops.zig").updateGit(&ed);
        try testing.expect(row_model.ghostHunk(&ed, 2) != null);
        try testing.expectEqual(2, row_model.ghostHunk(&ed, 2).?.old_count);
        try testing.expectEqual(null, row_model.ghostHunk(&ed, 5));
    }

    // The windows show the same rows: the right at "2c" (its line 3) puts
    // the left at its second blank row; at "three", at its "three".
    ed.view.top = 3;
    compare.sync(&ed);
    try testing.expectEqual(2, c.left.view.top);
    try testing.expectEqual(1, c.left.view.top_ghost.?);
    ed.view.top = 4;
    compare.sync(&ed);
    try testing.expectEqual(2, c.left.view.top);
    try testing.expectEqual(null, c.left.view.top_ghost);
    ed.view.top = 0;

    // Typing on the right: the left's blank rows follow (2b and 2c gone:
    // none left beside "two").
    try ed.feed("ggjjdddd");
    try expectText(&ed, "one\n2a\nthree\nfour");
    ed.tick();
    {
        const peek = ed.peekWindow(c.left);
        defer ed.unpeekWindow(peek);
        @import("../editor/git_ops.zig").updateGit(&ed);
        try testing.expectEqual(null, row_model.ghostHunk(&ed, 2));
    }

    // The left can't be changed; q there closes the pair.
    try ed.feed("u<cmd:git_compare>");
    try testing.expectEqual(null, ed.comparing);
    try testing.expectEqual(1, ed.window_list.items.len);
    try testing.expectEqual(.none, ed.buffer.compare);
    try testing.expectEqual(1, ed.buffers.items.len);

    // Closing the left window by hand ends it too.
    try ed.feed("<cmd:git_compare>");
    try testing.expect(ed.comparing != null);
    @import("../editor/window_ops.zig").focusWindow(&ed, ed.comparing.?.left);
    try ed.feed("q");
    try testing.expectEqual(null, ed.comparing);
    try testing.expectEqual(1, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "a.txt"));
}
