//! Languages without recompiling: `$XDG_CONFIG_HOME/zile/languages.toml`
//! (`~/.config/zile/languages.toml`) describes them, and their grammars are
//! shared libraries in `$XDG_DATA_HOME/zile/grammars/<name>/`
//! (`~/.local/share/zile/...`), built by `zile --grammar install`
//! (`grammars.zig`) and opened at startup.
//!
//!     [[language]]
//!     name = "lua"
//!     extensions = ["lua"]
//!     comment = "--"                     # or ["<!--", "-->"]
//!     indent = 3
//!     formatter = ["stylua", "-"]        # `{path}` is the file's path
//!     server = ["lua-language-server"]   # or { command = [...], language-id = "..." }
//!     grammar = { url = "https://github.com/tree-sitter-grammars/tree-sitter-lua", rev = "v0.4.0" }
//!
//! A built-in language can be listed too, to add extensions or change its
//! settings (a `grammar` there replaces the built-in one). Any language's
//! highlighting can be replaced by `~/.config/zile/queries/<name>/highlights.scm`.
//!
//! Everything loaded lives for the whole process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const c = @import("tree_sitter");
const toml = @import("toml.zig");
const languages = @import("../syntax/languages.zig");
const comment = @import("../core/comment.zig");
const Lsp = @import("../lsp/Lsp.zig");

/// A language's settings from the config file.
pub const Settings = struct {
    name: []const u8,
    comment: ?comment.Style = null,
    indent: ?usize = null,
    formatter: ?[]const []const u8 = null,
};

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
const arena = arena_state.allocator();
var settings: std.ArrayList(Settings) = .empty;

pub fn settingsFor(lang: []const u8) ?*const Settings {
    for (settings.items) |*s| if (std.mem.eql(u8, s.name, lang)) return s;
    return null;
}

/// `$XDG_<KIND>_HOME/zile/<sub>`, or under the usual folder in `$HOME`.
pub fn dir(gpa: Allocator, kind: enum { config, data, cache }, sub: []const u8) ?[]u8 {
    const env_name, const fallback = switch (kind) {
        .config => .{ "XDG_CONFIG_HOME", ".config" },
        .data => .{ "XDG_DATA_HOME", ".local/share" },
        .cache => .{ "XDG_CACHE_HOME", ".cache" },
    };
    if (std.c.getenv(env_name)) |e| {
        const base = std.mem.span(e);
        if (base.len > 0) return std.fs.path.join(gpa, &.{ base, "zile", sub }) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fs.path.join(gpa, &.{ home, fallback, "zile", sub }) catch null;
}

/// One `[[language]]` table, read.
pub const Entry = struct {
    name: []const u8,
    extensions: ?[]const []const u8 = null,
    grammar_url: ?[]const u8 = null,
    grammar_rev: ?[]const u8 = null,
    /// The folder in the repo with `src/` and `queries/` (TypeScript keeps
    /// two grammars in one repo).
    grammar_path: []const u8 = "",
    /// The `tree_sitter_<symbol>` entry point (the name, `-` as `_`).
    symbol: []const u8,
};

/// The config file's languages (also used by `zile --grammar`).
pub fn readEntries(a: Allocator, io: Io, path: []const u8, problems: *std.ArrayList([]const u8)) ![]Entry {
    const src = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => {
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ path, @errorName(err) }));
            return &.{};
        },
    };
    var diag: toml.Diagnostic = .{};
    const root = toml.parse(a, src, &diag) catch |err| {
        try problems.append(a, try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ path, diag.line, if (err == error.Syntax) diag.message else @errorName(err) }));
        return &.{};
    };
    var out: std.ArrayList(Entry) = .empty;
    for (root.tables("language")) |v| {
        if (v != .table) continue;
        const t = v.table;
        const name = t.string("name") orelse {
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: a [[language]] without a name", .{path}));
            continue;
        };
        var e: Entry = .{ .name = name, .extensions = try t.strings(a, "extensions"), .symbol = name };
        if (t.table("grammar")) |g| {
            e.grammar_url = g.string("url");
            e.grammar_rev = g.string("rev");
            e.grammar_path = g.string("path") orelse "";
            if (g.string("symbol")) |sym| e.symbol = sym;
        }
        if (std.mem.indexOfScalar(u8, e.symbol, '-') != null) {
            const sym = try a.dupe(u8, e.symbol);
            std.mem.replaceScalar(u8, sym, '-', '_');
            e.symbol = sym;
        }
        try out.append(a, e);
        try applySettings(a, name, t, problems);
    }
    return out.toOwnedSlice(a);
}

fn applySettings(a: Allocator, name: []const u8, t: *toml.Table, problems: *std.ArrayList([]const u8)) !void {
    var s: Settings = .{ .name = name };
    if (t.get("comment")) |v| switch (v) {
        .string => |open| s.comment = .{ .open = open },
        .array => |arr| if (arr.len == 2 and arr[0] == .string and arr[1] == .string) {
            s.comment = .{ .open = arr[0].string, .close = arr[1].string };
        },
        else => {},
    };
    if (t.int("indent")) |n| s.indent = @intCast(std.math.clamp(n, 1, 16));
    s.formatter = try t.strings(a, "formatter");
    // The server: a command, or a table with its command and the rest.
    var command: ?[]const []const u8 = try t.strings(a, "server");
    var language_id: []const u8 = name;
    var linter = false;
    var markers: []const []const u8 = &.{};
    if (t.table("server")) |srv| {
        command = try srv.strings(a, "command");
        if (srv.string("language-id")) |id| language_id = id;
        linter = srv.boolean("linter") orelse false;
        markers = (try srv.strings(a, "markers")) orelse &.{};
    }
    if (command) |cmd| if (cmd.len > 0) {
        const langs = try arena.alloc(struct { []const u8, []const u8 }, 1);
        langs[0] = .{ name, language_id };
        Lsp.addServer(.{ .languages = langs, .name = std.fs.path.basename(cmd[0]), .command = cmd, .linter = linter, .markers = markers }) catch
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: too many language servers", .{name}));
    };
    for (settings.items) |*old| if (std.mem.eql(u8, old.name, name)) {
        old.* = s;
        return;
    };
    try settings.append(arena, s);
}

