//! Editor tests: multicursor.

const std = @import("std");
const testing = std.testing;
const Editor = @import("../Editor.zig");
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;

test "multicursor: qf in a selection puts cursors on the matches inside it" {
    var ed = try testEditor("a1 a2\nxx a3 a4\na5");
    defer ed.deinit();
    try ed.feed("Vjsa<CR>");
    try testing.expectEqual(3, ed.cursors.items.len); // four matches, not the fifth
    try ed.feed("cZ<Esc>");
    try expectText(&ed, "Z1 Z2\nxx Z3 Z4\na5");
}

test "multicursor: visual I/A types on every line" {
    var ed = try testEditor("a\n  b\nc");
    defer ed.deinit();
    try ed.feed("VjjA,<Esc>");
    try expectText(&ed, "a,\n  b,\nc,");
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("<Esc>"); // removes the extra cursors
    try testing.expectEqual(0, ed.cursors.items.len);
    try ed.feed("ggVjjI- <Esc>");
    try expectText(&ed, "- a,\n  - b,\n- c,");
    // One undo step for the whole multi-cursor change.
    try ed.feed("u");
    try expectText(&ed, "a,\n  b,\nc,");
}

test "multicursor: normal-mode commands run at every cursor" {
    var ed = try testEditor("foo: u32,\nbarbaz: u8,\nx: bool,");
    defer ed.deinit();
    try ed.feed("qjqj"); // three cursors down the column
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("0i.<Esc>f:C = 0,<Esc>");
    try expectText(&ed, ".foo = 0,\n.barbaz = 0,\n.x = 0,");
    try ed.feed("<Esc>dd");
    try testing.expectEqual(0, ed.cursors.items.len);
}

test "multicursor: gzn adds the next match, then ciw changes all" {
    var ed = try testEditor("let a = old; old(old_x); old");
    defer ed.deinit();
    try ed.feed("foqnqn");
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("ciwnew<Esc>");
    try expectText(&ed, "let a = new; new(old_x); new");
    try ed.feed("<Esc>uggfoqa");
    try testing.expectEqual(2, ed.cursors.items.len); // old_x is not the word
    try ed.feed("<Esc>");
}

test "multicursor: Tab in the snipe or search prompt makes cursors" {
    var ed = try testEditor("int a; int b;\nfloat c; int d;");
    defer ed.deinit();
    ed.view.rows = 10;
    try ed.feed("sint<Tab>");
    try testing.expectEqual(.visual, ed.mode);
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("cuint<Esc>");
    try expectText(&ed, "uint a; uint b;\nfloat c; uint d;");
    try ed.feed("<Esc>gg/uint<Tab><Esc>");
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("x"); // each cursor is on its match's last character
    try expectText(&ed, "uin a; uin b;\nfloat c; uin d;");
}
