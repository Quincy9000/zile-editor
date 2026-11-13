//! Editor tests: motions.

const std = @import("std");
const testing = std.testing;
const commands = @import("../commands.zig");
const code_motion = @import("../editor/code_motion.zig");
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

test "marks: m sets, ' and ` go (also as motions), SPC f m lists; global marks cross files" {
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
    try testing.expectEqual(2, ed.picker.?.rowCount()); // B and this file's c
    try ed.feed("q'B");
    try testing.expectEqual(null, ed.buffer.path); // back in the scratch buffer
}

test "f, t, F, T ignore letter case; ; and , repeat" {
    var ed = try testEditor("xAbca\nDa");
    defer ed.deinit();
    try ed.feed("fa");
    try expectCursor(&ed, 0, 1); // the capital A
    try ed.feed(".");
    try expectCursor(&ed, 0, 4);
    try ed.feed("FA"); // a capital finds lower case too
    try expectCursor(&ed, 0, 1);
    try ed.feed("0dtA"); // till still works after an operator
    try expectText(&ed, "Abca\nDa");
    try ed.feed("u");
    try ed.feed("fd"); // on to the next line: "Da"
    try expectCursor(&ed, 1, 0);
    try ed.feed("$dFa"); // back across the line to the previous a; F is exclusive: "a\nD" goes
    try expectText(&ed, "xAbca");
}
