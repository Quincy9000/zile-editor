//! Editor tests: claude.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Claude = @import("../ai/Claude.zig");
const Terminal = @import("../terminal/Terminal.zig");
const window_ops = @import("../editor/window_ops.zig");
const ai_ghost = @import("../editor/ai_ghost.zig");
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
