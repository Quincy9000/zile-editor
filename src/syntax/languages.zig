//! The languages compiled into the editor (see `grammars` in build.zig), their
//! highlight queries, and query predicate evaluation.
//!
//! Queries are compiled lazily on first use and live for the whole process.
//! Main thread only.

const std = @import("std");
const c = @import("tree_sitter");
const grammars = @import("grammars");
const highlight = @import("highlight.zig");
const Regex = @import("Regex.zig");

pub const Style = highlight.Style;

pub const Language = struct {
    name: []const u8,
    extensions: []const []const u8,
    highlights_source: []const u8,
    /// Where other languages are inside this one (markdown's text and code
    /// fences); empty: nowhere.
    injections_source: []const u8 = "",
    ts: *const fn () callconv(.c) *const c.TSLanguage,
    query: ?*Query = null,
    query_failed: bool = false,
    injection_query: ?*InjectionQuery = null,
    injection_failed: bool = false,

    /// The compiled injection query, if it has one (and it compiles).
    pub fn injections(lang: *Language) ?*const InjectionQuery {
        if (lang.injection_query) |q| return q;
        if (lang.injection_failed or lang.injections_source.len == 0) return null;
        lang.injection_query = InjectionQuery.load(lang) catch |err| blk: {
            std.log.warn("{s} injection query: {s}", .{ lang.name, @errorName(err) });
            lang.injection_failed = true;
            break :blk null;
        };
        return lang.injection_query;
    }

    /// The compiled highlight query, or null if it failed to compile.
    pub fn highlights(lang: *Language) ?*const Query {
        if (lang.query) |q| return q;
        if (lang.query_failed) return null;
        lang.query = Query.load(lang) catch |err| blk: {
            std.log.warn("{s} highlight query: {s}", .{ lang.name, @errorName(err) });
            lang.query_failed = true;
            break :blk null;
        };
        return lang.query;
    }
};

/// The built-in grammars (compiled in, with the `tree_sitter_<name>` entry
/// point declared at compile time), then those loaded at startup from the
/// grammar folder (`config.zig`). Fixed capacity, so pointers to entries
/// stay valid.
pub const max_languages = 96;
var registry: [max_languages]Language = blk: {
    var langs: [max_languages]Language = undefined;
    for (grammars.all, 0..) |g, i| {
        langs[i] = .{
            .name = g.name,
            .extensions = g.extensions,
            .highlights_source = g.highlights,
            .injections_source = g.injections,
            .ts = @extern(*const fn () callconv(.c) *const c.TSLanguage, .{ .name = "tree_sitter_" ++ g.name }),
        };
    }
    break :blk langs;
};
var registry_len: usize = grammars.all.len;

/// Every language, built-in first.
pub fn all() []Language {
    return registry[0..registry_len];
}

/// Adds a language (a grammar loaded at runtime); one already known by
/// that name is replaced in place.
pub fn register(lang: Language) error{TooManyLanguages}!*Language {
    if (byName(lang.name)) |old| {
        old.* = lang;
        return old;
    }
    if (registry_len == registry.len) return error.TooManyLanguages;
    registry[registry_len] = lang;
    registry_len += 1;
    return &registry[registry_len - 1];
}

pub fn forPath(path: []const u8) ?*Language {
    const base = std.fs.path.basename(path);
    // No dot: the whole name (`PKGBUILD`). `.env.local` and the like are
    // `.env` files too.
    const ext = if (isEnvFile(path)) "env" else if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[dot + 1 ..] else base;
    // Later entries first: an extension given in the config wins over a
    // built-in language's.
    var i = registry_len;
    while (i > 0) {
        i -= 1;
        for (registry[i].extensions) |e| if (std.mem.eql(u8, e, ext)) return &registry[i];
    }
    return null;
}

/// A dotenv file: `.env`, `.env.local`, `.env.production`, `app.env`.
/// Highlighted as shell, but not formatted or checked as a script.
pub fn isEnvFile(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, ".env") or std.mem.startsWith(u8, base, ".env.") or std.mem.endsWith(u8, base, ".env");
}

/// The language a `#!` first line names (`#!/bin/bash`,
/// `#!/usr/bin/env python3`), if it is one we have.
pub fn forShebang(first_line: []const u8) ?*Language {
    if (!std.mem.startsWith(u8, first_line, "#!")) return null;
    var words = std.mem.tokenizeAny(u8, first_line[2..], " \t\r");
    var prog = std.fs.path.basename(words.next() orelse return null);
    if (std.mem.eql(u8, prog, "env")) {
        prog = words.next() orelse return null;
        if (std.mem.eql(u8, prog, "-S")) prog = words.next() orelse return null;
    }
    // `python3.12` -> `python`, `bash5` -> `bash`.
    const end = std.mem.indexOfAny(u8, prog, "0123456789.") orelse prog.len;
    const name = prog[0..end];
    const lang: []const u8 = for ([_][2][]const u8{
        .{ "bash", "bash" }, .{ "sh", "bash" },     .{ "zsh", "bash" },         .{ "dash", "bash" },
        .{ "ksh", "bash" },  .{ "python", "python" }, .{ "node", "javascript" }, .{ "deno", "typescript" },
        .{ "bun", "typescript" }, .{ "lua", "lua" }, .{ "luajit", "lua" },
    }) |m| {
        if (std.mem.eql(u8, m[0], name)) break m[1];
    } else return null;
    return byName(lang);
}

