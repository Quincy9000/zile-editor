//! Editor tests: claude.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Claude = @import("../ai/Claude.zig");
const Terminal = @import("../terminal/Terminal.zig");
const window_ops = @import("../editor/window_ops.zig");
const ai_ghost = @import("../editor/ai_ghost.zig");
const claude_panel = @import("../editor/claude_panel.zig");
const claude_chat = @import("../editor/claude_chat.zig");
const Chat = @import("../ai/Chat.zig");
const project_ops = @import("../editor/project_ops.zig");
const Editor = @import("../Editor.zig");
const noWake = Editor.noWake;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const FakeCli = support.FakeCli;

test "AI suggestion: typing it out keeps it, Tab takes the rest, other keys drop it" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ireturn ");
    ed.ai_suggestion = .{ .buffer = ed.buffer, .pos = ed.view.cursor, .text = try testing.allocator.dupe(u8, "a + b;\n}") };
    try ed.feed("a "); // matches: still offered, minus what was typed
    try testing.expectEqualStrings("+ b;\n}", ai_ghost.aiSuggestionHere(&ed).?);
    try ed.feed("<A-Right>"); // one character
    try testing.expectEqualStrings(" b;\n}", ai_ghost.aiSuggestionHere(&ed).?);
    try ed.feed("<A-l>"); // the rest of this line
    try expectText(&ed, "return a + b;");
    try testing.expectEqualStrings("\n}", ai_ghost.aiSuggestionHere(&ed).?);
    try ed.feed("<A-;>"); // all of what's left
    try expectText(&ed, "return a + b;\n}");
    try testing.expectEqual(null, ed.ai_suggestion);
    try ed.feed("<Tab>"); // Tab is just a tab
    try expectText(&ed, "return a + b;\n}   ");

    try ed.feed("<CR>");
    ed.ai_suggestion = .{ .buffer = ed.buffer, .pos = ed.view.cursor, .text = try testing.allocator.dupe(u8, "xyz") };
    try ed.feed("q"); // doesn't match: gone
    try testing.expectEqual(null, ai_ghost.aiSuggestionHere(&ed));
    try ed.feed("<Esc>");
}

