//! A language server for one language: document sync, diagnostics, and
//! definition / references / hover / completion / rename / symbols.
//!
//! The servers are a built-in table (no configuration yet). The editor runs
//! at most one instance of each, started when a file of its language opens.
//! Main thread only. `Editor.tick` calls `sync` and `poll` every frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("../Editor.zig");
const Buffer = @import("../core/Buffer.zig");
const Client = @import("Client.zig");
const Symbol = @import("../syntax/objects.zig").Symbol;

const Lsp = @This();

gpa: Allocator,
client: *Client,
/// Index into `servers`.
index: usize,
/// Characters that should pop up completion (from the server's capabilities).
triggers: std.ArrayList(u8) = .empty,
pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
/// Open documents.
docs: std.AutoHashMapUnmanaged(*Buffer, Doc) = .empty,
/// Diagnostics by buffer-style path (relative to the cwd when inside it).
diagnostics: std.StringArrayHashMapUnmanaged([]Diagnostic) = .empty,

const Doc = struct {
    uri: []u8,
    version: i32,
    /// `Buffer.edit_version` last sent.
    synced: u64,
};

pub const Severity = enum(u8) { err = 1, warning = 2, info = 3, hint = 4 };

pub const Diagnostic = struct {
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
    severity: Severity,
    message: []u8,
};

const Pending = union(enum) {
    initialize,
    definition,
    references,
    hover,
    rename,
    symbols,
    completion: struct { buffer: *Buffer, word_start: usize },
};

/// One edit of a WorkspaceEdit, by file (0-based positions).
pub const TextEdit = struct {
    path: []u8,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    text: []u8,
};

pub const Location = struct {
    path: []u8,
    line: u32,
    col: u32,
};

pub const Server = struct {
    /// Tree-sitter language name of the files it serves.
    language: []const u8,
    /// For messages.
    name: []const u8,
    command: []const []const u8,
    /// LSP `languageId` for didOpen.
    language_id: []const u8,
};

/// The built-in servers. One row per language.
pub const servers = [_]Server{
    .{ .language = "zig", .name = "zls", .command = &.{"zls"}, .language_id = "zig" },
    .{ .language = "c", .name = "clangd", .command = &.{"clangd"}, .language_id = "c" },
    .{ .language = "rust", .name = "rust-analyzer", .command = &.{"rust-analyzer"}, .language_id = "rust" },
};

/// The server for a buffer's language, if any (index into `servers`).
pub fn serverFor(b: *const Buffer) ?usize {
    const s = b.syntax orelse return null;
    if (b.path == null) return null;
    for (servers, 0..) |srv, i| if (std.mem.eql(u8, srv.language, s.lang.name)) return i;
    return null;
}

pub fn server(l: *const Lsp) *const Server {
    return &servers[l.index];
}

/// Whether `b` belongs to this server.
pub fn wants(l: *const Lsp, b: *const Buffer) bool {
    return serverFor(b) == l.index;
}

pub fn isTrigger(l: *const Lsp, cp: u21) bool {
    return cp < 0x80 and std.mem.indexOfScalar(u8, l.triggers.items, @intCast(cp)) != null;
}

pub fn start(ed: *Editor, index: usize) !*Lsp {
    const gpa = ed.gpa;
    const client = try Client.start(gpa, ed.io, servers[index].command, ed.wake_fn);
    errdefer client.deinit();
    const l = try gpa.create(Lsp);
    l.* = .{ .gpa = gpa, .client = client, .index = index };
    errdefer gpa.destroy(l);

    const root = try Client.uriFromPath(gpa, ed.cwd);
    defer gpa.free(root);
    const id = try client.request("initialize", .{
        .rootUri = root,
        .workspaceFolders = &[_]struct { uri: []const u8, name: []const u8 }{.{ .uri = root, .name = std.fs.path.basename(ed.cwd) }},
        .capabilities = .{
            .general = .{ .positionEncodings = &[_][]const u8{"utf-8"} },
            .textDocument = .{
                .synchronization = .{ .didSave = true },
                .completion = .{ .completionItem = .{ .snippetSupport = false } },
                .hover = .{ .contentFormat = &[_][]const u8{ "plaintext", "markdown" } },
                .publishDiagnostics = .{ .relatedInformation = false },
                .documentSymbol = .{ .hierarchicalDocumentSymbolSupport = true },
            },
        },
    });
    try l.pending.put(gpa, id, .initialize);
    return l;
}