/// The language a code fence or an injection names (`zig`, `js`, `sh`,
/// `python`): by name, then as a file extension.
pub fn forInjection(name: []const u8) ?*Language {
    if (byName(name)) |l| return l;
    var buf: [32]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(name.len, buf.len)], name[0..@min(name.len, buf.len)]);
    if (byName(lower)) |l| return l;
    for ([_][2][]const u8{ .{ "shell", "bash" }, .{ "console", "bash" }, .{ "jsonc", "json" } }) |a| {
        if (std.mem.eql(u8, a[0], lower)) return byName(a[1]);
    }
    var i = registry_len;
    while (i > 0) {
        i -= 1;
        for (registry[i].extensions) |e| if (std.mem.eql(u8, e, lower)) return &registry[i];
    }
    return null;
}

pub fn byName(name: []const u8) ?*Language {
    for (registry[0..registry_len]) |*lang| if (std.mem.eql(u8, lang.name, name)) return lang;
    return null;
}

/// Whether the parser is one this tree-sitter can use.
pub fn abiOk(lang: *const c.TSLanguage) bool {
    const v = c.ts_language_abi_version(lang);
    return v >= c.TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION and v <= c.TREE_SITTER_LANGUAGE_VERSION;
}

/// Compiles `source` as a highlight query for `lang`, or says where it
/// fails (for `zile --grammar list`). The error text is static.
pub fn checkQuery(lang: *Language) ?[]const u8 {
    var err_offset: u32 = 0;
    var err_type: c.TSQueryError = c.TSQueryErrorNone;
    const src = lang.highlights_source;
    const q = c.ts_query_new(lang.ts(), src.ptr, @intCast(src.len), &err_offset, &err_type) orelse return switch (err_type) {
        c.TSQueryErrorSyntax => "syntax error",
        c.TSQueryErrorNodeType => "unknown node type",
        c.TSQueryErrorField => "unknown field",
        c.TSQueryErrorCapture => "unknown capture",
        c.TSQueryErrorStructure => "impossible pattern",
        else => "error",
    };
    c.ts_query_delete(q);
    return null;
}

// Query data lives as long as the process; tree-sitter itself uses malloc.
const alloc = std.heap.c_allocator;

pub const Query = struct {
    ts: *c.TSQuery,
    /// Style for each capture index.
    capture_styles: []Style,
    /// Predicates for each pattern index.
    predicates: [][]Predicate,

    const LoadError = error{ QueryCompile, OutOfMemory };

    fn load(lang: *Language) LoadError!*Query {
        var err_offset: u32 = 0;
        var err_type: c.TSQueryError = c.TSQueryErrorNone;
        const src = lang.highlights_source;
        const ts = c.ts_query_new(lang.ts(), src.ptr, @intCast(src.len), &err_offset, &err_type) orelse {
            std.log.warn("{s}: query error {d} at byte {d}", .{ lang.name, err_type, err_offset });
            return error.QueryCompile;
        };
        const q = try alloc.create(Query);
        q.ts = ts;

        q.capture_styles = try alloc.alloc(Style, c.ts_query_capture_count(ts));
        for (q.capture_styles, 0..) |*s, i| {
            var len: u32 = 0;
            const name = c.ts_query_capture_name_for_id(ts, @intCast(i), &len);
            s.* = highlight.styleForCapture(name[0..len]);
        }

        q.predicates = try alloc.alloc([]Predicate, c.ts_query_pattern_count(ts));
        for (q.predicates, 0..) |*preds, i| preds.* = try parsePredicates(ts, @intCast(i));
        return q;
    }

    /// Whether all predicates of the match's pattern hold.
    pub fn matches(q: *const Query, m: c.TSQueryMatch, text: []const u8) bool {
        for (q.predicates[m.pattern_index]) |p| {
            if (!p.holds(m, text)) return false;
        }
        return true;
    }
};

