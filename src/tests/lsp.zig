//! Editor tests: lsp.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const commands = @import("../commands.zig");
const Lsp = @import("../lsp/Lsp.zig");
const notifications = @import("../editor/notifications.zig");
const inlay = @import("../editor/inlay.zig");
const borders = @import("../editor/borders.zig");
const resting = @import("../editor/resting.zig");
const row_model = @import("../editor/row_model.zig");
const prompts = @import("../editor/prompts.zig");
const signature_help = @import("../editor/signature_help.zig");
const completion_ops = @import("../editor/completion_ops.zig");
const lsp_ops = @import("../editor/lsp_ops.zig");
const Editor = @import("../Editor.zig");
const LineHint = Editor.LineHint;
const max_line_hints = Editor.max_line_hints;
const hintShift = Editor.hintShift;
const hintShiftBefore = Editor.hintShiftBefore;
const hintVisualToText = Editor.hintVisualToText;
const Mode = Editor.Mode;
const Seg = Editor.Seg;
const max_segments = Editor.max_segments;
const support = @import("support.zig");
const testEditor = support.testEditor;
const testEditorAs = support.testEditorAs;
const expectText = support.expectText;
const expectCursor = support.expectCursor;

test "a language server that exits is restarted a few times, then left" {
    var ed = try testEditor("");
    defer ed.deinit();
    for (0..lsp_ops.max_lsp_restarts) |n| {
        lsp_ops.serverExited(&ed, 0);
        try testing.expect(!ed.lsp_failed[0]);
        try testing.expectEqual(n + 1, ed.lsp_restarts[0]);
        try testing.expect(std.mem.endsWith(u8, ed.toasts.items[ed.toasts.items.len - 1].text(), "(restarting)"));
    }
    lsp_ops.serverExited(&ed, 0);
    try testing.expect(ed.lsp_failed[0]);
    try testing.expect(std.mem.indexOf(u8, ed.toasts.items[ed.toasts.items.len - 1].text(), "not restarting") != null);
}

test "tags: > closes, </ closes the open one, Enter splits, void and self-closing stay" {
    {
        var ed = try testEditorAs("x.html", "");
        defer ed.deinit();
        try ed.feed("i<lt>div class=\"a>b\">");
        try expectText(&ed, "<div class=\"a>b\"></div>");
        try ed.feed("<CR>");
        try expectText(&ed, "<div class=\"a>b\">\n  \n</div>");
        try ed.feed("<lt>br><Esc>");
        try expectText(&ed, "<div class=\"a>b\">\n  <br>\n</div>"); // void: no </br>
        try ed.feed("o<lt>p><Esc>");
        try expectText(&ed, "<div class=\"a>b\">\n  <br>\n  <p></p>\n</div>");
    }
    {
        var ed = try testEditorAs("x.html", "<ul>\n  <li>one");
        defer ed.deinit();
        try ed.feed("Go<lt>/"); // the <li> is the innermost open one
        try expectText(&ed, "<ul>\n  <li>one\n  </li>");
        try ed.feed("<CR><lt>/");
        try expectText(&ed, "<ul>\n  <li>one\n  </li>\n</ul>"); // at the <ul>'s indentation
    }
    {
        var ed = try testEditorAs("x.tsx", "const a: Array<string = [];\nconst A = () => ");
        defer ed.deinit();
        try ed.feed("GA<lt>View onPress={() => go()}><Esc>");
        try expectText(&ed, "const a: Array<string = [];\nconst A = () => <View onPress={() => go()}></View>");
        try ed.feed("ggf<lt>ea><Esc>"); // a generic: left alone
        try expectText(&ed, "const a: Array<string> = [];\nconst A = () => <View onPress={() => go()}></View>");
    }
    {
        var ed = try testEditorAs("x.tsx", "const f = ");
        defer ed.deinit();
        try ed.feed("A<lt>><Esc>"); // a fragment
        try expectText(&ed, "const f = <></>");
    }
    {
        var ed = try testEditorAs("x.tsx", "const x = <Foo />;");
        defer ed.deinit();
        try ed.feed("$i<lt>b><Esc>"); // after another element: a tag
        try expectText(&ed, "const x = <Foo /><b></b>;");
        try ed.feed("o<lt>Bar /><Esc>"); // self-closing: nothing added
        try expectText(&ed, "const x = <Foo /><b></b>;\n<Bar />");
    }
}

test "tags: editing a tag's name edits its partner, as one undo step" {
    {
        var ed = try testEditorAs("x.html", "<div>\n  <p>hi</p>\n</div>");
        defer ed.deinit();
        try ed.feed("lciwsection<Esc>");
        try expectText(&ed, "<section>\n  <p>hi</p>\n</section>");
        try ed.feed("u");
        try expectText(&ed, "<div>\n  <p>hi</p>\n</div>");
        try ed.feed("G$iaa<Esc>"); // the closing tag works too: </divaa>
        try expectText(&ed, "<divaa>\n  <p>hi</p>\n</divaa>");
        try ed.feed("jkkfpx"); // and in normal mode: x on the <p>
        try expectText(&ed, "<divaa>\n  <>hi</>\n</divaa>");
        try ed.feed("iem<Esc>"); // a name typed into the empty tag: both again
        try expectText(&ed, "<divaa>\n  <em>hi</em>\n</divaa>");
    }
    {
        var ed = try testEditorAs("x.tsx", "const A = () => (\n  <View style={s}>\n    <Text>hi</Text>\n  </View>\n);");
        defer ed.deinit();
        try ed.feed("jfVcwScrollView<Esc>");
        try expectText(&ed, "const A = () => (\n  <ScrollView style={s}>\n    <Text>hi</Text>\n  </ScrollView>\n);");
    }
}

