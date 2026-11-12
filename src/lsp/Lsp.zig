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
const Text = @import("../core/Text.zig");

const Lsp = @This();
const balance = @import("balance.zig");
const config = @import("../config/config.zig");

gpa: Allocator,
client: *Client,
/// Index into `servers`.
index: usize,
/// The project root this server works in (borrowed from the editor's
/// project list), and the editor's cwd for buffers without a project.
root: []const u8 = "",
cwd: []const u8 = "",
/// Characters that should pop up completion (from the server's capabilities).
triggers: std.ArrayList(u8) = .empty,
sig_triggers: std.ArrayList(u8) = .empty,
/// The server formats whole documents / ranges.
can_format: bool = false,
can_format_range: bool = false,
can_implement: bool = false,
can_inlay: bool = false,
/// The server offers code lens (and fills them in on request).
can_lens: bool = false,
can_resolve_lens: bool = false,
can_resolve_action: bool = false,
/// The latest workspace-symbol request: answers to older ones are stale.
ws_request: i64 = -1,
sig_retriggers: std.ArrayList(u8) = .empty,
pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
/// Titles of the server's work in progress, by notification key (owned).
progress_titles: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
/// Open documents.
docs: std.AutoHashMapUnmanaged(*Buffer, Doc) = .empty,
/// Diagnostics by buffer-style path (relative to the cwd when inside it).
diagnostics: std.StringArrayHashMapUnmanaged([]Diagnostic) = .empty,
/// What the server said about the file as it is sent, and about the real
/// text when that differs (a shadow document); `diagnostics` is both, merged.
raw_main: std.StringArrayHashMapUnmanaged([]Diagnostic) = .empty,
raw_shadow: std.StringArrayHashMapUnmanaged([]Diagnostic) = .empty,

const Doc = struct {
    uri: []u8,
    version: i32,
    /// `Buffer.edit_version` last sent.
    synced: u64,
    /// The file is missing a closing bracket: the server is sent it closed
    /// (else it can't parse it, and loses types and errors from there on),
    /// and this is the bracket left open, for our own error.
    unclosed: ?struct { line: u32, col: u32, closer: u8 } = null,
    /// Lines the buffer really has (the server's copy may have an extra).
    real_lines: u32 = 0,
    /// The real text is also open under `shadowUri`, so its own syntax
    /// errors are reported too.
    shadow: bool = false,
    shadow_version: i32 = 0,
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
    signature: *Buffer,
    format: struct { buffer: *Buffer, then_save: bool },
    implementation,
    /// Inlay hints for lines `first..last` of a buffer, as it was at `version`.
    inlay_hints: struct { buffer: *Buffer, version: u64, first: usize, last: usize },
    code_actions,
    /// A code action sent back for its edit (`codeAction/resolve`).
    code_action_resolve,
    /// `workspace/executeCommand`: the server answers with its own
    /// `workspace/applyEdit` request; this reply carries nothing.
    execute_command,
    workspace_symbols,
    /// A source action asked for before saving (fix all, organize imports).
    save_action,
    save_action_resolve,
    /// Code lens for a buffer as it was at `version`, and one filled in.
    code_lens: struct { buffer: *Buffer, version: u64 },
    code_lens_resolve: struct { buffer: *Buffer, version: u64, line: u32 },
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
    /// Tree-sitter language names of the files it serves, each with its LSP
    /// `languageId` (for didOpen).
    languages: []const struct { []const u8, []const u8 },
    /// For messages.
    name: []const u8,
    command: []const []const u8,
    /// JSX in a `.js`/`.jsx` file is `javascriptreact` to the server.
    react_ids: bool = false,
    /// Runs beside a file's main server, for its diagnostics only (eslint).
    linter: bool = false,
    /// A linter runs only in projects with one of these files at the root.
    markers: []const []const u8 = &.{},
    /// Settings sent once it has started (`workspace/didChangeConfiguration`),
    /// as JSON.
    settings: ?[]const u8 = null,
};

/// The built-in servers. One row per server; one server for a project
/// serves all of its languages.
const builtin_servers = [_]Server{
    .{ .languages = &.{.{ "zig", "zig" }}, .name = "zls", .command = &.{"zls"} },
    .{ .languages = &.{.{ "c", "c" }}, .name = "clangd", .command = &.{"clangd"} },
    .{ .languages = &.{.{ "rust", "rust" }}, .name = "rust-analyzer", .command = &.{"rust-analyzer"} },
    .{ .languages = &.{.{ "lua", "lua" }}, .name = "lua-language-server", .command = &.{"lua-language-server"} },
    .{ .languages = &.{.{ "go", "go" }}, .name = "gopls", .command = &.{"gopls"} },
    .{
        .languages = &.{ .{ "javascript", "javascript" }, .{ "typescript", "typescript" }, .{ "tsx", "typescriptreact" } },
        .name = "vtsls",
        .command = &.{ "vtsls", "--stdio" },
        .react_ids = true,
        // As the nvim config: reference and implementation counts (code
        // lens), function calls completed with their arguments.
        .settings =
        \\{"typescript":{"referencesCodeLens":{"enabled":true,"showOnAllFunctions":true},"implementationsCodeLens":{"enabled":true},"suggest":{"completeFunctionCalls":true}},
        \\ "javascript":{"referencesCodeLens":{"enabled":true,"showOnAllFunctions":true},"suggest":{"completeFunctionCalls":true}}}
        ,
    },
    .{ .languages = &.{.{ "html", "html" }}, .name = "html", .command = &.{ "vscode-html-language-server", "--stdio" } },
    .{ .languages = &.{.{ "css", "css" }}, .name = "css", .command = &.{ "vscode-css-language-server", "--stdio" } },
    .{
        .languages = &.{.{ "json", "json" }},
        .name = "json",
        .command = &.{ "vscode-json-language-server", "--stdio" },
        // The schemas the nvim config gives it: completion, hover and
        // checking for these files.
        .settings =
        \\{"json":{"validate":{"enable":true},"schemas":[
        \\{"fileMatch":["package.json"],"url":"https://json.schemastore.org/package.json"},
        \\{"fileMatch":["tsconfig.json","tsconfig.*.json"],"url":"https://json.schemastore.org/tsconfig.json"},
        \\{"fileMatch":["app.json","app.config.json"],"url":"https://www.schemastore.org/expo-53.0.0.json"},
        \\{"fileMatch":["eas.json"],"url":"https://raw.githubusercontent.com/expo/eas-cli/main/packages/eas-json/schema/eas.schema.json"}
        \\]}}
        ,
    },
    .{
        .languages = &.{ .{ "javascript", "javascript" }, .{ "typescript", "typescript" }, .{ "tsx", "typescriptreact" } },
        .name = "eslint",
        .command = &.{ "vscode-eslint-language-server", "--stdio" },
        .react_ids = true,
        .linter = true,
        .markers = &.{
            "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts", ".eslintrc",
            ".eslintrc.js",     ".eslintrc.cjs",     ".eslintrc.json",    ".eslintrc.yml",    ".eslintrc.yaml",
        },
    },
};