/// Where other languages are inside a language: each match's
/// `@injection.content` node is in the language its `@injection.language`
/// capture names, or its pattern's `#set! injection.language`.
pub const InjectionQuery = struct {
    ts: *c.TSQuery,
    content: ?u32 = null,
    language: ?u32 = null,
    /// Per pattern: the language `#set!` names, if any.
    set_language: []?[]const u8,
    predicates: [][]Predicate,

    fn load(lang: *Language) Query.LoadError!*InjectionQuery {
        var err_offset: u32 = 0;
        var err_type: c.TSQueryError = c.TSQueryErrorNone;
        const src = lang.injections_source;
        const ts = c.ts_query_new(lang.ts(), src.ptr, @intCast(src.len), &err_offset, &err_type) orelse {
            std.log.warn("{s}: injection query error {d} at byte {d}", .{ lang.name, err_type, err_offset });
            return error.QueryCompile;
        };
        const q = try alloc.create(InjectionQuery);
        q.* = .{ .ts = ts, .set_language = &.{}, .predicates = &.{} };
        for (0..c.ts_query_capture_count(ts)) |i| {
            var len: u32 = 0;
            const name = c.ts_query_capture_name_for_id(ts, @intCast(i), &len);
            if (std.mem.eql(u8, name[0..len], "injection.content")) q.content = @intCast(i);
            if (std.mem.eql(u8, name[0..len], "injection.language")) q.language = @intCast(i);
        }
        const patterns = c.ts_query_pattern_count(ts);
        q.set_language = try alloc.alloc(?[]const u8, patterns);
        q.predicates = try alloc.alloc([]Predicate, patterns);
        for (0..patterns) |i| {
            q.set_language[i] = setLanguage(ts, @intCast(i));
            q.predicates[i] = try parsePredicates(ts, @intCast(i));
        }
        return q;
    }

    pub fn matches(q: *const InjectionQuery, m: c.TSQueryMatch, text: []const u8) bool {
        for (q.predicates[m.pattern_index]) |p| {
            if (!p.holds(m, text)) return false;
        }
        return true;
    }

    /// `(#set! injection.language "html")` in pattern `pattern`.
    fn setLanguage(ts: *c.TSQuery, pattern: u32) ?[]const u8 {
        var count: u32 = 0;
        const steps_ptr = c.ts_query_predicates_for_pattern(ts, pattern, &count);
        if (count == 0) return null;
        const steps = steps_ptr[0..count];
        var i: usize = 0;
        while (i + 3 < steps.len) : (i += 1) {
            if (steps[i].type != c.TSQueryPredicateStepTypeString or steps[i + 1].type != c.TSQueryPredicateStepTypeString or steps[i + 2].type != c.TSQueryPredicateStepTypeString) continue;
            if (!std.mem.eql(u8, stringValue(ts, steps[i].value_id), "set!")) continue;
            if (!std.mem.eql(u8, stringValue(ts, steps[i + 1].value_id), "injection.language")) continue;
            return stringValue(ts, steps[i + 2].value_id);
        }
        return null;
    }
};

pub const Predicate = struct {
    kind: enum { eq, any_of, match },
    negate: bool,
    capture: u32,
    values: []const []const u8,
    regex: ?Regex = null,

    fn holds(p: Predicate, m: c.TSQueryMatch, text: []const u8) bool {
        const node_text = captureText(m, p.capture, text) orelse return true;
        const result = switch (p.kind) {
            .eq => std.mem.eql(u8, node_text, p.values[0]),
            .any_of => for (p.values) |v| {
                if (std.mem.eql(u8, node_text, v)) break true;
            } else false,
            .match => if (p.regex) |re| re.isMatch(node_text) else true,
        };
        return result != p.negate;
    }
};

fn captureText(m: c.TSQueryMatch, capture: u32, text: []const u8) ?[]const u8 {
    for (m.captures[0..m.capture_count]) |cap| {
        if (cap.index != capture) continue;
        const start = c.ts_node_start_byte(cap.node);
        const end = c.ts_node_end_byte(cap.node);
        if (end > text.len or start > end) return null;
        return text[start..end];
    }
    return null;
}

