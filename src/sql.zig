//! Running SQL (Ctrl-Enter in a SQL file): the statement at the cursor (or
//! the selected lines, or the whole file from the command picker) against the project's database,
//! the rows in the results picker (the whole file: in the run popup). As the nvim config's `sql.lua`:
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
// Results: a statement's rows, for the results picker

/// A statement run in the background (psql / sqlite3, no shell), its output
/// asked for as CSV and read into rows. Everything is in its arena.
pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    url: []const u8,
    statement: []const u8,
    /// The header: empty when the statement returned no table (an UPDATE).
    columns: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    /// The output as it came (CSV, header first).
    csv: []const u8 = "",
    /// What the client said when it failed (the database's error).
    err: []const u8 = "",
    failed: bool = false,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    joined: bool = false,
    io: Io,
    wake: *const fn () void,

    /// More than this much output is an error, not a frozen editor.
    const max_output = 64 << 20;

    pub fn start(gpa: Allocator, io: Io, url: []const u8, statement: []const u8, wake: *const fn () void) !*Results {
        const r = try gpa.create(Results);
        errdefer gpa.destroy(r);
        r.* = .{ .arena = .init(gpa), .url = "", .statement = "", .io = io, .wake = wake };
        errdefer r.arena.deinit();
        r.url = try r.arena.allocator().dupe(u8, url);
        r.statement = try r.arena.allocator().dupe(u8, statement);
        r.thread = try std.Thread.spawn(.{}, run, .{r});
        return r;
    }

    pub fn wait(r: *Results) void {
        if (r.joined) return;
        r.thread.join();
        r.joined = true;
    }

    pub fn destroy(r: *Results, gpa: Allocator) void {
        r.wait();
        r.arena.deinit();
        gpa.destroy(r);
    }

    fn fail(r: *Results, why: []const u8) void {
        r.failed = true;
        r.err = why;
    }

    fn run(r: *Results) void {
        defer {
            r.done.store(true, .release);
            r.wake();
        }
        const a = r.arena.allocator();
        const c = clientFor(r.url) orelse return r.fail("not a postgres:// or sqlite: database");
        // `-q`: only the rows, not "INSERT 0 1" (which CSV can't tell from a
        // header).
        const argv: []const []const u8 = switch (c.client) {
            .psql => &.{ "psql", c.target, "-X", "-q", "-v", "ON_ERROR_STOP=1", "--csv", "-c", r.statement },
            .sqlite3 => &.{ "sqlite3", "-csv", "-header", "-bail", c.target, r.statement },
        };
        const out = std.process.run(a, r.io, .{ .argv = argv, .stdout_limit = .limited(max_output) }) catch |e| return r.fail(switch (e) {
            error.FileNotFound => if (c.client == .psql) "psql is not installed" else "sqlite3 is not installed",
            error.StreamTooLong => "more than 64 MB of results: add a LIMIT",
            else => @errorName(e),
        });
        if (out.term != .exited or out.term.exited != 0) {
            const said = std.mem.trim(u8, out.stderr, " \r\n");
            return r.fail(if (said.len > 0) said else "the statement failed");
        }
        r.csv = out.stdout;
        const table = parseCsv(a, out.stdout) catch return r.fail("out of memory");
        if (table.len == 0) return;
        r.columns = table[0];
        r.rows = table[1..];
    }
};

/// CSV into rows of cells (RFC 4180: `"` quotes a cell with commas or
/// lines in it, `""` is a quote). The cells are in `a`.
pub fn parseCsv(a: Allocator, csv: []const u8) ![]const []const []const u8 {
    var rows: std.ArrayList([]const []const u8) = .empty;
    var row: std.ArrayList([]const u8) = .empty;
    var cell: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var quoted = false;
    // A row has begun (so a last line without a newline still counts).
    var open = false;
    while (i < csv.len) : (i += 1) {
        const b = csv[i];
        if (quoted) {
            if (b != '"') {
                try cell.append(a, b);
            } else if (i + 1 < csv.len and csv[i + 1] == '"') {
                try cell.append(a, '"');
                i += 1;
            } else quoted = false;
            continue;
        }
        switch (b) {
            '"' => {
                quoted = true;
                open = true;
            },
            ',' => {
                try row.append(a, try cell.toOwnedSlice(a));
                open = true;
            },
            '\n' => {
                if (cell.items.len > 0 and cell.items[cell.items.len - 1] == '\r') _ = cell.pop();
                try row.append(a, try cell.toOwnedSlice(a));
                try rows.append(a, try row.toOwnedSlice(a));
                open = false;
            },
            else => {
                try cell.append(a, b);
                open = true;
            },
        }
    }
    if (open) {
        try row.append(a, try cell.toOwnedSlice(a));
        try rows.append(a, try row.toOwnedSlice(a));
    }
    return rows.toOwnedSlice(a);
}

