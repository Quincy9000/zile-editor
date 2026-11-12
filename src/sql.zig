//! Running SQL (Ctrl-Enter in a SQL file): the statement at the cursor (or
//! the selected lines, or the whole file from the command picker) against the project's database,
//! the results in the run popup. As the nvim config's `sql.lua`:
//!
//! The database is the first of `$DATABASE_URL`, `DATABASE_URL` in the
//! nearest `.env` above the file, then above the working folder.
//!   postgres://... / postgresql://...   psql
//!   sqlite:path, sqlite3:path, *.db / *.sqlite / *.sqlite3   sqlite3
//!
//! Pure helpers; the editor runs the command.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The statement around `pos`: from after the `;` before it to its own `;`
/// (quotes and `--` comments skipped), trimmed. Empty if there is none.
pub fn statementAt(text: []const u8, pos: usize) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        if (quote != 0) {
            if (b == quote) quote = 0;
            continue;
        }
        switch (b) {
            '\'', '"' => quote = b,
            '-' => if (i + 1 < text.len and text[i + 1] == '-') {
                while (i < text.len and text[i] != '\n') i += 1;
            },
            ';' => {
                // The cursor anywhere up to and on the `;`: this statement.
                if (pos <= i) return trimStatement(text[start .. i + 1]);
                start = i + 1;
            },
            else => {},
        }
    }
    return trimStatement(text[start..]);
}

fn trimStatement(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    // Comment lines before it belong to the gap, not the statement.
    while (std.mem.startsWith(u8, t, "--")) {
        const nl = std.mem.indexOfScalar(u8, t, '\n') orelse return "";
        t = std.mem.trimStart(u8, t[nl + 1 ..], " \t\r\n");
    }
    return t;
}

/// `DATABASE_URL` from `.env` text (`KEY=value` or `export KEY=value`,
/// quotes taken off).
pub fn urlFromEnvFile(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
        if (!std.mem.startsWith(u8, line, "DATABASE_URL")) continue;
        const rest = std.mem.trimStart(u8, line["DATABASE_URL".len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        var v = std.mem.trim(u8, rest[1..], " \t");
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
        if (v.len > 0) return v;
    }
    return null;
}

/// The database URL for a file in `folder` (caller frees), and where it
/// came from (for the message).
pub fn findUrl(gpa: Allocator, io: Io, folder: []const u8, cwd: []const u8) ?struct { url: []u8, from: []u8 } {
    // (Tests never reach a real database from the environment.)
    if (!@import("builtin").is_test) if (std.c.getenv("DATABASE_URL")) |e| {
        const v = std.mem.span(e);
        if (v.len > 0) {
            const url = gpa.dupe(u8, v) catch return null;
            return .{ .url = url, .from = gpa.dupe(u8, "$DATABASE_URL") catch {
                gpa.free(url);
                return null;
            } };
        }
    };
    for ([_][]const u8{ folder, cwd }) |top| {
        var dir: ?[]const u8 = top;
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const path = std.fs.path.join(gpa, &.{ d, ".env" }) catch return null;
            const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
                gpa.free(path);
                continue;
            };
            defer gpa.free(data);
            const v = urlFromEnvFile(data) orelse {
                gpa.free(path);
                continue;
            };
            const url = gpa.dupe(u8, v) catch {
                gpa.free(path);
                return null;
            };
            return .{ .url = url, .from = path };
        }
    }
    return null;
}

pub const Client = enum { psql, sqlite3 };

/// Which client speaks to `url`, and the database argument for it.
pub fn clientFor(url: []const u8) ?struct { client: Client, target: []const u8 } {
    if (std.mem.startsWith(u8, url, "postgres://") or std.mem.startsWith(u8, url, "postgresql://")) return .{ .client = .psql, .target = url };
    for ([_][]const u8{ "sqlite3://", "sqlite://", "sqlite3:", "sqlite:" }) |p| {
        if (std.mem.startsWith(u8, url, p)) return .{ .client = .sqlite3, .target = url[p.len..] };
    }
    for ([_][]const u8{ ".db", ".sqlite", ".sqlite3" }) |ext| {
        if (std.mem.endsWith(u8, url, ext)) return .{ .client = .sqlite3, .target = url };
    }
    return null;
}