/// Parses the predicates of one pattern. Unknown ones (`#set!`, ...) are ignored.
fn parsePredicates(ts: *c.TSQuery, pattern: u32) ![]Predicate {
    var count: u32 = 0;
    const steps_ptr = c.ts_query_predicates_for_pattern(ts, pattern, &count);
    if (count == 0) return &.{};
    const steps = steps_ptr[0..count];
    var out: std.ArrayList(Predicate) = .empty;

    var i: usize = 0;
    while (i < steps.len) {
        // One predicate: name, args..., done.
        var end = i;
        while (end < steps.len and steps[end].type != c.TSQueryPredicateStepTypeDone) end += 1;
        defer i = end + 1;
        const args = steps[i..end];
        if (args.len < 2 or args[0].type != c.TSQueryPredicateStepTypeString) continue;
        if (args[1].type != c.TSQueryPredicateStepTypeCapture) continue;

        const name = stringValue(ts, args[0].value_id);
        const negate = std.mem.startsWith(u8, name, "not-");
        const base = if (negate) name["not-".len..] else name;

        var values: std.ArrayList([]const u8) = .empty;
        for (args[2..]) |a| {
            if (a.type == c.TSQueryPredicateStepTypeString) try values.append(alloc, stringValue(ts, a.value_id));
        }
        if (values.items.len == 0) continue;

        var p: Predicate = .{ .kind = .eq, .negate = negate, .capture = args[1].value_id, .values = try values.toOwnedSlice(alloc) };
        if (std.mem.eql(u8, base, "eq?")) {
            p.kind = .eq;
        } else if (std.mem.eql(u8, base, "any-of?")) {
            p.kind = .any_of;
        } else if (std.mem.eql(u8, base, "match?") or std.mem.eql(u8, base, "lua-match?")) {
            p.kind = .match;
            p.regex = Regex.compile(p.values[0], std.mem.eql(u8, base, "lua-match?"));
        } else continue;
        try out.append(alloc, p);
    }
    return out.toOwnedSlice(alloc);
}

fn stringValue(ts: *c.TSQuery, id: u32) []const u8 {
    var len: u32 = 0;
    const s = c.ts_query_string_value_for_id(ts, id, &len);
    return s[0..len];
}

/// Runs `q` over `[start, end)` of the tree, writing a style for every byte
/// into `out` (indexed from `start`). Later captures override earlier ones,
/// so specific patterns (listed after general ones) win.
pub fn run(q: *const Query, cursor: *c.TSQueryCursor, root: c.TSNode, text: []const u8, start: usize, end: usize, out: []Style) void {
    @memset(out, .none);
    _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
    c.ts_query_cursor_exec(cursor, q.ts, root);
    var m: c.TSQueryMatch = undefined;
    var capture_index: u32 = 0;
    while (c.ts_query_cursor_next_capture(cursor, &m, &capture_index)) {
        const cap = m.captures[capture_index];
        const style = q.capture_styles[cap.index];
        if (style == .none) continue;
        if (!q.matches(m, text)) continue;
        const s = @max(c.ts_node_start_byte(cap.node), start);
        const e = @min(c.ts_node_end_byte(cap.node), end);
        if (e > s) @memset(out[s - start .. e - start], style);
    }
}

/// Like `run`, over styles already there: only bytes a capture styles
/// change (another language's highlights over its host's).
pub fn overlay(q: *const Query, cursor: *c.TSQueryCursor, root: c.TSNode, text: []const u8, start: usize, end: usize, out: []Style) void {
    _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(start), @intCast(end));
    c.ts_query_cursor_exec(cursor, q.ts, root);
    var m: c.TSQueryMatch = undefined;
    var capture_index: u32 = 0;
    while (c.ts_query_cursor_next_capture(cursor, &m, &capture_index)) {
        const cap = m.captures[capture_index];
        const style = q.capture_styles[cap.index];
        if (style == .none) continue;
        if (!q.matches(m, text)) continue;
        const s = @max(c.ts_node_start_byte(cap.node), start);
        const e = @min(c.ts_node_end_byte(cap.node), end);
        if (e > s) @memset(out[s - start .. e - start], style);
    }
}

test "every grammar's highlight query compiles" {
    for (all()) |*lang| {
        if (lang.highlights() == null) {
            std.debug.print("query failed for {s}\n", .{lang.name});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqualStrings("zig", forPath("src/main.zig").?.name);
    try std.testing.expectEqualStrings("rust", forPath("/x/lib.rs").?.name);
    try std.testing.expectEqual(null, forPath("README"));
    try std.testing.expectEqualStrings("bash", forPath("/home/x/.bashrc").?.name);
    try std.testing.expectEqualStrings("bash", forPath("pkg/PKGBUILD").?.name);
    try std.testing.expectEqualStrings("sql", forPath("q.sql").?.name);
    try std.testing.expectEqualStrings("bash", forShebang("#!/usr/bin/env bash").?.name);
    try std.testing.expectEqualStrings("bash", forShebang("#!/bin/sh -e").?.name);
    try std.testing.expectEqualStrings("python", forShebang("#!/usr/bin/env python3.12").?.name);
    try std.testing.expectEqual(null, forShebang("echo hi"));
    // Injection queries compile too; a fence's language by name or extension.
    for (all()) |*lang| if (lang.injections_source.len > 0 and lang.injections() == null) {
        std.debug.print("injection query failed for {s}\n", .{lang.name});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings("markdown", forPath("README.md").?.name);
    try std.testing.expectEqualStrings("javascript", forInjection("js").?.name);
    try std.testing.expectEqualStrings("bash", forInjection("sh").?.name);
    try std.testing.expectEqualStrings("python", forInjection("Python").?.name);
    try std.testing.expectEqual(null, forInjection("nonsense"));
}