/// Every server: the built-in ones, then the config's (`config.zig`),
/// which win for their languages.
pub const max_servers = 48;
var server_buf: [max_servers]Server = blk: {
    var b: [max_servers]Server = undefined;
    for (builtin_servers, 0..) |srv, i| b[i] = srv;
    break :blk b;
};
pub var servers: []const Server = server_buf[0..builtin_servers.len];

/// Adds a server (from the config), before any has started.
pub fn addServer(srv: Server) error{TooManyServers}!void {
    if (servers.len == max_servers) return error.TooManyServers;
    server_buf[servers.len] = srv;
    servers = server_buf[0 .. servers.len + 1];
}

/// The server for a buffer's language, if any (index into `servers`).
pub fn serverFor(b: *const Buffer) ?usize {
    // The last one for the language: the config's over a built-in one.
    var i = servers.len;
    while (i > 0) {
        i -= 1;
        if (!servers[i].linter and serves(i, b)) return i;
    }
    return null;
}

/// Whether server `index` is for `b`'s language (main server or linter).
pub fn serves(index: usize, b: *const Buffer) bool {
    const s = b.syntax orelse return false;
    const path = b.path orelse return false;
    // A shell server would check `.env` files as scripts.
    if (@import("../syntax/languages.zig").isEnvFile(path)) return false;
    for (servers[index].languages) |lang| if (std.mem.eql(u8, lang[0], s.lang.name)) return true;
    return false;
}

/// The `languageId` this server knows `b` by.
pub fn languageId(l: *const Lsp, b: *const Buffer) []const u8 {
    const name = if (b.syntax) |s| s.lang.name else "";
    const srv = l.server();
    if (srv.react_ids and std.mem.eql(u8, name, "javascript")) {
        if (b.path) |p| if (std.mem.endsWith(u8, p, ".jsx")) return "javascriptreact";
    }
    for (srv.languages) |lang| if (std.mem.eql(u8, lang[0], name)) return lang[1];
    return srv.languages[0][1];
}

pub fn server(l: *const Lsp) *const Server {
    return &servers[l.index];
}

/// Whether `b` belongs to this server: its language, in its project.
pub fn wants(l: *const Lsp, b: *const Buffer) bool {
    return serves(l.index, b) and std.mem.eql(u8, bufferRoot(b, l.cwd), l.root);
}

/// The project root a buffer's server works in.
pub fn bufferRoot(b: *const Buffer, cwd: []const u8) []const u8 {
    return if (b.project) |p| p.root else cwd;
}

pub fn isTrigger(l: *const Lsp, cp: u21) bool {
    return cp < 0x80 and std.mem.indexOfScalar(u8, l.triggers.items, @intCast(cp)) != null;
}

/// Characters that open signature help (`(`), and ones that update it while
/// open (`,`), from the server's capabilities.
pub fn isSignatureTrigger(l: *const Lsp, cp: u21, open: bool) bool {
    if (cp >= 0x80) return false;
    const c: u8 = @intCast(cp);
    if (std.mem.indexOfScalar(u8, l.sig_triggers.items, c) != null) return true;
    return open and std.mem.indexOfScalar(u8, l.sig_retriggers.items, c) != null;
}

/// Starts server `index` for the project at `root_path` (which must outlive it).
pub fn start(ed: *Editor, index: usize, root_path: []const u8) !*Lsp {
    const gpa = ed.gpa;
    const log = logPath(gpa, index);
    defer if (log) |p| gpa.free(p);
    const client = try Client.start(gpa, ed.io, servers[index].command, ed.wake_fn, log);
    errdefer client.deinit();
    const l = try gpa.create(Lsp);
    l.* = .{ .gpa = gpa, .client = client, .index = index, .root = root_path, .cwd = ed.cwd };
    errdefer gpa.destroy(l);

    const root = try Client.uriFromPath(gpa, root_path);
    defer gpa.free(root);
    const id = try client.request("initialize", .{
        .rootUri = root,
        .workspaceFolders = &[_]struct { uri: []const u8, name: []const u8 }{.{ .uri = root, .name = std.fs.path.basename(root_path) }},
        .capabilities = .{
            .general = .{ .positionEncodings = &[_][]const u8{"utf-8"} },
            // Indexing and the like show as notifications.
            .window = .{ .workDoneProgress = true },
            .workspace = .{ .inlayHint = .{ .refreshSupport = true }, .codeLens = .{ .refreshSupport = true } },
            .textDocument = .{
                .inlayHint = .{ .dynamicRegistration = false },
                .codeLens = .{ .dynamicRegistration = false },
                .synchronization = .{ .didSave = true },
                // Snippets: function arguments arrive as placeholders.
                .completion = .{ .completionItem = .{ .snippetSupport = true } },
                .signatureHelp = .{ .signatureInformation = .{
                    .documentationFormat = &[_][]const u8{ "plaintext", "markdown" },
                    .parameterInformation = .{ .labelOffsetSupport = true },
                    .activeParameterSupport = true,
                } },
                .hover = .{ .contentFormat = &[_][]const u8{ "plaintext", "markdown" } },
                .publishDiagnostics = .{ .relatedInformation = false },
                .documentSymbol = .{ .hierarchicalDocumentSymbolSupport = true },
            },
        },
    });
    try l.pending.put(gpa, id, .initialize);
    return l;
}