test "tags: a nameless JSX tag (<>, or a name deleted) gets the name on both sides" {
    {
        // A fragment: typing a name into `<>` names `</>` too.
        var ed = try testEditorAs("x.tsx", "const a = <>hi</>;");
        defer ed.deinit();
        try ed.feed("f<lt>aView<Esc>");
        try expectText(&ed, "const a = <View>hi</View>;");
        try ed.feed("u");
        try expectText(&ed, "const a = <>hi</>;");
        // From the closing side too.
        try ed.feed("$F/aText<Esc>");
        try expectText(&ed, "const a = <Text>hi</Text>;");
    }
    {
        // A name deleted, then a new one typed later.
        var ed = try testEditorAs("x.tsx", "const a = <h1>hi</h1>;");
        defer ed.deinit();
        try ed.feed("fhdiw");
        try expectText(&ed, "const a = <>hi</>;");
        try ed.feed("0f<lt>ah2<Esc>");
        try expectText(&ed, "const a = <h2>hi</h2>;");
    }
}

test "emmet: Tab expands an abbreviation in markup, with tab stops" {
    {
        var ed = try testEditorAs("x.html", "<body>\n  \n</body>");
        defer ed.deinit();
        try ed.feed("jAul>li.item$*2<Tab>");
        try expectText(&ed, "<body>\n  <ul>\n    <li class=\"item1\"></li>\n    <li class=\"item2\"></li>\n  </ul>\n</body>");
        try ed.feed("one<Tab>two<Esc>"); // tab stops: the first <li>, then the second
        try expectText(&ed, "<body>\n  <ul>\n    <li class=\"item1\">one</li>\n    <li class=\"item2\">two</li>\n  </ul>\n</body>");
        try ed.feed("ohello<Tab><Esc>"); // prose: a tab, not <hello>
        try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "<hello>") == null);
    }
    {
        var ed = try testEditorAs("x.tsx", "const A = () => (\n  <View>\n    \n  </View>\n);");
        defer ed.deinit();
        try ed.feed("jjAText.title<Tab>Hi<Esc>");
        try expectText(&ed, "const A = () => (\n  <View>\n    <Text className=\"title\">Hi</Text>\n  </View>\n);");
    }
    {
        var ed = try testEditorAs("x.ts", "const x = ");
        defer ed.deinit();
        try ed.feed("Adiv<Tab><Esc>"); // TypeScript without JSX: no markup
        try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "<div>") == null);
    }
}

test "completion between JSX tags offers elements and the file's components" {
    const gpa = testing.allocator;
    var ed = try testEditorAs("x.tsx", "import { View } from \"rn\";\nconst A = () => (\n  <View>\n    \n  </View>\n);");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa, "{\"items\":[]}", .{});
    defer reply.deinit();
    try ed.feed("3jAvie");
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 3, reply.value);
    const c = completion_ops.completionShown(&ed).?;
    try testing.expectEqualStrings("View", c.current().?.label);
    try ed.feed("<CR>");
    try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "    <View></View>\n") != null);
}

test "completion in CSS: a - keeps the list (background-color, --gap)" {
    const gpa = testing.allocator;
    var ed = try testEditorAs("x.css", "a {\n  \n}");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"background"},{"label":"background-color"},{"label":"border"}]}
    , .{});
    defer reply.deinit();
    try ed.feed("jAba");
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("ckground-");
    const c = completion_ops.completionShown(&ed) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("background-color", c.current().?.label);
    try ed.feed("<CR>");
    try testing.expectEqualStrings("  background-color", ed.text().lineSlice(1));
}

test "completion in CSS: a property's values as the server lists them, each with its documentation" {
    const gpa = testing.allocator;
    var ed = try testEditorAs("x.css", "a {\n  justify-content:\n}");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"isIncomplete":true,"items":[
        \\{"label":"space-between","documentation":{"kind":"markdown","value":"Flex items are evenly distributed in the line\\."}},
        \\{"label":"center","documentation":{"kind":"markdown","value":"Packed toward the center\\.\n\n![Baseline icon](data:image/svg+xml;base64,AAAA)\n\n[MDN Reference](https://developer.mozilla.org/docs/Web/CSS/justify-content)"}},
        \\{"label":"end","documentation":"plain"}]}
    , .{});
    defer reply.deinit();
    try ed.feed("jA ");
    // Nothing typed after `: `: the values only (not the file's words), in
    // the server's order (not the shortest first).
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor, reply.value);
    const c = completion_ops.completionShown(&ed) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(3, c.shown.items.len);
    try testing.expectEqualStrings("space-between", c.current().?.label);
    try testing.expectEqualStrings("Flex items are evenly distributed in the line.", c.docText());
    try ed.feed("<C-n>");
    try testing.expectEqualStrings("center", completion_ops.completionShown(&ed).?.current().?.label);
    try testing.expectEqualStrings("Packed toward the center.\n\nMDN Reference\n(https://developer.mozilla.org/docs/Web/CSS/justify-content)", completion_ops.completionShown(&ed).?.docText());
    try ed.feed("<CR>");
    try testing.expectEqualStrings("  justify-content: center", ed.text().lineSlice(1));
}

