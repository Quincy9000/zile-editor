//! Editor tests: motions.

const std = @import("std");
const testing = std.testing;
const commands = @import("../commands.zig");
const code_motion = @import("../editor/code_motion.zig");
const jumplist = @import("../editor/jumplist.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const support = @import("support.zig");
const testEditor = support.testEditor;
const testEditorAs = support.testEditorAs;
const expectText = support.expectText;
const expectCursor = support.expectCursor;
const settlePicker = support.settlePicker;

test "counts and word motions" {
    var ed = try testEditor("one two three four");
    defer ed.deinit();
    try ed.feed("2w");
    try testing.expectEqual(8, ed.view.cursor);
    try ed.feed("b");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed("$");
    try testing.expectEqual(17, ed.view.cursor);
    try ed.feed("0");
    try testing.expectEqual(0, ed.view.cursor);
}

test "sticky column across short lines" {
    var ed = try testEditor("long line here\nab\nanother long line");
    defer ed.deinit();
    try ed.feed("10l");
    try testing.expectEqual(10, ed.cursorCol());
    try ed.feed("j");
    try testing.expectEqual(1, ed.cursorCol()); // clamped onto 'b'
    try ed.feed("j");
    try testing.expectEqual(10, ed.cursorCol()); // restored
}

test "gg and G with counts" {
    var ed = try testEditor("a\n  b\nc\nd");
    defer ed.deinit();
    try ed.feed("G");
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("2G");
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expectEqual(2, ed.cursorCol()); // first non-blank
    try ed.feed("gg");
    try testing.expectEqual(0, ed.cursorLine());
}

test "operators with motions" {
    var ed = try testEditor("one two three\nfour five");
    defer ed.deinit();
    try ed.feed("dw");
    try expectText(&ed, "two three\nfour five");
    try ed.feed("wdw"); // last word: keeps the line break
    try expectText(&ed, "two \nfour five");
    try ed.feed("ggd$");
    try expectText(&ed, "\nfour five");
    try ed.feed("jde");
    try expectText(&ed, "\n five");
    try ed.feed("u");
    try expectText(&ed, "\nfour five");
}

test "statement object: vis/dis/yas take the header line and its block" {
    var ed = try testEditor("fn a() void {\n    if (x) {\n        y();\n    }\n}\n");
    defer ed.deinit();
    try ed.feed("jvis");
    try testing.expectEqual(.visual, ed.mode);
    const r = code_motion.visualRange(&ed);
    try testing.expectEqualStrings("    if (x) {\n        y();\n    }", ed.text().slice(r.start, r.end));
    try testing.expect(r.linewise);
    try ed.feed("<Esc>dis");
    try expectText(&ed, "fn a() void {\n}\n");
    try ed.feed("u");
    try ed.feed("ggjjdas"); // from inside the block
    try expectText(&ed, "fn a() void {\n}\n");
}

test "text objects" {
    var ed = try testEditor("call(a, \"str ing\", [1, 2])");
    defer ed.deinit();
    try ed.feed("fsdi\"");
    try expectText(&ed, "call(a, \"\", [1, 2])");
    try ed.feed("f1ci[x<Esc>");
    try expectText(&ed, "call(a, \"\", [x])");
    try ed.feed("0f,da(");
    try expectText(&ed, "call");
}

test "f, t, ; and ," {
    var ed = try testEditor("a.b.c.d");
    defer ed.deinit();
    try ed.feed("f.");
    try testing.expectEqual(1, ed.view.cursor);
    try ed.feed("..");
    try testing.expectEqual(5, ed.view.cursor);
    try ed.feed(",");
    try testing.expectEqual(3, ed.view.cursor);
    try ed.feed("0dt.");
    try expectText(&ed, ".b.c.d");
}

test "f searches the line from its start; ; walks on; after an operator it starts at the cursor" {
    var ed = try testEditor("a.b.c.d\nxx");
    defer ed.deinit();
    try ed.feed("$f.");
    try testing.expectEqual(1, ed.view.cursor); // from the left, though the cursor was at the end
    try ed.feed(".");
    try testing.expectEqual(3, ed.view.cursor);
    try ed.feed("0lldf.");
    try expectText(&ed, "a.c.d\nxx"); // from the cursor
}

test ". repeats the last find, or the last change if that came after" {
    var ed = try testEditor("a.b.c.d");
    defer ed.deinit();
    try ed.feed("f..");
    try testing.expectEqual(3, ed.view.cursor); // f. then . : the second dot
    try ed.feed("x"); // a change: . repeats it now
    try expectText(&ed, "a.bc.d");
    try ed.feed(".");
    try expectText(&ed, "a.b.d");
}

test "structure keys: grow (Alt-u) / shrink (Alt-i), siblings, carrying a node, functions, case" {
    var ed = try testEditorAs("a.zig", "fn add(first: u8, second: u8) u8 {\n    return call(first, second, 3);\n}\n\nfn two() void {}");
    defer ed.deinit();
    const t = ed.text();
    // Alt-u from the cursor on `first` (the argument): the name, then the call.
    try ed.feed("jff<A-u>");
    var r = code_motion.visualRange(&ed);
    try testing.expectEqualStrings("first", t.slice(r.start, r.end));
    try ed.feed("<A-u>");
    r = code_motion.visualRange(&ed);
    try testing.expectEqualStrings("call(first, second, 3)", t.slice(r.start, r.end));
    // Alt-i goes back, and from the first step to the cursor.
    try ed.feed("<A-i>");
    r = code_motion.visualRange(&ed);
    try testing.expectEqualStrings("first", t.slice(r.start, r.end));
    try ed.feed("<A-i>");
    try testing.expectEqual(Mode.normal, ed.mode);
    // Alt-n: the next argument.
    try ed.feed("<A-n>");
    try testing.expectEqual(t.lineStart(1) + 23, ed.view.cursor); // on `second`
    // Alt-P carries `second` left past `first`; again does nothing at the edge.
    try ed.feed("<A-P>");
    try testing.expectEqualStrings("    return call(second, first, 3);", t.lineSlice(1));
    try testing.expectEqual(t.lineStart(1) + 16, ed.view.cursor);
    try ed.feed("u");
    try testing.expectEqualStrings("    return call(first, second, 3);", t.lineSlice(1));
    // Selected, it stays selected as it travels.
    try ed.feed("0ff<A-u><A-N><A-N>");
    try testing.expectEqualStrings("    return call(second, 3, first);", t.lineSlice(1));
    r = code_motion.visualRange(&ed);
    try testing.expectEqualStrings("first", t.slice(r.start, r.end));
    try ed.feed("<Esc>");
    // Functions.
    try ed.feed("gg<A-f>");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("<A-F>");
    try testing.expectEqual(0, ed.cursorLine());
    // Case: add -> Add -> ADD -> add (kebab and snake are the same for one word).
    try ed.feed("w<A-c>");
    try testing.expectEqualStrings("fn Add(", t.lineSlice(0)[0..7]);
    try ed.feed("<A-c>");
    try testing.expectEqualStrings("fn ADD(", t.lineSlice(0)[0..7]);
    try ed.feed("<A-c>");
    try testing.expectEqualStrings("fn add(", t.lineSlice(0)[0..7]);
}

test "J, r, ~, >>, %" {
    var ed = try testEditor("foo(\n    bar)\nx");
    defer ed.deinit();
    try ed.feed("J");
    try expectText(&ed, "foo( bar)\nx");
    try ed.feed("0");
    try ed.runCommand(commands.get("replace_char")); // no key of its own anymore
    try ed.feed("F");
    try expectText(&ed, "Foo( bar)\nx");
    try ed.feed("l~");
    try expectText(&ed, "FOo( bar)\nx");
    try ed.feed(">>");
    try expectText(&ed, "    FOo( bar)\nx");
    try ed.feed("0%"); // first bracket on the line is '(' at 7; its partner is at 12
    try testing.expectEqual(12, ed.view.cursor);
    try ed.feed("<lt><lt>");
    try expectText(&ed, "FOo( bar)\nx");
}

test "il / al line objects (nvim's vil / val)" {
    var ed = try testEditor("first\n    second line  \nthird");
    defer ed.deinit();
    try ed.feed("jvild");
    try expectText(&ed, "first\n      \nthird");
    try ed.feed("u");
    try ed.feed("cilnew<Esc>");
    try expectText(&ed, "first\n    new  \nthird");
    try ed.feed("yal");
    try testing.expectEqualStrings("first\n    new  \nthird\n", ed.registers.get(null).?.text);
    try ed.feed("valc"); // change everything
    try ed.feed("gone<Esc>");
    try expectText(&ed, "gone");
}

test "syntax text objects: dif, daa, cia, vac" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-objects.zig"); // missing file: empty, but zig syntax
    try ed.insertAt(0, "fn f(a: u8, b: u8) void {\n    g(a, b);\n}");
    try ed.buffer.history.commit(ed.gpa);
    try ed.feed("fbdaa"); // on the parameter `b`: takes ", b: u8"
    try expectText(&ed, "fn f(a: u8) void {\n    g(a, b);\n}");
    try ed.feed("j^facia"); // first call argument
    try ed.feed("x<Esc>");
    try expectText(&ed, "fn f(a: u8) void {\n    g(x, b);\n}");
    try ed.feed("dif");
    try expectText(&ed, "fn f(a: u8) void {\n}");
    try ed.feed("u");
    try ed.feed("ggvac");
    try testing.expectEqual(.visual, ed.mode); // no class here: selection unchanged
}

