//! Code actions (`SPC l a`) and workspace symbols (`SPC f w`).

const std = @import("std");
const lsp_docs = @import("../lsp/docs.zig");
const Editor = @import("../Editor.zig");
const lsp_ops = @import("lsp_ops.zig");
const Lsp = @import("../lsp/Lsp.zig");

pub fn clearCodeActions(ed: *Editor) void {
    for (ed.code_actions.items) |a| {
        ed.gpa.free(a.title);
        ed.gpa.free(a.kind);
        ed.gpa.free(a.json);
    }
    ed.code_actions.clearRetainingCapacity();
}

/// `SPC l a`: asks every server that has this file (the language's own,
/// and a linter's: eslint has fixes of its own) for what can be done on
/// lines `first..last`. Their answers fill one list.
pub fn requestCodeActions(ed: *Editor, first: usize, last: usize) !void {
    clearCodeActions(ed);
    ed.code_actions_waiting = 0;
    for (ed.lsps.items) |l| {
        if (!l.wants(ed.buffer) or !l.can_code_action) continue;
        l.requestCodeActions(ed, first, last) catch continue;
        ed.code_actions_waiting += 1;
    }
    if (ed.code_actions_waiting == 0) ed.setMessage(.info, "no language server here offers code actions", .{});
}

/// Adds an action from `server`; `json` is taken over, the rest copied.
/// Fixes come before refactorings, the fix a server prefers first.
pub fn addCodeAction(ed: *Editor, server: ?*Lsp, title: []const u8, kind: []const u8, preferred: bool, json: []u8) !void {
    const t = try ed.gpa.dupe(u8, title);
    errdefer ed.gpa.free(t);
    const k = try ed.gpa.dupe(u8, kind);
    errdefer ed.gpa.free(k);
    const rank: u8 = if (preferred) 0 else if (std.mem.startsWith(u8, kind, "quickfix")) 1 else 2;
    var at = ed.code_actions.items.len;
    while (at > 0 and ed.code_actions.items[at - 1].rank > rank) at -= 1;
    try ed.code_actions.insert(ed.gpa, at, .{ .title = t, .kind = k, .json = json, .server = server, .rank = rank });
}

/// A server answered (its actions are added already): the list is shown,
/// or shown again with what was added; "none" only once all have answered.
pub fn codeActionsArrived(ed: *Editor) !void {
    ed.code_actions_waiting -|= 1;
    if (ed.code_actions.items.len == 0) {
        if (ed.code_actions_waiting == 0) ed.setMessage(.info, "no code actions here", .{});
        return;
    }
    if (ed.picker) |p| {
        if (p.kind == .code_actions) return p.refill();
        return;
    }
    try ed.openPicker(.code_actions, "");
}

pub fn applyCodeAction(ed: *Editor, i: usize) !void {
    if (i >= ed.code_actions.items.len) return;
    const a = ed.code_actions.items[i];
    const server = a.server orelse return;
    // (It may have gone since it offered this.)
    if (std.mem.indexOfScalar(*Lsp, ed.lsps.items, server) == null) return ed.setMessage(.err, "the server that offered this is gone", .{});
    try server.applyCodeAction(ed, a.json);
}

pub fn clearWorkspaceSymbols(ed: *Editor) void {
    for (ed.workspace_symbols.items) |s| {
        ed.gpa.free(s.name);
        ed.gpa.free(s.path);
    }
    ed.workspace_symbols.clearRetainingCapacity();
}

pub fn addWorkspaceSymbol(ed: *Editor, name: []const u8, kind: []const u8, path: []const u8, line: usize, col: usize) !void {
    const n = try ed.gpa.dupe(u8, name);
    errdefer ed.gpa.free(n);
    const p = try ed.gpa.dupe(u8, path);
    errdefer ed.gpa.free(p);
    try ed.workspace_symbols.append(ed.gpa, .{ .name = n, .kind = kind, .path = p, .line = line, .col = col });
}

/// `SPC f w`: the picker opens at once; the server fills it as you type.
pub fn showWorkspaceSymbols(ed: *Editor) !void {
    const l = lsp_ops.languageServer(ed) orelse return;
    clearWorkspaceSymbols(ed);
    try ed.openPicker(.workspace_symbols, "");
    try l.requestWorkspaceSymbols("");
}

/// The server answered: the open picker lists the new symbols.
pub fn workspaceSymbolsArrived(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind == .workspace_symbols) try p.refill();
}

/// `SPC l y`: the type the hover tells of goes to the register (and the
/// clipboard, as any yank); the hover is shown, to see what it was taken from.
pub fn yankType(ed: *Editor, content: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const t = @import("../lsp/hover_type.zig").of(content, &buf) orelse return ed.setMessage(.info, "no type in what the language server says here", .{});
    try ed.registers.store(null, .yank, t, false);
    try showHover(ed, content);
    const line = t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
    const more: []const u8 = if (line.len < t.len) " ..." else "";
    ed.setMessage(.info, "yanked the type: {s}{s}", .{ line[0..@min(line.len, 90)], more });
}

pub fn showHover(ed: *Editor, content: []const u8) !void {
    // As plain lines: the box doesn't render markdown.
    const plain = try lsp_docs.plain(ed.gpa, content, 78);
    if (ed.hover) |h| ed.gpa.free(h);
    ed.hover = plain;
}