test "snippets: the exact trigger first, indented like its line" {
    const gpa = testing.allocator;
    const reply = try std.json.parseFromSlice(std.json.Value, gpa, "{\"items\":[{\"label\":\"useState\"},{\"label\":\"user\"}]}", .{});
    defer reply.deinit();
    {
        var ed = try testEditorAs("x.tsx", "function A() {\n  \n}");
        defer ed.deinit();
        try ed.feed("jAus");
        try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 2, reply.value);
        try testing.expectEqualStrings("us", completion_ops.completionShown(&ed).?.current().?.label);
        try ed.feed("<CR>count<Tab>Count<Tab>0<Esc>");
        try expectText(&ed, "function A() {\n  const [count, setCount] = useState(0);\n}");
    }
    {
        var ed = try testEditorAs("x.ts", "function A() {\n  \n}");
        defer ed.deinit();
        try ed.feed("jAtc");
        try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 2, reply.value);
        try testing.expectEqualStrings("tc", completion_ops.completionShown(&ed).?.current().?.label);
        try ed.feed("<CR><Esc>");
        try expectText(&ed, "function A() {\n  try {\n    \n  } catch (err) {\n    \n  }\n}");
    }
    {
        var ed = try testEditorAs("x.ts", "");
        defer ed.deinit();
        try ed.feed("ius"); // React Native snippets are for .jsx / .tsx only
        try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
        const c = completion_ops.completionShown(&ed).?;
        for (c.shown.items) |i| try testing.expect(!std.mem.eql(u8, c.items[i].label, "us"));
    }
}

test "code lens: a row above its line that the cursor steps over" {
    var ed = try testEditor("a\nfn f() {}\nb");
    defer ed.deinit();
    try row_model.addLens(&ed, ed.buffer, 1, "2 references");
    try row_model.addLens(&ed, ed.buffer, 1, "1 implementation");
    try testing.expectEqualStrings("2 references | 1 implementation", row_model.lensText(&ed, 1).?);
    try testing.expectEqual(2, row_model.subRows(&ed, 1)); // the lens row and the line
    try ed.feed("j");
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expectEqual(1, row_model.cursorRow(&ed).sub); // on the text, not the lens
    try ed.feed("k");
    try testing.expectEqual(0, ed.cursorLine());
    try ed.feed("jj");
    try testing.expectEqual(2, ed.cursorLine());
    row_model.clickCell(&ed, 1, 0); // the lens row: its line
    try testing.expectEqual(1, ed.cursorLine());
    ed.options.code_lens = false;
    try testing.expectEqual(1, row_model.subRows(&ed, 1));
}

test "code lens: lenses move with the lines, and a refresh doesn't blank them" {
    var ed = try testEditor("a\nfn f() {}\nb\nfn g() {}");
    defer ed.deinit();
    try row_model.addLens(&ed, ed.buffer, 1, "2 references");
    try row_model.addLens(&ed, ed.buffer, 3, "1 reference");
    // New lines above: both move down.
    try ed.feed("Onew<Esc>");
    try testing.expectEqual(null, row_model.lensText(&ed, 1));
    try testing.expectEqualStrings("2 references", row_model.lensText(&ed, 2).?);
    try testing.expectEqualStrings("1 reference", row_model.lensText(&ed, 4).?);
    // A line opened at the end of a lens's line doesn't move it.
    try ed.feed("jjA<CR>x<Esc>");
    try testing.expectEqualStrings("2 references", row_model.lensText(&ed, 2).?);
    try testing.expectEqualStrings("1 reference", row_model.lensText(&ed, 5).?);
    // Deleting lines: the lens of a deleted line goes, the next moves up.
    try ed.feed("ggjdd");
    try testing.expectEqual(null, row_model.lensText(&ed, 1));
    try testing.expectEqualStrings("1 reference", row_model.lensText(&ed, 4).?);
    // A refresh: the kept title shows until the resolved one replaces it.
    ed.buffer.lenses.items[ed.buffer.lenses.items.len - 1].stale = true;
    try testing.expectEqualStrings("1 reference", row_model.lensText(&ed, 4).?);
    try row_model.addLens(&ed, ed.buffer, 4, "2 references");
    try testing.expectEqualStrings("2 references", row_model.lensText(&ed, 4).?);
    try row_model.addLens(&ed, ed.buffer, 4, "1 implementation");
    try testing.expectEqualStrings("2 references | 1 implementation", row_model.lensText(&ed, 4).?);
}

