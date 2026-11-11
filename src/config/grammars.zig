//! `zile --grammar ...`: grammars for the languages in `languages.toml`,
//! fetched and built without rebuilding zile.
//!
//!   zile --grammar install [name...]   fetch (git) and build (zig cc) the
//!                                      grammars the config names, or these
//!   zile --grammar list                every language: where its grammar
//!                                      comes from, and whether it works
//!
//! Sources are kept in `$XDG_CACHE_HOME/zile/grammar-src/<name>`; a grammar
//! is installed as `$XDG_DATA_HOME/zile/grammars/<name>/parser.so` with its
//! `queries/*.scm`. The compiler is `$ZILE_CC` (split on spaces) if set,
//! else `zig cc`, else `cc`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const languages = @import("../syntax/languages.zig");

/// Runs `zile --grammar <args>`; returns the exit code.
pub fn main(gpa: Allocator, io: Io, args: []const []const u8) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sub = if (args.len > 0) args[0] else "";
    if (std.mem.eql(u8, sub, "install")) return install(a, io, args[1..]);
    if (std.mem.eql(u8, sub, "list")) return list(a, io);
    std.debug.print(
        \\usage: zile --grammar install [name...]   fetch and build grammars named in languages.toml
        \\       zile --grammar list                show every language and its grammar
        \\
    , .{});
    return 2;
}

fn configEntries(a: Allocator, io: Io) ![]config.Entry {
    const path = config.dir(a, .config, "languages.toml") orelse return error.NoHome;
    var problems: std.ArrayList([]const u8) = .empty;
    const entries = try config.readEntries(a, io, path, &problems);
    for (problems.items) |p| std.debug.print("{s}\n", .{p});
    return entries;
}

fn install(a: Allocator, io: Io, names: []const []const u8) u8 {
    const entries = configEntries(a, io) catch |err| {
        std.debug.print("can't read languages.toml: {s}\n", .{@errorName(err)});
        return 1;
    };
    const src_root = config.dir(a, .cache, "grammar-src") orelse return 1;
    const out_root = config.dir(a, .data, "grammars") orelse return 1;
    var failed: usize = 0;
    var done: usize = 0;
    for (entries) |e| {
        if (names.len > 0) {
            const wanted = for (names) |n| {
                if (std.mem.eql(u8, n, e.name)) break true;
            } else false;
            if (!wanted) continue;
        }
        const url = e.grammar_url orelse {
            if (names.len > 0) std.debug.print("{s}: no `grammar = {{ url = ... }}` in languages.toml\n", .{e.name});
            continue;
        };
        installOne(a, io, e, url, src_root, out_root) catch |err| {
            std.debug.print("{s}: failed ({s})\n", .{ e.name, @errorName(err) });
            failed += 1;
            continue;
        };
        done += 1;
    }
    for (names) |n| {
        const known = for (entries) |e| {
            if (std.mem.eql(u8, e.name, n)) break true;
        } else false;
        if (!known) {
            std.debug.print("{s}: not in languages.toml (add a [[language]] with a grammar url)\n", .{n});
            failed += 1;
        }
    }
    if (done == 0 and failed == 0) std.debug.print("nothing to install: no language in languages.toml has a grammar url\n", .{});
    return if (failed > 0) 1 else 0;
}

