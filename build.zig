const std = @import("std");

/// Tree-sitter grammars compiled into the editor. Adding a language: fetch its
/// repo into build.zig.zon and add a row here. The editor picks up the name,
/// file extensions and `queries/highlights.scm` from this table.
const grammars = [_]struct {
    name: []const u8,
    dep: []const u8,
    extensions: []const []const u8,
    scanner: bool,
    /// Where `parser.c` lives in the repo (TypeScript has two grammars).
    src: []const u8 = "src",
    /// Highlight queries, joined in order: TypeScript's only add to
    /// JavaScript's.
    highlights: []const Query = &.{.{}},
}{
    .{ .name = "zig", .dep = "ts_zig", .extensions = &.{ "zig", "zon" }, .scanner = false },
    .{ .name = "c", .dep = "ts_c", .extensions = &.{ "c", "h" }, .scanner = false },
    .{ .name = "json", .dep = "ts_json", .extensions = &.{ "json", "jsonc", "json5", "webmanifest" }, .scanner = false },
    .{ .name = "python", .dep = "ts_python", .extensions = &.{"py"}, .scanner = true },
    .{ .name = "rust", .dep = "ts_rust", .extensions = &.{"rs"}, .scanner = true },
    .{ .name = "toml", .dep = "ts_toml", .extensions = &.{"toml"}, .scanner = true },
    .{ .name = "yaml", .dep = "ts_yaml", .extensions = &.{ "yaml", "yml" }, .scanner = true },
    // Shell: scripts, dotfiles (`.bashrc` -> "bashrc") and names without a
    // dot (`PKGBUILD`); scripts without either are found by their `#!`.
    .{
        .name = "bash",
        .dep = "ts_bash",
        .extensions = &.{ "sh", "bash", "zsh", "bashrc", "bash_profile", "bash_logout", "profile", "zshrc", "zprofile", "zshenv", "zlogin", "xinitrc", "xprofile", "envrc", "PKGBUILD", "install", "env" },
        .scanner = true,
    },
    .{ .name = "lua", .dep = "ts_lua", .extensions = &.{ "lua", "rockspec", "luacheckrc" }, .scanner = true },
    .{ .name = "sql", .dep = "ts_sql", .extensions = &.{ "sql", "psql", "pgsql" }, .scanner = true },
    .{ .name = "html", .dep = "ts_html", .extensions = &.{ "html", "htm" }, .scanner = true, .highlights = &.{ .{}, .{ .path = "queries/html.scm", .own = true } } },
    .{ .name = "css", .dep = "ts_css", .extensions = &.{"css"}, .scanner = true },
    .{
        .name = "javascript",
        .dep = "ts_javascript",
        .extensions = &.{ "js", "mjs", "cjs", "jsx" },
        .scanner = true,
        .highlights = &.{ .{}, .{ .path = "queries/highlights-jsx.scm" }, .{ .path = "queries/jsx.scm", .own = true } },
    },
    .{
        .name = "typescript",
        .dep = "ts_typescript",
        .extensions = &.{ "ts", "mts", "cts" },
        .scanner = true,
        .src = "typescript/src",
        .highlights = &.{ .{ .dep = "ts_javascript" }, .{} },
    },
    .{
        .name = "tsx",
        .dep = "ts_typescript",
        .extensions = &.{"tsx"},
        .scanner = true,
        .src = "tsx/src",
        .highlights = &.{ .{ .dep = "ts_javascript" }, .{ .dep = "ts_javascript", .path = "queries/highlights-jsx.scm" }, .{}, .{ .path = "queries/jsx.scm", .own = true } },
    },
};