/// A placeholder for `line` while its lens is resolved: the title it had
/// (if any, and none is there yet), marked stale.
fn keepOldLens(gpa: Allocator, b: *Buffer, old: []const Buffer.Lens, line: u32) !void {
    var i: usize = 0;
    while (i < b.lenses.items.len and b.lenses.items[i].line < line) i += 1;
    if (i < b.lenses.items.len and b.lenses.items[i].line == line) return;
    const prev = for (old) |o| {
        if (o.line == line and !o.gone) break o;
    } else return;
    const text = try gpa.dupe(u8, prev.text);
    errdefer gpa.free(text);
    try b.lenses.insert(gpa, i, .{ .line = line, .text = text, .stale = true });
}

/// `$XDG_CACHE_HOME/zile/lsp/<server>.log`: the server's error output from
/// its last start (none in tests). Caller frees.
pub fn logPath(gpa: Allocator, index: usize) ?[]u8 {
    if (@import("builtin").is_test) return null;
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "lsp/{s}.log", .{servers[index].name}) catch return null;
    return config.dir(gpa, .cache, name);
}

pub fn deinit(l: *Lsp) void {
    const gpa = l.gpa;
    l.client.deinit();
    l.triggers.deinit(gpa);
    l.sig_triggers.deinit(gpa);
    l.sig_retriggers.deinit(gpa);
    l.pending.deinit(gpa);
    var titles = l.progress_titles.valueIterator();
    while (titles.next()) |t| gpa.free(t.*);
    l.progress_titles.deinit(gpa);
    var docs = l.docs.valueIterator();
    while (docs.next()) |d| gpa.free(d.uri);
    l.docs.deinit(gpa);
    for (l.diagnostics.keys(), l.diagnostics.values()) |k, v| {
        gpa.free(k);
        freeDiagnostics(gpa, v);
    }
    l.diagnostics.deinit(gpa);
    for ([_]*std.StringArrayHashMapUnmanaged([]Diagnostic){ &l.raw_main, &l.raw_shadow }) |m| {
        for (m.keys(), m.values()) |k, v| {
            gpa.free(k);
            freeDiagnostics(gpa, v);
        }
        m.deinit(gpa);
    }
    gpa.destroy(l);
}

fn freeDiagnostics(gpa: Allocator, list: []Diagnostic) void {
    for (list) |d| gpa.free(d.message);
    gpa.free(list);
}

/// By line, the most severe first within a line: how every list of
/// diagnostics is kept.
pub fn sortDiagnostics(list: []Diagnostic) void {
    std.mem.sort(Diagnostic, list, {}, struct {
        fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
            return if (a.line != b.line) a.line < b.line else @intFromEnum(a.severity) < @intFromEnum(b.severity);
        }
    }.lessThan);
}

/// The diagnostics on `line` in a sorted list.
pub fn diagnosticsOnLine(list: []const Diagnostic, line: usize) []const Diagnostic {
    const Cmp = struct {
        fn order(l: usize, d: Diagnostic) std.math.Order {
            return std.math.order(l, d.line);
        }
    };
    const lo = std.sort.lowerBound(Diagnostic, list, line, Cmp.order);
    const hi = std.sort.upperBound(Diagnostic, list, line, Cmp.order);
    return list[lo..hi];
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
            const text = try serverText(l.gpa, b, doc);
            defer l.gpa.free(text);
            doc.version += 1;
            doc.synced = b.edit_version;
            try l.client.notify("textDocument/didChange", .{
                .textDocument = .{ .uri = doc.uri, .version = doc.version },
                .contentChanges = &[_]struct { text: []const u8 }{.{ .text = text }},
            });
            try l.syncShadow(b, doc);
        } else {
            const abs = try ed.absolutePath(b.path.?);
            defer l.gpa.free(abs);
            const uri = try Client.uriFromPath(l.gpa, abs);
            errdefer l.gpa.free(uri);
            var doc: Doc = .{ .uri = uri, .version = 1, .synced = b.edit_version };
            const text = try serverText(l.gpa, b, &doc);
            defer l.gpa.free(text);
            try l.docs.put(l.gpa, b, doc);
            try l.syncShadow(b, l.docs.getPtr(b).?);
            try l.client.notify("textDocument/didOpen", .{
                .textDocument = .{ .uri = uri, .languageId = l.languageId(b), .version = 1, .text = text },
            });
        }
    }
}

const shadow_prefix = "zile-real-";

/// The URI the real text is opened under: the same folder (so imports
/// resolve), the name prefixed.
fn shadowUri(gpa: Allocator, uri: []const u8) ![]u8 {
    const slash = (std.mem.lastIndexOfScalar(u8, uri, '/') orelse return error.OutOfMemory) + 1;
    return std.mem.concat(gpa, u8, &.{ uri[0..slash], shadow_prefix, uri[slash..] });
}

/// Keeps the shadow document in step: open while the file is missing a
/// bracket, closed once it isn't.
fn syncShadow(l: *Lsp, b: *Buffer, doc: *Doc) !void {
    if (doc.unclosed == null) {
        if (!doc.shadow) return;
        doc.shadow = false;
        const uri = try shadowUri(l.gpa, doc.uri);
        defer l.gpa.free(uri);
        try l.client.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
        return;
    }
    const uri = try shadowUri(l.gpa, doc.uri);
    defer l.gpa.free(uri);
    const text = try fullText(l.gpa, b);
    defer l.gpa.free(text);
    doc.shadow_version += 1;
    if (!doc.shadow) {
        doc.shadow = true;
        try l.client.notify("textDocument/didOpen", .{
            .textDocument = .{ .uri = uri, .languageId = l.languageId(b), .version = doc.shadow_version, .text = text },
        });
    } else {
        try l.client.notify("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = doc.shadow_version },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = text }},
        });
    }
}

