//! Your settings: `$XDG_CONFIG_HOME/zile/config.zon`
//! (`~/.config/zile/config.zon`), read at startup and again when the file
//! is saved from zile. Every name is one plain word:
//!
//!     .{
//!         .fontfamily = "JetBrains Mono",   // a family's name, or a font file
//!         .fontsize = 18,
//!         .projects = .{ "~/code" },         // folders SPC p p looks in
//!         .wrap = false,
//!         .tabwidth = 2,
//!         .keys = .{
//!             .normal = .{ .{ "<Space>x", "git_changes" } },
//!         },
//!     }
//!
//! What isn't in the file keeps its default. The options are the editor's
//! own (`Editor.Options`), their names without the underscores.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Editor = @import("../Editor.zig");
const config = @import("config.zig");
const km = @import("../input/keymap.zig");
const notifications = @import("../editor/notifications.zig");

/// A key sequence (`<Space>x`, as the keymap writes them) and the name of
/// the command it runs (the command picker shows the names).
pub const Bind = struct { []const u8, []const u8 };

pub const Keys = struct {
    normal: []const Bind = &.{},
    insert: []const Bind = &.{},
    visual: []const Bind = &.{},
};

pub const Settings = struct {
    /// A font family as fontconfig knows it, or the path of a font file.
    fontfamily: ?[]const u8 = null,
    /// In pixels.
    fontsize: ?i32 = null,
    /// Folders searched (three levels deep) for projects (`SPC p p`).
    projects: ?[]const []const u8 = null,
    keys: Keys = .{},

    // `Editor.Options`, a field for each (checked below).
    tabwidth: ?usize = null,
    expandtab: ?bool = null,
    scrolloff: ?usize = null,
    ghostlines: ?bool = null,
    relativenumbers: ?bool = null,
    diagnostictext: ?bool = null,
    ligatures: ?bool = null,
    autopairs: ?bool = null,
    formatonsave: ?bool = null,
    aicomplete: ?bool = null,
    highlightpatterns: ?bool = null,
    cursorword: ?bool = null,
    indentscope: ?bool = null,
    trailingspace: ?bool = null,
    trimonsave: ?bool = null,
    codelens: ?bool = null,
    homefilter: ?bool = null,
    stickycontext: ?bool = null,
    wrap: ?bool = null,
    autosave: ?bool = null,
    icons: ?bool = null,
    smoothscroll: ?bool = null,
    gitblame: ?bool = null,
    debugvalues: ?bool = null,
    inlayhints: ?bool = null,
};

/// An option's name in the file: the field's, without its underscores.
fn plain(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (name) |ch| {
            if (ch != '_') out = out ++ &[_]u8{ch};
        }
        return out;
    }
}

/// The options that are set under their own name (the rest have other
/// names here: `projects`).
fn isOption(comptime name: []const u8) bool {
    return !std.mem.eql(u8, name, "project_dirs");
}

comptime {
    // An option added to the editor is a setting here too.
    for (@typeInfo(Editor.Options).@"struct".field_names) |name| {
        if (isOption(name) and !@hasField(Settings, plain(name)))
            @compileError("config/settings.zig: no setting for the option " ++ name);
    }
}

// What is read lives as long as zile does (the editor keeps slices of it).
var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
const arena = arena_state.allocator();

pub const Loaded = struct {
    settings: Settings = .{},
    /// What was wrong with the file, to show.
    problems: []const []const u8 = &.{},
};

/// The file's path (in `gpa`), if there is a home to have it in.
pub fn path(gpa: Allocator) ?[]u8 {
    return config.dir(gpa, .config, "config.zon");
}

/// Reads the file. When there is none, one is made first: a copy of zile's
/// default one (`defaultFile`), if that is installed.
pub fn read(io: Io) Loaded {
    const file = path(arena) orelse return .{};
    _ = create(io, file);
    const source = Io.Dir.cwd().readFileAllocOptions(io, file, arena, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return .{ .problems = one("config.zon: could not be read ({s})", .{@errorName(err)}) },
    };
    return parse(source);
}

/// Where zile's default `config.zon` is installed (every setting at its
/// default; the repo's `config.zon`, which `zig build` puts in
/// `share/zile/`). It is a file beside the program, not part of it: looked
/// for in `../share/zile` from the executable, then in the data folders
/// (`$XDG_DATA_HOME`, `$XDG_DATA_DIRS`). Null when it isn't installed.
pub fn defaultFile(a: Allocator, io: Io) ?[]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &buf)) |n| {
        if (existing(a, io, &.{ buf[0..n], "..", "share", "zile", "config.zon" })) |f| return f;
    } else |_| {}
    if (config.dir(a, .data, "config.zon")) |f| {
        if (Io.Dir.cwd().access(io, f, .{})) |_| return f else |_| a.free(f);
    }
    const dirs: []const u8 = if (std.c.getenv("XDG_DATA_DIRS")) |d| std.mem.span(d) else "/usr/local/share:/usr/share";
    var it = std.mem.tokenizeScalar(u8, dirs, ':');
    while (it.next()) |d| if (existing(a, io, &.{ d, "zile", "config.zon" })) |f| return f;
    return null;
}

