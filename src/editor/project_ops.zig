//! Projects: the git repo (or build-file folder) a file is in.

const std = @import("std");
const Io = std.Io;
const Project = @import("../core/Project.zig");
const RunMemory = @import("../terminal/RunMemory.zig");
const state_files = @import("state_files.zig");
const Editor = @import("../Editor.zig");
const browser = @import("browser.zig");

/// The project for `root`, shared by every buffer in it.
pub fn internProject(ed: *Editor, root: []const u8, git: bool) ?*const Project {
    for (ed.projects.items) |p| if (std.mem.eql(u8, p.root, root)) return p;
    const p = ed.gpa.create(Project) catch return null;
    p.* = .{ .root = ed.gpa.dupe(u8, root) catch {
        ed.gpa.destroy(p);
        return null;
    }, .git = git };
    ed.projects.append(ed.gpa, p) catch {
        ed.gpa.free(p.root);
        ed.gpa.destroy(p);
        return null;
    };
    return p;
}

/// The project a buffer path (relative to the cwd, or absolute) belongs to.
pub fn projectOf(ed: *Editor, path: []const u8) ?*const Project {
    const abs = ed.absolutePath(path) catch return null;
    defer ed.gpa.free(abs);
    const f = Project.detect(ed.io, std.fs.path.dirname(abs) orelse return null) orelse return null;
    return internProject(ed, f.root, f.git);
}

/// The current project: the focused buffer's, else the last one used.
pub fn project(ed: *const Editor) ?*const Project {
    return ed.buffer.project orelse ed.last_project;
}

/// Where project-wide things happen: the current project, else the cwd.
pub fn projectRoot(ed: *const Editor) []const u8 {
    if (ed.work_dir) |w| return w;
    return if (project(ed)) |p| p.root else ed.cwd;
}

/// `c` in Files ("work here", a cd): `dir` is where Files, search, the
/// runner and the terminal work from now on.
pub fn workIn(ed: *Editor, dir: []const u8) !void {
    const owned = try ed.gpa.dupe(u8, dir);
    if (ed.work_dir) |old| ed.gpa.free(old);
    ed.work_dir = owned;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = std.mem.span(std.c.getenv("HOME") orelse "");
    const shown = if (home.len > 0 and std.mem.startsWith(u8, owned, home)) std.fmt.bufPrint(&buf, "~{s}", .{owned[home.len..]}) catch owned else owned;
    ed.setMessage(.info, "working in {s}", .{shown});
}

/// The current project's repository root, if it is one.
pub fn gitRoot(ed: *const Editor) ?[]const u8 {
    const p = project(ed) orelse return null;
    return if (p.git) p.root else null;
}

/// A path from a picker (relative to the folder it listed) as a buffer path.
/// Caller frees.
pub fn pickerPath(ed: *Editor, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return ed.normalizePath(path);
    const abs = try std.fs.path.join(ed.gpa, &.{ ed.picker_root, path });
    defer ed.gpa.free(abs);
    return ed.normalizePath(abs);
}

/// A buffer's project becomes the one we're in (and is remembered for
/// `SPC p p`).
pub fn enterProject(ed: *Editor, p: ?*const Project) void {
    const proj = p orelse return;
    if (ed.last_project == proj) return;
    ed.last_project = proj;
    rememberProject(ed, proj.root);
}

pub fn knownProjectsPath(ed: *Editor) ?[]u8 {
    return RunMemory.statePath(ed.gpa, "projects");
}

/// Projects opened before, most recent first.
pub fn knownProjects(ed: *Editor) []const []u8 {
    if (ed.known_projects == null) {
        ed.known_projects = .empty;
        if (@import("builtin").is_test) return ed.known_projects.?.items;
        const path = knownProjectsPath(ed) orelse return &.{};
        defer ed.gpa.free(path);
        const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(1 << 20)) catch return &.{};
        defer ed.gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| if (line.len > 0) {
            const owned = ed.gpa.dupe(u8, line) catch break;
            ed.known_projects.?.append(ed.gpa, owned) catch ed.gpa.free(owned);
        };
    }
    return ed.known_projects.?.items;
}

pub const max_known_projects = 50;

pub fn rememberProject(ed: *Editor, root: []const u8) void {
    _ = knownProjects(ed);
    const list = &ed.known_projects.?;
    for (list.items, 0..) |r, i| if (std.mem.eql(u8, r, root)) {
        if (i == 0) return;
        const owned = list.orderedRemove(i);
        list.insert(ed.gpa, 0, owned) catch ed.gpa.free(owned);
        return saveKnownProjects(ed);
    };
    const owned = ed.gpa.dupe(u8, root) catch return;
    list.insert(ed.gpa, 0, owned) catch return ed.gpa.free(owned);
    while (list.items.len > max_known_projects) ed.gpa.free(list.pop().?);
    saveKnownProjects(ed);
}

pub fn saveKnownProjects(ed: *Editor) void {
    if (@import("builtin").is_test) return;
    const path = knownProjectsPath(ed) orelse return;
    defer ed.gpa.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ed.gpa);
    for (ed.known_projects.?.items) |r| out.print(ed.gpa, "{s}\n", .{r}) catch return;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(ed.io, dir) catch return;
    Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// `SPC p p` picked a project: find a file in it.
pub fn switchProject(ed: *Editor, root: []const u8) !void {
    const f = Project.detect(ed.io, root) orelse Project.Found{ .root = root, .git = false };
    const p = internProject(ed, f.root, f.git) orelse return;
    // Leaving a project keeps its session; coming back to one with nothing
    // open restores it.
    const same = project(ed) == p;
    if (!same) state_files.saveSession(ed, false);
    enterProject(ed, p);
    if (!same and ed.deferred_target == null and !state_files.hasBuffersIn(ed, p) and state_files.restoreSession(ed, p.root)) return;
    try exploreProject(ed, p.root);
}

/// The Files picker (the explorer) at project `root`.
pub fn exploreProject(ed: *Editor, root: []const u8) !void {
    const r = try ed.gpa.dupe(u8, root);
    defer ed.gpa.free(r);
    ed.next_picker_root = internProject(ed, r, (Project.detect(ed.io, r) orelse Project.Found{ .root = r, .git = false }).git).?.root;
    try browser.setBrowseDir(ed, r);
    try ed.openPicker(.browse, "");
}

/// Forgets project `root` from the list of ones opened before.
pub fn forgetProject(ed: *Editor, root: []const u8) void {
    _ = knownProjects(ed);
    const list = &ed.known_projects.?;
    for (list.items, 0..) |r, i| if (std.mem.eql(u8, r, root)) {
        ed.gpa.free(list.orderedRemove(i));
        saveKnownProjects(ed);
        return;
    };
}