/// Columns are lined up to this width at most; a longer value runs on past
/// it (whole: it is data, not cut), putting only its own row out of line.
const max_column = 60;

fn cellWidth(value: []const u8) usize {
    return std.unicode.utf8CountCodepoints(value) catch value.len;
}

/// The results as text: the header, a rule, a line per row, the columns
/// lined up with ` │ ` between. A value's line breaks and tabs are spaces
/// (a row is one line). Caller frees.
pub fn tableText(gpa: Allocator, columns: []const []const u8, rows: []const []const []const u8) ![]u8 {
    const widths = try gpa.alloc(usize, columns.len);
    defer gpa.free(widths);
    for (columns, widths) |name, *w| w.* = cellWidth(name);
    for (rows) |row| for (row, 0..) |value, c| {
        if (c < widths.len) widths[c] = @max(widths[c], @min(cellWidth(value), max_column));
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try tableRow(gpa, &out, columns, widths);
    for (widths, 0..) |w, c| {
        if (c > 0) try out.appendSlice(gpa, "─┼─");
        for (0..w) |_| try out.appendSlice(gpa, "─");
    }
    try out.append(gpa, '\n');
    for (rows) |row| try tableRow(gpa, &out, row, widths);
    return out.toOwnedSlice(gpa);
}

fn tableRow(gpa: Allocator, out: *std.ArrayList(u8), row: []const []const u8, widths: []const usize) !void {
    for (row, 0..) |value, c| {
        if (c > 0) try out.appendSlice(gpa, " │ ");
        for (value) |b| try out.append(gpa, if (b == '\n' or b == '\r' or b == '\t') ' ' else b);
        // Nothing after the last value: no spaces at the ends of lines.
        const w = if (c < widths.len) widths[c] else 0;
        if (c + 1 < row.len) try out.appendNTimes(gpa, ' ', w -| cellWidth(value));
    }
    try out.append(gpa, '\n');
}

test "tableText: columns lined up, a row a line" {
    const gpa = std.testing.allocator;
    const text = try tableText(gpa, &.{ "id", "email", "note" }, &.{
        &.{ "1", "a@x.io", "two\nlines" },
        &.{ "20", "é", "" },
    });
    defer gpa.free(text);
    try std.testing.expectEqualStrings(
        \\id │ email  │ note
        \\───┼────────┼──────────
        \\1  │ a@x.io │ two lines
        \\20 │ é      │ 
        \\
    , text);
}

test "parseCsv: quoted cells hold commas, quotes and lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parseCsv(arena.allocator(), "a,b,c\n1,\"x,\"\"y\"\"\nz\",\n2,,last");
    try std.testing.expectEqual(3, rows.len);
    try std.testing.expectEqualStrings("b", rows[0][1]);
    try std.testing.expectEqualStrings("x,\"y\"\nz", rows[1][1]);
    try std.testing.expectEqualStrings("", rows[1][2]);
    try std.testing.expectEqual(3, rows[2].len);
    try std.testing.expectEqualStrings("last", rows[2][2]);
}

// ---------------------------------------------------------------------------
// Completion: the database's tables and columns (as vim-dadbod-completion)