pub fn deinit(l: *Lsp) void {
    const gpa = l.gpa;
    l.client.deinit();
    l.triggers.deinit(gpa);
    l.pending.deinit(gpa);
    var docs = l.docs.valueIterator();
    while (docs.next()) |d| gpa.free(d.uri);
    l.docs.deinit(gpa);
    for (l.diagnostics.keys(), l.diagnostics.values()) |k, v| {
        gpa.free(k);
        freeDiagnostics(gpa, v);
    }
    l.diagnostics.deinit(gpa);
    gpa.destroy(l);
}

fn freeDiagnostics(gpa: Allocator, list: []Diagnostic) void {
    for (list) |d| gpa.free(d.message);
    gpa.free(list);
}

pub fn diagnosticsFor(l: *const Lsp, path: []const u8) []const Diagnostic {
    return l.diagnostics.get(path) orelse &.{};
}

// ---------------------------------------------------------------------------
// Document sync

/// Opens new documents and sends changed text (whole-document sync).
pub fn sync(l: *Lsp, ed: *Editor) !void {
    for (ed.buffers.items) |b| {
        if (!l.wants(b)) continue;
        if (l.docs.getPtr(b)) |doc| {
            if (doc.synced == b.edit_version) continue;
            const text = try fullText(l.gpa, b);
            defer l.gpa.free(text);
            doc.version += 1;
            doc.synced = b.edit_version;
            try l.client.notify("textDocument/didChange", .{
                .textDocument = .{ .uri = doc.uri, .version = doc.version },
                .contentChanges = &[_]struct { text: []const u8 }{.{ .text = text }},
            });
        } else {
            const abs = try ed.absolutePath(b.path.?);
            defer l.gpa.free(abs);
            const uri = try Client.uriFromPath(l.gpa, abs);
            errdefer l.gpa.free(uri);
            const text = try fullText(l.gpa, b);
            defer l.gpa.free(text);
            try l.docs.put(l.gpa, b, .{ .uri = uri, .version = 1, .synced = b.edit_version });
            try l.client.notify("textDocument/didOpen", .{
                .textDocument = .{ .uri = uri, .languageId = l.server().language_id, .version = 1, .text = text },
            });
        }
    }
}

/// The document as the server should see it (with the final newline).
fn fullText(gpa: Allocator, b: *const Buffer) ![]u8 {
    const body = b.text.slice(0, b.text.len());
    return std.mem.concat(gpa, u8, &.{ body, if (b.final_newline and body.len > 0) "\n" else "" });
}

pub fn didSave(l: *Lsp, b: *Buffer) void {
    const doc = l.docs.get(b) orelse return;
    l.client.notify("textDocument/didSave", .{ .textDocument = .{ .uri = doc.uri } }) catch {};
}

/// Call before a buffer is destroyed or reused for another file.
pub fn closeBuffer(l: *Lsp, b: *Buffer) void {
    const doc = l.docs.fetchRemove(b) orelse return;
    defer l.gpa.free(doc.value.uri);
    l.client.notify("textDocument/didClose", .{ .textDocument = .{ .uri = doc.value.uri } }) catch {};
    // A completion for this buffer can no longer be applied.
    var stale: ?i64 = null;
    var it = l.pending.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .completion => |cp| if (cp.buffer == b) {
            stale = e.key_ptr.*;
        },
        else => {},
    };
    if (stale) |k| _ = l.pending.remove(k);
}

// ---------------------------------------------------------------------------
// Requests

fn position(ed: *Editor) struct { line: usize, character: usize } {
    const t = ed.text();
    const line = ed.cursorLine();
    return .{ .line = line, .character = ed.view.cursor - t.lineStart(line) };
}

fn docUri(l: *Lsp, ed: *Editor) ?[]const u8 {
    const doc = l.docs.get(ed.buffer) orelse {
        ed.setMessage(.err, "no language server for this file", .{});
        return null;
    };
    return doc.uri;
}

pub fn requestDefinition(l: *Lsp, ed: *Editor) !void {
    const uri = l.docUri(ed) orelse return;
    const id = try l.client.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = position(ed) });
    try l.pending.put(l.gpa, id, .definition);
}