test "claude: lock file, handshake, selection, mentions, openDiff accepted" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/a.zig", .data = "const a = 1;\nconst b = 2;\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const cfg = try std.fmt.allocPrintSentinel(gpa, "{s}/cfg", .{base}, 0);
    defer gpa.free(cfg);
    const setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });
    _ = setenv("CLAUDE_CONFIG_DIR", cfg.ptr, 1);
    const file = try std.fmt.allocPrint(gpa, "{s}/proj/a.zig", .{base});
    defer gpa.free(file);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(file);
    ed.claude = try Claude.start(&ed);
    const c = ed.claude.?;

    // The lock file announces us.
    const lock = try std.fmt.allocPrint(gpa, "{s}/ide/{d}.lock", .{ cfg, c.port() });
    defer gpa.free(lock);
    const lock_text = try Io.Dir.cwd().readFileAlloc(io, lock, gpa, .limited(4096));
    defer gpa.free(lock_text);
    try testing.expect(std.mem.indexOf(u8, lock_text, "\"transport\":\"ws\"") != null);
    try testing.expect(std.mem.indexOf(u8, lock_text, &c.token) != null);

    // A wrong token is turned away; the right one gets in.
    try testing.expectError(error.Handshake, FakeCli.connect(c.port(), "wrong-token-wrong-token-wrong-to"));
    var cli = try FakeCli.connect(c.port(), &c.token);
    defer cli.deinit();
    cli.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"claude-code\",\"version\":\"test\"}}}");
    const hello = try cli.expect(&ed, "\"id\":1");
    defer gpa.free(hello);
    try testing.expect(std.mem.indexOf(u8, hello, "\"protocolVersion\":\"2025-06-18\"") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"logging\":{}") != null);

    // The cursor's place in the file is shared.
    const sel = try cli.expect(&ed, "selection_changed");
    defer gpa.free(sel);
    try testing.expect(std.mem.indexOf(u8, sel, "a.zig") != null);

    // Tools are listed.
    cli.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const tools = try cli.expect(&ed, "\"id\":2");
    defer gpa.free(tools);
    try testing.expect(std.mem.indexOf(u8, tools, "openDiff") != null);

    // A mention of lines 1-2 (0-based 0..1).
    c.mention(file, .{ 0, 1 });
    const men = try cli.expect(&ed, "at_mentioned");
    defer gpa.free(men);
    try testing.expect(std.mem.indexOf(u8, men, "\"lineStart\":0,\"lineEnd\":1") != null);

    // A proposed edit opens as a diff; SPC a y accepts it.
    const call = try std.fmt.allocPrint(gpa,
        \\{{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{{"name":"openDiff","arguments":{{"old_file_path":"{s}","new_file_path":"{s}","new_file_contents":"const a = 10;\nconst b = 2;\n","tab_name":"t1"}}}}}}
    , .{ file, file });
    defer gpa.free(call);
    cli.send(call);
    for (0..200) |_| {
        ed.tick();
        if (c.diffs.items.len > 0) break;
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expectEqual(1, c.diffs.items.len);
    try testing.expect(std.mem.startsWith(u8, ed.buffer.displayName(), "Claude: "));
    try testing.expectEqual(1, ed.buffer.git.?.hunks.items.len); // line 1 changed
    try ed.feed("<Space>ay");
    const saved = try cli.expect(&ed, "\"id\":3");
    defer gpa.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "FILE_SAVED") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "const a = 10;") != null);
    try testing.expectEqual(0, c.diffs.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "a.zig")); // back on the file

    // A rejected one answers DIFF_REJECTED.
    const call2 = try std.mem.replaceOwned(u8, gpa, call, "\"id\":3", "\"id\":4");
    defer gpa.free(call2);
    cli.send(call2);
    for (0..200) |_| {
        ed.tick();
        if (c.diffs.items.len > 0) break;
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try ed.feed("<Space>an");
    const rejected = try cli.expect(&ed, "\"id\":4");
    defer gpa.free(rejected);
    try testing.expect(std.mem.indexOf(u8, rejected, "DIFF_REJECTED") != null);
}

