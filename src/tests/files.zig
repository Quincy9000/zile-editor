//! Editor tests: files.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Session = @import("../Session.zig");
const state_files = @import("../editor/state_files.zig");
const project_ops = @import("../editor/project_ops.zig");
const Editor = @import("../Editor.zig");
const PromptKind = Editor.PromptKind;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const expectCursor = support.expectCursor;
const waitForRun = support.waitForRun;
const settlePicker = support.settlePicker;

test "files: SPC SPC lists the project's folder; typing finds files below it; src/ goes in" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    settlePicker(&ed);
    const p = ed.picker.?;
    // Nothing typed: just the folder's own entries (folders first).
    try testing.expect(std.mem.endsWith(u8, p.itemAt(0).?.text, "/"));
    const entries = p.rowCount();
    try testing.expect(entries < 100);
    for (0..entries) |i| try testing.expect(std.mem.indexOfScalar(u8, std.mem.trimEnd(u8, p.itemAt(i).?.text, "/"), '/') == null);
    // Typing: a file deep inside comes up.
    try ed.feed("pairs.zig");
    settlePicker(&ed);
    try testing.expectEqualStrings("src/pairs.zig", ed.picker.?.itemAt(0).?.text);
    // src/ goes into that folder; its entries again.
    try ed.feed("<C-u>src/");
    settlePicker(&ed);
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/src"));
    try ed.feed("Editor.z");
    settlePicker(&ed);
    try testing.expectEqualStrings("Editor.zig", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/Editor.zig"));
}

test "buffers: open, switch back via picker, kill" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-missing-a.txt"); // replaces the scratch buffer
    try testing.expectEqual(1, ed.buffers.items.len);
    try ed.openFile("./edit-test-missing-b.txt");
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.openFile("edit-test-missing-b.txt"); // already open: no duplicate
    try testing.expectEqual(2, ed.buffers.items.len);

    try ed.feed("<Space>b<CR>"); // top entry is the previous buffer
    try testing.expectEqualStrings("edit-test-missing-a.txt", ed.buffer.path.?);

    try ed.feed("<cmd:kill_buffer>");
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expectEqualStrings("edit-test-missing-b.txt", ed.buffer.path.?);
}

test "file picker offers to create a missing file" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>no/such/file-xyz.txt");
    const p = ed.picker.?;
    p.sync();
    try testing.expectEqual(0, p.createRow().?);
    try ed.feed("<CR>");
    try testing.expectEqualStrings("no/such/file-xyz.txt", ed.buffer.path.?);
    try testing.expect(!ed.buffer.modified); // nothing written until saved
}

test "autosave on leaving a file; the cursor and undo come back next time" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const a = try std.fs.path.join(gpa, &.{ dir, "a.txt" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ dir, "b.txt" });
    defer gpa.free(b);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "other\n" });
    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = dir;
        try ed.openFile(a);
        try ed.feed("jjAx<Esc>");
        try ed.openFile(b); // leaving a.txt saves it
        ed.tick(); // ...and keeps its undo history
        const saved = try tmp.dir.readFileAlloc(testing.io, "a.txt", gpa, .limited(1024));
        defer gpa.free(saved);
        try testing.expectEqualStrings("one\ntwo\nthreex\n", saved);
        state_files.rememberPositions(&ed);
        state_files.saveVisits(&ed);
    }
    var ed = try testEditor("");
    defer ed.deinit();
    ed.state_dir = dir;
    try ed.openFile(a);
    try testing.expectEqual(2, ed.cursorLine()); // where it was left
    try ed.feed("u"); // the edit from last time undoes
    try expectText(&ed, "one\ntwo\nthree");
}

test "saving a TypeScript file with no servers running still saves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "a.ts" });
    defer testing.allocator.free(path);
    var ed = try testEditor("");
    defer ed.deinit();
    ed.options.format_on_save = false;
    try ed.openFile(path);
    try ed.feed("iconst x = 1;<Esc><Space>s");
    try testing.expect(ed.save_chain == null);
    const saved = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .limited(64));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("const x = 1;\n", saved);
}