/// A table and its columns.
/// A table and its columns. `schema`: the Postgres schema it is in (""
/// where there are none: sqlite).
pub const Table = struct { schema: []const u8 = "", name: []const u8, columns: []const []const u8 };

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
            .psql => &.{ "psql", c.target, "-X", "-At", "-F", "\t", "-c", "select table_schema || '.' || table_name, column_name from information_schema.columns where table_schema not in ('pg_catalog', 'information_schema') order by (table_schema <> 'public'), table_schema, table_name, ordinal_position" },
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

/// "table\tcolumn" lines (grouped by table) into tables; the table as
/// `schema.table` where there are schemas.
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
            if (current) |name| try tables.append(a, splitName(name, try cols.toOwnedSlice(a)));
            current = t;
        }
        try cols.append(a, line[tab + 1 ..]);
    }
    if (current) |name| try tables.append(a, splitName(name, try cols.toOwnedSlice(a)));
    return tables.toOwnedSlice(a);
}

fn splitName(name: []const u8, columns: []const []const u8) Table {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return .{ .name = name, .columns = columns };
    return .{ .schema = name[0..dot], .name = name[dot + 1 ..], .columns = columns };
}

/// The table `name` means, written `table` or `schema.table` (quoted or
/// not). Without a schema: the first of that name (`public`'s is first).
fn tableNamed(schema: []const Table, name: []const u8) ?Table {
    var in: []const u8 = "";
    var bare = name;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| {
        in = std.mem.trim(u8, name[0..d], "\"");
        bare = name[d + 1 ..];
    }
    bare = std.mem.trim(u8, bare, "\"");
    for (schema) |t| {
        if (!std.ascii.eqlIgnoreCase(t.name, bare)) continue;
        if (in.len == 0 or t.schema.len == 0 or std.ascii.eqlIgnoreCase(t.schema, in)) return t;
    }
    return null;
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
    return source(null, schema, statement, name) catch null;
}

/// `tableFor`, and with `a`, what a `with` names too (`with big as (select
/// id, total from …) select b. from big b`): its select list's names.
fn source(a: ?Allocator, schema: []const Table, statement: []const u8, name: []const u8) !?Table {
    var words: [512][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, statement, " \t\r\n,();");
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    for (words[0..n], 0..) |w, i| {
        if (!namesTable(w) or i + 1 >= n) continue;
        const written = words[i + 1];
        var j = i + 2;
        if (j < n and std.ascii.eqlIgnoreCase(words[j], "as")) j += 1;
        if (j >= n or !std.ascii.eqlIgnoreCase(words[j], name)) continue;
        if (try named(a, schema, statement, written)) |t| return t;
    }
    // Not an alias: the table itself (`users.`), then.
    return named(a, schema, statement, name);
}

/// The word after this one is a table's name.
fn namesTable(w: []const u8) bool {
    return std.ascii.eqlIgnoreCase(w, "from") or std.ascii.eqlIgnoreCase(w, "join") or
        std.ascii.eqlIgnoreCase(w, "update") or std.ascii.eqlIgnoreCase(w, "into");
}

/// A table of the database, or (with `a`) one the statement's `with` makes.
fn named(a: ?Allocator, schema: []const Table, statement: []const u8, written: []const u8) !?Table {
    if (tableNamed(schema, written)) |t| return t;
    const arena = a orelse return null;
    const columns = try withColumns(arena, statement, written) orelse return null;
    return .{ .name = written, .columns = columns };
}

fn isNameByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Where `needle` is in `hay` as a whole word, in either case, from `from`.
fn findWord(hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) continue;
        if (i > 0 and isNameByte(hay[i - 1])) continue;
        if (i + needle.len < hay.len and isNameByte(hay[i + needle.len])) continue;
        return i;
    }
    return null;
}