pub fn requestReferences(l: *Lsp, ed: *Editor) !void {
    const uri = l.docUri(ed) orelse return;
    const id = try l.client.request("textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = position(ed),
        .context = .{ .includeDeclaration = true },
    });
    try l.pending.put(l.gpa, id, .references);
}

pub fn requestHover(l: *Lsp, ed: *Editor) !void {
    const uri = l.docUri(ed) orelse return;
    const id = try l.client.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = position(ed) });
    try l.pending.put(l.gpa, id, .hover);
}

pub fn requestSymbols(l: *Lsp, ed: *Editor) !void {
    const uri = l.docUri(ed) orelse return;
    try l.sync(ed);
    const id = try l.client.request("textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } });
    try l.pending.put(l.gpa, id, .symbols);
}

pub fn requestRename(l: *Lsp, ed: *Editor, pos: usize, new_name: []const u8) !void {
    const uri = l.docUri(ed) orelse return;
    try l.sync(ed);
    const t = ed.text();
    const line = t.lineOf(pos);
    const id = try l.client.request("textDocument/rename", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = line, .character = pos - t.lineStart(line) },
        .newName = new_name,
    });
    try l.pending.put(l.gpa, id, .rename);
}

pub fn requestCompletion(l: *Lsp, ed: *Editor, word_start: usize) !void {
    const doc = l.docs.get(ed.buffer) orelse return;
    // Send pending edits first so the server sees what was just typed.
    try l.sync(ed);
    const id = try l.client.request("textDocument/completion", .{ .textDocument = .{ .uri = doc.uri }, .position = position(ed) });
    try l.pending.put(l.gpa, id, .{ .completion = .{ .buffer = ed.buffer, .word_start = word_start } });
}

// ---------------------------------------------------------------------------
// Incoming messages

/// Handles everything the server sent. Returns false if the server is gone.
pub fn poll(l: *Lsp, ed: *Editor) bool {
    var msgs: std.ArrayList([]u8) = .empty;
    defer msgs.deinit(l.gpa);
    const alive = l.client.takeMessages(&msgs);
    for (msgs.items) |body| {
        defer l.gpa.free(body);
        var parsed = std.json.parseFromSlice(std.json.Value, l.gpa, body, .{}) catch continue;
        defer parsed.deinit();
        l.dispatch(ed, parsed.value) catch |err| ed.setMessage(.err, "lsp: {s}", .{@errorName(err)});
    }
    return alive;
}

fn dispatch(l: *Lsp, ed: *Editor, msg: std.json.Value) !void {
    if (msg != .object) return;
    const obj = msg.object;
    if (obj.get("method")) |m| {
        const method = if (m == .string) m.string else return;
        if (obj.get("id")) |id| return l.answerServerRequest(id, method, obj.get("params"));
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) try l.onDiagnostics(ed, obj.get("params") orelse return);
        return;
    }
    const id = obj.get("id") orelse return;
    if (id != .integer) return;
    const req = (l.pending.fetchRemove(id.integer) orelse return).value;
    const result = obj.get("result") orelse .null;
    if (obj.get("error")) |e| {
        if (req != .completion) ed.setMessage(.err, "lsp: {s}", .{str(field(e, "message")) orelse "request failed"});
        return;
    }
    switch (req) {
        .initialize => {
            // Remember which characters pop up completion (`.`, `::`, `->`...).
            const caps = field(result, "capabilities");
            if (field(field(caps, "completionProvider"), "triggerCharacters")) |tc| if (tc == .array) {
                for (tc.array.items) |s| if (str(s)) |chars| if (chars.len > 0) {
                    try l.triggers.append(l.gpa, chars[chars.len - 1]);
                };
            };
            // `.{}` would serialize as `[]` (an empty tuple); the spec wants `{}`.
            try l.client.notifyNow("initialized", struct {}{});
            try l.client.markReady();
        },
        .definition, .references => {
            var locs: std.ArrayList(Location) = .empty;
            defer {
                for (locs.items) |loc| l.gpa.free(loc.path);
                locs.deinit(l.gpa);
            }
            try l.collectLocations(ed, result, &locs);
            const what = if (req == .definition) "definition" else "references";
            try ed.showLocations(locs.items, what);
        },
        .hover => {
            const text = hoverText(result) orelse return ed.setMessage(.info, "no hover information", .{});
            try ed.showHover(text);
        },
        .completion => |cp| try ed.showCompletion(cp.buffer, cp.word_start, result),
        .symbols => {
            var list: std.ArrayList(Symbol) = .empty;
            errdefer {
                for (list.items) |s| l.gpa.free(s.name);
                list.deinit(l.gpa);
            }
            try l.collectSymbols(result, "", &list);
            defer list.deinit(l.gpa); // the names now belong to the editor
            try ed.setSymbols(list.items);
        },
        .rename => {
            var edits: std.ArrayList(TextEdit) = .empty;
            defer {
                for (edits.items) |e| {
                    l.gpa.free(e.path);
                    l.gpa.free(e.text);
                }
                edits.deinit(l.gpa);
            }
            try l.collectWorkspaceEdit(ed, result, &edits);
            try ed.applyEdits(edits.items);
        },
    }
}

