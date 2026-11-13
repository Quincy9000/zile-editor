//! Editor tests: pickers.

const std = @import("std");
const testing = std.testing;
const notifications = @import("../editor/notifications.zig");
const lsp_actions = @import("../editor/lsp_actions.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const settlePicker = support.settlePicker;

test "leader menus: quit refuses unsaved changes, SPC Q Q forces" {
    var ed = try testEditor("x");
    defer ed.deinit();
    try ed.feed("ia<Esc><Space>Q");
    try testing.expectEqual(.leader_quit, ed.picker.?.kind); // the quit menu
    try ed.feed("<Esc><Space>q"); // smart close, last buffer: quit, but it's unsaved
    try testing.expect(!ed.should_quit);
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("<Space>QQ");
    try testing.expect(ed.should_quit);
}

test "leader menu: rows keep their keys; a selection survives the menus" {
    var ed = try testEditor("hello world");
    defer ed.deinit();
    try ed.feed("<Space>");
    try testing.expectEqual(.leader, ed.picker.?.kind);
    try testing.expectEqual(Mode.picker_normal, ed.mode);
    try ed.feed("t"); // SPC t: the toggles
    try testing.expectEqual(.toggles, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // Visual, through two menus (SPC f f): the selection is the query.
    try ed.feed("0viw<Space>ff");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expectEqualStrings("hello", ed.picker.?.query.items());
    try ed.feed("<Esc><Esc>");
    // i filters the leader menu (its / is grep).
    try ed.feed("<Space>iwindo");
    settlePicker(&ed);
    try testing.expectEqualStrings("Windows", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
}

test "escape leaves the leader menu" {
    var ed = try testEditor("abc");
    defer ed.deinit();
    try ed.feed("<Space>f<Esc>");
    try testing.expectEqual(0, ed.pending_len);
    try testing.expectEqual(null, ed.picker);
    try ed.feed("x"); // a plain command works again
    try expectText(&ed, "bc");
}

test "command picker: fuzzy search and accept" {
    var ed = try testEditor("x");
    defer ed.deinit();
    try ed.feed("ia<Esc>"); // modified, so quit_without_saving is observable
    try ed.feed("<Space>fc");
    try testing.expectEqual(.picker, ed.mode);
    try ed.feed("quitwo<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(ed.should_quit);
}

test "prefix switches sources; Esc closes and resume restores" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed(">savefi");
    try testing.expectEqual(.commands, ed.picker.?.kind);
    try testing.expectEqualStrings("savefi", ed.picker.?.activeQuery());
    ed.picker.?.sync();
    try testing.expectEqualStrings("save_file", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
    try testing.expectEqual(.normal, ed.mode);
    try ed.feed("<Space>'");
    try testing.expectEqualStrings(">savefi", ed.picker.?.query.items());
}

test "picker: vim keys edit the query in normal mode" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openPicker(.commands, "");
    try ed.feed("open file here");
    const q = &ed.picker.?.query;
    try ed.feed("<Esc>");
    try testing.expectEqual(Mode.picker_normal, ed.mode);
    try testing.expectEqual(13, q.cursor); // on the last `e`, like vim
    try ed.feed("bdw");
    try testing.expectEqualStrings("open file ", q.items());
    try ed.feed("0wciwthe<Esc>");
    try testing.expectEqualStrings("open the ", q.items());
    try ed.feed("u");
    try testing.expectEqualStrings("open file ", q.items());
    try ed.feed("0x");
    try testing.expectEqualStrings("pen file ", q.items());
    try ed.feed("Io<Esc>");
    try testing.expectEqualStrings("open file ", q.items());
    try ed.feed("$D");
    try testing.expectEqualStrings("open file", q.items());
    try ed.feed("0yiw$p");
    try testing.expectEqualStrings("open fileopen", q.items());
    try ed.feed("S");
    try testing.expectEqual(Mode.picker, ed.mode);
    try testing.expectEqualStrings("", q.items());
    // Typing goes where the cursor is.
    try ed.feed("ac<Left>b");
    try testing.expectEqualStrings("abc", q.items());
    // j / k still move through the results; Esc closes.
    try ed.feed("<Esc>j<Esc>");
    try testing.expect(ed.picker == null);
}

test "pickers as menus: buffers' actions, the S-Tab menu, toggles, row keys" {
    var ed = try testEditor("main");
    defer ed.deinit();
    // Buffers: n makes one, x closes it, the list stays open and shows it.
    try ed.feed("<Space>b<Esc>n");
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<C-x>"); // while typing: Ctrl-x closes the selected one
    settlePicker(&ed);
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expect(ed.picker != null);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    // Tab: the action menu for the row; "new" from it.
    try ed.feed("<S-Tab>");
    try testing.expectEqual(.open_in, ed.picker.?.kind);
    settlePicker(&ed);
    try ed.feed("inew<CR>");
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.feed("<Esc>");
    // In the Tab menu the keys beside the rows run them too.
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<S-Tab>");
    settlePicker(&ed);
    try ed.feed("n"); // a letter in its normal mode
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(3, ed.buffers.items.len);
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<S-Tab>");
    settlePicker(&ed);
    try ed.feed("<C-x>"); // a Ctrl key: closes the row, the list comes back
    settlePicker(&ed);
    try testing.expectEqual(2, ed.buffers.items.len);
    try testing.expectEqual(.buffers, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // Toggles: Enter flips one and the list stays, with the new state.
    const wrap = ed.options.wrap;
    try ed.feed("<Space>tline wrap");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expectEqual(!wrap, ed.options.wrap);
    try testing.expect(ed.picker != null);
    settlePicker(&ed);
    try testing.expectEqualStrings(if (wrap) "off" else "on", ed.picker.?.itemAt(0).?.detail);
    try ed.feed("<Esc><Esc>");
    try testing.expectEqual(null, ed.picker);
    // A menu: a row's key runs it (W: trim trailing whitespace).
    try ed.text().insert(ed.gpa, 0, "x   ");
    try ed.feed("<Space>l");
    settlePicker(&ed);
    try ed.feed("W");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "x   ") == null);
}

test "jumplist: C-o / C-i, one entry per line, the picker" {
    var ed = try testEditor("a\nb\nc\nd\ne");
    defer ed.deinit();
    try ed.feed("jG"); // from line 2 to the end
    try ed.feed("gg"); // from the end to the top
    try ed.feed("/d<CR>"); // a search is a jump too
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("<C-o>");
    try testing.expectEqual(0, ed.cursorLine());
    try ed.feed("<C-o>");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("<C-o>");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<C-o>"); // nothing older
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<C-i><C-i><Tab>");
    try testing.expectEqual(3, ed.cursorLine()); // back where we started
    // Edits above keep entries on their text.
    try ed.feed("ggOnew<Esc>");
    try ed.feed("<C-o>");
    try testing.expectEqual(4, ed.cursorLine()); // "d" moved down a line
    // The picker lists newest first and goes where you pick.
    try ed.feed("<Space>fj");
    ed.picker.?.sync();
    try testing.expectEqual(.jumps, ed.picker.?.kind);
    try ed.feed("<CR>");
    try testing.expect(ed.picker == null);
}

test "pickers: Esc moves from typing to normal mode, j/k move, q closes" {
    var ed = try testEditor("alpha\nbeta\ngamma");
    defer ed.deinit();
    try ed.feed("<cmd:search_buffer>");
    try testing.expectEqual(.picker, ed.mode); // buffer lines start typing
    try ed.feed("a<Esc>");
    try testing.expectEqual(.picker_normal, ed.mode);
    settlePicker(&ed);
    try ed.feed("jjk"); // moving, not typing
    try testing.expectEqualStrings("a", ed.picker.?.query.items());
    try testing.expectEqual(1, ed.picker.?.selected);
    try ed.feed("Gi"); // back to typing
    try testing.expectEqual(.picker, ed.mode);
    try ed.feed("<Esc><Esc>");
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(.normal, ed.mode);
}

test "picker normal mode: j reaches the create row" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>render<Esc>");
    settlePicker(&ed);
    const rows = ed.picker.?.rowCount();
    try ed.feed("j");
    try testing.expectEqual(@min(1, rows - 1), ed.picker.?.selected);
    try ed.feed("<Esc>");
}

test "notifications: toasts expire, progress updates in place, history keeps both" {
    var ed = try testEditor("");
    defer ed.deinit();
    notifications.notify(&ed, .info, "pushed", .{});
    notifications.progress(&ed, 7, true, "zls: indexing {d}%", .{10});
    notifications.progress(&ed, 7, true, "zls: indexing {d}%", .{80});
    try testing.expectEqual(2, ed.toasts.items.len);
    try testing.expectEqualStrings("zls: indexing 80%", ed.toasts.items[1].text());
    try testing.expect(notifications.wantsFrames(&ed));
    // Long after: the plain toast is gone, the busy one stays until done.
    ed.now = notifications.timeAfter(&ed, 60_000);
    notifications.pruneToasts(&ed);
    try testing.expectEqual(1, ed.toasts.items.len);
    notifications.progress(&ed, 7, false, "zls: done", .{});
    ed.now = notifications.timeAfter(&ed, 60_000);
    notifications.pruneToasts(&ed);
    try testing.expectEqual(0, ed.toasts.items.len);
    ed.setMessage(.err, "oops", .{});
    try ed.feed("<Space>fn");
    settlePicker(&ed);
    try testing.expectEqualStrings("oops", ed.picker.?.itemAt(0).?.text);
    try testing.expectEqualStrings("pushed", ed.picker.?.itemAt(1).?.text);
    try ed.feed("q");
}

test "themes: moving previews, Esc goes back, Enter keeps" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.theme_names = &.{ "one", "two", "three" };
    try ed.feed("<cmd:pick_theme>");
    settlePicker(&ed);
    try ed.feed("j");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.theme_index);
    try ed.feed("<Esc>");
    try testing.expectEqual(0, ed.theme_index);
    try ed.feed("<cmd:pick_theme>");
    settlePicker(&ed);
    try ed.feed("jj<CR>");
    try testing.expectEqual(2, ed.theme_index);
}