test "missing tools: quiet until an action needs them, then said plainly" {
    var ed = try testEditorAs("main.go", "package main");
    defer ed.deinit();
    const i = Lsp.serverFor(ed.buffer).?;
    const toasts = ed.toasts.items.len;
    lsp_ops.serverStartFailed(&ed, i, error.FileNotFound);
    try testing.expectEqual(toasts, ed.toasts.items.len); // nothing on opening
    try testing.expect(lsp_ops.languageServer(&ed) == null); // gd, K, rename...
    try testing.expect(std.mem.endsWith(u8, ed.message.text(), "isn't installed"));
    // A command needing a program that isn't there.
    const cmd: commands.Command = .{ .name = "x", .doc = "x", .run = struct {
        fn run(_: commands.Context) anyerror!void {
            return error.ShouldNotRun;
        }
    }.run, .needs = "zile-no-such-program" };
    try ed.runCommand(&cmd);
    try testing.expectEqualStrings("zile-no-such-program isn't installed", ed.message.text());
}

test "applyEdits: a rename's edits land bottom-up as one undo step" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-rename.zig");
    try ed.insertAt(0, "const foo = 1;\nconst bar = foo + foo;");
    try ed.buffer.history.commit(ed.gpa);
    var p1 = "edit-test-rename.zig".*;
    var p2 = "edit-test-rename.zig".*;
    var p3 = "edit-test-rename.zig".*;
    var n1 = "total".*;
    var n2 = "total".*;
    var n3 = "total".*;
    const edits = [_]Lsp.TextEdit{
        .{ .path = &p1, .start_line = 0, .start_col = 6, .end_line = 0, .end_col = 9, .text = &n1 },
        .{ .path = &p2, .start_line = 1, .start_col = 12, .end_line = 1, .end_col = 15, .text = &n2 },
        .{ .path = &p3, .start_line = 1, .start_col = 18, .end_line = 1, .end_col = 21, .text = &n3 },
    };
    try prompts.applyEdits(&ed, &edits);
    try expectText(&ed, "const total = 1;\nconst bar = total + total;");
    try ed.feed("u");
    try expectText(&ed, "const foo = 1;\nconst bar = foo + foo;");
}

test "SPC l l without a language server: tree-sitter outline picker" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-symbols.zig");
    try ed.insertAt(0, "const A = struct {\n    fn one() void {}\n};\nfn two() void {}");
    try ed.buffer.history.commit(ed.gpa);
    try ed.feed("<Space>ll");
    try testing.expectEqual(.symbols, ed.picker.?.kind);
    try ed.feed("one<CR>");
    try expectCursor(&ed, 1, 4);
}

test "snippet completion: placeholders, typing over, Tab / Shift-Tab, Backspace" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doThing","insertText":"doThing(${1:path}, ${2:opts})$0","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("<Tab>"); // accept
    try expectText(&ed, "doThing(path, opts)");
    try testing.expectEqual(8, ed.view.cursor); // on "path", which typing replaces
    try ed.feed("src");
    try expectText(&ed, "doThing(src, opts)");
    try ed.feed("<Tab>"); // on to "opts"
    try testing.expectEqual(13, ed.view.cursor);
    try ed.feed("<S-Tab><Tab>"); // back and forth keeps what was typed
    try expectText(&ed, "doThing(src, opts)");
    try ed.feed("<BS>"); // a fresh placeholder goes whole
    try expectText(&ed, "doThing(src, )");
    try ed.feed("o<Tab>"); // the last Tab lands on $0, after the call
    try expectText(&ed, "doThing(src, o)");
    try testing.expectEqual(15, ed.view.cursor);
    try testing.expectEqual(null, ed.snippet);
    try ed.feed("<Esc>");
}

test "signature help: the active parameter, closed by )" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ifoo(a, ");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"signatures":[{"label":"fn foo(a: u8, b: []const u8) void","documentation":"Does foo.\nMore.",
        \\ "parameters":[{"label":[7,12]},{"label":"b: []const u8","documentation":{"kind":"markdown","value":"The bytes."}}],
        \\ "activeParameter":1}]}
    , .{});
    defer reply.deinit();
    try signature_help.showSignature(&ed, ed.buffer, reply.value);
    const sig = ed.signature.?;
    try testing.expectEqualStrings("b: []const u8", sig.label[sig.param_start..sig.param_end]);
    try testing.expectEqualStrings("The bytes.", sig.doc);
    try ed.feed("b)");
    try testing.expectEqual(null, ed.signature);
    try ed.feed("<Esc>");
}