/// zls asks for configuration and progress tokens; answer so it never waits.
fn answerServerRequest(l: *Lsp, id: std.json.Value, method: []const u8, params: ?std.json.Value) !void {
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        const n = if (field(params orelse .null, "items")) |items| (if (items == .array) items.array.items.len else 0) else 0;
        const nulls: [32]?u8 = @splat(null);
        return l.client.respond(id, nulls[0..@min(n, nulls.len)]);
    }
    try l.client.respond(id, null);
}

fn onDiagnostics(l: *Lsp, ed: *Editor, params: std.json.Value) !void {
    const uri = str(field(params, "uri")) orelse return;
    const abs = (try Client.pathFromUri(l.gpa, uri)) orelse return;
    defer l.gpa.free(abs);
    const path = try ed.relativePath(abs);
    errdefer l.gpa.free(path);

    var list: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (list.items) |d| l.gpa.free(d.message);
        list.deinit(l.gpa);
    }
    if (field(params, "diagnostics")) |arr| if (arr == .array) for (arr.array.items) |d| {
        const range = field(d, "range") orelse continue;
        const from = field(range, "start") orelse continue;
        const to = field(range, "end") orelse continue;
        const sev = int(field(d, "severity")) orelse 1;
        try list.append(l.gpa, .{
            .line = @intCast(int(field(from, "line")) orelse 0),
            .col = @intCast(int(field(from, "character")) orelse 0),
            .end_line = @intCast(int(field(to, "line")) orelse 0),
            .end_col = @intCast(int(field(to, "character")) orelse 0),
            .severity = std.enums.fromInt(Severity, std.math.cast(u8, sev) orelse 1) orelse .err,
            .message = try l.gpa.dupe(u8, str(field(d, "message")) orelse ""),
        });
    };
    std.mem.sort(Diagnostic, list.items, {}, struct {
        fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
            return if (a.line != b.line) a.line < b.line else @intFromEnum(a.severity) < @intFromEnum(b.severity);
        }
    }.lessThan);

    const gop = try l.diagnostics.getOrPut(l.gpa, path);
    if (gop.found_existing) {
        l.gpa.free(path);
        freeDiagnostics(l.gpa, gop.value_ptr.*);
    }
    gop.value_ptr.* = try list.toOwnedSlice(l.gpa);
}

/// Location | Location[] | LocationLink[] | null
fn collectLocations(l: *Lsp, ed: *Editor, result: std.json.Value, out: *std.ArrayList(Location)) !void {
    switch (result) {
        .array => |arr| for (arr.items) |item| try l.collectLocations(ed, item, out),
        .object => {
            const uri = str(field(result, "uri")) orelse str(field(result, "targetUri")) orelse return;
            const range = field(result, "range") orelse field(result, "targetSelectionRange") orelse return;
            const from = field(range, "start") orelse return;
            const abs = (try Client.pathFromUri(l.gpa, uri)) orelse return;
            defer l.gpa.free(abs);
            const path = try ed.relativePath(abs);
            errdefer l.gpa.free(path);
            try out.append(l.gpa, .{
                .path = path,
                .line = @intCast(int(field(from, "line")) orelse 0),
                .col = @intCast(int(field(from, "character")) orelse 0),
            });
        },
        else => {},
    }
}