fn existing(a: Allocator, io: Io, parts: []const []const u8) ?[]u8 {
    const f = std.fs.path.join(a, parts) catch return null;
    Io.Dir.cwd().access(io, f, .{}) catch {
        a.free(f);
        return null;
    };
    return f;
}

/// Makes `file` a copy of the default one unless something is there
/// already. False when there is still no file (no default one installed).
fn create(io: Io, file: []const u8) bool {
    if (Io.Dir.cwd().access(io, file, .{})) |_| return true else |_| {}
    const from = defaultFile(arena, io) orelse return false;
    const text = Io.Dir.cwd().readFileAlloc(io, from, arena, .limited(1 << 20)) catch return false;
    if (std.fs.path.dirname(file)) |d| Io.Dir.cwd().createDirPath(io, d) catch return false;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text, .flags = .{ .exclusive = true } }) catch return false;
    return true;
}

fn one(comptime fmt: []const u8, args: anytype) []const []const u8 {
    const list = arena.alloc([]const u8, 1) catch return &.{};
    list[0] = std.fmt.allocPrint(arena, fmt, args) catch return &.{};
    return list;
}

/// `source` as settings; when something in it is wrong, none of it is taken
/// and `problems` says where (`config.zon:3:5: ...`).
pub fn parse(source: [:0]const u8) Loaded {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const s = std.zon.parse.fromSlice(Settings, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return .{},
        error.ParseZon => {
            var problems: std.ArrayList([]const u8) = .empty;
            const text = std.fmt.allocPrint(arena, "{f}", .{diagnostics.fmt("config.zon")}) catch return .{};
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |l| problems.append(arena, l) catch {};
            return .{ .problems = problems.items };
        },
    };
    return .{ .settings = s };
}

/// Puts `s` to work in `ed`: its options, the project folders, the keys.
/// Returns what could not be applied (a key that isn't one, a command that
/// doesn't exist). The font is the caller's (`fontFile`): it is loaded once.
pub fn apply(ed: *Editor, s: *const Settings) []const []const u8 {
    var problems: std.ArrayList([]const u8) = .empty;
    inline for (@typeInfo(Editor.Options).@"struct".field_names) |name| {
        const key = comptime plain(name);
        if (comptime isOption(name)) {
            if (@field(s, key)) |v| @field(ed.options, name) = v;
        }
    }
    if (s.projects) |dirs| set: {
        const out = arena.alloc([]const u8, dirs.len) catch break :set;
        for (dirs, out) |d, *o| o.* = expandHome(d);
        ed.options.project_dirs = out;
    }
    inline for (.{ "normal", "insert", "visual" }) |mode| {
        for (@field(s.keys, mode)) |b| {
            ed.keymap.bind(@field(km.Mode, mode), b[0], b[1]) catch |err| {
                const why = switch (err) {
                    error.UnknownCommand => std.fmt.allocPrint(arena, "config.zon: keys: there is no command named \"{s}\" (for {s})", .{ b[1], b[0] }),
                    error.OutOfMemory => continue,
                    else => std.fmt.allocPrint(arena, "config.zon: keys: \"{s}\" isn't a key sequence (as in <Space>x, <C-s>)", .{b[0]}),
                } catch continue;
                problems.append(arena, why) catch {};
            };
        }
    }
    return problems.items;
}

fn expandHome(dir: []const u8) []const u8 {
    if (dir.len == 0 or dir[0] != '~') return dir;
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return dir;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ home, dir[1..] }) catch dir;
}

/// The font file for `fontfamily`: itself when it is a path, else what
/// fontconfig has for that family. `problem` is set when it has no such
/// family (null is returned: the usual font is used).
pub fn fontFile(gpa: Allocator, io: Io, family: []const u8, problem: *?[]const u8) ?[]u8 {
    if (std.mem.indexOfScalar(u8, family, '/') != null) return gpa.dupe(u8, expandHome(family)) catch null;
    const r = std.process.run(gpa, io, .{ .argv = &.{ "fc-match", "-f", "%{family}\n%{file}", family } }) catch {
        problem.* = std.fmt.allocPrint(arena, "config.zon: fontfamily needs fontconfig (fc-match) to find \"{s}\"; a font file's path works without it", .{family}) catch null;
        return null;
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, r.stdout, " \n"), '\n');
    const found = lines.next() orelse "";
    const file = lines.next() orelse "";
    // fontconfig always answers, with its nearest: only the family asked for counts.
    var names = std.mem.splitScalar(u8, found, ',');
    const matches = while (names.next()) |n| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, n, " "), family)) break true;
    } else false;
    if (!matches or file.len == 0) {
        problem.* = std.fmt.allocPrint(arena, "config.zon: no font family named \"{s}\" is installed (fc-list : family lists them)", .{family}) catch null;
        return null;
    }
    return gpa.dupe(u8, file) catch null;
}