test "opening a file: its cursor's line is centred in the window, not at the edge" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    for (0..300) |i| try lines.print(gpa, "line {d}\n", .{i});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "long.txt", .data = lines.items });
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const path = try std.fs.path.join(gpa, &.{ dir, "long.txt" });
    defer gpa.free(path);
    var ed = try testEditor("");
    defer ed.deinit();
    ed.setViewSize(40, 80);
    // A jump far into it: the line in the middle.
    try ed.jumpTo(path, 200, 0);
    ed.setViewSize(40, 80); // the next frame
    try testing.expectEqual(200, ed.cursorLine());
    try testing.expectEqual(180, ed.view.top);
    // Within the view: no scrolling.
    try ed.jumpTo(path, 205, 0);
    try testing.expectEqual(180, ed.view.top);
    try ed.jumpTo(path, 20, 0);
    try testing.expectEqual(0, ed.view.top);
}

test "start screen: a menu; q quits zile, f finds a file, Esc leaves it" {
    {
        var ed = try testEditor("");
        defer ed.deinit();
        try state_files.openStarter(&ed);
        settlePicker(&ed);
        try ed.feed("q");
        try testing.expect(ed.should_quit);
    }
    {
        var ed = try testEditor("");
        defer ed.deinit();
        try state_files.openStarter(&ed);
        settlePicker(&ed);
        try ed.feed("f");
        try testing.expectEqual(.browse, ed.picker.?.kind);
        try ed.feed("<Esc><Esc>");
        try state_files.openStarter(&ed);
        try ed.feed("<Esc>");
        try testing.expectEqual(null, ed.picker);
        try testing.expect(!ed.should_quit);
    }
}

test "files: a typed folder path goes there (/ or Enter); c works there (cd)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "one/two");
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>");
    var typed: [Io.Dir.max_path_bytes + 16]u8 = undefined;
    // An absolute path, then /: into it.
    try ed.feed(try std.fmt.bufPrint(&typed, "<C-u>{s}/one/", .{dir}));
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/one"));
    // A path typed out, then Enter: into it (not a new file named so).
    try ed.feed(try std.fmt.bufPrint(&typed, "{s}/one/two<CR>", .{dir}));
    try testing.expect(ed.picker != null);
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/one/two"));
    // c: work here.
    try ed.feed("<Esc>c");
    try testing.expect(std.mem.endsWith(u8, project_ops.projectRoot(&ed), "/one/two"));
    try ed.feed("<Esc>");
}

test "hex: a binary file opens as a hex dump; saving writes the bytes" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.bin", .data = "\x00\x01ABC\xff" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fs.path.join(gpa, &.{ dir, "a.bin" });
    defer gpa.free(path);
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(path);
    try testing.expect(ed.buffer.hex);
    try expectText(&ed, "00000000: 0001 4142 43ff                           ..ABC.");
    // Change the byte `41` (A) to `61` (a): `r6` on its first digit.
    try ed.feed("0f4r6");
    try ed.feed("<cmd:save_file>");
    const back = try tmp.dir.readFileAlloc(testing.io, "a.bin", gpa, .limited(64));
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, "\x00\x01aBC\xff", back);
    // Not hex: refused, the file as it was.
    try ed.feed("0f6rz");
    try ed.feed("<cmd:save_file>");
    try testing.expect(std.mem.startsWith(u8, ed.message.text(), "not saved"));
}

test "search buffer picker jumps to the line" {
    var ed = try testEditor("one\ntwo\nthree");
    defer ed.deinit();
    try ed.feed("<cmd:search_buffer>thr<CR>");
    try expectCursor(&ed, 2, 0);
}

