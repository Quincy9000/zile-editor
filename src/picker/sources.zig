//! Picker sources. Each source is a struct with a fixed set of declarations,
//! dispatched at comptime by `Kind`:
//!
//!   title:   []const u8           prompt label
//!   prefix:  ?u8                  typing this first switches any picker here
//!   fill:    fn (*Editor, *Items)  static items, filled on the main thread
//!   produce: Engine.Producer      dynamic items, produced on the worker thread
//!   accept:  fn (*Editor, Item)    act on the chosen item (main thread)
//!   create:  fn (*Editor, query)   optional "Create <query>" row
//!   preview: fn (*Editor, *const Item, *Preview)
//!
//! Adding a source = adding a `Kind` tag and a struct below.

const std = @import("std");
const Io = std.Io;
const Editor = @import("../Editor.zig");
const Engine = @import("Engine.zig");
const Items = @import("Items.zig");
const Item = Items.Item;
const commands = @import("../commands.zig");
const keys = @import("../input/keys.zig");
const Syntax = @import("../syntax/Syntax.zig");
const languages = @import("../syntax/languages.zig");
const motions = @import("../core/motions.zig");

pub const Kind = enum { files, buffers, commands, lines, grep, locations, diagnostics, symbols };

fn Impl(comptime kind: Kind) type {
    return switch (kind) {
        .files => Files,
        .buffers => Buffers,
        .commands => Commands,
        .lines => Lines,
        .grep => Grep,
        .locations => Locations,
        .diagnostics => Diagnostics,
        .symbols => Symbols,
    };
}

pub const Preview = struct {
    text: std.ArrayList(u8) = .empty,
    /// Line to scroll to (0-based).
    focus_line: usize = 0,
    /// Show line numbers (file contents, not prose).
    numbered: bool = false,
    /// Syntax style per byte of `text` (empty when not highlighted).
    styles: std.ArrayList(Syntax.Style) = .empty,

    pub fn clear(p: *Preview) void {
        p.text.clearRetainingCapacity();
        p.styles.clearRetainingCapacity();
        p.focus_line = 0;
        p.numbered = false;
    }

    /// Shows file contents: numbered and, for known languages, highlighted.
    fn setCode(p: *Preview, gpa: std.mem.Allocator, text: []const u8, path: ?[]const u8) !void {
        try p.text.appendSlice(gpa, text);
        p.numbered = true;
        // Big previews would take a noticeable moment to parse.
        if (text.len > max_highlight) return;
        const lang = languages.forPath(path orelse return) orelse return;
        try Syntax.highlightText(gpa, lang, p.text.items, &p.styles);
    }

    const max_highlight = 256 * 1024;
};

pub fn title(kind: Kind) []const u8 {
    return switch (kind) {
        inline else => |k| Impl(k).title,
    };
}

pub fn prefix(kind: Kind) ?u8 {
    return switch (kind) {
        inline else => |k| Impl(k).prefix,
    };
}

/// Sources whose items depend on the query get a fresh engine per query.
pub fn queryDriven(kind: Kind, io: Io) bool {
    return kind == .grep and haveRg(io);
}

pub fn canCreate(kind: Kind) bool {
    return switch (kind) {
        inline else => |k| @hasDecl(Impl(k), "create"),
    };
}

/// The source a query's first byte switches to, if any.
pub fn byPrefix(c: u8) ?Kind {
    inline for (comptime std.meta.tags(Kind)) |k| {
        if (Impl(k).prefix) |p| if (p == c) return k;
    }
    return null;
}

/// Static sources fill `e.items` now; dynamic ones return their producer.
pub fn setup(kind: Kind, ed: *Editor, e: *Engine) !?Engine.Producer {
    switch (kind) {
        inline else => |k| {
            const S = Impl(k);
            if (@hasDecl(S, "fill")) try S.fill(ed, &e.items);
            return if (@hasDecl(S, "produce")) S.produce else null;
        },
    }
}

pub fn accept(kind: Kind, ed: *Editor, item: Item) !void {
    switch (kind) {
        inline else => |k| try Impl(k).accept(ed, item),
    }
}

pub fn create(kind: Kind, ed: *Editor, query: []const u8) !void {
    switch (kind) {
        inline else => |k| if (@hasDecl(Impl(k), "create")) try Impl(k).create(ed, query),
    }
}