fn installOne(a: Allocator, io: Io, e: config.Entry, url: []const u8, src_root: []const u8, out_root: []const u8) !void {
    const repo = try std.fs.path.join(a, &.{ src_root, e.name });
    const rev = e.grammar_rev orelse "HEAD";
    std.debug.print("{s}: fetching {s} ({s})\n", .{ e.name, url, rev });
    // A shallow fetch of exactly that revision (tag, branch or commit).
    const cwd = Io.Dir.cwd();
    cwd.access(io, try std.fs.path.join(a, &.{ repo, ".git" }), .{}) catch {
        try cwd.createDirPath(io, repo);
        try run(a, io, &.{ "git", "-C", repo, "init", "-q" });
        try run(a, io, &.{ "git", "-C", repo, "remote", "add", "origin", url });
    };
    try run(a, io, &.{ "git", "-C", repo, "remote", "set-url", "origin", url });
    try run(a, io, &.{ "git", "-C", repo, "fetch", "-q", "--depth", "1", "origin", rev });
    try run(a, io, &.{ "git", "-C", repo, "checkout", "-q", "--force", "FETCH_HEAD" });

    const base = if (e.grammar_path.len > 0) try std.fs.path.join(a, &.{ repo, e.grammar_path }) else repo;
    const src = try std.fs.path.join(a, &.{ base, "src" });
    const out = try std.fs.path.join(a, &.{ out_root, e.name });
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ out, "queries" }));

    // parser.c, and the scanner if there is one (C, or C++ in old grammars).
    var argv: std.ArrayList([]const u8) = .empty;
    const cxx = exists(io, try std.fs.path.join(a, &.{ src, "scanner.cc" }));
    try argv.appendSlice(a, try compiler(a, io, cxx));
    try argv.appendSlice(a, &.{ "-shared", "-fPIC", "-O2", "-I", src, try std.fs.path.join(a, &.{ src, "parser.c" }) });
    const scanner_c = try std.fs.path.join(a, &.{ src, "scanner.c" });
    if (exists(io, scanner_c)) try argv.append(a, scanner_c);
    if (cxx) try argv.append(a, try std.fs.path.join(a, &.{ src, "scanner.cc" }));
    const so = try std.fs.path.join(a, &.{ out, "parser.so" });
    const tmp = try std.mem.concat(a, u8, &.{ so, ".new" });
    try argv.appendSlice(a, &.{ "-o", tmp });
    std.debug.print("{s}: building\n", .{e.name});
    try run(a, io, argv.items);
    // Replaced whole, so a running zile keeps the old one it has open.
    try cwd.rename(tmp, cwd, so, io);

    // The queries: the grammar folder's, else the repo's.
    var copied: usize = 0;
    for ([_][]const u8{ base, repo }) |from| {
        const qdir = try std.fs.path.join(a, &.{ from, "queries" });
        var d = cwd.openDir(io, qdir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".scm")) continue;
            try d.copyFile(entry.name, cwd, try std.fs.path.join(a, &.{ out, "queries", entry.name }), io, .{});
            copied += 1;
        }
        if (copied > 0) break;
    }
    std.debug.print("{s}: installed in {s} ({d} quer{s})\n", .{ e.name, out, copied, if (copied == 1) "y" else "ies" });
    if (copied == 0) std.debug.print("{s}: the repo has no queries: put a highlights.scm in {s}/queries\n", .{ e.name, out });
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The C (or C++) compiler command.
fn compiler(a: Allocator, io: Io, cxx: bool) ![]const []const u8 {
    if (std.c.getenv("ZILE_CC")) |e| {
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, std.mem.span(e), ' ');
        while (it.next()) |p| try parts.append(a, p);
        if (parts.items.len > 0) return parts.items;
    }
    if (runQuiet(a, io, &.{ "zig", "version" })) return if (cxx) &.{ "zig", "c++" } else &.{ "zig", "cc" };
    return if (cxx) &.{"c++"} else &.{"cc"};
}

fn runQuiet(a: Allocator, io: Io, argv: []const []const u8) bool {
    _ = a;
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

fn run(a: Allocator, io: Io, argv: []const []const u8) !void {
    _ = a;
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore }) catch |err| {
        std.debug.print("  can't run {s}: {s}\n", .{ argv[0], @errorName(err) });
        return error.CommandFailed;
    };
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("  `{s}` failed\n", .{argv[0]});
        return error.CommandFailed;
    }
}

fn list(a: Allocator, io: Io) u8 {
    const report = config.load(io);
    for (report.problems) |p| std.debug.print("! {s}\n", .{p});
    const entries = configEntries(a, io) catch &.{};
    const gd = config.dir(a, .data, "grammars");
    for (languages.all()) |*lang| {
        const own = if (gd) |d| exists(io, std.fs.path.join(a, &.{ d, lang.name, "parser.so" }) catch "") else false;
        const configured = for (entries) |e| {
            if (std.mem.eql(u8, e.name, lang.name)) break true;
        } else false;
        const from: []const u8 = if (own) "grammar folder" else if (configured) "built-in, configured" else "built-in";
        const query = languages.checkQuery(lang);
        std.debug.print("{s:<12} {s:<22} ", .{ lang.name, from });
        for (lang.extensions, 0..) |ext, i| std.debug.print("{s}.{s}", .{ if (i > 0) " " else "", ext });
        if (query) |why| std.debug.print("   highlights: {s}", .{why});
        std.debug.print("\n", .{});
    }
    return 0;
}