test "snippet: one more Tab after the call goes to the end, adding the ;" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-snippet.zig"); // a Zig buffer (not on disk)
    try ed.feed("iconst x = do");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doThing","insertText":"doThing(${1:a})$0","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("<Tab>1<Tab>"); // accept, fill a, past the call
    try expectText(&ed, "const x = doThing(1)");
    try testing.expect(ed.snippet != null); // one more stop: the ;
    try ed.feed("<Tab>");
    try expectText(&ed, "const x = doThing(1);");
    try testing.expectEqual(ed.text().len(), ed.view.cursor);
    try testing.expectEqual(null, ed.snippet);
    try ed.feed("<Tab>"); // a plain tab again
    try testing.expect(std.mem.endsWith(u8, ed.text().slice(0, ed.text().len()), ";   "));

    // The ; already there: the Tab moves past it.
    try ed.feed("<Esc>oconst y = do;<Left>");
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("<Tab>2<Tab><Tab>");
    try expectText(&ed, "const x = doThing(1);   \nconst y = doThing(2);");
    try testing.expectEqual(ed.text().len(), ed.view.cursor);

    // Inside another call: no ; stop, the snippet just ends.
    try ed.feed("<Esc>oouter(do, 3);<Esc>0fda");
    try ed.feed("<Right>");
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("<Tab>4<Tab>");
    try expectText(&ed, "const x = doThing(1);   \nconst y = doThing(2);\nouter(doThing(4), 3);");
    try testing.expectEqual(null, ed.snippet);
}

test "formatting: SPC l f, one undo step, format on save, SPC t f" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data = "const  x=1;\nfn f() void {\nreturn;\n}\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.allocPrint(gpa, "{s}/m.zig", .{buf[0..try tmp.dir.realPath(io, &buf)]});
    defer gpa.free(path);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(path);
    try ed.feed("jj"); // on "return;"
    try ed.feed("<cmd:format_buffer>");
    if (ed.message.kind == .err) return error.SkipZigTest; // no zig fmt here
    try expectText(&ed, "const x = 1;\nfn f() void {\n    return;\n}");
    try testing.expectEqual(2, ed.cursorLine()); // still on "return;"
    try ed.feed("u"); // one undo step
    try expectText(&ed, "const  x=1;\nfn f() void {\nreturn;\n}");

    // Saving formats first.
    try ed.feed("<Space>s");
    const saved = try tmp.dir.readFileAlloc(io, "m.zig", gpa, .limited(1024));
    defer gpa.free(saved);
    try testing.expectEqualStrings("const x = 1;\nfn f() void {\n    return;\n}\n", saved);

    // Off: saved as typed.
    try ed.feed("<cmd:toggle_format_on_save>ggiconst  y=2;<CR><Esc><Space>s");
    const raw = try tmp.dir.readFileAlloc(io, "m.zig", gpa, .limited(1024));
    defer gpa.free(raw);
    try testing.expect(std.mem.startsWith(u8, raw, "const  y=2;\n"));
}

test "snippet without $0 (clangd's printf): Tab after the last argument leaves the call, then the ;" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-snippet.c");
    try ed.feed("ipr");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"printf","insertText":"printf(${1:const char *, ...})","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("<Tab>\"hi\"<Tab>");
    try expectText(&ed, "printf(\"hi\")");
    try testing.expectEqual(ed.text().len(), ed.view.cursor); // after the )
    try ed.feed("<Tab>");
    try expectText(&ed, "printf(\"hi\");");
    try testing.expectEqual(null, ed.snippet);
}

test "any function completion ends with ; on Tab: no arguments, plain text; not for keywords" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-calls.zig");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[
        \\ {"label":"reset","kind":3,"insertText":"reset()","insertTextFormat":2},
        \\ {"label":"flush","kind":2,"insertText":"flush()"},
        \\ {"label":"iffy","kind":14,"insertText":"if (${1:cond}) {$0}","insertTextFormat":2}
        \\]}
    , .{});
    defer reply.deinit();

    try ed.feed("ires");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("<Tab><Tab>"); // a snippet with nothing to fill in
    try expectText(&ed, "reset();");

    try ed.feed("<CR>flu");
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 3, reply.value);
    try ed.feed("<Tab><Tab>"); // plain text
    try expectText(&ed, "reset();\nflush();");

    try ed.feed("<CR>iff");
    try completion_ops.showCompletion(&ed, ed.buffer, ed.view.cursor - 3, reply.value);
    try ed.feed("<Tab>x<Tab>"); // a keyword snippet: no ;
    try expectText(&ed, "reset();\nflush();\nif (x) {}");
    try testing.expectEqual(null, ed.snippet);
}

test "completion: arrow keys and Ctrl-n / Ctrl-p move through the suggestions" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doOne"},{"label":"doTwo"},{"label":"doThree"}]}
    , .{});
    defer reply.deinit();
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try testing.expectEqual(0, ed.completion.?.selected);
    try ed.feed("<Down>");
    try testing.expectEqual(1, ed.completion.?.selected);
    try ed.feed("<Down>");
    try testing.expectEqual(2, ed.completion.?.selected);
    try ed.feed("<Up>");
    try testing.expectEqual(1, ed.completion.?.selected);
    try ed.feed("<C-n><C-p><C-p>");
    try testing.expectEqual(0, ed.completion.?.selected);
    try ed.feed("<Down><CR>");
    try expectText(&ed, "doTwo");
}