test "SPC q with the Claude panel: the last code window hides the panel first" {
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    const t = try Terminal.create(ed.gpa, ed.io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 5" }, .cwd = "/", .cols = 40, .rows = 5, .wake = noWake });
    defer t.destroy();
    const code_window = ed.window;
    try window_ops.splitWindow(&ed, .right);
    ed.window.term = t;
    window_ops.focusWindow(&ed, code_window);

    try ed.feed("<cmd:window_close>"); // the last code window stays
    try testing.expectEqual(2, ed.window_list.items.len);
    try ed.feed("<Space>q"); // hides the panel, not the code
    try testing.expectEqual(1, ed.window_list.items.len);
    try testing.expectEqual(code_window, ed.window);
    try testing.expect(!ed.should_quit);
    try ed.feed("<Space>q"); // then on to buffers / quitting
    try testing.expect(ed.should_quit);
}

test "SPC a i: a box to tell Claude something; Enter sends it and the code keeps the keyboard" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 3;\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const cfg = try std.fmt.allocPrintSentinel(gpa, "{s}/cfg", .{base}, 0);
    defer gpa.free(cfg);
    const setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });
    _ = setenv("CLAUDE_CONFIG_DIR", cfg.ptr, 1);
    const file = try std.fmt.allocPrint(gpa, "{s}/a.zig", .{base});
    defer gpa.free(file);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile(file);
    try project_ops.workIn(&ed, base);
    // Claude's panel, hidden: a program that says what it was sent.
    ed.claude = try Claude.start(&ed);
    const c = ed.claude.?;
    c.term = try Terminal.create(ed.gpa, ed.io, .{ .argv = &.{ "/bin/sh", "-c", "while read -r line; do echo \"got <$line>\"; done" }, .cwd = "/", .cols = 60, .rows = 5, .wake = noWake });
    c.ready = true;
    const code_window = ed.window;
    // Claude's own terminal is on screen: the box talks to that.
    try claude_panel.showClaude(&ed);
    window_ops.focusWindow(&ed, code_window);

    // Esc in normal mode closes the box, nothing sent.
    try claude_panel.claudeAskPrompt(&ed);
    try testing.expect(ed.cmd_float != null);
    try testing.expectEqual(Editor.Mode.insert, ed.mode);
    try ed.feed("never mind<Esc><Esc>");
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expect(!c.saying());
    try testing.expectEqual(2, ed.window_list.items.len);

    // On a selection: its lines lead the message. vim's keys edit it; Enter
    // sends from insert mode.
    try ed.feed("Vj");
    try claude_panel.claudeAskPrompt(&ed);
    var title: [64]u8 = undefined;
    try testing.expectEqualStrings("Tell Claude about a.zig:1-2", claude_panel.tellTitle(&ed, &title));
    try ed.feed("why twoo<Esc>xa?<CR>");
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expectEqual(code_window, ed.window); // the panel shows, the code has the keys
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expectEqual(Editor.Mode.normal, ed.mode);
    var got = false;
    for (0..300) |_| {
        ed.tick();
        const out = try c.term.?.screenText(gpa);
        defer gpa.free(out);
        if (std.mem.indexOf(u8, out, "got <@a.zig#L1-2 why two?>") != null) {
            got = true;
            break;
        }
        support.io_sleep(10);
    }
    try testing.expect(got);
    try testing.expect(!c.saying());
}