/// The shell command that runs `statement` (the database comes from
/// `$ZILE_DB`, so a password never shows in the command). Caller frees.
pub fn command(gpa: Allocator, client: Client, statement: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, switch (client) {
        .psql => "psql \"$ZILE_DB\" -X -v ON_ERROR_STOP=1 -P pager=off -c ",
        .sqlite3 => "sqlite3 -header -column -bail \"$ZILE_DB\" ",
    });
    // One single-quoted word: `'` written as `'\''` (sh, bash, zsh, fish).
    try out.append(gpa, '\'');
    for (statement) |b| {
        if (b == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, b);
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

/// The URL with its password hidden, for messages. Caller frees.
pub fn redact(gpa: Allocator, url: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return gpa.dupe(u8, url);
    const auth_end = std.mem.indexOfScalarPos(u8, url, scheme_end + 3, '@') orelse return gpa.dupe(u8, url);
    const colon = std.mem.indexOfScalarPos(u8, url[0..auth_end], scheme_end + 3, ':') orelse return gpa.dupe(u8, url);
    return std.mem.concat(gpa, u8, &.{ url[0 .. colon + 1], "***", url[auth_end..] });
}

// ---------------------------------------------------------------------------
// Completion: the database's tables and columns (as vim-dadbod-completion)

/// A table and its columns.
pub const Table = struct { name: []const u8, columns: []const []const u8 };

/// The tables and columns of a database, loaded in the background (psql /
/// sqlite3, no shell), with everything in its arena.
pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    url: []const u8,
    tables: []Table = &.{},
    /// Couldn't connect (completion just has no tables then).
    failed: bool = false,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    joined: bool = false,
    io: Io,
    wake: *const fn () void,

    pub fn load(gpa: Allocator, io: Io, url: []const u8, wake: *const fn () void) !*Schema {
        const s = try gpa.create(Schema);
        errdefer gpa.destroy(s);
        s.* = .{ .arena = .init(gpa), .url = "", .io = io, .wake = wake };
        errdefer s.arena.deinit();
        s.url = try s.arena.allocator().dupe(u8, url);
        s.thread = try std.Thread.spawn(.{}, run, .{s});
        return s;
    }

    pub fn wait(s: *Schema) void {
        if (s.joined) return;
        s.thread.join();
        s.joined = true;
    }

    pub fn destroy(s: *Schema, gpa: Allocator) void {
        s.wait();
        s.arena.deinit();
        gpa.destroy(s);
    }

    fn run(s: *Schema) void {
        defer {
            s.done.store(true, .release);
            s.wake();
        }
        const a = s.arena.allocator();
        const c = clientFor(s.url) orelse {
            s.failed = true;
            return;
        };
        const argv: []const []const u8 = switch (c.client) {
            .psql => &.{ "psql", c.target, "-X", "-At", "-F", "\t", "-c", "select table_name, column_name from information_schema.columns where table_schema not in ('pg_catalog', 'information_schema') order by table_name, ordinal_position" },
            .sqlite3 => &.{ "sqlite3", "-separator", "\t", c.target, "select m.name, p.name from sqlite_master m join pragma_table_info(m.name) p where m.type in ('table', 'view') order by m.name, p.cid" },
        };
        const r = std.process.run(a, s.io, .{ .argv = argv }) catch {
            s.failed = true;
            return;
        };
        if (r.term != .exited or r.term.exited != 0) {
            s.failed = true;
            return;
        }
        s.tables = parseColumns(a, r.stdout) catch &.{};
    }
};

/// "table\tcolumn" lines (grouped by table) into tables.
pub fn parseColumns(a: Allocator, out: []const u8) ![]Table {
    var tables: std.ArrayList(Table) = .empty;
    var cols: std.ArrayList([]const u8) = .empty;
    var current: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const t = line[0..tab];
        if (current == null or !std.mem.eql(u8, current.?, t)) {
            if (current) |name| try tables.append(a, .{ .name = name, .columns = try cols.toOwnedSlice(a) });
            current = t;
        }
        try cols.append(a, line[tab + 1 ..]);
    }
    if (current) |name| try tables.append(a, .{ .name = name, .columns = try cols.toOwnedSlice(a) });
    return tables.toOwnedSlice(a);
}

const keywords = [_][]const u8{
    "select",  "from",     "where",  "join",    "left",     "right",   "inner",   "outer",   "on",      "group by",
    "order by", "having",  "limit",  "offset",  "insert into", "values", "update", "set",    "delete from", "returning",
    "create table", "alter table", "drop table", "primary key", "foreign key", "references", "not null", "default", "distinct", "as",
    "and",     "or",       "not",    "in",      "like",     "ilike",   "between", "is null", "exists",  "case",
    "when",    "then",     "else",   "end",     "union",    "with",    "count",   "sum",     "avg",     "min",
    "max",     "coalesce", "asc",    "desc",    "begin",    "commit",  "rollback",
};