/// A query file: in the grammar's own repo unless `dep` says another.
/// A highlight query: a file in a grammar's repo (this grammar's, or `dep`'s),
/// or, with `own`, one of zile's (`queries/` here).
const Query = struct { dep: ?[]const u8 = null, path: []const u8 = "queries/highlights.scm", own: bool = false };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = zileExe(b, target, optimize);
    b.installArtifact(exe);

    // `zig build release`: an optimized zile in zig-out/release/zile, apart
    // from the debug one `zig build` installs, for everyday use (it starts
    // in a millisecond and opens a big file in a fraction of the time).
    const release = b.addInstallArtifact(zileExe(b, target, .ReleaseFast), .{
        .dest_dir = .{ .override = .{ .custom = "release" } },
    });
    const release_step = b.step("release", "Build an optimized zile into zig-out/release/zile");
    release_step.dependOn(&release.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // `zig build run -- file.zig` forwards everything after `--`.
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);

    // Editor core has no raylib dependency, so it is tested headlessly.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addSyntax(b, test_mod, target, optimize);
    addTerminal(b, test_mod, target, optimize);
    // For the terminal-mode grid's color type (no window code runs in tests).
    test_mod.addImport("raylib", raylibDep(b, target, optimize).module("raylib"));
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// raylib, built from source (with its bundled GLFW, statically linked)
/// rather than the system shared library: we need direct access to GLFW
/// symbols for ordered key/char input and for waking the event loop from
/// other threads.
fn raylibDep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Dependency {
    return b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .raudio = false,
        .rmodels = false,
        // Image clipboard is the one raylib feature calling X11 directly;
        // without it nothing needs libX11 at startup (GLFW loads X11 and GL
        // itself when a window opens), so the same binary starts on a
        // server and draws in the terminal instead.
        .config = @as([]const u8, "-DSUPPORT_CLIPBOARD_IMAGE=0"),
    });
}

/// The editor executable, built with `optimize`.
fn zileExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("raylib", raylibDep(b, target, optimize).module("raylib"));
    addSyntax(b, exe_mod, target, optimize);
    addTerminal(b, exe_mod, target, optimize);
    return b.addExecutable(.{ .name = "zile", .root_module = exe_mod });
}

/// Links libghostty-vt (terminal emulation, C API) and provides it as the
/// `vt` import. The PTY and drawing are ours (src/terminal, src/ui).
fn addTerminal(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const dep = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    const lib = dep.artifact("ghostty-vt-static");
    const api = b.addTranslateC(.{
        .root_source_file = dep.path("include/ghostty/vt.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The headers are installed with the library, but a separate translate-c
    // step needs the include tree explicitly.
    api.addIncludePath(lib.getEmittedIncludeTree());
    api.defineCMacro("GHOSTTY_STATIC", "1");
    mod.addImport("vt", api.createModule());
    mod.linkLibrary(lib);
}

/// Links tree-sitter and the grammars into `mod`, and provides the
/// `tree_sitter` (C API) and `grammars` (language table) imports.
fn addSyntax(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const ts_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    const api = b.addTranslateC(.{
        .root_source_file = ts_dep.path("lib/include/tree_sitter/api.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("tree_sitter", api.createModule());
    mod.linkLibrary(ts_dep.artifact("tree-sitter"));

    // Each grammar is its own library: they ship different `tree_sitter/parser.h`.
    const files = b.addWriteFiles();
    var table: std.ArrayList(u8) = .empty;
    table.appendSlice(b.allocator, "// Generated by build.zig.\n" ++
        "pub const Grammar = struct { name: []const u8, extensions: []const []const u8, highlights: []const u8 };\n" ++
        "pub const all = [_]Grammar{\n") catch @panic("OOM");
    for (grammars) |g| {
        const dep = b.dependency(g.dep, .{});
        const lib_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        lib_mod.addIncludePath(dep.path(g.src));
        lib_mod.addCSourceFile(.{ .file = dep.path(b.fmt("{s}/parser.c", .{g.src})), .flags = &.{"-std=c11"} });
        if (g.scanner) lib_mod.addCSourceFile(.{ .file = dep.path(b.fmt("{s}/scanner.c", .{g.src})), .flags = &.{"-std=c11"} });
        mod.linkLibrary(b.addLibrary(.{ .name = b.fmt("tree-sitter-{s}", .{g.name}), .root_module = lib_mod }));

        table.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .extensions = &.{{", .{g.name})) catch @panic("OOM");
        for (g.extensions) |ext| table.appendSlice(b.allocator, b.fmt(" \"{s}\",", .{ext})) catch @panic("OOM");
        table.appendSlice(b.allocator, " }, .highlights = \"\"") catch @panic("OOM");
        for (g.highlights, 0..) |q, k| {
            const from = if (q.dep) |d| b.dependency(d, .{}) else dep;
            const name = b.fmt("{s}-{d}.scm", .{ g.name, k });
            _ = files.addCopyFile(if (q.own) b.path(q.path) else from.path(q.path), name);
            table.appendSlice(b.allocator, b.fmt(" ++ @embedFile(\"{s}\") ++ \"\\n\"", .{name})) catch @panic("OOM");
        }
        table.appendSlice(b.allocator, " },\n") catch @panic("OOM");
    }
    table.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const table_file = files.add("grammars.zig", table.items);
    mod.addImport("grammars", b.createModule(.{ .root_source_file = table_file }));
}