test "colour wheel: SPC l c edits the colour at the cursor; Enter writes, Esc leaves it, one undo" {
    var ed = try testEditor("a = #ff0000; b = 0x0000FF;");
    defer ed.deinit();
    try ed.feed("<cmd:pick_color>");
    try testing.expect(ed.color_picker != null);
    try testing.expectEqual(4, ed.view.cursor); // on the literal
    try ed.feed("60l<CR>"); // red, 120 degrees round: green
    try expectText(&ed, "a = #00ff00; b = 0x0000FF;");
    try testing.expectEqual(null, ed.color_picker);
    try ed.feed("u");
    try expectText(&ed, "a = #ff0000; b = 0x0000FF;");
    // From past the first literal: the next one, written back in its form.
    try ed.feed("$<cmd:pick_color>");
    try ed.feed("50j<Esc>"); // changed, then cancelled
    try expectText(&ed, "a = #ff0000; b = 0x0000FF;");
    try ed.feed("fb<cmd:pick_color>25Jy<CR>");
    try expectText(&ed, "a = #ff0000; b = 0x000080;");
    try testing.expectEqualStrings("0x000080", ed.registers.get(null).?.text);
    // Keys don't leak to the editor while it is open.
    try ed.feed("<cmd:pick_color>dd");
    try expectText(&ed, "a = #ff0000; b = 0x000080;");
    try ed.feed("q");
    try ed.feed("ggOno colours here<Esc><cmd:pick_color>");
    try testing.expectEqual(null, ed.color_picker);
}