/// The command: opens the file (made first, from `default_file`, when
/// there is none).
pub fn open(ed: *Editor) !void {
    const file = path(ed.gpa) orelse return ed.setMessage(.err, "no home folder to keep config.zon in", .{});
    defer ed.gpa.free(file);
    if (!create(ed.io, file)) ed.setMessage(.info, "a new config.zon (zile's default one isn't installed: share/zile/config.zon beside the program)", .{});
    try ed.openFile(file);
}

/// A file was saved: when it is the settings, they are read and applied.
pub fn saved(ed: *Editor, file: []const u8) void {
    const mine = path(ed.gpa) orelse return;
    defer ed.gpa.free(mine);
    if (!std.mem.eql(u8, mine, file)) return;
    const loaded = read(ed.io);
    for (loaded.problems) |p| notifications.notify(ed, .err, "{s}", .{p});
    if (loaded.problems.len > 0) return;
    const problems = apply(ed, &loaded.settings);
    for (problems) |p| notifications.notify(ed, .err, "{s}", .{p});
    if (problems.len == 0) ed.setMessage(.info, "settings applied (the font when zile next starts)", .{});
}

test "config.zon: plain names for the options, projects and keys; what is wrong is said with its line" {
    const testing = std.testing;
    const loaded = parse(
        \\.{
        \\    .fontfamily = "Some Mono",
        \\    .fontsize = 20,
        \\    .projects = .{ "/srv/code", "~/work" },
        \\    .wrap = false,
        \\    .tabwidth = 2,
        \\    .trimonsave = true,
        \\    .keys = .{ .normal = .{ .{ "<Space>x", "git_changes" }, .{ "<Space>y", "no_such_command" } } },
        \\}
    );
    try testing.expectEqual(0, loaded.problems.len);
    try testing.expectEqualStrings("Some Mono", loaded.settings.fontfamily.?);
    try testing.expectEqual(20, loaded.settings.fontsize.?);

    var ed = try Editor.init(testing.allocator, testing.io);
    defer ed.deinit();
    try testing.expect(ed.options.wrap);
    const problems = apply(&ed, &loaded.settings);
    try testing.expect(!ed.options.wrap);
    try testing.expectEqual(2, ed.options.tab_width);
    try testing.expect(ed.options.trim_on_save);
    try testing.expect(ed.options.autosave); // not in the file: as it was
    try testing.expectEqual(2, ed.options.project_dirs.len);
    try testing.expectEqualStrings("/srv/code", ed.options.project_dirs[0]);
    try testing.expect(std.mem.endsWith(u8, ed.options.project_dirs[1], "/work"));
    try testing.expect(ed.options.project_dirs[1][0] != '~' or std.c.getenv("HOME") == null);
    // The key is bound; the command that doesn't exist is said.
    try ed.feed("<Space>x");
    try testing.expectEqual(.git_hunks, ed.picker.?.kind);
    try testing.expectEqual(1, problems.len);
    try testing.expect(std.mem.indexOf(u8, problems[0], "no_such_command") != null);

    // A name that isn't a setting: nothing is taken, the line is said.
    const wrong = parse(
        \\.{
        \\    .wrap = false,
        \\    .fontfmily = "x",
        \\}
    );
    try testing.expectEqual(null, wrong.settings.wrap);
    try testing.expect(wrong.problems.len > 0);
    try testing.expect(std.mem.startsWith(u8, wrong.problems[0], "config.zon:3:"));

    // SPC o is the file's key (a row of the leader menu).
    try testing.expect(std.mem.indexOfScalar(u8, @import("../picker/sources.zig").rowKeys(.leader), 'o') != null);

    // The repo's default file (config.zon, installed beside the program)
    // reads, and says every option at the
    // editor's own default: a new option, or a default changed, is added there.
    const default_file = try Io.Dir.cwd().readFileAllocOptions(testing.io, "config.zon", testing.allocator, .limited(1 << 20), .of(u8), 0);
    defer testing.allocator.free(default_file);
    const fresh = parse(default_file);
    try testing.expectEqual(0, fresh.problems.len);
    const defaults: Editor.Options = .{};
    inline for (@typeInfo(Editor.Options).@"struct".field_names) |name| {
        const key = comptime plain(name);
        if (comptime isOption(name)) {
            const v = @field(fresh.settings, key) orelse return error.OptionMissingFromDefaultConfig;
            try testing.expectEqual(@field(defaults, name), v);
        }
    }
    try testing.expectEqual(18, fresh.settings.fontsize.?);
    try testing.expectEqual(0, fresh.settings.projects.?.len);
    try testing.expectEqual(null, fresh.settings.fontfamily);
}