test "dib / ci\" jump to the nearest pair ahead" {
    var ed = try testEditor("let v = foo(a, b);\nprint(\"old\")");
    defer ed.deinit();
    try ed.feed("dib");
    try expectText(&ed, "let v = foo();\nprint(\"old\")");
    try testing.expectEqual(12, ed.view.cursor);
    try ed.feed("ciqnew<Esc>");
    try expectText(&ed, "let v = foo();\nprint(\"new\")");
    try ed.feed("gg0va[");
    try testing.expectEqual(.visual, ed.mode); // no [] anywhere: nothing selected, no crash
}

test "SPC ,: back to the last jump, and again: back here" {
    var ed = try testEditor("a\nb\nc\nd\ne");
    defer ed.deinit();
    try ed.feed("jG"); // a jump from line 2 to the end
    try ed.feed("<Space>,");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<Space>,");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("<Space>,");
    try testing.expectEqual(1, ed.cursorLine());
}

test "bookmarks: m sets, ' and ` go (also as motions), SPC m lists; they cross files" {
    var ed = try testEditor("one\n  two\nthree\nfour");
    defer ed.deinit();
    try ed.feed("jwma"); // on "two"
    try ed.feed("G'a");
    try expectCursor(&ed, 1, 2);
    try ed.feed("gg`a");
    try expectCursor(&ed, 1, 2);
    try ed.feed("ggOzero<Esc>"); // marks move with the text
    try ed.feed("G'a");
    try testing.expectEqual(2, ed.cursorLine());
    try ed.feed("Gd'a"); // linewise, as a motion
    try expectText(&ed, "zero\none");
    try ed.feed("'z");
    try testing.expectEqual(.info, ed.message.kind);

    try ed.feed("mB"); // a global mark, here in the scratch buffer
    try ed.openFile("src/pairs.zig");
    try ed.feed("5jmc");
    try ed.feed("<cmd:pick_mark>");
    settlePicker(&ed);
    try testing.expectEqual(3, ed.picker.?.rowCount()); // every file's: a, B and c
    try ed.feed("<Esc>q'B");
    try testing.expectEqual(null, ed.buffer.path); // back in the scratch buffer
}