test "pickers: registers paste, undo history travels the tree, help finds keys" {
    var ed = try testEditor("alpha beta");
    defer ed.deinit();
    try ed.feed("\"ayiww\"byiw");
    try ed.feed("<Space>fy");
    settlePicker(&ed);
    const p = ed.picker.?;
    var found: ?usize = null;
    for (0..p.rowCount()) |row| if (std.mem.eql(u8, p.itemAt(row).?.detail, "\"a")) {
        found = row;
    };
    for (0..found.?) |_| try ed.feed("j");
    try ed.feed("<CR>");
    try expectText(&ed, "alpha balphaeta");

    // Undo history: two more states, then back to an earlier one and forward
    // to a branch that plain redo could no longer reach.
    try ed.feed("u");
    try expectText(&ed, "alpha beta");
    try ed.feed("x"); // "alpha eta": a second branch from the same state
    try ed.feed("<Space>fu");
    settlePicker(&ed);
    try testing.expectEqual(3, ed.picker.?.rowCount()); // opened, the paste, the x
    try ed.feed("j<CR>"); // the paste's state
    try expectText(&ed, "alpha balphaeta");
    try ed.feed("<Space>fuG<CR>"); // the file as opened
    try expectText(&ed, "alpha beta");

    try ed.feed("<cmd:help_keys>comment / un");
    settlePicker(&ed);
    const h = ed.picker.?;
    try testing.expect(h.rowCount() > 0);
    try testing.expect(std.mem.indexOf(u8, h.itemAt(0).?.text, "Comment / uncomment") != null);
    try ed.feed("<Esc><Esc>");
}