test "Claude drawn by zile: a row for each thing said, a picker to answer what it asks" {
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    ed.chat = try Chat.create(ed.gpa, ed.io, ".", noWake);
    const c = ed.chat.?;
    c.offline = true; // no CLI: its lines are given below
    const p = &ed.chat_panel;

    // The box says it; the conversation shows in its panel, the code keeps the keys.
    try claude_panel.claudeAskPrompt(&ed);
    try ed.feed("fix it<CR>");
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expect(p.shown and !p.focus);
    try testing.expectEqual(1, ed.window_list.items.len); // a panel, not a split
    try testing.expectEqual(1, c.entries.items.len);
    try ed.feed("x");
    try expectText(&ed, "ode");

    // What Claude writes is a row that grows; the panel follows it.
    try c.event("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"On it.\\nSecond line.\"}}}");
    ed.tick();
    try testing.expectEqual(2, c.entries.items.len);
    try testing.expectEqual(1, p.sel);
    try testing.expect(p.tail);

    // A tool wants permission: a notification, and SPC a y is the picker.
    try c.event("{\"type\":\"control_request\",\"request_id\":\"r-1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"rm x\"}}}");
    ed.tick();
    try testing.expect(ed.toasts.items.len > 0 and ed.toasts.items[ed.toasts.items.len - 1].busy);
    try testing.expectEqual(2, p.sel); // the question is the row to look at
    claude_panel.claudeResolve(&ed, true);
    try testing.expectEqual(.claude_ask, ed.picker.?.kind);
    try testing.expect(!p.shown); // the picker instead of the panel, which comes back after
    support.settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount()); // allow, refuse: nothing was suggested
    try ed.feed("<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"behavior\":\"allow\"") != null);
    try testing.expectEqualStrings("✓ Allow Bash? rm x", Chat.rowLine(&c.entries.items[2]));
    try testing.expect(p.shown and !p.focus);

    // A question of Claude's own: its options are the picker's rows.
    try c.event("{\"type\":\"control_request\",\"request_id\":\"q-1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"Tea or coffee?\",\"options\":[{\"label\":\"Tea\",\"description\":\"leaves\"},{\"label\":\"Coffee\",\"description\":\"beans\"}]}]}}}");
    ed.tick();
    claude_panel.claudeResolve(&ed, true);
    support.settlePicker(&ed);
    try ed.feed("j<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"answers\":{\"Tea or coffee?\":\"Coffee\"}") != null);

    // Its turn over: a notification with the start of what it said.
    try c.event("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"All fixed.\"}}}");
    try c.event("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}");
    ed.tick();
    try testing.expectEqualStrings("Claude is done: All fixed.", ed.toasts.items[ed.toasts.items.len - 1].text());
    try c.say("more"); // (and on with the conversation)

    // SPC a a goes into the panel: j / k are its rows, y copies the one selected.
    try claude_chat.toggle(&ed);
    try testing.expect(p.focus);
    try ed.feed("ggj");
    try testing.expectEqual(1, p.sel);
    try testing.expect(!p.follow and !p.tail);
    try ed.feed("y");
    try testing.expectEqualStrings("On it.\nSecond line.", ed.registers.get(null).?.text);
    try ed.feed("dd"); // nothing of the code's
    try expectText(&ed, "ode");
    // Tab goes into the row's text, where it shows: vim's keys, to copy
    // part of it; not to change. Tab (or Esc) comes back to the rows.
    try ed.feed("<Tab>");
    try testing.expect(Editor.side_float.focused(&ed));
    try expectText(&ed, "On it.\nSecond line.");
    try ed.feed("jwyiw");
    try testing.expectEqualStrings("line", ed.registers.get(null).?.text);
    try ed.feed("ddx");
    try expectText(&ed, "On it.\nSecond line.");
    try ed.feed("vl<Esc>"); // (an Esc that ends a selection stays)
    try testing.expect(Editor.side_float.focused(&ed));
    try ed.feed("<Tab>");
    try testing.expectEqual(null, ed.side_window);
    try testing.expect(p.shown and p.focus);
    try expectText(&ed, "ode");
    try ed.feed("<Tab><Esc>");
    try testing.expectEqual(null, ed.side_window);
    try testing.expect(p.shown and p.focus);
    // Rows that come while another is being read don't take the selection.
    try c.event("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Done.\"}}}");
    ed.tick();
    try testing.expectEqual(1, p.sel);
    try ed.feed("G");
    try testing.expectEqual(c.entries.items.len - 1, p.sel);
    try testing.expect(p.follow);
    // `i` is the box; Esc Esc closes it, the panel has the keys again.
    try ed.feed("i");
    try testing.expect(ed.cmd_float != null);
    try ed.feed("<Esc><Esc>");
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expect(p.focus);
    // `o`: the row in a buffer of its own, to yank part of it; not to change.
    try ed.feed("ggjo");
    try testing.expect(!p.focus);
    try expectText(&ed, "On it.\nSecond line.");
    try ed.feed("jyiw");
    try testing.expectEqualStrings("Second", ed.registers.get(null).?.text);
    try ed.feed("ddx");
    try ed.feed("ihello<Esc>");
    try expectText(&ed, "On it.\nSecond line.");
    // Ctrl-w gives the keys back to the code, the panel staying; Esc there hides it.
    try claude_chat.toggle(&ed);
    try ed.feed("<C-w>");
    try testing.expect(p.shown and !p.focus);
    try ed.feed("v<Esc>"); // (not the Esc that ends a selection)
    try testing.expect(p.shown);
    try ed.feed("<Esc>");
    try testing.expect(!p.shown);
    // In the panel, Esc hides it too. SPC is the code's menu.
    try claude_chat.toggle(&ed);
    try ed.feed("<Esc>");
    try testing.expect(!p.shown and !p.focus);
    try claude_chat.toggle(&ed);
    try ed.feed("<Space>");
    try testing.expect(!p.shown and ed.picker != null); // a picker takes the panel's place
    try ed.feed("<Esc>");
    try testing.expect(!p.shown);
    // From the panel, q (or SPC a a) hides it.
    try claude_chat.toggle(&ed);
    try ed.feed("q");
    try testing.expect(!p.shown);
}