test "files: save as, rename, copy, delete, new" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const at = struct {
        fn path(d: []const u8, name: []const u8) ![]u8 {
            return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ d, name });
        }
    }.path;
    const a = try at(dir, "a.txt");
    defer gpa.free(a);
    const b = try at(dir, "sub/b.zig");
    defer gpa.free(b);
    const c = try at(dir, "c.zig");
    defer gpa.free(c);

    var ed = try testEditor("");
    defer ed.deinit();

    // A scratch buffer: SPC s asks for a name, then saves there.
    try ed.feed("ihello<Esc><Space>s");
    try testing.expectEqual(PromptKind.save_as, ed.search_prompt.?.kind);
    try ed.search_prompt.?.input.set(gpa, a);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, a, ed.buffer.path.?));
    try testing.expect(!ed.buffer.modified);
    const saved = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(1024));
    defer gpa.free(saved);
    try testing.expectEqualStrings("hello\n", saved);

    // Rename into a new folder: the file moves and the language follows.
    try ed.feed("<cmd:rename_file>");
    try testing.expect(std.mem.endsWith(u8, a, ed.search_prompt.?.input.items())); // prefilled
    try ed.search_prompt.?.input.set(gpa, b);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, b, ed.buffer.path.?));
    try testing.expect(ed.buffer.syntax != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "a.txt", .{}));
    try tmp.dir.access(io, "sub/b.zig", .{});

    // Copy: writes a copy (unsaved edits included) and opens it; the
    // original keeps its unsaved state (with autosave off: else leaving it
    // saves it).
    ed.options.autosave = false;
    try ed.feed("A!<Esc><cmd:copy_file>");
    try ed.search_prompt.?.input.set(gpa, c);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, c, ed.buffer.path.?));
    try testing.expectEqualStrings("hello!", ed.text().slice(0, ed.text().len()));
    try testing.expect(ed.buffers.items[0].modified);

    // Refuses to overwrite an existing file.
    try ed.feed("<cmd:save_file_as>");
    try ed.search_prompt.?.input.set(gpa, b);
    try ed.feed("<CR>");
    try testing.expectEqual(.err, ed.message.kind);
    try testing.expect(std.mem.endsWith(u8, c, ed.buffer.path.?));

    // Delete: "No" keeps it, "Yes" removes it and closes the buffer.
    try ed.feed("<cmd:delete_file><CR>");
    try tmp.dir.access(io, "c.zig", .{});
    try ed.feed("<cmd:delete_file>j<CR>"); // the confirmation starts in normal mode: j to "Yes"
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "c.zig", .{}));
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expect(std.mem.endsWith(u8, b, ed.buffer.path.?));

    // New file: prefilled with the current folder; created on first save.
    try ed.feed("<cmd:new_file>");
    try testing.expect(std.mem.endsWith(u8, ed.search_prompt.?.input.items(), "sub/"));
    try ed.feed("new.txt<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "sub/new.txt"));
    try testing.expectEqual(2, ed.buffers.items.len);
}

test "file browser: into folders, up, open, create" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.txt", .data = "hi\n" });
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    const readme = try std.fmt.allocPrint(gpa, "{s}/readme.txt", .{dir});
    defer gpa.free(readme);
    try ed.openFile(readme);

    const rows = struct {
        fn get(e: *Editor, i: usize) []const u8 {
            e.picker.?.sync();
            return e.picker.?.itemAt(i).?.text;
        }
    }.get;

    // Opens in the file's folder: folders first.
    try ed.feed("<Space>.");
    try testing.expectEqualStrings(dir, ed.browse_dir.items);
    try testing.expectEqualStrings("src/", rows(&ed, 0));
    try testing.expectEqualStrings("readme.txt", rows(&ed, 1));

    // Enter on a folder goes in (`/` with nothing typed starts a path at
    // the root); typing filters; <BS> edits, then goes up and selects the
    // folder we came from.
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/src"));
    try testing.expectEqualStrings("deep/", rows(&ed, 0));
    try ed.feed("ma");
    try testing.expectEqualStrings("main.zig", rows(&ed, 0));
    try ed.feed("<BS><BS><BS>");
    try testing.expectEqualStrings(dir, ed.browse_dir.items);
    ed.picker.?.sync();
    try testing.expectEqual(0, ed.picker.?.selected); // "src/"
    try ed.feed("<Down><BS>");
    ed.picker.?.sync();
    // Up from tmp dir; then back down via <CR> on a folder.
    try ed.feed("<Esc><Esc><Space>.<CR>ma<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    try testing.expect(ed.picker == null);

    // A new name offers to create it in the browsed folder.
    try ed.feed("<Space>.new.zig<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/new.zig"));
}

test "buffers: new, last, kill others" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-a.txt");
    const a = ed.buffer;
    try ed.feed("<cmd:new_buffer>");
    try testing.expect(ed.buffer != a);
    try ed.feed("<cmd:last_buffer>");
    try testing.expectEqual(a, ed.buffer);
    try ed.feed("<cmd:new_buffer><cmd:new_buffer><cmd:kill_other_buffers>");
    try testing.expectEqual(1, ed.buffers.items.len);
}

