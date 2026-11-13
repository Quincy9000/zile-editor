//! Code actions (`SPC l a`) and workspace symbols (`SPC f w`).

const lsp_docs = @import("../lsp/docs.zig");
const Editor = @import("../Editor.zig");
const lsp_ops = @import("lsp_ops.zig");

pub fn clearCodeActions(ed: *Editor) void {
    for (ed.code_actions.items) |a| {
        ed.gpa.free(a.title);
        ed.gpa.free(a.kind);
        ed.gpa.free(a.json);
    }
    ed.code_actions.clearRetainingCapacity();
}

/// Adds an action; `json` is taken over, the rest copied.
pub fn addCodeAction(ed: *Editor, title: []const u8, kind: []const u8, json: []u8) !void {
    const t = try ed.gpa.dupe(u8, title);
    errdefer ed.gpa.free(t);
    const k = try ed.gpa.dupe(u8, kind);
    errdefer ed.gpa.free(k);
    try ed.code_actions.append(ed.gpa, .{ .title = t, .kind = k, .json = json });
}

pub fn showCodeActions(ed: *Editor) !void {
    if (ed.code_actions.items.len == 0) return ed.setMessage(.info, "no code actions here", .{});
    try ed.openPicker(.code_actions, "");
}

pub fn applyCodeAction(ed: *Editor, i: usize) !void {
    if (i >= ed.code_actions.items.len) return;
    const l = lsp_ops.lspFor(ed, ed.buffer) orelse return;
    try l.applyCodeAction(ed, ed.code_actions.items[i].json);
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

pub fn showHover(ed: *Editor, content: []const u8) !void {
    // As plain lines: the box doesn't render markdown.
    const plain = try lsp_docs.plain(ed.gpa, content, 78);
    if (ed.hover) |h| ed.gpa.free(h);
    ed.hover = plain;
}
