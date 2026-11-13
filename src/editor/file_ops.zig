//! File operations (SPC f): each asks for a path in a boxed prompt.

const std = @import("std");
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const textops = @import("../textops.zig");
const state_files = @import("state_files.zig");
const formatting = @import("formatting.zig");
const Editor = @import("../Editor.zig");
const project_ops = @import("project_ops.zig");
const prompts = @import("prompts.zig");
const git_ops = @import("git_ops.zig");
const lsp_ops = @import("lsp_ops.zig");
const PromptKind = Editor.PromptKind;

/// Opens the prompt for `kind`, prefilled with the current path (or, for a
/// new file, the current file's folder) so it only needs editing.
pub fn filePrompt(ed: *Editor, kind: PromptKind) !void {
    const path = ed.buffer.path;
    if (path == null and (kind == .rename_file or kind == .copy_file))
        return ed.setMessage(.info, "this buffer has no file yet: SPC b w saves it as one", .{});
    prompts.startSearch(ed, true, kind);
    const prefill: []const u8 = if (path) |p| switch (kind) {
        .new_file => p[0 .. if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| i + 1 else 0],
        else => p,
    } else "";
    try ed.search_prompt.?.input.set(ed.gpa, prefill);
}

pub fn finishFilePrompt(ed: *Editor, kind: PromptKind) !void {
    const raw = try git_ops.takePromptText(ed) orelse return;
    defer ed.gpa.free(raw);
    const typed = std.mem.trim(u8, raw, " ");
    if (typed.len == 0 or typed[typed.len - 1] == '/') return ed.setMessage(.info, "cancelled: no file name", .{});
    const path = try ed.normalizePath(typed);
    defer ed.gpa.free(path);
    if (kind == .new_file) {
        try ed.openFile(path);
        if (!formatting.fileExists(ed, path)) ed.setMessage(.info, "new file \"{s}\" (created when saved)", .{path});
        return;
    }
    const b = ed.buffer;
    if (b.path) |p| if (std.mem.eql(u8, p, path)) {
        if (kind == .save_as) return saveCurrent(ed);
        return ed.setMessage(.info, "that is already its name", .{});
    };
    // Never clobber another file (or an open buffer that will become one).
    if (formatting.fileExists(ed, path) or formatting.findBuffer(ed, path) != null)
        return ed.setMessage(.err, "\"{s}\" already exists", .{path});
    switch (kind) {
        .save_as => {
            const n = writeBufferTo(ed, b, path) orelse return;
            try setBufferPath(ed, b, path);
            ed.setMessage(.info, "saved as \"{s}\" ({d}B)", .{ path, n });
        },
        .rename_file => {
            const old = b.path.?;
            if (formatting.fileExists(ed, old)) {
                if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(ed.io, dir) catch {};
                Io.Dir.rename(Io.Dir.cwd(), old, Io.Dir.cwd(), path, ed.io) catch |err|
                    return ed.setMessage(.err, "could not rename: {s}", .{@errorName(err)});
            }
            ed.setMessage(.info, "renamed \"{s}\" -> \"{s}\"", .{ old, path });
            try setBufferPath(ed, b, path); // frees `old`, so after the message
        },
        .copy_file => {
            _ = writeBufferTo(ed, b, path) orelse return;
            try ed.openFile(path);
            ed.setMessage(.info, "copied to \"{s}\"", .{path});
        },
        else => unreachable,
    }
}

/// Writes `b`'s text to `path` without changing which file it belongs to.
/// Null (with a message) on failure.
pub fn writeBufferTo(ed: *Editor, b: *Buffer, path: []const u8) ?usize {
    const prev_path = b.path;
    const prev_modified = b.modified;
    b.path = @constCast(path); // restored below; save only reads it
    defer b.path = prev_path;
    const n = b.save(ed.gpa, ed.io) catch |err| {
        ed.setMessage(.err, "could not write \"{s}\": {s}", .{ path, @errorName(err) });
        return null;
    };
    // Saving a copy leaves the buffer as modified as it was.
    if (prev_path != null and !std.mem.eql(u8, prev_path.?, path)) b.modified = prev_modified;
    return n;
}

/// Points `b` at another file: the language, LSP and git follow.
pub fn setBufferPath(ed: *Editor, b: *Buffer, path: []const u8) !void {
    const owned = try ed.gpa.dupe(u8, path);
    lsp_ops.lspCloseBuffer(ed, b);
    if (b.path) |p| ed.gpa.free(p);
    b.path = owned;
    if (b.syntax) |*s| s.deinit(ed.gpa);
    b.syntax = @import("../syntax/Syntax.zig").forPath(path);
    if (b.git) |*g| g.deinit(ed.gpa);
    b.git = null;
    b.project = project_ops.projectOf(ed, path);
    git_ops.loadGitBase(ed, b);
    if (b == ed.buffer) git_ops.updateGit(ed);
}