/// What the server is sent: the document, closed at the end if it is
/// missing brackets (`doc` notes which one is left open).
fn serverText(gpa: Allocator, b: *const Buffer, doc: *Doc) ![]u8 {
    const body = b.text.slice(0, b.text.len());
    doc.real_lines = @intCast(b.text.lineOf(body.len) + 1);
    doc.unclosed = null;
    // Markup is prose as much as code: a `(` in a sentence is no mistake.
    if (b.syntax) |syn| if (std.mem.eql(u8, syn.lang.name, "html")) return fullText(gpa, b);
    const r = try balance.scan(gpa, body);
    defer gpa.free(r.closers);
    if (r.closers.len == 0) return fullText(gpa, b);
    const open = b.text.lineStart(b.text.lineOf(r.innermost));
    doc.unclosed = .{
        .line = @intCast(b.text.lineOf(r.innermost)),
        .col = @intCast(r.innermost - open),
        .closer = r.closers[0],
    };
    return std.mem.concat(gpa, u8, &.{ body, "\n", r.closers, "\n" });
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
    if (doc.value.shadow) if (shadowUri(l.gpa, doc.value.uri)) |su| {
        defer l.gpa.free(su);
        l.client.notify("textDocument/didClose", .{ .textDocument = .{ .uri = su } }) catch {};
    } else |_| {};
    // A completion for this buffer can no longer be applied.
    var stale: ?i64 = null;
    var it = l.pending.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .completion => |cp| if (cp.buffer == b) {
            stale = e.key_ptr.*;
        },
        .signature => |sb| if (sb == b) {
            stale = e.key_ptr.*;
        },
        .format => |f| if (f.buffer == b) {
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

/// Asks for the inlay hints of lines `first..last` of `b` (type and
/// parameter labels). The answer replaces the hints in that range.
pub fn requestInlayHints(l: *Lsp, ed: *Editor, b: *Buffer, first: usize, last: usize) !void {
    _ = ed;
    const doc = l.docs.get(b) orelse return;
    // Only once the server has the text these lines are of.
    if (doc.synced != b.edit_version) return;
    const id = try l.client.request("textDocument/inlayHint", .{
        .textDocument = .{ .uri = doc.uri },
        .range = .{ .start = .{ .line = first, .character = 0 }, .end = .{ .line = last + 1, .character = 0 } },
    });
    b.hint_pending = true;
    try l.pending.put(l.gpa, id, .{ .inlay_hints = .{ .buffer = b, .version = b.edit_version, .first = first, .last = last } });
}

/// The code lens of `b` (its text as the server has it).
pub fn requestCodeLens(l: *Lsp, b: *Buffer) !void {
    const doc = l.docs.get(b) orelse return;
    if (doc.synced != b.edit_version) return;
    const id = try l.client.request("textDocument/codeLens", .{ .textDocument = .{ .uri = doc.uri } });
    b.lens_pending = true;
    b.lens_version = b.edit_version;
    try l.pending.put(l.gpa, id, .{ .code_lens = .{ .buffer = b, .version = b.edit_version } });
}

/// The hints of an inlay-hint answer, as labels at byte offsets of `t`. A
/// label is a string or a list of parts (their texts joined); padding the
/// server asks for becomes a space. The caller owns the texts.
pub fn parseInlayHints(gpa: Allocator, t: *const Text, result: std.json.Value, out: *std.ArrayList(Buffer.Hint)) !void {
    if (result != .array) return;
    for (result.array.items) |item| {
        const from = field(item, "position") orelse continue;
        const line: usize = @intCast(@max(int(field(from, "line")) orelse continue, 0));
        if (line >= t.lineCount()) continue;
        const col: usize = @intCast(@max(int(field(from, "character")) orelse 0, 0));
        const pos = t.lineStart(line) + @min(col, t.lineLen(line));
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        const pad_left = if (field(item, "paddingLeft")) |p| p == .bool and p.bool else false;
        const pad_right = if (field(item, "paddingRight")) |p| p == .bool and p.bool else false;
        if (pad_left) try text.append(gpa, ' ');
        const label = field(item, "label") orelse continue;
        switch (label) {
            .string => |s| try text.appendSlice(gpa, s),
            .array => |parts| for (parts.items) |part| {
                try text.appendSlice(gpa, str(field(part, "value")) orelse "");
            },
            else => {},
        }
        // Nothing to show (padding alone doesn't count).
        if (text.items.len == @intFromBool(pad_left)) {
            text.deinit(gpa);
            continue;
        }
        if (pad_right) try text.append(gpa, ' ');
        // A hint is one line; whatever a label says, it doesn't break it.
        for (text.items) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
            c.* = ' ';
        };
        try out.append(gpa, .{ .pos = pos, .text = try text.toOwnedSlice(gpa) });
    }
}

/// Implementations of the symbol at the cursor; a server without them
/// gets asked for the definition instead.
pub fn requestImplementation(l: *Lsp, ed: *Editor) !void {
    if (!l.can_implement) {
        ed.setMessage(.info, "{s} has no implementations: going to the definition", .{l.server().name});
        return l.requestDefinition(ed);
    }
    const uri = l.docUri(ed) orelse return;
    const id = try l.client.request("textDocument/implementation", .{ .textDocument = .{ .uri = uri }, .position = position(ed) });
    try l.pending.put(l.gpa, id, .implementation);
}

/// Fixes and refactors for lines `first..last` (inclusive) of the buffer.
pub fn requestCodeActions(l: *Lsp, ed: *Editor, first: usize, last: usize) !void {
    const uri = l.docUri(ed) orelse return;
    try l.sync(ed);
    const t = ed.text();
    const Pos = struct { line: usize, character: usize };
    const Range = struct { start: Pos, end: Pos };
    // The diagnostics on those lines go along: fixes are offered for them.
    const Diag = struct { range: Range, severity: u8, message: []const u8 };
    var diags: std.ArrayList(Diag) = .empty;
    defer diags.deinit(l.gpa);
    for (ed.diagnostics(ed.buffer)) |d| {
        if (d.end_line < first or d.line > last) continue;
        try diags.append(l.gpa, .{
            .range = .{ .start = .{ .line = d.line, .character = d.col }, .end = .{ .line = d.end_line, .character = d.end_col } },
            .severity = @intFromEnum(d.severity),
            .message = d.message,
        });
    }
    const id = try l.client.request("textDocument/codeAction", .{
        .textDocument = .{ .uri = uri },
        .range = Range{ .start = .{ .line = first, .character = 0 }, .end = .{ .line = last, .character = t.lineLen(@min(last, t.lineCount() - 1)) } },
        .context = .{ .diagnostics = diags.items },
    });
    try l.pending.put(l.gpa, id, .code_actions);
}

/// Before saving `b`: the whole-file action of `kind` (`source.fixAll.eslint`,
/// `source.organizeImports`); the answer moves the editor's save on.
pub fn requestSourceAction(l: *Lsp, ed: *Editor, b: *Buffer, kind: []const u8) !void {
    const doc = l.docs.get(b) orelse return error.NotOpen;
    try l.sync(ed);
    const Pos = struct { line: usize, character: usize };
    const last = b.text.lineCount() - 1;
    const id = try l.client.request("textDocument/codeAction", .{
        .textDocument = .{ .uri = doc.uri },
        .range = .{ .start = Pos{ .line = 0, .character = 0 }, .end = Pos{ .line = last, .character = b.text.lineLen(last) } },
        .context = .{ .diagnostics = &[_]u8{}, .only = &[_][]const u8{kind} },
    });
    try l.pending.put(l.gpa, id, .save_action);
}

/// Carries out a code action (its JSON as the server sent it): applies its
/// edit, asking the server for it first if it came without one, then runs
/// its command.
pub fn applyCodeAction(l: *Lsp, ed: *Editor, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, l.gpa, json, .{});
    defer parsed.deinit();
    const action = parsed.value;
    const has_edit = field(action, "edit") != null;
    // A bare Command has its name where an action has a command object.
    const is_command = str(field(action, "command")) != null;
    if (!has_edit and !is_command and l.can_resolve_action) {
        const id = try l.client.request("codeAction/resolve", action);
        return l.pending.put(l.gpa, id, .code_action_resolve);
    }
    try l.finishCodeAction(ed, action);
}