/// DocumentSymbol[] (nested via `children`) or SymbolInformation[] (flat,
/// with `containerName`), flattened in document order with qualified names.
fn collectSymbols(l: *Lsp, v: std.json.Value, parent: []const u8, out: *std.ArrayList(Symbol)) !void {
    if (v != .array) return;
    for (v.array.items) |sym| {
        const name = str(field(sym, "name")) orelse continue;
        const container = str(field(sym, "containerName")) orelse parent;
        const range = field(sym, "selectionRange") orelse field(sym, "range") orelse
            field(field(sym, "location"), "range") orelse continue;
        const begin = field(range, "start") orelse continue;
        const qualified = try std.mem.concat(l.gpa, u8, &.{ container, if (container.len > 0) "." else "", name });
        errdefer l.gpa.free(qualified);
        const kind: usize = @intCast(int(field(sym, "kind")) orelse 0);
        try out.append(l.gpa, .{
            .name = qualified,
            .kind = if (kind < symbol_kinds.len) symbol_kinds[kind] else "",
            .line = @intCast(int(field(begin, "line")) orelse 0),
            .col = @intCast(int(field(begin, "character")) orelse 0),
        });
        if (field(sym, "children")) |children| try l.collectSymbols(children, qualified, out);
    }
}

/// LSP SymbolKind -> short label (index = kind number).
const symbol_kinds = [_][]const u8{
    "",       "file",   "module", "namespace", "package", "class",  "method",   "property", "field",
    "ctor",   "enum",   "iface",  "fn",        "var",     "const",  "string",   "number",   "bool",
    "array",  "object", "key",    "null",      "member",  "struct", "event",    "operator", "typeparam",
};

/// WorkspaceEdit: `changes: {uri: TextEdit[]}` or
/// `documentChanges: [{textDocument: {uri}, edits: TextEdit[]}]`.
fn collectWorkspaceEdit(l: *Lsp, ed: *Editor, result: std.json.Value, out: *std.ArrayList(TextEdit)) !void {
    if (field(result, "documentChanges")) |dc| if (dc == .array) for (dc.array.items) |change| {
        const uri = str(field(field(change, "textDocument"), "uri")) orelse continue;
        try l.collectTextEdits(ed, uri, field(change, "edits") orelse continue, out);
    };
    if (field(result, "changes")) |ch| if (ch == .object) {
        var it = ch.object.iterator();
        while (it.next()) |e| try l.collectTextEdits(ed, e.key_ptr.*, e.value_ptr.*, out);
    };
}

fn collectTextEdits(l: *Lsp, ed: *Editor, uri: []const u8, edits: std.json.Value, out: *std.ArrayList(TextEdit)) !void {
    if (edits != .array) return;
    const abs = (try Client.pathFromUri(l.gpa, uri)) orelse return;
    defer l.gpa.free(abs);
    for (edits.array.items) |e| {
        const range = field(e, "range") orelse continue;
        const from = field(range, "start") orelse continue;
        const to = field(range, "end") orelse continue;
        const path = try ed.relativePath(abs);
        errdefer l.gpa.free(path);
        try out.append(l.gpa, .{
            .path = path,
            .start_line = @intCast(int(field(from, "line")) orelse 0),
            .start_col = @intCast(int(field(from, "character")) orelse 0),
            .end_line = @intCast(int(field(to, "line")) orelse 0),
            .end_col = @intCast(int(field(to, "character")) orelse 0),
            .text = try l.gpa.dupe(u8, str(field(e, "newText")) orelse ""),
        });
    }
}

/// MarkupContent | MarkedString | MarkedString[]
fn hoverText(result: std.json.Value) ?[]const u8 {
    const contents = field(result, "contents") orelse return null;
    return switch (contents) {
        .string => |s| s,
        .object => str(field(contents, "value")),
        .array => |a| if (a.items.len > 0) (if (a.items[0] == .string) a.items[0].string else str(field(a.items[0], "value"))) else null,
        else => null,
    };
}

// JSON helpers

pub fn field(v: ?std.json.Value, name: []const u8) ?std.json.Value {
    const val = v orelse return null;
    if (val != .object) return null;
    return val.object.get(name);
}

pub fn str(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

pub fn int(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return if (val == .integer) val.integer else null;
}