pub fn preview(kind: Kind, ed: *Editor, item: *const Item, out: *Preview) !void {
    out.clear();
    switch (kind) {
        inline else => |k| try Impl(k).preview(ed, item, out),
    }
}

// ---------------------------------------------------------------------------

const Files = struct {
    pub const title = "Find file";
    pub const prefix: ?u8 = null;

    /// Directories never worth listing when walking without git.
    const skip_dirs = std.StaticStringMap(void).initComptime(.{
        .{"zig-out"}, .{"zig-pkg"}, .{"node_modules"}, .{"target"}, .{"__pycache__"},
    });

    pub fn produce(e: *Engine) anyerror!void {
        try eachProjectFile(e, {}, addPath);
    }

    fn addPath(_: void, e: *Engine, path: []const u8, n: usize) !void {
        try e.items.append(.{ .text = path });
        if (n % 2048 == 0) try e.checkpoint();
    }

    /// Calls `onFile(ctx, engine, path, index)` for every file in the project:
    /// from ripgrep or git when available (so .gitignore applies), else by
    /// walking the directory.
    pub fn eachProjectFile(e: *Engine, ctx: anytype, comptime onFile: fn (@TypeOf(ctx), *Engine, []const u8, usize) anyerror!void) !void {
        if (haveRg(e.io)) {
            const Adapter = struct {
                inner: @TypeOf(ctx),
                n: usize = 0,
                fn record(a: *@This(), eng: *Engine, path: []const u8) !bool {
                    a.n += 1;
                    try onFile(a.inner, eng, path, a.n);
                    return true;
                }
            };
            var adapter: Adapter = .{ .inner = ctx };
            if (try streamCommand(e, &.{ "rg", "--files", "--null", "--no-require-git" }, 0, &adapter, Adapter.record)) return;
        }
        if (try gitFiles(e, ctx, onFile)) return;
        try walk(e, ctx, onFile);
    }

    /// Inside a git repo, git knows exactly which files matter (.gitignore etc).
    fn gitFiles(e: *Engine, ctx: anytype, comptime onFile: anytype) !bool {
        const result = std.process.run(e.gpa, e.io, .{
            .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        }) catch return false;
        defer e.gpa.free(result.stdout);
        defer e.gpa.free(result.stderr);
        if (!result.term.success()) return false;
        var it = std.mem.splitScalar(u8, result.stdout, 0);
        var n: usize = 0;
        while (it.next()) |path| {
            if (path.len == 0) continue;
            n += 1;
            try onFile(ctx, e, path, n);
        }
        return true;
    }

    fn walk(e: *Engine, ctx: anytype, comptime onFile: anytype) !void {
        const io = e.io;
        var root = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
        defer root.close(io);
        var w = try root.walkSelectively(e.gpa);
        defer {
            // Close directories still open if we stop early.
            while (w.stack.items.len > 0) w.leave(io);
            w.deinit();
        }
        var n: usize = 0;
        while (true) {
            // An unreadable directory is skipped; the walker moves on.
            const entry = (w.next(io) catch continue) orelse break;
            // Hidden files and directories are skipped, like fd does.
            if (entry.basename[0] == '.') continue;
            switch (entry.kind) {
                .directory => {
                    if (skip_dirs.has(entry.basename)) continue;
                    w.enter(io, entry) catch {};
                },
                .file, .sym_link => {
                    n += 1;
                    try onFile(ctx, e, entry.path, n);
                },
                else => {},
            }
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.openFile(item.text);
    }

    pub fn create(ed: *Editor, query: []const u8) !void {
        try ed.openFile(query);
        ed.setMessage(.info, "new file \"{s}\" (SPC f s to create it on disk)", .{query});
    }

    pub const preview_limit = 1024 * 1024;

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const data = Io.Dir.cwd().readFileAlloc(ed.io, item.text, ed.gpa, .limited(preview_limit)) catch |err| {
            const why = switch (err) {
                error.StreamTooLong => "file too large to preview",
                error.IsDir => "directory",
                else => @errorName(err),
            };
            try out.text.print(ed.gpa, "({s})", .{why});
            return;
        };
        defer ed.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) {
            try out.text.appendSlice(ed.gpa, "(binary file)");
            return;
        }
        try out.setCode(ed.gpa, data, item.text);
    }
};