test "completion: zls builtins after @ (the server's range starts after the @)" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ix = @");
    // As zls answers: filterText without the @, the edit from after it.
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[
        \\ {"label":"@as","filterText":"as","insertTextFormat":2,"textEdit":{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":5}},"newText":"as(${1:T}, ${2:x})"}},
        \\ {"label":"@import","filterText":"import","insertTextFormat":2,"textEdit":{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":5}},"newText":"import(${1:path})"}}
        \\]}
    , .{});
    defer reply.deinit();
    try completion_ops.showCompletion(&ed, ed.buffer, 4, reply.value); // our guess: the word starts at the @
    try testing.expectEqual(2, ed.completion.?.shown.items.len);
    try ed.feed("im");
    try testing.expectEqual(1, ed.completion.?.shown.items.len);
    try ed.feed("<Tab>");
    try expectText(&ed, "x = @import(path)");
}

test "completion: a typo hides the list, fixing it brings the list back" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doOne"},{"label":"doTwo"}]}
    , .{});
    defer reply.deinit();
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try testing.expectEqual(2, completion_ops.completionShown(&ed).?.shown.items.len);
    try ed.feed("x"); // "dox": nothing matches
    try testing.expectEqual(null, completion_ops.completionShown(&ed));
    try testing.expect(ed.completion != null); // kept, out of sight
    try ed.feed("<CR>"); // keys act as if no popup were there...
    try expectText(&ed, "dox\n");
    try testing.expectEqual(null, ed.completion); // ...and leaving the word drops it
    try ed.feed("<BS>");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try testing.expectEqual(null, completion_ops.completionShown(&ed));
    try ed.feed("<BS>T"); // fix the typo and go on: "doT"
    try testing.expectEqual(1, completion_ops.completionShown(&ed).?.shown.items.len);
    try ed.feed("<BS><BS><BS>"); // back to nothing typed: every item
    try testing.expectEqual(2, completion_ops.completionShown(&ed).?.shown.items.len);
    try ed.feed("d<Down><Tab>");
    try expectText(&ed, "doTwo");
}

test "completion: letter case never rules a suggestion out" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("iAR");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"arrayList"},{"label":"ArrayList"},{"label":"other"}]}
    , .{});
    defer reply.deinit();
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try testing.expectEqual(2, completion_ops.completionShown(&ed).?.shown.items.len);
    try ed.feed("<BS><BS><BS>arr");
    try testing.expectEqual(2, completion_ops.completionShown(&ed).?.shown.items.len);
}

test "snippet: Esc removes the arguments that were never filled in, with their commas" {
    const gpa = testing.allocator;
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doThing","insertText":"doThing(${1:path: Path}, ${2:opts: Opts}, ${3:last})$0","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();

    // Nothing filled in: the whole argument list goes.
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("<Tab>");
    try expectText(&ed, "doThing(path: Path, opts: Opts, last)");
    try ed.feed("<Esc>");
    try expectText(&ed, "doThing()");
    try testing.expectEqual(Mode.normal, ed.mode);
    try testing.expectEqual(null, ed.snippet);
    try testing.expectEqual(7, ed.view.cursor); // on the (
    try ed.feed("u"); // one undo step for the whole insert
    try expectText(&ed, "");

    // The first one typed over: the rest go, and the comma after it.
    try ed.feed("ido");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("<Tab>src<Esc>");
    try expectText(&ed, "doThing(src)");

    // Tabbed on to the second without typing: it goes (the first was left
    // as it came); the third was never reached.
    try ed.feed("S"); // start over on the line
    try ed.feed("do");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("<Tab><Tab><Esc>");
    try expectText(&ed, "doThing(path: Path)");
}