test "pickers: the list of pickers opens one; code actions and project symbols list the server's answers" {
    var ed = try testEditor("");
    defer ed.deinit();
    // SPC f: the menu; / filters it by name, Enter opens the row.
    try ed.feed("<Space>f/undo");
    settlePicker(&ed);
    try testing.expectEqualStrings("Undo history", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<CR>");
    try testing.expectEqual(.undo, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // SPC f r: recent files, a picker of its own.
    try ed.feed("<Space>fr");
    try testing.expectEqual(.recent, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // C-t: the same picker in its next scope, the query kept.
    try ed.feed("<Space><Space>main");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed("<C-t>");
    try testing.expectEqual(.buffers, ed.picker.?.kind);
    try testing.expectEqualStrings("main", ed.picker.?.query.items());
    try testing.expectEqual(Mode.picker, ed.mode);
    try ed.feed("<C-t>");
    try testing.expectEqual(.recent, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // Search: project, then this file.
    try ed.feed("<Space>/x<C-t>");
    try testing.expectEqual(.lines, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");

    try lsp_actions.showCodeActions(&ed); // none: a message, no picker
    try testing.expectEqual(null, ed.picker);
    try lsp_actions.addCodeAction(&ed, "Remove unused variable", "quickfix", try testing.allocator.dupe(u8, "{}"));
    try lsp_actions.showCodeActions(&ed);
    settlePicker(&ed);
    try testing.expectEqualStrings("Remove unused variable", ed.picker.?.itemAt(0).?.text);
    try ed.feed("q");

    try ed.openPicker(.workspace_symbols, "");
    try lsp_actions.addWorkspaceSymbol(&ed, "handleKey", "fn", "src/Editor.zig", 10, 4);
    try lsp_actions.workspaceSymbolsArrived(&ed); // the server answered: the list fills in
    settlePicker(&ed);
    try testing.expectEqualStrings("handleKey", ed.picker.?.itemAt(0).?.text);
    try testing.expectEqualStrings("fn  src/Editor.zig:11", ed.picker.?.itemAt(0).?.detail);
    try ed.feed("<Esc><CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/Editor.zig"));
    try testing.expectEqual(10, ed.cursorLine());
}

test "pickers that jump to a line centre it" {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    for (0..200) |i| try lines.print(testing.allocator, "line {d}\n", .{i});
    var ed = try testEditor(lines.items);
    defer ed.deinit();
    ed.setViewSize(20, 40);
    try ed.feed("<cmd:search_buffer>line 150<CR>");
    try testing.expectEqual(150, ed.cursorLine());
    try testing.expectEqual(140, ed.view.top); // ten rows above it
    try ed.feed("ggmaG<cmd:pick_mark><CR>"); // a mark near the top: as centred as the start allows
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(0, ed.view.top);
}

test "pickers: Tab goes through the scopes, as Ctrl-t does" {
    var ed = try testEditor("x");
    defer ed.deinit();
    try ed.feed("<Space><Space>");
    const first = ed.picker.?.kind;
    try ed.feed("<Tab>");
    const second = ed.picker.?.kind;
    try testing.expect(second != first);
    try ed.feed("<C-t>");
    try testing.expect(ed.picker.?.kind != second);
}