fn finishCodeAction(l: *Lsp, ed: *Editor, action: std.json.Value) !void {
    if (field(action, "edit")) |edit| {
        var edits: std.ArrayList(TextEdit) = .empty;
        defer {
            for (edits.items) |e| {
                l.gpa.free(e.path);
                l.gpa.free(e.text);
            }
            edits.deinit(l.gpa);
        }
        try l.collectWorkspaceEdit(ed, edit, &edits);
        try ed.applyEdits(edits.items);
    }
    const command = if (str(field(action, "command")) != null) action else field(action, "command") orelse return;
    const name = str(field(command, "command")) orelse return;
    const id = try l.client.request("workspace/executeCommand", .{
        .command = name,
        .arguments = field(command, "arguments") orelse std.json.Value{ .array = .init(l.gpa) },
    });
    try l.pending.put(l.gpa, id, .execute_command);
}

/// Symbols matching `query` across the project (answered into the editor's
/// workspace-symbol list; only the latest request counts).
pub fn requestWorkspaceSymbols(l: *Lsp, query: []const u8) !void {
    const id = try l.client.request("workspace/symbol", .{ .query = query });
    l.ws_request = id;
    try l.pending.put(l.gpa, id, .workspace_symbols);
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

/// Asks for the current buffer's formatting (lines `range`, inclusive, if
/// given and supported). `then_save`: save once it's applied.
pub fn requestFormat(l: *Lsp, ed: *Editor, range: ?[2]usize, then_save: bool) !void {
    const doc = l.docs.get(ed.buffer) orelse return error.NotOpen;
    try l.sync(ed);
    const options = .{ .tabSize = ed.indentWidth(), .insertSpaces = !ed.usesTabs() };
    const id = if (range != null and l.can_format_range)
        try l.client.request("textDocument/rangeFormatting", .{
            .textDocument = .{ .uri = doc.uri },
            .range = .{ .start = .{ .line = range.?[0], .character = 0 }, .end = .{ .line = range.?[1] + 1, .character = 0 } },
            .options = options,
        })
    else
        try l.client.request("textDocument/formatting", .{ .textDocument = .{ .uri = doc.uri }, .options = options });
    try l.pending.put(l.gpa, id, .{ .format = .{ .buffer = ed.buffer, .then_save = then_save } });
}

/// Asks what call the cursor is in, and which argument.
pub fn requestSignature(l: *Lsp, ed: *Editor) !void {
    const doc = l.docs.get(ed.buffer) orelse return;
    try l.sync(ed);
    const id = try l.client.request("textDocument/signatureHelp", .{ .textDocument = .{ .uri = doc.uri }, .position = position(ed) });
    try l.pending.put(l.gpa, id, .{ .signature = ed.buffer });
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
        if (obj.get("id")) |id| return l.answerServerRequest(ed, id, method, obj.get("params"));
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) try l.onDiagnostics(ed, obj.get("params") orelse return);
        if (std.mem.eql(u8, method, "$/progress")) try l.onProgress(ed, obj.get("params") orelse return);
        if (std.mem.eql(u8, method, "window/showMessage")) {
            const params = obj.get("params") orelse return;
            const message = str(field(params, "message")) orelse return;
            // 1 = error, 2 = warning, 3 = info, 4 = log.
            const level = if (field(params, "type")) |t| (if (t == .integer) t.integer else 3) else 3;
            if (level <= 3) ed.notify(if (level == 1) .err else .info, "{s}: {s}", .{ l.server().name, std.mem.sliceTo(message, '\n') });
        }
        return;
    }
    const id = obj.get("id") orelse return;
    if (id != .integer) return;
    const req = (l.pending.fetchRemove(id.integer) orelse return).value;
    if (req == .workspace_symbols and id.integer != l.ws_request) return; // a newer query is out
    const result = obj.get("result") orelse .null;
    if (obj.get("error")) |e| {
        if (req == .completion) ed.completion_pending = false;
        // A save waiting on this goes on without it.
        if (req == .save_action or req == .save_action_resolve) {
            ed.saveChainNext();
            return;
        }
        // A failed hint request isn't repeated until the text changes.
        if (req == .inlay_hints) {
            req.inlay_hints.buffer.hint_pending = false;
            req.inlay_hints.buffer.hint_version = req.inlay_hints.version;
            return;
        }
        if (req != .completion) ed.setMessage(.err, "lsp: {s}", .{str(field(e, "message")) orelse "request failed"});
        // Formatting before a save failed: save anyway.
        if (req == .format and req.format.then_save) ed.saveBufferNow(req.format.buffer);
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
            const provides = struct {
                fn f(v: ?std.json.Value) bool {
                    const x = v orelse return false;
                    return switch (x) {
                        .bool => |b| b,
                        .null => false,
                        else => true,
                    };
                }
            }.f;
            l.can_format = provides(field(caps, "documentFormattingProvider"));
            l.can_implement = provides(field(caps, "implementationProvider"));
            l.can_inlay = provides(field(caps, "inlayHintProvider"));
            l.can_lens = field(caps, "codeLensProvider") != null;
            l.can_resolve_lens = provides(field(field(caps, "codeLensProvider"), "resolveProvider"));
            l.can_resolve_action = provides(field(field(caps, "codeActionProvider"), "resolveProvider"));
            l.can_format_range = provides(field(caps, "documentRangeFormattingProvider"));
            const sig = field(caps, "signatureHelpProvider");
            inline for (.{ .{ "triggerCharacters", &l.sig_triggers }, .{ "retriggerCharacters", &l.sig_retriggers } }) |f| {
                if (field(sig, f[0])) |tc| if (tc == .array) {
                    for (tc.array.items) |x| if (str(x)) |chars| if (chars.len > 0) try f[1].append(l.gpa, chars[0]);
                };
            }
            // `.{}` would serialize as `[]` (an empty tuple); the spec wants `{}`.
            try l.client.notifyNow("initialized", struct {}{});
            if (l.server().settings) |json| {
                var parsed = try std.json.parseFromSlice(std.json.Value, l.gpa, json, .{});
                defer parsed.deinit();
                try l.client.notifyNow("workspace/didChangeConfiguration", .{ .settings = parsed.value });
            }
            try l.client.markReady();
        },
        .definition, .references, .implementation => {
            var locs: std.ArrayList(Location) = .empty;
            defer {
                for (locs.items) |loc| l.gpa.free(loc.path);
                locs.deinit(l.gpa);
            }
            try l.collectLocations(ed, result, &locs);
            const what = switch (req) {
                .definition => "definition",
                .implementation => "implementations",
                else => "references",
            };
            try ed.showLocations(locs.items, what);
        },
        .inlay_hints => |ih| {
            var hints: std.ArrayList(Buffer.Hint) = .empty;
            defer {
                for (hints.items) |h| l.gpa.free(h.text);
                hints.deinit(l.gpa);
            }
            try parseInlayHints(l.gpa, &ih.buffer.text, result, &hints);
            try ed.takeInlayHints(ih.buffer, &hints, ih.first, ih.last, ih.version);
        },
        .code_actions => {
            ed.clearCodeActions();
            if (result == .array) for (result.array.items) |action| {
                const title = str(field(action, "title")) orelse continue;
                // Kept as the server wrote it, to hand back when picked.
                const json = try std.json.Stringify.valueAlloc(l.gpa, action, .{});
                errdefer l.gpa.free(json);
                try ed.addCodeAction(title, str(field(action, "kind")) orelse "", json);
            };
            try ed.showCodeActions();
        },
        .code_action_resolve => try l.finishCodeAction(ed, result),
        .save_action => {
            // The first action offered (there is one of each kind, if any).
            const action: ?std.json.Value = if (result == .array and result.array.items.len > 0) result.array.items[0] else null;
            if (action) |a| {
                if (field(a, "edit") == null and str(field(a, "command")) == null and l.can_resolve_action) {
                    const rid = try l.client.request("codeAction/resolve", a);
                    return l.pending.put(l.gpa, rid, .save_action_resolve);
                }
                l.finishCodeAction(ed, a) catch {};
            }
            ed.saveChainNext();
        },
        .code_lens => |cl| {
            cl.buffer.lens_pending = false;
            if (!ed.bufferAlive(cl.buffer) or cl.version != cl.buffer.edit_version) return;
            // The new set replaces the old, but a lens still to be resolved
            // keeps its old title meanwhile: rows don't vanish and come back
            // (everything below would jump) on every refresh.
            var old = cl.buffer.lenses;
            cl.buffer.lenses = .empty;
            defer {
                for (old.items) |o| l.gpa.free(o.text);
                old.deinit(l.gpa);
            }
            if (result != .array) return;
            for (result.array.items) |lens| {
                const line = int(field(field(field(lens, "range"), "start"), "line")) orelse continue;
                if (line < 0) continue;
                if (str(field(field(lens, "command"), "title"))) |title| {
                    try ed.addLens(cl.buffer, @intCast(line), title);
                } else if (l.can_resolve_lens) {
                    const rid = try l.client.request("codeLens/resolve", lens);
                    try l.pending.put(l.gpa, rid, .{ .code_lens_resolve = .{ .buffer = cl.buffer, .version = cl.version, .line = @intCast(line) } });
                    try keepOldLens(l.gpa, cl.buffer, old.items, @intCast(line));
                }
            }
            ed.wake_fn();
        },
        .code_lens_resolve => |cl| {
            if (!ed.bufferAlive(cl.buffer) or cl.version != cl.buffer.edit_version) return;
            const title = str(field(field(result, "command"), "title")) orelse return;
            try ed.addLens(cl.buffer, cl.line, title);
            ed.wake_fn();
        },
        .save_action_resolve => {
            l.finishCodeAction(ed, result) catch {};
            ed.saveChainNext();
        },
        .execute_command => {},
        .workspace_symbols => {
            ed.clearWorkspaceSymbols();
            if (result == .array) for (result.array.items) |sym| {
                const name = str(field(sym, "name")) orelse continue;
                const loc = field(sym, "location") orelse continue;
                const uri = str(field(loc, "uri")) orelse continue;
                const from = field(field(loc, "range"), "start");
                const abs = (try Client.pathFromUri(l.gpa, uri)) orelse continue;
                defer l.gpa.free(abs);
                const path = try ed.relativePath(abs);
                defer l.gpa.free(path);
                const kind: usize = @intCast(int(field(sym, "kind")) orelse 0);
                try ed.addWorkspaceSymbol(
                    name,
                    if (kind < symbol_kinds.len) symbol_kinds[kind] else "",
                    path,
                    @intCast(int(field(from, "line")) orelse 0),
                    @intCast(int(field(from, "character")) orelse 0),
                );
            };
            try ed.workspaceSymbolsArrived();
        },
        .hover => {
            const text = hoverText(result) orelse return ed.setMessage(.info, "no hover information", .{});
            try ed.showHover(text);
        },
        .completion => |cp| try ed.showCompletion(cp.buffer, cp.word_start, result),
        .signature => |b| try ed.showSignature(b, result),
        .format => |f| {
            var edits: std.ArrayList(TextEdit) = .empty;
            defer {
                for (edits.items) |e| {
                    l.gpa.free(e.path);
                    l.gpa.free(e.text);
                }
                edits.deinit(l.gpa);
            }
            if (l.docs.get(f.buffer)) |doc| try l.collectTextEdits(ed, doc.uri, result, &edits);
            try ed.applyFormatEdits(f.buffer, edits.items, f.then_save);
        },
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
fn answerServerRequest(l: *Lsp, ed: *Editor, id: std.json.Value, method: []const u8, params: ?std.json.Value) !void {
    // A command the server runs for a code action edits through us.
    if (std.mem.eql(u8, method, "workspace/applyEdit")) {
        var edits: std.ArrayList(TextEdit) = .empty;
        defer {
            for (edits.items) |e| {
                l.gpa.free(e.path);
                l.gpa.free(e.text);
            }
            edits.deinit(l.gpa);
        }
        if (field(params orelse .null, "edit")) |edit| try l.collectWorkspaceEdit(ed, edit, &edits);
        try ed.applyEdits(edits.items);
        return l.client.respond(id, .{ .applied = true });
    }
    if (std.mem.eql(u8, method, "workspace/codeLens/refresh")) {
        for (ed.buffers.items) |b| b.lens_version = std.math.maxInt(u64);
        ed.wake_fn();
        return l.client.respond(id, null);
    }
    // The server's picture changed (it finished indexing, say): ask again.
    if (std.mem.eql(u8, method, "workspace/inlayHint/refresh")) {
        for (ed.buffers.items) |b| b.hint_version = std.math.maxInt(u64);
        ed.wake_fn();
        return l.client.respond(id, null);
    }
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        const n = if (field(params orelse .null, "items")) |items| (if (items == .array) items.array.items.len else 0) else 0;
        if (std.mem.eql(u8, l.server().name, "eslint")) return l.respondEslintSettings(id, n);
        // A server with settings of ours: each section asked for.
        if (l.server().settings) |json| {
            var parsed = try std.json.parseFromSlice(std.json.Value, l.gpa, json, .{});
            defer parsed.deinit();
            var answers: std.ArrayList(std.json.Value) = .empty;
            defer answers.deinit(l.gpa);
            const items = field(params orelse .null, "items") orelse .null;
            if (items == .array) for (items.array.items) |item| {
                var v: std.json.Value = parsed.value;
                if (str(field(item, "section"))) |section| {
                    var parts = std.mem.splitScalar(u8, section, '.');
                    while (parts.next()) |part| v = field(v, part) orelse .null;
                }
                try answers.append(l.gpa, v);
            };
            return l.client.respond(id, answers.items);
        }
        const nulls: [32]?u8 = @splat(null);
        return l.client.respond(id, nulls[0..@min(n, nulls.len)]);
    }
    try l.client.respond(id, null);
}