test "inlay hints: parsed from zls's answer, kept in place through edits, mapped to columns" {
    const gpa = testing.allocator;
    var ed = try testEditor("const x = add(1, 2);\nconst s = \"zile\";");
    defer ed.deinit();
    ed.options.inlay_hints = true;
    // As zls answers (labels, padding, byte columns).
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"position":{"line":0,"character":7},"label":": u32","kind":1,"paddingLeft":false,"paddingRight":false},
        \\ {"position":{"line":0,"character":14},"label":"a:","kind":2,"paddingLeft":false,"paddingRight":true},
        \\ {"position":{"line":0,"character":17},"label":[{"value":"b"},{"value":":"}],"kind":2,"paddingRight":true},
        \\ {"position":{"line":1,"character":7},"label":": *const [4:0]u8","kind":1},
        \\ {"position":{"line":9,"character":0},"label":"off the end"},
        \\ {"position":{"line":0,"character":2},"label":""}]
    , .{});
    defer reply.deinit();
    var parsed: std.ArrayList(Buffer.Hint) = .empty;
    defer {
        for (parsed.items) |h| gpa.free(h.text);
        parsed.deinit(gpa);
    }
    try Lsp.parseInlayHints(gpa, ed.text(), reply.value, &parsed);
    try testing.expectEqual(4, parsed.items.len); // the empty label and the missing line are skipped
    try testing.expectEqualStrings("b: ", parsed.items[2].text); // parts joined, padding added

    try inlay.takeInlayHints(&ed, ed.buffer, &parsed, 0, 1, ed.buffer.edit_version);
    try testing.expectEqual(0, parsed.items.len); // the buffer has them now
    var buf: [max_line_hints]LineHint = undefined;
    const first = inlay.lineHints(&ed, ed.buffer, 0, &buf);
    try testing.expectEqual(3, first.len);
    try testing.expectEqual(7, first[0].off);
    // `x` ends at 7: the hint is in front of the byte at 7 (the space).
    try testing.expectEqual(0, hintShift(first, 6));
    try testing.expectEqual(5, hintShift(first, 7)); // ": u32"
    try testing.expectEqual(5 + 3, hintShift(first, 14)); // + "a: "
    try testing.expectEqual(5, hintShiftBefore(first, 14)); // a range ending at 14 stops before it
    // And back: the screen column of a character after the hints.
    const bytes = ed.text().lineSlice(0);
    try testing.expectEqual(14, hintVisualToText(first, bytes, 14 + 5 + 3, 4)); // the `1`
    try testing.expectEqual(7, hintVisualToText(first, bytes, 8, 4)); // on the first hint: the text after it

    // Typing before a hint moves it on; deleting around it keeps it in the line.
    try ed.feed("ggi// <Esc>");
    const moved = inlay.lineHints(&ed, ed.buffer, 0, &buf);
    try testing.expectEqual(10, moved[0].off);
    try ed.feed("0dw");
    try testing.expectEqual(7, inlay.lineHints(&ed, ed.buffer, 0, &buf)[0].off);
    // Not on the line being typed on in insert mode.
    try ed.feed("A");
    try testing.expectEqual(0, inlay.lineHints(&ed, ed.buffer, 0, &buf).len);
    try testing.expectEqual(1, inlay.lineHints(&ed, ed.buffer, 1, &buf).len);
    try ed.feed("<Esc>");
    try testing.expectEqual(3, inlay.lineHints(&ed, ed.buffer, 0, &buf).len);

    // A new answer for the lines replaces the old; one for stale text is dropped.
    var again: std.ArrayList(Buffer.Hint) = .empty;
    defer again.deinit(gpa);
    try again.append(gpa, .{ .pos = 0, .text = try gpa.dupe(u8, "new ") });
    const stale_version = ed.buffer.edit_version -% 1;
    try inlay.takeInlayHints(&ed, ed.buffer, &again, 0, 1, stale_version);
    try testing.expectEqual(3, inlay.lineHints(&ed, ed.buffer, 0, &buf).len); // dropped
    gpa.free(again.items[0].text);
    again.clearRetainingCapacity();
    try again.append(gpa, .{ .pos = 0, .text = try gpa.dupe(u8, "new ") });
    try inlay.takeInlayHints(&ed, ed.buffer, &again, 0, 1, ed.buffer.edit_version);
    try testing.expectEqual(1, inlay.lineHints(&ed, ed.buffer, 0, &buf).len);
    try testing.expectEqual(0, inlay.lineHints(&ed, ed.buffer, 1, &buf).len);
    // Off: nothing.
    ed.options.inlay_hints = false;
    try testing.expectEqual(0, inlay.lineHints(&ed, ed.buffer, 0, &buf).len);
}

test "inlay hints: a click lands on the character it looks like it is on" {
    const gpa = testing.allocator;
    var ed = try testEditor("const x = 1;");
    defer ed.deinit();
    var new: std.ArrayList(Buffer.Hint) = .empty;
    defer new.deinit(gpa);
    try new.append(gpa, .{ .pos = 7, .text = try gpa.dupe(u8, ": u8") });
    try inlay.takeInlayHints(&ed, ed.buffer, &new, 0, 0, ed.buffer.edit_version);
    row_model.clickCell(&ed, 0, 6); // the `x`
    try testing.expectEqual(6, ed.view.cursor);
    row_model.clickCell(&ed, 0, 12); // after the hint: " = " begins at screen column 11
    try testing.expectEqual(8, ed.view.cursor); // the `=` is at 8, screen column 12
    row_model.clickCell(&ed, 0, 8); // on the hint: the text right after it
    try testing.expectEqual(7, ed.view.cursor);
}

test "completion: ( takes the selected suggestion's name, then opens the call" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"drawText","insertText":"drawText(${1:text}, ${2:x})$0","insertTextFormat":2},{"label":"other"}]}
    , .{});
    defer reply.deinit();
    try ed.feed("idrawtex");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try testing.expectEqual(1, completion_ops.completionShown(&ed).?.shown.items.len);
    try ed.feed("(");
    try expectText(&ed, "drawText()");
    try testing.expectEqual(9, ed.view.cursor); // inside the parentheses
    try testing.expectEqual(null, ed.completion);
    // A plain item works the same; nothing to take when nothing matches.
    try ed.feed("<Esc>Soth");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("(");
    try expectText(&ed, "other()");
    try ed.feed("<Esc>Szzz");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    try ed.feed("(");
    try expectText(&ed, "zzz()");
}

test "completion: the exact name first, then shorter names, whatever order the server sent" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"DrawTexture"},{"label":"DrawTextureV"},{"label":"DrawTextEx"},{"label":"DrawText"},{"label":"DrawTextCodepoint"}]}
    , .{});
    defer reply.deinit();
    try ed.feed("idrawtext");
    try completion_ops.showCompletion(&ed, ed.buffer, 0, reply.value);
    const c = completion_ops.completionShown(&ed).?;
    try testing.expectEqualStrings("DrawText", c.items[c.shown.items[0]].label);
    // Not yet the whole name: the shortest of the equal matches leads.
    try ed.feed("<BS>");
    const d = completion_ops.completionShown(&ed).?;
    try testing.expectEqualStrings("DrawText", d.items[d.shown.items[0]].label);
    try testing.expectEqualStrings("DrawTextEx", d.items[d.shown.items[1]].label);
    try testing.expectEqualStrings("DrawTexture", d.items[d.shown.items[2]].label);
    try ed.feed("<CR>"); // Enter takes the first one
    try expectText(&ed, "DrawText");
}