/// The end of the parenthesis opened at `open` (the index of its `)`),
/// quotes skipped.
fn closing(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        if (quote != 0) {
            if (b == quote) quote = 0;
            continue;
        }
        switch (b) {
            '\'', '"' => quote = b,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The columns of `name` if the statement's `with` makes it (`name as (select
/// …)`): what its select list calls them. A `*` in the list is left out.
fn withColumns(a: Allocator, statement: []const u8, name: []const u8) !?[]const []const u8 {
    var from: usize = 0;
    while (findWord(statement, name, from)) |at| : (from = at + 1) {
        var i = at + name.len;
        while (i < statement.len and std.ascii.isWhitespace(statement[i])) i += 1;
        if (i + 2 > statement.len or !std.ascii.eqlIgnoreCase(statement[i..][0..2], "as")) continue;
        i += 2;
        // (`as materialized (`, `as not materialized (`.)
        const open = std.mem.indexOfScalarPos(u8, statement, i, '(') orelse continue;
        if (std.mem.indexOfAny(u8, statement[i..open], ",;") != null) continue;
        const body = statement[open + 1 .. closing(statement, open) orelse statement.len];
        return try selectNames(a, body);
    }
    return null;
}

/// The names of a select's columns: `select a, t.b, count(*) as n from …`
/// gives a, b, n.
fn selectNames(a: Allocator, select: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const start = (findWord(select, "select", 0) orelse return names.items) + "select".len;
    // The list: up to the `from` outside any parenthesis; its commas likewise.
    var depth: usize = 0;
    var quote: u8 = 0;
    var item = start;
    var i = start;
    while (i <= select.len) : (i += 1) {
        const end = i == select.len;
        const b = if (end) ',' else select[i];
        if (!end and quote != 0) {
            if (b == quote) quote = 0;
            continue;
        }
        const at_from = !end and depth == 0 and findWord(select, "from", i) == i;
        if (!end and !at_from) switch (b) {
            '\'' => quote = b,
            '(' => depth += 1,
            ')' => depth -|= 1,
            else => {},
        };
        if (end or at_from or (b == ',' and depth == 0)) {
            const one = std.mem.trim(u8, select[item..i], " \t\r\n");
            item = i + 1;
            // Its name: the last word (after `as`, or of `t.column`).
            var e = one.len;
            while (e > 0 and one[e - 1] == '"') e -= 1;
            var st = e;
            while (st > 0 and isNameByte(one[st - 1])) st -= 1;
            if (st < e and !std.ascii.isDigit(one[st])) try names.append(a, one[st..e]);
            if (at_from) break;
        }
    }
    return names.items;
}

/// Where columns are what comes next: in `order by`, `group by`, `having`
/// and `returning`, and between the parentheses of `insert into t (`
/// (`table`: that t).
const Clause = union(enum) { other, columns, insert: []const u8 };

/// The clause `before` (a statement up to the cursor's word) ends in.
fn clauseAt(before: []const u8) Clause {
    const boundaries = [_][]const u8{ "select", "from", "where", "join", "on", "by", "having", "returning", "limit", "offset", "set", "values", "into", "union", "with", "using", "over", "when", "then", "else" };
    var last: []const u8 = "";
    var into_at: usize = 0;
    var into_table: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, before, " \t\r\n,();=<>");
    while (it.next()) |w| {
        if (std.ascii.eqlIgnoreCase(last, "into") and into_table.len == 0) into_table = w;
        for (boundaries) |k| if (std.ascii.eqlIgnoreCase(w, k)) {
            last = k;
            if (std.mem.eql(u8, k, "into")) {
                into_at = it.index;
                into_table = "";
            }
        };
    }
    if (std.mem.eql(u8, last, "by") or std.mem.eql(u8, last, "having") or std.mem.eql(u8, last, "returning")) return .columns;
    if (std.mem.eql(u8, last, "into") and into_table.len > 0) {
        const rest = before[into_at..];
        if (std.mem.count(u8, rest, "(") > std.mem.count(u8, rest, ")")) return .{ .insert = into_table };
    }
    return .other;
}

/// Completion items (as LSP JSON) for where the Postgres server has none:
/// after `name.` the columns of what that names (a table, an alias, what a
/// `with` makes); in `order by`, `group by`, `having` and `returning` the
/// columns of the statement's tables; in `insert into t (` those of t.
/// Elsewhere none. Caller frees.
pub fn fallbackJson(gpa: Allocator, schema: []const Table, text: []const u8, word_start: usize) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Item = struct { label: []const u8, detail: []const u8, kind: u8 = 5 };
    var items: std.ArrayList(Item) = .empty;
    const statement = statementAt(text, word_start);
    if (word_start > 0 and text[word_start - 1] == '.') {
        var s = word_start - 1;
        while (s > 0 and isNameByte(text[s - 1])) s -= 1;
        if (try source(a, schema, statement, text[s .. word_start - 1])) |t| {
            for (t.columns) |col| try items.append(a, .{ .label = col, .detail = t.name });
        }
    } else {
        // The statement up to the word being typed.
        const offset = @intFromPtr(statement.ptr) -| @intFromPtr(text.ptr);
        const before = statement[0..@min(word_start -| offset, statement.len)];
        switch (clauseAt(before)) {
            .other => {},
            .insert => |table| if (try named(a, schema, statement, table)) |t| {
                for (t.columns) |col| try items.append(a, .{ .label = col, .detail = t.name });
            },
            .columns => {
                var it = std.mem.tokenizeAny(u8, statement, " \t\r\n,();");
                var after_table = false;
                while (it.next()) |w| {
                    if (after_table) if (try named(a, schema, statement, w)) |t| {
                        for (t.columns) |col| try items.append(a, .{ .label = col, .detail = t.name });
                    };
                    after_table = namesTable(w);
                }
            },
        }
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .items = items.items }, .{});
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
    const tables_email = try parseColumns(arena.allocator(), "orders\tid\norders\ttotal\nusers\tid\nusers\temail\n");
    try testing.expectEqual(2, tables.len);
    try testing.expectEqualStrings("total", tables[0].columns[1]);
    // The same table name in two schemas: each keeps its own columns.
    const two = try parseColumns(arena.allocator(), "public.items\tid\nportal.items\tid\nportal.items\tamount\n");
    try testing.expectEqual(2, two.len);
    try testing.expectEqualStrings("portal", two[1].schema);
    const q = "select sum(r.amount) from portal.items r join items i on i.id = r.id group by r.";
    try testing.expectEqual(2, tableFor(two, q, "r").?.columns.len);
    try testing.expectEqual(1, tableFor(two, q, "i").?.columns.len);
    // What a `with` makes, and where columns come next.
    const cte = "with big as (select id, o.total, count(*) as n, upper(name) shout from orders o), x as (select 1) select b. from big b order by ";
    {
        const dot = std.mem.indexOf(u8, cte, "b. ").? + 2;
        const json = try fallbackJson(testing.allocator, tables, cte, dot);
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"label\":\"id\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"label\":\"total\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"label\":\"n\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"label\":\"shout\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"label\":\"name\"") == null);
        // `order by`: the columns of what the statement reads (the `with`'s).
        const by = try fallbackJson(testing.allocator, tables, cte, cte.len);
        defer testing.allocator.free(by);
        try testing.expect(std.mem.indexOf(u8, by, "\"label\":\"shout\"") != null);
    }
    inline for (.{
        .{ "select count(*) from users u group by ", true, "email" },
        .{ "select * from users having ", true, "email" },
        .{ "update users set name = 'x' returning ", true, "email" },
        .{ "insert into orders (", true, "total" },
        .{ "insert into orders (id, ", true, "total" },
        .{ "select * from users u join orders o on o.id = u.id order by u.id, ", true, "total" },
        // Not where columns come next: nothing of ours.
        .{ "select * from users limit ", false, "email" },
        .{ "insert into orders (id) values (", false, "total" },
        .{ "select * from users where ", false, "email" },
        .{ "select * from nothing_known order by ", false, "email" },
    }) |case| {
        const json = try fallbackJson(testing.allocator, tables_email, case[0], case[0].len);
        defer testing.allocator.free(json);
        const needle = "\"label\":\"" ++ case[2] ++ "\"";
        testing.expectEqual(case[1], std.mem.indexOf(u8, json, needle) != null) catch |err| {
            std.debug.print("case: {s}\n", .{case[0]});
            return err;
        };
    }
    // (Only the table inserted into.)
    const ins = try fallbackJson(testing.allocator, tables_email, "insert into orders (", "insert into orders (".len);
    defer testing.allocator.free(ins);
    try testing.expect(std.mem.indexOf(u8, ins, "\"label\":\"email\"") == null);
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
