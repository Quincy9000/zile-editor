//! Editor tests: sql.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const run_popup = @import("../editor/run_popup.zig");
const sql_ops = @import("../editor/sql_ops.zig");
const completion_ops = @import("../editor/completion_ops.zig");
const Editor = @import("../Editor.zig");
const support = @import("support.zig");
const testEditor = support.testEditor;
const testEditorAs = support.testEditorAs;

test "SQL file: Ctrl-Enter runs the statement at the cursor; the runner has no SQL in it" {
    var ed = try testEditorAs("q.sql", "select 1;\nselect 2;\n");
    defer ed.deinit();
    // No database under tests: it gets as far as looking for one.
    try ed.feed("j<C-CR>");
    try testing.expect(std.mem.startsWith(u8, ed.message.buf[0..ed.message.len], "no database"));
    ed.setMessage(.info, "", .{});
    // While typing too, and you stay typing.
    try ed.feed("A<C-CR>");
    try testing.expect(ed.mode == .insert);
    try testing.expect(std.mem.startsWith(u8, ed.message.buf[0..ed.message.len], "no database"));
    try testing.expectEqualStrings("select 2;", ed.text().lineSlice(1));
    try ed.feed("<Esc> r");
    const p = ed.picker orelse return error.TestUnexpectedResult;
    p.sync();
    for (0..p.rowCount()) |row| if (p.itemAt(row)) |it| try testing.expect(!std.mem.startsWith(u8, it.text, "SQL"));
}

test "Ctrl-Enter while typing outside SQL is Enter" {
    var ed = try testEditorAs("a.txt", "one");
    defer ed.deinit();
    try ed.feed("A<C-CR>two");
    try testing.expectEqualStrings("two", ed.text().lineSlice(1));
}

test "SQL results: a statement's rows in a grid (vim keys: cells, blocks, rows, search); an error at the cursor" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const db = try std.fs.path.join(gpa, &.{ dir, "app.db" });
    defer gpa.free(db);
    const made = std.process.run(gpa, testing.io, .{ .argv = &.{ "sqlite3", db, "create table users(id integer, email text, note text); insert into users values (1, 'a@x.io', 'two\nlines'), (2, 'b@x.io', 'has, a comma');" } }) catch return error.SkipZigTest;
    gpa.free(made.stdout);
    gpa.free(made.stderr);
    var ed = try testEditorAs("q.sql", "select * from users;\n");
    defer ed.deinit();
    const S = struct {
        fn finish(e: *Editor) void {
            e.sql_results.?.wait();
            e.tick();
        }
    };
    try run_popup.startSqlStatement(&ed, db, "select * from users", db);
    S.finish(&ed);
    const g = &(ed.grid orelse return error.TestUnexpectedResult);
    try testing.expectEqual(2, g.rows.len);
    // The grid has the keys: `l` is a cell to the right, not the code's.
    try ed.feed("ly");
    try testing.expectEqualStrings("a@x.io", ed.registers.get(null).?.text);
    try ed.feed("w");
    try testing.expectEqualStrings("two\nlines", ed.grid.?.cell(ed.grid.?.row, ed.grid.?.col));
    try ed.feed("y");
    try testing.expectEqualStrings("two\nlines", ed.registers.get(null).?.text);
    // Two rows.
    try ed.feed("ggVjy");
    try testing.expectEqualStrings("1\ta@x.io\ttwo\nlines\n2\tb@x.io\thas, a comma", ed.registers.get(null).?.text);
    // A search lands on its cell.
    try ed.feed("gg0/comma<CR>");
    try testing.expectEqual(1, ed.grid.?.row);
    try testing.expectEqual(2, ed.grid.?.col);
    try testing.expectEqual(0, ed.cursorLine()); // the code didn't move
    // `o`: as a table in a buffer.
    try ed.feed("o");
    try testing.expect(ed.grid == null and ed.buffer.no_wrap);
    try testing.expectEqualStrings("id │ email  │ note", ed.text().lineSlice(0));
    try testing.expectEqualStrings("2  │ b@x.io │ has, a comma", ed.text().lineSlice(3));
    // Back, and Esc closes it.
    try sql_ops.showSqlResults(&ed);
    try testing.expect(ed.grid != null);
    try ed.feed("<Esc>");
    try testing.expect(ed.grid == null);

    // No rows back, and an error (the database's words, at the cursor).
    try run_popup.startSqlStatement(&ed, db, "update users set note = '' where id = 9", db);
    S.finish(&ed);
    try testing.expect(ed.grid == null);
    try testing.expectEqualStrings("ran: no rows came back", ed.message.buf[0..ed.message.len]);
    try run_popup.startSqlStatement(&ed, db, "select * from nope", db);
    S.finish(&ed);
    try testing.expect(ed.grid == null);
    try testing.expect(std.mem.indexOf(u8, ed.hover.?, "no such table: nope") != null);
}

test "SQL completion: tables and columns from the database, after an alias its columns" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const db = try std.fs.path.join(gpa, &.{ dir, "app.db" });
    defer gpa.free(db);
    const made = std.process.run(gpa, testing.io, .{ .argv = &.{ "sqlite3", db, "create table users(id integer, email text); create table orders(id integer, total real);" } }) catch return error.SkipZigTest;
    gpa.free(made.stdout);
    gpa.free(made.stderr);
    const env = try std.fmt.allocPrint(gpa, "DATABASE_URL=sqlite:{s}\n", .{db});
    defer gpa.free(env);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = env });
    const path = try std.fs.path.join(gpa, &.{ dir, "q.sql" });
    defer gpa.free(path);
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(path);
    ed.tick();
    ed.sql_schema.?.wait();
    try testing.expectEqual(2, ed.sql_schema.?.tables.len);
    try ed.feed("iselect  from users u;<Esc>0f a"); // between `select` and `from`
    try ed.feed("u.");
    const c = completion_ops.completionShown(&ed).?;
    try testing.expectEqual(2, c.shown.items.len); // users' columns only
    try ed.feed("em");
    try testing.expectEqualStrings("email", completion_ops.completionShown(&ed).?.current().?.label);
    try ed.feed("<Esc>o");
    try ed.feed("ord");
    try testing.expectEqualStrings("orders", completion_ops.completionShown(&ed).?.current().?.label);
}