test "diagnostics: a long message wraps onto rows under its line, which j skips" {
    var ed = try testEditor("    const a = 1;\nnext\n");
    defer ed.deinit();
    ed.options.diagnostic_text = true;
    ed.setViewSize(10, 40);
    const diags = try ed.gpa.alloc(Lsp.Diagnostic, 1);
    diags[0] = .{ .line = 0, .col = 10, .end_line = 0, .end_col = 11, .severity = .err, .message = try ed.gpa.dupe(u8, "expected type 'u8', found 'comptime_int' because of reasons") };
    try ed.check_results.append(ed.gpa, .{ .buffer = ed.buffer, .diags = diags, .libc = false });
    var buf: [max_segments]Seg = undefined;
    const d = row_model.diagText(&ed, 0, row_model.segments(&ed, 0, &buf)).?;
    // 16 cells of text, 3 of gap: 21 left after it, then rows at the indent.
    try testing.expectEqual(19, d.first_col);
    try testing.expectEqualStrings("expected type 'u8',", d.pieces[0]);
    try testing.expectEqual(4, d.col);
    try testing.expectEqualStrings("found 'comptime_int' because of", d.pieces[1]);
    try testing.expectEqualStrings("reasons", d.pieces[2]);
    try testing.expectEqual(2, d.rows());
    try testing.expectEqual(3, row_model.subRows(&ed, 0));
    // j goes from the line to the next one, over the message's row.
    try ed.feed("j");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("k");
    try testing.expectEqual(0, ed.cursorLine());
    // Off: no rows.
    ed.options.diagnostic_text = false;
    try testing.expectEqual(1, row_model.subRows(&ed, 0));
}

test "diagnostics: the mouse resting on one (or its message) finds it after a moment" {
    var ed = try testEditor("    const a = 1;\nnext\n");
    defer ed.deinit();
    ed.options.diagnostic_text = true; // the message's rows too
    ed.setViewSize(10, 40);
    const diags = try ed.gpa.alloc(Lsp.Diagnostic, 1);
    diags[0] = .{ .line = 0, .col = 10, .end_line = 0, .end_col = 11, .severity = .err, .message = try ed.gpa.dupe(u8, "expected type 'u8', found 'comptime_int' because of reasons") };
    try ed.check_results.append(ed.gpa, .{ .buffer = ed.buffer, .diags = diags, .libc = false });
    var out: [4]*const Lsp.Diagnostic = undefined;
    // On the `a`: nothing yet, then the diagnostic.
    resting.mouseHover(&ed, .{ 0, 10 });
    try testing.expect(ed.mouse_hover.?.rest.shows);
    ed.now = notifications.timeAfter(&ed, 100);
    try testing.expectEqual(0, borders.hoveredDiagnostics(&ed, &out).len);
    ed.now = notifications.timeAfter(&ed, 500);
    try testing.expectEqual(1, borders.hoveredDiagnostics(&ed, &out).len);
    // Elsewhere on the line: nothing.
    resting.mouseHover(&ed, .{ 0, 4 });
    ed.now = notifications.timeAfter(&ed, 500);
    try testing.expectEqual(0, borders.hoveredDiagnostics(&ed, &out).len);
    // On the message's row under the line: its diagnostic.
    resting.mouseHover(&ed, .{ 1, 6 });
    ed.now = notifications.timeAfter(&ed, 500);
    try testing.expectEqual(1, borders.hoveredDiagnostics(&ed, &out).len);
    // On the next line: nothing.
    resting.mouseHover(&ed, .{ 3, 1 });
    ed.now = notifications.timeAfter(&ed, 500);
    try testing.expectEqual(0, borders.hoveredDiagnostics(&ed, &out).len);
}

test "diagnostics: by default no message after the line (it pops up), in both front ends" {
    var ed = try testEditor("    const a = 1;\nnext\n");
    defer ed.deinit();
    ed.setViewSize(10, 40);
    const diags = try ed.gpa.alloc(Lsp.Diagnostic, 1);
    diags[0] = .{ .line = 0, .col = 10, .end_line = 0, .end_col = 11, .severity = .err, .message = try ed.gpa.dupe(u8, "expected type 'u8', found 'comptime_int' because of reasons") };
    try ed.check_results.append(ed.gpa, .{ .buffer = ed.buffer, .diags = diags, .libc = false });
    var buf: [max_segments]Seg = undefined;
    try testing.expectEqual(1, row_model.subRows(&ed, 0));
    try testing.expectEqual(null, row_model.diagText(&ed, 0, row_model.segments(&ed, 0, &buf)));
    ed.options.diagnostic_text = true;
    try testing.expectEqual(3, row_model.subRows(&ed, 0));
}
