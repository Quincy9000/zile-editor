//! Editor tests: windows.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const window_ops = @import("../editor/window_ops.zig");
const Editor = @import("../Editor.zig");
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const settlePicker = support.settlePicker;

test "SPC q: closes the window, then buffers, then the editor" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile("zile-test-a.txt");
    try ed.openFile("zile-test-b.txt");
    try ed.feed("<cmd:split_right>");
    try ed.feed("<Space>q"); // two windows: the focused one goes
    try testing.expectEqual(1, ed.window_list.items.len);
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.feed("<Space>q"); // one window, two buffers: the buffer goes
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expect(!ed.should_quit);
    try ed.feed("<Space>q"); // last of everything: quit
    try testing.expect(ed.should_quit);
}

test "scratch pad: SPC t s opens it below, again closes it (saved)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.state_dir = dir;
    try ed.feed("<cmd:toggle_scratch>");
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "scratch.md"));
    try ed.feed("inote<Esc><cmd:toggle_scratch>");
    try testing.expectEqual(1, ed.window_list.items.len);
    try expectText(&ed, "code");
    const saved = try tmp.dir.readFileAlloc(testing.io, "scratch.md", testing.allocator, .limited(1024));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("note\n", saved);
}

test "SPC Q s saves every modified buffer, then quits; SPC q checks all buffers" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const a = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{dir});
    defer gpa.free(a);
    const b = try std.fmt.allocPrint(gpa, "{s}/b.txt", .{dir});
    defer gpa.free(b);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(a);
    try ed.feed("ialpha<Esc>");
    try ed.openFile(b);
    try ed.feed("ibeta<Esc>[b"); // back to a.txt, which is saved? no: both modified
    try ed.feed("<Space>q");
    try testing.expect(!ed.should_quit); // a.txt is unsaved: not closed
    try ed.feed("<Space>Qs");
    try testing.expect(ed.should_quit);

    const saved_a = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(saved_a);
    try testing.expectEqualStrings("alpha\n", saved_a);
    const saved_b = try tmp.dir.readFileAlloc(io, "b.txt", gpa, .limited(64));
    defer gpa.free(saved_b);
    try testing.expectEqualStrings("beta\n", saved_b);
}

test "windows: split, move, edit in one shows in the other, close" {
    var ed = try testEditor("one\ntwo\nthree");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.feed("<cmd:split_right>"); // split right: focus moves to the new window
    try testing.expectEqual(2, ed.window_list.items.len);
    const right = ed.window;
    try ed.feed("G");
    try ed.feed("<cmd:window_left>");
    try testing.expect(ed.window != right);
    try testing.expectEqual(0, ed.cursorLine()); // each window has its own cursor
    // Typing above shifts the other window's cursor with the text.
    try ed.feed("Onew<Esc>");
    try testing.expectEqual(3, right.view.cursor - ed.text().lineStart(3) + 3);
    try ed.feed("<cmd:window_right>");
    try testing.expectEqual(right, ed.window);
    try testing.expectEqual(3, ed.cursorLine()); // still on "three"
    try ed.feed("<cmd:window_next>"); // wraps to the first window
    try testing.expect(ed.window != right);
    try ed.feed("<cmd:split_down><cmd:window_close><cmd:window_close>");
    try testing.expectEqual(1, ed.window_list.items.len);
    try ed.feed("<cmd:window_close>"); // the last window stays
    try testing.expectEqual(1, ed.window_list.items.len);
}

test "windows: killing a buffer shown in another window" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile("zile-test-a.txt");
    try ed.feed("<cmd:split_right>");
    try ed.openFile("zile-test-b.txt");
    const b = ed.buffer;
    try ed.feed("<cmd:window_left>");
    try ed.feed("<cmd:last_buffer>"); // flip to the other buffer: b, here too
    try testing.expectEqual(b, ed.buffer);
    try ed.feed("<cmd:kill_buffer>");
    // Both windows moved off the killed buffer.
    for (ed.window_list.items) |w| try testing.expect(window_ops.windowBuffer(&ed, w) != b);
}