test "projects: each window's pickers, git and runner use its file's project" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "alpha/.git");
    try tmp.dir.createDirPath(io, "alpha/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha/src/a.txt", .data = "a\n" });
    try tmp.dir.createDirPath(io, "beta/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "beta/b.txt", .data = "b\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fmt.allocPrint(gpa, "{s}/alpha/src/a.txt", .{base});
    defer gpa.free(a);
    const b = try std.fmt.allocPrint(gpa, "{s}/beta/b.txt", .{base});
    defer gpa.free(b);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ base, "run-commands" });
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);

    try ed.openFile(a);
    try testing.expectEqualStrings("alpha", project_ops.project(&ed).?.name());
    try testing.expect(std.mem.endsWith(u8, project_ops.gitRoot(&ed).?, "/alpha"));
    // The file picker lists alpha, relative to its root, and opens from there.
    try ed.feed("<Space><Space>");
    try testing.expect(std.mem.endsWith(u8, ed.picker_root, "/alpha"));
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/alpha"));
    ed.picker.?.sync();
    try testing.expectEqualStrings("src/", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");

    // The runner remembers per project.
    try ed.feed("<cmd:run_runner>echo alpha<CR>");
    waitForRun(&ed);
    try ed.feed("q");

    try ed.feed("<cmd:split_right>");
    try ed.openFile(b);
    try testing.expectEqualStrings("beta", project_ops.project(&ed).?.name());
    try ed.feed("<Space><Space>");
    try testing.expect(std.mem.endsWith(u8, ed.picker_root, "/beta"));
    try ed.feed("<Esc><Esc><cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try ed.feed("<Esc><Esc><cmd:window_left><cmd:run_runner>"); // back in alpha's window
    settlePicker(&ed);
    try testing.expectEqualStrings("echo alpha", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
}

test "paths: trailing slashes and .. resolve; a folder argument opens the explorer" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    const inside = try ed.normalizePath("./src/../src/main.zig/");
    defer gpa.free(inside);
    try testing.expectEqualStrings("src/main.zig", inside);
    const outside = try ed.normalizePath("../elsewhere/x.zig");
    defer gpa.free(outside);
    try testing.expect(std.fs.path.isAbsolute(outside));
    try testing.expect(std.mem.indexOf(u8, outside, "..") == null);

    ed.openArg("src/main.zig/");
    try testing.expectEqualStrings("src/main.zig", ed.buffer.path.?);
    ed.openArg("src");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/src"));
}

test "SPC b Enter flips to the previous buffer" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    try ed.openFile("src/format.zig");
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "pairs.zig"));
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "format.zig"));
}

test "visits, recent files and sessions survive a restart" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/a.txt", .data = "a1\na2\na3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/b.txt", .data = "b1\nb2\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const state = try std.fs.path.join(gpa, &.{ base, "state" });
    defer gpa.free(state);
    const a = try std.fmt.allocPrint(gpa, "{s}/proj/a.txt", .{base});
    defer gpa.free(a);
    const b = try std.fmt.allocPrint(gpa, "{s}/proj/b.txt", .{base});
    defer gpa.free(b);
    const root = try std.fmt.allocPrint(gpa, "{s}/proj", .{base});
    defer gpa.free(root);

    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = state;
        ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
        try ed.openFile(b);
        try ed.openFile(a);
        try ed.feed("jj"); // a.txt: line 3
        try ed.feed("<cmd:split_right>");
        try ed.openFile(b);
        try ed.feed("j");
        try testing.expect(!Session.exists(&ed, root));
        try ed.feed("<Space>p<Esc>s"); // the projects picker: s saves the session
        try testing.expect(Session.exists(&ed, root));
        try ed.feed("<Esc>");
        // deinit saves the visits.
    }
    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = state;
        ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
        // b.txt was opened most.
        try ed.feed("<cmd:recent_files>");
        settlePicker(&ed);
        try testing.expect(std.mem.endsWith(u8, ed.picker.?.itemAt(0).?.text, "b.txt"));
        try testing.expectEqual(2, ed.picker.?.rowCount());
        try ed.feed("<Esc><Esc>");

        try testing.expect(state_files.restoreSession(&ed, root));
        try testing.expectEqual(2, ed.window_list.items.len);
        try testing.expectEqual(2, ed.buffers.items.len);
        // Focus is back in the right-hand window, on b.txt line 2.
        try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "b.txt"));
        try testing.expectEqual(1, ed.cursorLine());
        try ed.feed("<cmd:window_left>");
        try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "a.txt"));
        try testing.expectEqual(2, ed.cursorLine());
    }
}