const Buffers = struct {
    pub const title = "Switch buffer";
    pub const prefix: ?u8 = null;

    pub fn fill(ed: *Editor, items: *Items) !void {
        const order = try ed.buffersByRecency(ed.gpa);
        defer ed.gpa.free(order);
        for (order) |b| {
            try items.append(.{
                .text = b.displayName(),
                .detail = if (b.modified) "[+]" else "",
                .id = @intCast(ed.bufferIndex(b)),
            });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        ed.switchTo(ed.buffers.items[item.id]);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const b = ed.buffers.items[item.id];
        try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
        out.focus_line = b.text.lineOf(ed.cursorOf(b));
    }
};

const Commands = struct {
    pub const title = "Command";
    pub const prefix: ?u8 = '>';

    pub fn fill(ed: *Editor, items: *Items) !void {
        for (&commands.all, 0..) |*c, i| {
            if (c.hidden) continue;
            var buf: [64]u8 = undefined;
            var w: Io.Writer = .fixed(&buf);
            if (ed.keymap.firstBinding(.normal, c)) |seq| keys.formatSequenceDisplay(seq, &w) catch {};
            try items.append(.{ .text = c.name, .detail = w.buffered(), .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.runCommand(&commands.all[item.id]);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const c = &commands.all[item.id];
        try out.text.print(ed.gpa, "{s}\n\n{s}\n", .{ c.name, c.doc });
        if (item.detail.len > 0) try out.text.print(ed.gpa, "\nkey: {s}\n", .{item.detail});
    }
};

/// `SPC s s`: the current buffer's lines (Doom's swiper / consult-line).
const Lines = struct {
    pub const title = "Search buffer";
    pub const prefix: ?u8 = null;

    pub fn fill(ed: *Editor, items: *Items) !void {
        const t = ed.text();
        var num: [16]u8 = undefined;
        for (0..t.lineCount()) |line| {
            const text = std.mem.trim(u8, t.lineSlice(line), " \t");
            if (text.len == 0) continue;
            const label = std.fmt.bufPrint(&num, "{d}", .{line + 1}) catch unreachable;
            try items.append(.{ .text = text, .detail = label, .id = @intCast(line) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        const t = ed.text();
        ed.setCursor(motions.firstNonBlank(t, @min(item.id, t.lineCount() - 1)));
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const b = ed.buffer;
        try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
        out.focus_line = item.id;
    }
};

// ---------------------------------------------------------------------------
// Sources that point into files: "path:line[:col]" details.

/// Parses a "path:line" or "path:line:col" detail (1-based) into 0-based parts.
fn parseLocation(detail: []const u8) ?struct { path: []const u8, line: usize, col: usize } {
    const last = std.mem.lastIndexOfScalar(u8, detail, ':') orelse return null;
    const n1 = std.fmt.parseInt(usize, detail[last + 1 ..], 10) catch return null;
    if (std.mem.lastIndexOfScalar(u8, detail[0..last], ':')) |prev| {
        if (std.fmt.parseInt(usize, detail[prev + 1 .. last], 10)) |line| {
            return .{ .path = detail[0..prev], .line = line -| 1, .col = n1 -| 1 };
        } else |_| {}
    }
    return .{ .path = detail[0..last], .line = n1 -| 1, .col = 0 };
}

fn jumpToDetail(ed: *Editor, item: Item) !void {
    const loc = parseLocation(item.detail) orelse return;
    try ed.jumpTo(loc.path, loc.line, loc.col);
}

/// Previews `path` around `line`, from its buffer if open (unsaved edits
/// included), else from disk.
fn previewAt(ed: *Editor, path: []const u8, line: usize, out: *Preview) !void {
    for (ed.buffers.items) |b| {
        if (b.path) |bp| if (std.mem.eql(u8, bp, path)) {
            try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), path);
            out.focus_line = line;
            return;
        };
    }
    const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(Files.preview_limit)) catch |err| {
        try out.text.print(ed.gpa, "({s})", .{@errorName(err)});
        return;
    };
    defer ed.gpa.free(data);
    try out.setCode(ed.gpa, data, path);
    out.focus_line = line;
}

fn previewDetail(ed: *Editor, item: *const Item, out: *Preview) !void {
    const loc = parseLocation(item.detail) orelse return;
    try previewAt(ed, loc.path, loc.line, out);
}

/// `SPC /`: search every line of the project, fuzzily.
///
/// With ripgrep, each query runs `rg` with a subsequence regex built from it
/// (`abc` -> `a.*?b.*?c`), streaming matches in, and the engine ranks them
/// fuzzily. Without it, every line of every file is loaded once and filtered
/// in memory.
const Grep = struct {
    pub const title = "Search project";
    pub const prefix: ?u8 = null;

    /// Files larger than this are skipped, and lines are capped at `max_line`.
    const max_file = 1024 * 1024;
    const max_line = 300;
    /// rg results kept per query.
    const max_matches = 20_000;

    pub fn produce(e: *Engine) anyerror!void {
        if (!haveRg(e.io)) return Files.eachProjectFile(e, {}, addLines);
        const query = e.producerQuery();
        if (std.mem.trim(u8, query, " ").len == 0) return;
        const pattern = try fuzzyRegex(e.gpa, query);
        defer e.gpa.free(pattern);
        const max_cols = std.fmt.comptimePrint("--max-columns={d}", .{max_line});
        _ = try streamCommand(e, &.{
            "rg",                    "--null", "--line-number", "--no-heading", "--color=never", "--smart-case",
            "--no-require-git", // honor .gitignore outside git repos too
            max_cols, "--max-columns-preview", "-e", pattern,
        }, '\n', {}, addRgMatch);
    }

    /// "path\0line:text" from `rg --null --line-number`.
    fn addRgMatch(_: void, e: *Engine, record: []const u8) !bool {
        if (e.items.count() >= max_matches) return false;
        const nul = std.mem.indexOfScalar(u8, record, 0) orelse return true;
        const rest = record[nul + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return true;
        var detail: [std.fs.max_path_bytes + 16]u8 = undefined;
        const where = std.fmt.bufPrint(&detail, "{s}:{s}", .{ record[0..nul], rest[0..colon] }) catch return true;
        const text = std.mem.trim(u8, rest[colon + 1 ..], " \t\r");
        try e.items.append(.{ .text = text, .detail = where });
        return true;
    }

    /// `wake fn` -> `w.*?a.*?k.*?e.*?f.*?n`: the characters in order, spaces ignored.
    fn fuzzyRegex(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var it = std.unicode.Utf8View.initUnchecked(query).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (cp.len == 1 and cp[0] == ' ') continue;
            if (out.items.len > 0) try out.appendSlice(gpa, ".*?");
            if (cp.len == 1 and std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$#&-~", cp[0]) != null) try out.append(gpa, '\\');
            try out.appendSlice(gpa, cp);
        }
        return out.toOwnedSlice(gpa);
    }

    fn addLines(_: void, e: *Engine, path: []const u8, _: usize) !void {
        const data = Io.Dir.cwd().readFileAlloc(e.io, path, e.gpa, .limited(max_file)) catch return;
        defer e.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) return; // binary
        var detail: [std.fs.max_path_bytes + 16]u8 = undefined;
        var lines = std.mem.splitScalar(u8, data, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            const text = std.mem.trim(u8, line, " \t\r");
            if (text.len < 2) continue;
            const where = std.fmt.bufPrint(&detail, "{s}:{d}", .{ path, n }) catch continue;
            try e.items.append(.{ .text = text[0..@min(text.len, max_line)], .detail = where });
            if (e.items.count() % 4096 == 0) try e.checkpoint();
        }
    }

    pub const accept = jumpToDetail;
    pub const preview = previewDetail;
};

/// Definitions / references from the language server (`ed.locations`).
const Locations = struct {
    pub const title = "Locations";
    pub const prefix: ?u8 = null;

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [std.fs.max_path_bytes + 32]u8 = undefined;
        for (ed.locations.items) |loc| {
            const text = try lineText(ed, loc.path, loc.line);
            defer ed.gpa.free(text);
            const where = std.fmt.bufPrint(&detail, "{s}:{d}:{d}", .{ loc.path, loc.line + 1, loc.col + 1 }) catch continue;
            try items.append(.{ .text = std.mem.trim(u8, text, " \t"), .detail = where });
        }
    }

    /// The text of one line of a file (open buffer or disk). Caller frees.
    fn lineText(ed: *Editor, path: []const u8, line: usize) ![]u8 {
        for (ed.buffers.items) |b| {
            if (b.path) |bp| if (std.mem.eql(u8, bp, path)) {
                if (line >= b.text.lineCount()) return ed.gpa.dupe(u8, "");
                return ed.gpa.dupe(u8, b.text.lineSlice(line));
            };
        }
        const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(Files.preview_limit)) catch
            return ed.gpa.dupe(u8, path);
        defer ed.gpa.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        var i: usize = 0;
        while (it.next()) |l| : (i += 1) if (i == line) return ed.gpa.dupe(u8, l);
        return ed.gpa.dupe(u8, "");
    }

    pub const accept = jumpToDetail;
    pub const preview = previewDetail;
};

/// `SPC c x`: language server diagnostics for all files.
const Diagnostics = struct {
    pub const title = "Diagnostics";
    pub const prefix: ?u8 = '!';

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [std.fs.max_path_bytes + 32]u8 = undefined;
        for (ed.lsps) |maybe| {
            const l = maybe orelse continue;
            for (l.diagnostics.keys(), l.diagnostics.values()) |path, list| {
                for (list) |d| {
                    const where = std.fmt.bufPrint(&detail, "{s}:{d}:{d}", .{ path, d.line + 1, d.col + 1 }) catch continue;
                    const first_line = std.mem.sliceTo(d.message, '\n');
                    try items.append(.{ .text = first_line, .detail = where, .id = @intFromEnum(d.severity) });
                }
            }
        }
    }

    pub const accept = jumpToDetail;
    pub const preview = previewDetail;
};

test "location details" {
    const a = parseLocation("src/main.zig:12:5").?;
    try std.testing.expectEqualStrings("src/main.zig", a.path);
    try std.testing.expectEqual(11, a.line);
    try std.testing.expectEqual(4, a.col);
    const b = parseLocation("build.zig:3").?;
    try std.testing.expectEqualStrings("build.zig", b.path);
    try std.testing.expectEqual(2, b.line);
}

// ---------------------------------------------------------------------------
// External programs

var rg_state: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 yes, 2 no

/// Whether ripgrep is on PATH (checked once).
pub fn haveRg(io: Io) bool {
    const state = rg_state.load(.acquire);
    if (state != 0) return state == 1;
    const found = onPath(io, "rg");
    rg_state.store(if (found) 1 else 2, .release);
    return found;
}

fn onPath(io: Io, name: []const u8) bool {
    const path = std.c.getenv("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path), ':');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (dirs.next()) |dir| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (Io.Dir.accessAbsolute(io, full, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Runs `argv` and calls `onRecord(ctx, engine, record)` for every
/// `sep`-terminated record of its output as it streams in (`onRecord` returns
/// false to stop early). The process is registered with the engine so closing
/// or re-querying the picker kills it. Returns false if it could not start.
fn streamCommand(e: *Engine, argv: []const []const u8, sep: u8, ctx: anytype, comptime onRecord: anytype) !bool {
    var child = std.process.spawn(e.io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return false;
    e.child_pid.store(child.id.?, .release);
    defer {
        e.child_pid.store(0, .release);
        child.kill(e.io);
    }
    const out = child.stdout.?;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(e.gpa);
    var chunk: [64 * 1024]u8 = undefined;
    var records: usize = 0;
    reading: while (true) {
        const n = out.readStreaming(e.io, &.{&chunk}) catch break;
        try buf.appendSlice(e.gpa, chunk[0..n]);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buf.items, start, sep)) |end| {
            const keep_going = try onRecord(ctx, e, buf.items[start..end]);
            start = end + 1;
            records += 1;
            if (!keep_going) break :reading;
            if (records % 1024 == 0) try e.checkpoint();
        }
        buf.replaceRangeAssumeCapacity(0, start, &.{});
    }
    return true;
}

test "fuzzy regex for rg" {
    const gpa = std.testing.allocator;
    const r = try Grep.fuzzyRegex(gpa, "a.b c");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("a.*?\\..*?b.*?c", r);
}

/// `SPC c l`: the current file's symbols (`ed.symbols`), in document order.
const Symbols = struct {
    pub const title = "Symbols";
    pub const prefix: ?u8 = '@';

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [64]u8 = undefined;
        for (ed.symbols.items, 0..) |sym, i| {
            const label = std.fmt.bufPrint(&detail, "{s}  {d}", .{ sym.kind, sym.line + 1 }) catch sym.kind;
            try items.append(.{ .text = sym.name, .detail = label, .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= ed.symbols.items.len) return;
        const sym = ed.symbols.items[item.id];
        const t = ed.text();
        const line = @min(sym.line, t.lineCount() - 1);
        ed.setCursor(t.lineStart(line) + @min(sym.col, t.lineLen(line)));
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.symbols.items.len) return;
        const b = ed.buffer;
        try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
        out.focus_line = ed.symbols.items[item.id].line;
    }
};