test "Claude's slash commands and models: the CLI's own lists, in pickers" {
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    ed.chat = try Chat.create(ed.gpa, ed.io, ".", noWake);
    const c = ed.chat.?;
    c.offline = true;
    // Before the CLI has said what it has: a message, no empty picker.
    try claude_chat.menu(&ed, .commands);
    try testing.expectEqual(null, ed.picker);
    try c.event("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"zile-init\",\"response\":{\"commands\":[{\"name\":\"review\",\"description\":\"Review the diff\"},{\"name\":\"init\",\"description\":\"Make a CLAUDE.md\"}],\"models\":[{\"value\":\"default\",\"displayName\":\"Default\",\"description\":\"Fable\"},{\"value\":\"opus\",\"displayName\":\"Opus\",\"description\":\"For complex work\"}],\"current_permission_mode\":\"default\"}}}");

    // A command taken starts the box; what is typed after it goes with it.
    try claude_chat.menu(&ed, .commands);
    try testing.expectEqual(.claude_commands, ed.picker.?.kind);
    support.settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    try ed.feed("rev<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(ed.cmd_float != null);
    try expectText(&ed, "/review ");
    try ed.feed("the last commit<CR>");
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expectEqualStrings("/review the last commit", c.entries.items[c.entries.items.len - 1].text.items);

    // `/` first in the box is that picker too.
    try claude_panel.claudeAskPrompt(&ed);
    try ed.feed("/");
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expectEqual(.claude_commands, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    try testing.expectEqual(null, ed.picker);
    // (Not first, it is a `/`.)
    try claude_panel.claudeAskPrompt(&ed);
    try ed.feed("a/");
    try expectText(&ed, "a/");
    try ed.feed("<Esc><Esc>");

    // The model: the row taken is asked for; the CLI says what answers now.
    try claude_chat.menu(&ed, .models);
    support.settlePicker(&ed);
    try ed.feed("j<CR>");
    try testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"subtype\":\"set_model\",\"model\":\"opus\"") != null);
    // The effort: the model's levels; what is used: rows to look at.
    try c.event("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"zile-init\",\"response\":{\"commands\":[],\"models\":[{\"value\":\"default\",\"displayName\":\"Default\",\"description\":\"\",\"supportedEffortLevels\":[\"low\",\"medium\",\"high\"]}]}}}");
    try claude_chat.menu(&ed, .efforts);
    try testing.expectEqual(.claude_efforts, ed.picker.?.kind);
    support.settlePicker(&ed);
    try testing.expectEqual(3, ed.picker.?.rowCount());
    try ed.feed("jj<CR>");
    try testing.expectEqualStrings("high", c.effort);
    try claude_chat.menu(&ed, .usage);
    try testing.expectEqual(null, ed.picker); // not known yet
    try c.event("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"zile-9\",\"response\":{\"session\":{\"total_cost_usd\":0.5},\"rate_limits\":{\"five_hour\":{\"utilization\":34,\"resets_at\":\"2099-01-01T00:00:00Z\"},\"seven_day\":{\"utilization\":5,\"resets_at\":\"2099-01-01T00:00:00Z\"}}}}}");
    try claude_chat.menu(&ed, .usage);
    support.settlePicker(&ed);
    try testing.expectEqual(3, ed.picker.?.rowCount()); // two limits, the conversation
    try testing.expectEqualStrings("5-hour limit    34% used", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.picker);
    // The permission mode.
    try claude_chat.menu(&ed, .modes);
    support.settlePicker(&ed);
    try ed.feed("jj<CR>");
    try testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"subtype\":\"set_permission_mode\",\"mode\":\"plan\"") != null);
}