test "open in: Ctrl-v / Ctrl-s / S-Tab menu split; a project into a split" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/xx.txt", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/yy.txt", .data = "y\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const x = try std.fmt.allocPrint(gpa, "{s}/proj/xx.txt", .{base});
    defer gpa.free(x);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile(x);
    const x_buffer = ed.buffer;

    try ed.feed("<Space><Space>yy");
    ed.picker.?.sync();
    try ed.feed("<C-v>"); // split right
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "yy.txt"));
    try testing.expectEqual(x_buffer, ed.window_list.items[0].buffer); // the old window keeps xx

    try ed.feed("<Space><Space>xx");
    ed.picker.?.sync();
    try ed.feed("<S-Tab>");
    try testing.expectEqual(.open_in, ed.picker.?.kind);
    ed.picker.?.sync();
    try ed.feed("<Down><Down><CR>"); // "Split below"
    try testing.expectEqual(3, ed.window_list.items.len);
    try testing.expectEqual(x_buffer, ed.buffer);

    // A project into a split: the split waits for the file.
    try ed.feed("<Space>p");
    ed.picker.?.sync();
    try ed.feed("<C-v>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expectEqual(3, ed.window_list.items.len);
    try ed.feed("<Esc><Esc>"); // changed our mind: no split
    try testing.expectEqual(3, ed.window_list.items.len);
    try ed.feed("<Space>pp");
    ed.picker.?.sync();
    try ed.feed("<C-s>yy");
    ed.picker.?.sync();
    try ed.feed("<CR>");
    try testing.expectEqual(4, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "yy.txt"));
}

test "zoom keys request a size change" {
    var ed = try testEditor("abc");
    defer ed.deinit();
    try ed.feed("<cmd:zoom_in>");
    try testing.expectEqual(1, ed.zoom_request);
    try ed.feed("<cmd:zoom_out><cmd:zoom_out>");
    try testing.expectEqual(-1, ed.zoom_request);
    try ed.feed("<cmd:zoom_reset>");
    try testing.expect(ed.zoom_reset);
    try expectText(&ed, "abc");
    try testing.expectEqual(.normal, ed.mode);
}

test "SPC w: the windows picker flips, moves, makes, resizes, swaps, maximises" {
    var ed = try testEditor("one\ntwo");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.feed("<Space>w");
    try testing.expectEqual(.windows, ed.picker.?.kind);
    settlePicker(&ed);
    // One window, then the rows that make new ones.
    try testing.expectEqual(4, ed.picker.?.rowCount());
    try testing.expectEqualStrings("+ New window right...", ed.picker.?.itemAt(1).?.text);
    try ed.feed("v"); // split right: two windows, in the new (right) one
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(2, ed.window_list.items.len);
    const right = ed.window;
    try ed.openFile("src/format.zig"); // a file of its own
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    // SPC w Enter: the other window (the one you're in is listed last).
    try ed.feed("<Space>w");
    settlePicker(&ed);
    try testing.expectEqualStrings("here", ed.picker.?.itemAt(1).?.detail);
    try ed.feed("<CR>");
    const left = ed.window;
    try testing.expect(left != right);
    // SPC w w: back and forth between the last two.
    try ed.feed("<Space>ww");
    try testing.expectEqual(right, ed.window);
    try ed.feed("<Space>ww");
    try testing.expectEqual(left, ed.window);
    // h / l: the window that way from here.
    try ed.feed("<Space>wl");
    try testing.expectEqual(right, ed.window);
    try ed.feed("<Space>wh");
    try testing.expectEqual(left, ed.window);
    // > widens the one you're in (the left), whatever row is selected; the
    // list stays.
    const before = left.rect.w;
    try ed.feed("<Space>w>>");
    try testing.expect(ed.picker != null);
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try testing.expect(left.rect.w > before);
    // z: yours maximised; again: back.
    try ed.feed("z");
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try testing.expect(left.rect.w > 80);
    try ed.feed("z");
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try testing.expect(left.rect.w < 80);
    // X: the right window's buffer and this one's trade places.
    const mine = ed.buffer;
    try ed.feed("X<Esc>");
    try testing.expect(ed.buffer != mine);
    try testing.expectEqual(mine, right.buffer);
    // "+ New window right...": the Files picker, and the file opens beside.
    try ed.feed("<Space>w");
    settlePicker(&ed);
    ed.picker.?.selected = 2; // past the two windows
    try ed.feed("<CR>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed("build.zig");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expectEqual(3, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "build.zig"));
    // v splits the window you're in, not the selected row's (another one).
    const here = ed.buffer;
    try ed.feed("<Space>w");
    settlePicker(&ed);
    try testing.expect(!std.mem.eql(u8, "here", ed.picker.?.itemAt(0).?.detail));
    try ed.feed("v");
    try testing.expectEqual(4, ed.window_list.items.len);
    try testing.expectEqual(here, ed.buffer);
}

test "QQ quits without asking, even with unsaved changes; Qq still records" {
    var ed = try testEditor("one");
    defer ed.deinit();
    try ed.feed("Qqxx");
    try testing.expectEqual('q', ed.macro_register.?);
    try ed.feed("Q");
    try testing.expect(!ed.should_quit);
    try ed.feed("QQ");
    try testing.expect(ed.should_quit);
}