/// What `load` found wrong, for the editor to show.
pub const Report = struct { problems: []const []const u8 = &.{} };

/// Reads the config, opens the grammars it names, and applies query
/// overrides. Call once, before any file opens.
pub fn load(io: Io) Report {
    var problems: std.ArrayList([]const u8) = .empty;
    loadInner(io, &problems) catch |err| problems.append(arena, @errorName(err)) catch {};
    return .{ .problems = problems.items };
}

fn loadInner(io: Io, problems: *std.ArrayList([]const u8)) !void {
    const cfg = dir(arena, .config, "languages.toml") orelse return;
    const entries = try readEntries(arena, io, cfg, problems);
    const grammars_dir = dir(arena, .data, "grammars");
    for (entries) |e| {
        // A grammar of its own, built by `zile --grammar install`.
        var opened = false;
        if (grammars_dir) |gd| {
            const so = try std.fs.path.join(arena, &.{ gd, e.name, "parser.so" });
            if (Io.Dir.cwd().access(io, so, .{})) |_| {
                openGrammar(io, e, gd, so) catch |err| {
                    try problems.append(arena, try std.fmt.allocPrint(arena, "{s} grammar: {s}", .{ e.name, @errorName(err) }));
                };
                opened = true;
            } else |_| if (e.grammar_url != null and languages.byName(e.name) == null) {
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: grammar not built yet (run `zile --grammar install {s}`)", .{ e.name, e.name }));
            }
        }
        // More extensions for a built-in language (a grammar just opened
        // has them already).
        if (!opened) if (e.extensions) |exts| if (languages.byName(e.name)) |lang| {
            const merged = try arena.alloc([]const u8, lang.extensions.len + exts.len);
            @memcpy(merged[0..exts.len], exts);
            @memcpy(merged[exts.len..], lang.extensions);
            lang.extensions = merged;
        };
    }
    // Highlight queries of your own, for any language.
    for (languages.all()) |*lang| {
        const q = dir(arena, .config, "queries") orelse break;
        const path = try std.fs.path.join(arena, &.{ q, lang.name, "highlights.scm" });
        const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
        lang.highlights_source = src;
        lang.query = null;
        lang.query_failed = false;
        if (languages.checkQuery(lang)) |why| try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ path, why }));
    }
}

pub const GrammarError = error{ OpenFailed, NoEntryPoint, IncompatibleVersion, TooManyLanguages, OutOfMemory };

/// Opens a grammar's `parser.so` and registers its language (its queries
/// from the grammar folder).
fn openGrammar(io: Io, e: Entry, grammars_dir: []const u8, so: []const u8) GrammarError!void {
    var lib = std.DynLib.open(so) catch return error.OpenFailed;
    const symbol = try std.fmt.allocPrintSentinel(arena, "tree_sitter_{s}", .{e.symbol}, 0);
    const entry = lib.lookup(*const fn () callconv(.c) *const c.TSLanguage, symbol) orelse {
        lib.close();
        return error.NoEntryPoint;
    };
    if (!languages.abiOk(entry())) {
        lib.close();
        return error.IncompatibleVersion;
    }
    // The library stays open for good.
    const hl_path = try std.fs.path.join(arena, &.{ grammars_dir, e.name, "queries", "highlights.scm" });
    const highlights = Io.Dir.cwd().readFileAlloc(io, hl_path, arena, .limited(4 << 20)) catch "";
    const exts = e.extensions orelse if (languages.byName(e.name)) |old| old.extensions else &.{};
    _ = try languages.register(.{ .name = e.name, .extensions = exts, .highlights_source = highlights, .ts = entry });
}

test "entries and settings from a config" {
    var a_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "languages.toml", .data =
        \\[[language]]
        \\name = "my-lang"
        \\extensions = ["ml"]
        \\comment = ["(*", "*)"]
        \\indent = 3
        \\formatter = ["fmt", "{path}"]
        \\grammar = { url = "https://example.com/g", rev = "v1", path = "sub" }
        \\
        \\[[language]]
        \\extensions = ["x"]
    });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const path = try std.fs.path.join(a, &.{ dir_path, "languages.toml" });
    var problems: std.ArrayList([]const u8) = .empty;
    const entries = try readEntries(a, std.testing.io, path, &problems);
    try std.testing.expectEqual(1, entries.len);
    try std.testing.expectEqual(1, problems.items.len); // the one without a name
    try std.testing.expectEqualStrings("my_lang", entries[0].symbol);
    try std.testing.expectEqualStrings("sub", entries[0].grammar_path);
    const s = settingsFor("my-lang").?;
    try std.testing.expectEqualStrings("*)", s.comment.?.close);
    try std.testing.expectEqual(3, s.indent.?);
    try std.testing.expectEqualStrings("{path}", s.formatter.?[1]);
    settings = .empty;
}