/// `SPC b x`: asks (in a Yes/No picker) before deleting the current file.
pub fn deleteFilePrompt(ed: *Editor) !void {
    const path = ed.buffer.path orelse return ed.setMessage(.info, "this buffer has no file", .{});
    if (!formatting.fileExists(ed, path)) return ed.setMessage(.info, "\"{s}\" is not on disk", .{path});
    ed.confirm_target = ed.buffer;
    try ed.openPicker(.confirm_delete, "");
}

/// Deletes `b`'s file from disk and closes it (after the confirmation).
pub fn deleteFile(ed: *Editor, b: *Buffer) !void {
    const path = b.path orelse return;
    Io.Dir.cwd().deleteFile(ed.io, path) catch |err|
        return ed.setMessage(.err, "could not delete \"{s}\": {s}", .{ path, @errorName(err) });
    ed.setMessage(.info, "deleted \"{s}\"", .{path});
    b.modified = false;
    try ed.killBuffer(b);
}

/// `SPC b y` / `SPC b f`: the file's path, relative or absolute, to the clipboard.
pub fn yankPath(ed: *Editor, absolute: bool) !void {
    const path = ed.buffer.path orelse return ed.setMessage(.info, "this buffer has no file", .{});
    const out = if (absolute) try ed.absolutePath(path) else try ed.gpa.dupe(u8, path);
    defer ed.gpa.free(out);
    try ed.registers.store(null, .yank, out, false);
    ed.setMessage(.info, "yanked \"{s}\"", .{out});
}

/// `SPC s`: writes the current buffer (formatted first, with format on
/// save); one without a file asks for a name.
pub fn saveCurrent(ed: *Editor) !void {
    const b = ed.buffer;
    if (ed.claude) |c| if (c.diffFor(b) != null)
        return ed.setMessage(.info, "this is Claude's proposal: SPC a y accepts it, SPC a n rejects it", .{});
    if (b.path == null) return filePrompt(ed, .save_as);
    if (ed.options.trim_on_save) _ = try textops.trimTrailing(ed);
    // JavaScript / TypeScript: eslint's fixes and organized imports first.
    const lang = if (b.syntax) |sx| sx.lang.name else "";
    if (ed.save_chain == null and (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "typescript") or std.mem.eql(u8, lang, "tsx"))) {
        ed.save_chain = .{ .buffer = b, .step = .start, .started = ed.now };
        return saveChainNext(ed);
    }
    finishSave(ed, b);
}

/// The last part of saving: formatted (format on save), then written.
pub fn finishSave(ed: *Editor, b: *Buffer) void {
    // `.env` files are shell-ish, not scripts: shfmt would rewrite them.
    const env = if (b.path) |p| @import("../syntax/languages.zig").isEnvFile(p) else false;
    if (ed.options.format_on_save and b.syntax != null and b == ed.buffer and !env) {
        formatting.formatBuffer(ed, null, true) catch saveBufferNow(ed, b);
        return;
    }
    saveBufferNow(ed, b);
}

/// The save of a JS/TS file, a step at a time: eslint's "fix all", then
/// "organize imports", then format and write. Each server's answer (or 2
/// seconds without one) moves it on; a server not running is skipped.
pub fn saveChainNext(ed: *Editor) void {
    const chain = &(ed.save_chain orelse return);
    const b = chain.buffer;
    if (!state_files.bufferAlive(ed, b)) {
        ed.save_chain = null;
        return;
    }
    while (true) {
        chain.step = switch (chain.step) {
            .start => .fix_all,
            .fix_all => .organize,
            .organize, .done => .done,
        };
        chain.started = ed.now;
        switch (chain.step) {
            .start => unreachable,
            .fix_all => for (ed.lsps.items) |l| {
                if (l.server().linter and std.mem.eql(u8, l.server().name, "eslint") and l.wants(b)) {
                    if (l.requestSourceAction(ed, b, "source.fixAll.eslint")) |_| return else |_| {}
                }
            },
            .organize => if (lsp_ops.lspFor(ed, b)) |l| {
                if (l.requestSourceAction(ed, b, "source.organizeImports")) |_| return else |_| {}
            },
            .done => {
                ed.save_chain = null;
                finishSave(ed, b);
                return;
            },
        }
    }
}

/// A step waiting too long on its server: on without it.
pub fn tickSaveChain(ed: *Editor) void {
    const chain = ed.save_chain orelse return;
    const ms = @divTrunc(chain.started.durationTo(ed.now).nanoseconds, std.time.ns_per_ms);
    if (ms > 2000) saveChainNext(ed);
}

/// Writes `b` as it is.
pub fn saveBufferNow(ed: *Editor, b: *Buffer) void {
    const n = b.save(ed.gpa, ed.io) catch |err| {
        if (err == error.InvalidHex) return ed.setMessage(.err, "not saved: a line of the hex view isn't hex (an odd digit, or a letter past f)", .{});
        return ed.setMessage(.err, "could not save \"{s}\": {s}", .{ b.displayName(), @errorName(err) });
    };
    ed.setMessage(.info, "\"{s}\" {d}L, {d}B written", .{ b.displayName(), b.text.lineCount(), n });
    if (lsp_ops.lspFor(ed, b)) |l| l.didSave(b);
}