/// The settings the eslint server asks for (as nvim-lspconfig gives them;
/// formatting is prettier's).
fn respondEslintSettings(l: *Lsp, id: std.json.Value, n: usize) !void {
    const uri = try Client.uriFromPath(l.gpa, l.root);
    defer l.gpa.free(uri);
    var flat = false;
    for ([_][]const u8{ "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts" }) |f| {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ l.root, f }) catch continue;
        std.Io.Dir.cwd().access(l.client.io, p, .{}) catch continue;
        flat = true;
    }
    const Settings = struct {
        validate: []const u8 = "on",
        useESLintClass: bool = false,
        experimental: struct { useFlatConfig: bool },
        codeActionOnSave: struct { enable: bool = false, mode: []const u8 = "all" } = .{},
        format: bool = false,
        quiet: bool = false,
        onIgnoredFiles: []const u8 = "off",
        rulesCustomizations: []const struct {} = &.{},
        run: []const u8 = "onType",
        problems: struct { shortenToSingleLine: bool = false } = .{},
        nodePath: []const u8 = "",
        workingDirectory: struct { mode: []const u8 = "location" } = .{},
        codeAction: struct {
            disableRuleComment: struct { enable: bool = true, location: []const u8 = "separateLine" } = .{},
            showDocumentation: struct { enable: bool = true } = .{},
        } = .{},
        workspaceFolder: struct { uri: []const u8, name: []const u8 },
    };
    const one: Settings = .{ .experimental = .{ .useFlatConfig = flat }, .workspaceFolder = .{ .uri = uri, .name = std.fs.path.basename(l.root) } };
    var all: [8]Settings = @splat(one);
    return l.client.respond(id, all[0..@min(@max(n, 1), all.len)]);
}