test "bookmarks: m shows a box for one key; the same key again removes; SPC m finds and removes" {
    var ed = try testEditor("zero\none\ntwo\nthree");
    defer ed.deinit();
    try ed.feed("jm");
    try testing.expect(ed.awaiting_char.?.cmd.char_prompt.len > 0); // the box is up, for one key
    try ed.feed("x");
    try ed.feed("jjm "); // Space: no name
    try testing.expectEqual(2, ed.marks.items.len);
    try testing.expectEqual('x', ed.marks.items[0].name);
    try ed.feed("m "); // again on the same line: off
    try testing.expectEqual(1, ed.marks.items.len);
    try ed.feed("m<Esc>"); // given up
    try testing.expectEqual(1, ed.marks.items.len);
    try ed.feed("m1ggO<Esc>"); // any key names one; bookmarks follow their text
    try testing.expect(jumplist.bookmarkOn(&ed, 2) != null);
    try testing.expect(jumplist.bookmarkOn(&ed, 4) != null);
    try ed.feed("'1");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("gg<Space>m");
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    try ed.feed("1"); // by name
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("ggmx"); // a name in use moves
    try testing.expectEqual(2, ed.marks.items.len);
    try testing.expect(jumplist.bookmarkOn(&ed, 0) != null);
    try testing.expect(jumplist.bookmarkOn(&ed, 2) == null);
    try ed.feed("<Space>m");
    settlePicker(&ed);
    try ed.feed("<Esc>d"); // the first row is the oldest: 1
    settlePicker(&ed);
    try testing.expectEqual(1, ed.marks.items.len);
    try testing.expectEqual('x', ed.marks.items[0].name);
    try ed.feed("qjmyjmz'x"); // a jump to one puts it last
    try testing.expectEqual('y', ed.marks.items[0].name);
    try testing.expectEqual('x', ed.marks.items[2].name);
    try ed.feed("<Space>m");
    settlePicker(&ed);
    try ed.feed("<CR>"); // y, the first row
    try testing.expectEqual('z', ed.marks.items[0].name);
    try testing.expectEqual('y', ed.marks.items[2].name);
}


test "jumplist picker: the place picked sinks to the bottom, the place left is on top" {
    var ed = try testEditor("a\nb\nc\nd\ne\nf");
    defer ed.deinit();
    try ed.feed("jG"); // from line 1
    try ed.feed("3gg"); // from line 5
    try ed.feed("<Space>j");
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    try ed.feed("<CR>"); // the top row: line 5, the last place left
    try testing.expectEqual(5, ed.cursorLine());
    try ed.feed("<Space>j");
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount()); // line 2 (just left), then 1; not line 5, where the cursor is
    try ed.feed("<CR>");
    try testing.expectEqual(2, ed.cursorLine());
    try ed.feed("<C-o>"); // and back where that jump left from
    try testing.expectEqual(5, ed.cursorLine());
}

test "jumplist: a place the cursor is already on is passed over" {
    var ed = try testEditor("a\nb\nc\nd\ne\nf");
    defer ed.deinit();
    try ed.feed("jG3gg"); // left line 1, then line 5
    try ed.feed("<C-o>"); // back on line 5 (line 2 remembered)
    try testing.expectEqual(5, ed.cursorLine());
    try ed.feed("kkkk"); // by hand to line 1: where <C-o> would go next
    try ed.feed("<Space>j");
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount()); // lines 2 and 5, not this one
    try ed.feed("q4j"); // on line 5 again, as the list has it
    try ed.feed("<C-o>");
    try testing.expectEqual(1, ed.cursorLine());
}