test "file browser: new folder and file, rename, move, copy and paste, delete" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    try tmp.dir.createDirPath(io, "sub");
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const exists = struct {
        fn at(d: Io.Dir, name: []const u8) bool {
            d.access(testing.io, name, .{}) catch return false;
            return true;
        }
    }.at;

    var ed = try testEditor("");
    defer ed.deinit();
    const a = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{base});
    defer gpa.free(a);
    try ed.openFile(a);
    try ed.feed("<Space>.<Esc>"); // the browser, in normal mode
    settlePicker(&ed);
    try testing.expectEqual(.browse, ed.picker.?.kind);

    try ed.feed("onewdir<CR>"); // o: a folder; back in the browser, on it
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "newdir"));
    try testing.expectEqualStrings("newdir/", ed.picker.?.itemAt(ed.picker.?.selected).?.text);

    try ed.feed("ggjj"); // newdir/, sub/, a.txt
    settlePicker(&ed);
    try testing.expectEqualStrings("a.txt", ed.picker.?.itemAt(ed.picker.?.selected).?.text);
    try ed.feed("yyp"); // copy, paste beside itself
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "a copy.txt"));

    try ed.feed("r<C-u>b.txt<CR>"); // rename the copy (selected after the paste)
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "b.txt"));
    try testing.expect(!exists(tmp.dir, "a copy.txt"));

    // Move the open file into sub/: its buffer follows.
    try ed.feed("gg");
    settlePicker(&ed);
    while (!std.mem.eql(u8, ed.picker.?.itemAt(ed.picker.?.selected).?.text, "a.txt")) {
        try ed.feed("j");
        settlePicker(&ed);
    }
    try ed.feed("m<C-u>sub/a.txt<CR>");
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "sub/a.txt"));
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "sub/a.txt"));
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/sub"));

    // Delete asks; No keeps, Yes removes and closes its buffer.
    try ed.feed("x");
    try testing.expectEqual(.confirm_remove, ed.picker.?.kind);
    settlePicker(&ed);
    try ed.feed("<CR>"); // "No" is first
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "sub/a.txt"));
    try ed.feed("ddj<CR>");
    settlePicker(&ed);
    try testing.expect(!exists(tmp.dir, "sub/a.txt"));
    try testing.expectEqual(null, ed.buffer.path);
    // Esc in a prompt goes back to the browser.
    try ed.feed("nxyz<Esc>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed("q");
}

test "buffer picker: x closes the selected buffer in place; pickers take a visual selection" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    try ed.openFile("src/format.zig");
    try ed.feed("<Space>b<Esc>");
    settlePicker(&ed);
    try testing.expectEqualStrings("src/pairs.zig", ed.picker.?.itemAt(0).?.text);
    try ed.feed("x");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    try testing.expectEqual(.picker_normal, ed.mode);
    try ed.feed("q");
    // Visual SPC SPC / SPC /: the selection is the query.
    try ed.feed("<cmd:new_buffer>ihello @import<Esc>0viw<Space><Space>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expectEqualStrings("hello", ed.picker.?.query.items());
    try ed.feed("<Esc><Esc>wviW<Space>/");
    try testing.expectEqual(.grep, ed.picker.?.kind); // not the symbols picker
    try testing.expectEqualStrings(" @import", ed.picker.?.query.items());
    try ed.feed("<Esc><Esc>");
}

test "file browser: typing a name ending in / makes a folder and goes into it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{base});
    defer gpa.free(a);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(a);
    try ed.feed("<Space>.");
    settlePicker(&ed);
    try ed.feed("newdir/"); // nothing matches, so the / is part of the name
    try testing.expectEqualStrings("newdir/", ed.picker.?.query.items());
    settlePicker(&ed);
    try ed.feed("<CR>");
    tmp.dir.access(io, "newdir", .{}) catch return error.FolderNotMade;
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/newdir"));
    // Nested, and a plain name is still a file.
    try ed.feed("x/y/");
    settlePicker(&ed);
    try ed.feed("<CR>");
    tmp.dir.access(io, "newdir/x/y", .{}) catch return error.FolderNotMade;
    try ed.feed("note.txt");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "x/y/note.txt"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "newdir/x/y/note.txt", .{})); // not on disk until saved
}