/// `$/progress`: work the server reports on (indexing, building) becomes a
/// notification that updates in place and goes when the work ends.
fn onProgress(l: *Lsp, ed: *Editor, params: std.json.Value) !void {
    const token = field(params, "token") orelse return;
    var h = std.hash.Wyhash.init(l.index + 1);
    switch (token) {
        .string => |s| h.update(s),
        .integer => |i| h.update(std.mem.asBytes(&i)),
        else => return,
    }
    const key = h.final() | 1;
    const value = field(params, "value") orelse return;
    const kind = str(field(value, "kind")) orelse return;
    const name = l.server().name;
    const message = str(field(value, "message")) orelse "";
    if (std.mem.eql(u8, kind, "begin")) {
        const title = try l.gpa.dupe(u8, str(field(value, "title")) orelse "working");
        if (try l.progress_titles.fetchPut(l.gpa, key, title)) |old| l.gpa.free(old.value);
    }
    const title: []const u8 = l.progress_titles.get(key) orelse "";
    if (std.mem.eql(u8, kind, "end")) {
        ed.progress(key, false, "{s}: {s} {s}", .{ name, title, if (message.len > 0) message else "done" });
        if (l.progress_titles.fetchRemove(key)) |old| l.gpa.free(old.value);
        return;
    }
    const percent: ?i64 = if (field(value, "percentage")) |p| switch (p) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    } else null;
    if (percent) |p| {
        ed.progress(key, true, "{s}: {s} {s} {d}%", .{ name, title, message, p });
    } else ed.progress(key, true, "{s}: {s} {s}", .{ name, title, message });
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
            .message = if (l.server().linter and str(field(d, "code")) != null)
                try std.fmt.allocPrint(l.gpa, "{s} ({s})", .{ str(field(d, "message")) orelse "", str(field(d, "code")).? })
            else
                try l.gpa.dupe(u8, str(field(d, "message")) orelse ""),
        });
    };
    // The shadow document's answer is about the real text.
    const base = std.fs.path.basename(path);
    const is_shadow = std.mem.startsWith(u8, base, shadow_prefix);
    const real_path = if (is_shadow) try std.fs.path.join(l.gpa, &.{ std.fs.path.dirname(path) orelse "", base[shadow_prefix.len..] }) else path;
    if (is_shadow) l.gpa.free(path);
    errdefer if (is_shadow) l.gpa.free(real_path);
    const map = if (is_shadow) &l.raw_shadow else &l.raw_main;
    const gop = try map.getOrPut(l.gpa, real_path);
    if (gop.found_existing) {
        l.gpa.free(real_path);
        freeDiagnostics(l.gpa, gop.value_ptr.*);
    }
    gop.value_ptr.* = try list.toOwnedSlice(l.gpa);
    try l.mergeDiagnostics(ed, gop.key_ptr.*);
}