/// The table a name before a `.` means in `statement`: a table of that
/// name, or one given that alias (`from users u`, `join orders as o`).
pub fn tableFor(schema: []const Table, statement: []const u8, name: []const u8) ?Table {
    for (schema) |t| if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    var words: [512][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, statement, " \t\r\n,();");
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    for (words[0..n], 0..) |w, i| {
        const after_table = std.ascii.eqlIgnoreCase(w, "from") or std.ascii.eqlIgnoreCase(w, "join") or
            std.ascii.eqlIgnoreCase(w, "update") or std.ascii.eqlIgnoreCase(w, "into");
        if (!after_table or i + 1 >= n) continue;
        const table = words[i + 1];
        var j = i + 2;
        if (j < n and std.ascii.eqlIgnoreCase(words[j], "as")) j += 1;
        if (j >= n or !std.ascii.eqlIgnoreCase(words[j], name)) continue;
        // `schema.table` names the table after the dot.
        const bare = if (std.mem.lastIndexOfScalar(u8, table, '.')) |d| table[d + 1 ..] else table;
        for (schema) |t| if (std.ascii.eqlIgnoreCase(t.name, bare)) return t;
    }
    return null;
}

/// Completion items (as LSP JSON) at a word starting at `word_start` in
/// `text`: after `name.` that table's columns only; else keywords, tables
/// and every column. Caller frees.
pub fn completionJson(gpa: Allocator, schema: []const Table, text: []const u8, word_start: usize) ![]u8 {
    const Item = struct { label: []const u8, detail: []const u8, kind: u8 };
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(gpa);
    var details: std.ArrayList([]u8) = .empty;
    defer {
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    if (word_start > 0 and text[word_start - 1] == '.') {
        var s = word_start - 1;
        while (s > 0 and (std.ascii.isAlphanumeric(text[s - 1]) or text[s - 1] == '_')) s -= 1;
        const name = text[s .. word_start - 1];
        const t = tableFor(schema, statementAt(text, word_start), name) orelse return gpa.dupe(u8, "{\"items\":[]}");
        for (t.columns) |col| try items.append(gpa, .{ .label = col, .detail = t.name, .kind = 5 });
    } else {
        for (keywords) |k| try items.append(gpa, .{ .label = k, .detail = "keyword", .kind = 14 });
        for (schema) |t| try items.append(gpa, .{ .label = t.name, .detail = "table", .kind = 22 });
        for (schema) |t| for (t.columns) |col| {
            try items.append(gpa, .{ .label = col, .detail = t.name, .kind = 5 });
        };
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .items = items.items }, .{});
}

const testing = std.testing;

test "tables, aliases and completion items" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tables = try parseColumns(arena.allocator(), "orders\tid\norders\ttotal\nusers\tid\nusers\tname\n");
    try testing.expectEqual(2, tables.len);
    try testing.expectEqualStrings("total", tables[0].columns[1]);
    const sql = "select u.name, o. from users u join public.orders as o on o.id = u.id";
    try testing.expectEqualStrings("users", tableFor(tables, sql, "u").?.name);
    try testing.expectEqualStrings("orders", tableFor(tables, sql, "o").?.name);
    try testing.expectEqualStrings("users", tableFor(tables, sql, "USERS").?.name);
    try testing.expectEqual(null, tableFor(tables, sql, "x"));
    const at = std.mem.indexOf(u8, sql, "o. ").? + 2;
    const json = try completionJson(testing.allocator, tables, sql, at);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"total\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\"") == null); // users' column: not offered after o.
}

test "the statement at the cursor" {
    const src = "select 1;\n-- next\nselect 'a;b'\n  from t; -- tail\nupdate x set y = 2";
    try testing.expectEqualStrings("select 1;", statementAt(src, 3));
    try testing.expectEqualStrings("select 1;", statementAt(src, 8)); // on the `;`
    const at = std.mem.indexOf(u8, src, "from").?;
    try testing.expectEqualStrings("select 'a;b'\n  from t;", statementAt(src, at));
    try testing.expectEqualStrings("update x set y = 2", statementAt(src, src.len));
}

test "urls: .env, clients, quoting, redaction" {
    try testing.expectEqualStrings("postgres://u:p@h/db", urlFromEnvFile("A=1\nexport DATABASE_URL=\"postgres://u:p@h/db\"\n").?);
    try testing.expectEqual(null, urlFromEnvFile("DATABASE_URLX=1"));
    try testing.expectEqual(Client.psql, clientFor("postgresql://h/db").?.client);
    try testing.expectEqualStrings("app.db", clientFor("sqlite:app.db").?.target);
    try testing.expectEqual(Client.sqlite3, clientFor("/x/data.sqlite").?.client);
    try testing.expectEqual(null, clientFor("mysql://h/db"));
    const cmd = try command(testing.allocator, .psql, "select 'x';");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.endsWith(u8, cmd, "-c 'select '\\''x'\\'';'"));
    const r = try redact(testing.allocator, "postgres://me:secret@host:5432/db");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("postgres://me:***@host:5432/db", r);
}