/// Rebuilds what is shown for `path` from the server's answers. A file
/// missing a bracket is judged twice: closed (types and errors all the way
/// down) and as it really is (its syntax errors); both are shown, and our
/// own "unclosed" note stands in when the server has no syntax error to
/// give.
fn mergeDiagnostics(l: *Lsp, ed: *Editor, path: []const u8) !void {
    var list: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (list.items) |d| l.gpa.free(d.message);
        list.deinit(l.gpa);
    }
    var unclosed: @FieldType(Doc, "unclosed") = null;
    var real_lines: u32 = std.math.maxInt(u32);
    for (ed.buffers.items) |b| {
        const bp = b.path orelse continue;
        if (!std.mem.eql(u8, bp, path)) continue;
        if (l.docs.get(b)) |doc| {
            unclosed = doc.unclosed;
            if (doc.unclosed != null) real_lines = doc.real_lines;
        }
        break;
    }
    for (l.raw_main.get(path) orelse &.{}) |d| {
        if (d.line >= real_lines) continue; // on the lines we added
        try list.append(l.gpa, try cloneDiagnostic(l.gpa, d));
    }
    var shadow_error = false;
    if (unclosed != null) for (l.raw_shadow.get(path) orelse &.{}) |d| {
        if (d.severity == .err) shadow_error = true;
        const dup = for (list.items) |e| {
            if (e.line == d.line and e.col == d.col and std.mem.eql(u8, e.message, d.message)) break true;
        } else false;
        if (!dup) try list.append(l.gpa, try cloneDiagnostic(l.gpa, d));
    };
    if (unclosed) |open| if (!shadow_error) {
        const what = switch (open.closer) {
            '}' => "'{'",
            ')' => "'('",
            else => "'['",
        };
        try list.append(l.gpa, .{
            .line = open.line,
            .col = open.col,
            .end_line = open.line,
            .end_col = open.col + 1,
            .severity = .err,
            .message = try std.fmt.allocPrint(l.gpa, "unclosed {s}: missing '{c}'", .{ what, open.closer }),
        });
    };
    sortDiagnostics(list.items);
    const gop = try l.diagnostics.getOrPut(l.gpa, path);
    if (gop.found_existing) {
        freeDiagnostics(l.gpa, gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try l.gpa.dupe(u8, path);
    }
    gop.value_ptr.* = try list.toOwnedSlice(l.gpa);
}

fn cloneDiagnostic(gpa: Allocator, d: Diagnostic) !Diagnostic {
    var c = d;
    c.message = try gpa.dupe(u8, d.message);
    return c;
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
