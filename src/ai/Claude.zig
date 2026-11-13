//! Claude Code in zile: the `claude` CLI runs in a terminal panel and
//! connects back to the editor (the IDE protocol its VS Code / JetBrains
//! extensions use): a WebSocket on 127.0.0.1 announced by a lock file in
//! `~/.claude/ide/`, speaking MCP. Through it Claude sees the selection,
//! shows proposed edits as diffs in the editor (accepted or rejected here),
//! reads diagnostics, and gets `@` mentions sent from the editor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Editor = @import("../Editor.zig");
const Buffer = @import("../core/Buffer.zig");
const WsServer = @import("WsServer.zig");
const Terminal = @import("../terminal/Terminal.zig");
const file_ops = @import("../editor/file_ops.zig");
const project_ops = @import("../editor/project_ops.zig");
const claude_panel = @import("../editor/claude_panel.zig");

const Claude = @This();

/// A proposed edit waiting for accept / reject (`openDiff` blocks the CLI
/// until we answer).
pub const Diff = struct {
    conn: u32,
    /// The request id, as JSON (owned).
    id: []u8,
    tab_name: []u8,
    /// The file it changes (absolute, owned).
    path: []u8,
    /// The proposal shown in the editor (a buffer of the editor's).
    buffer: *Buffer,
};

gpa: Allocator,
io: Io,
server: *WsServer,
token: [32]u8,
lock_path: ?[]u8 = null,
/// The workspace folders last written to the lock file (their count).
lock_projects: usize = 0,
/// The panel's terminal running `claude` (owned; null until opened).
term: ?*Terminal = null,
diffs: std.ArrayList(Diff) = .empty,
/// A client finished the MCP handshake.
ready: bool = false,
/// `at_mentioned` notifications waiting for a client (JSON, owned).
queued: std.ArrayList([]u8) = .empty,
/// The last `selection_changed` sent (JSON, owned), to send only changes.
last_selection: std.ArrayList(u8) = .empty,

pub fn start(ed: *Editor) !*Claude {
    var raw: [16]u8 = undefined;
    ed.io.randomSecure(&raw) catch ed.io.random(&raw);
    var token: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{&raw}) catch unreachable;
    const server = try WsServer.start(ed.gpa, ed.io, ed.wake_fn, &token);
    errdefer server.destroy();
    const c = try ed.gpa.create(Claude);
    c.* = .{ .gpa = ed.gpa, .io = ed.io, .server = server, .token = token };
    c.writeLock(ed);
    return c;
}

pub fn destroy(c: *Claude) void {
    if (c.lock_path) |p| {
        Io.Dir.cwd().deleteFile(c.io, p) catch {};
        c.gpa.free(p);
    }
    if (c.term) |t| t.destroy();
    c.server.destroy();
    for (c.diffs.items) |d| c.freeDiff(d);
    c.diffs.deinit(c.gpa);
    for (c.queued.items) |q| c.gpa.free(q);
    c.queued.deinit(c.gpa);
    c.last_selection.deinit(c.gpa);
    c.gpa.destroy(c);
}

fn freeDiff(c: *Claude, d: Diff) void {
    c.gpa.free(d.id);
    c.gpa.free(d.tab_name);
    c.gpa.free(d.path);
}

pub fn port(c: *const Claude) u16 {
    return c.server.port;
}

// ---------------------------------------------------------------------------
// The lock file: how `claude` finds us.

fn lockDir(gpa: Allocator) ?[]u8 {
    if (std.c.getenv("CLAUDE_CONFIG_DIR")) |d| {
        const dir = std.mem.span(d);
        if (dir.len > 0) return std.fs.path.join(gpa, &.{ dir, "ide" }) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fs.path.join(gpa, &.{ home, ".claude", "ide" }) catch null;
}

/// (Re)writes `<port>.lock` with the projects open (the CLI connects when
/// its directory is in one of them; ours always, by port).
fn writeLock(c: *Claude, ed: *Editor) void {
    const dir = lockDir(c.gpa) orelse return;
    defer c.gpa.free(dir);
    Io.Dir.cwd().createDirPath(c.io, dir) catch return;
    if (c.gpa.dupeSentinel(u8, dir, 0)) |dz| {
        defer c.gpa.free(dz);
        _ = std.c.chmod(dz.ptr, 0o700);
    } else |_| {}
    var folders: std.ArrayList([]const u8) = .empty;
    defer folders.deinit(c.gpa);
    folders.append(c.gpa, ed.cwd) catch return;
    for (ed.projects.items) |p| if (!std.mem.eql(u8, p.root, ed.cwd)) folders.append(c.gpa, p.root) catch return;
    const json = std.json.Stringify.valueAlloc(c.gpa, .{
        .pid = std.c.getpid(),
        .workspaceFolders = folders.items,
        .ideName = "zile",
        .transport = "ws",
        .authToken = @as([]const u8, &c.token),
        .runningInWindows = false,
    }, .{}) catch return;
    defer c.gpa.free(json);
    const path = std.fmt.allocPrint(c.gpa, "{s}/{d}.lock", .{ dir, c.port() }) catch return;
    const tmp = std.fmt.allocPrint(c.gpa, "{s}.tmp", .{path}) catch {
        c.gpa.free(path);
        return;
    };
    defer c.gpa.free(tmp);
    // Written whole, then renamed in (readers never see half a file).
    const file = Io.Dir.cwd().createFile(c.io, tmp, .{ .permissions = .fromMode(0o600) }) catch {
        c.gpa.free(path);
        return;
    };
    file.writeStreamingAll(c.io, json) catch {};
    file.close(c.io);
    Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), path, c.io) catch {};
    if (c.lock_path) |old| c.gpa.free(old);
    c.lock_path = path;
    c.lock_projects = ed.projects.items.len;
}

/// The environment `claude` needs to connect to this editor.
pub fn env(c: *const Claude, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "CLAUDE_CODE_SSE_PORT={d}", .{c.port()}) catch "";
}

// ---------------------------------------------------------------------------
// Messages

/// Per frame: answer the CLI, notice lost connections, share the selection.
pub fn tick(c: *Claude, ed: *Editor) void {
    if (ed.projects.items.len != c.lock_projects) c.writeLock(ed);
    while (c.server.poll()) |m| {
        defer c.gpa.free(m.text);
        c.handle(ed, m.conn, m.text) catch |err| ed.setMessage(.err, "claude: {s}", .{@errorName(err)});
    }
    while (c.server.pollClosed()) |conn| c.connectionClosed(ed, conn);
    c.shareSelection(ed);
}

fn handle(c: *Claude, ed: *Editor, conn: u32, text: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, c.gpa, text, .{}) catch return;
    defer parsed.deinit();
    const msg = parsed.value;
    if (msg != .object) return;
    const method = str(field(msg, "method")) orelse return; // replies to us: none expected
    const id = field(msg, "id") orelse return; // a notification (ide_connected, initialized)
    const id_json = try std.json.Stringify.valueAlloc(c.gpa, id, .{});
    defer c.gpa.free(id_json);
    const params = field(msg, "params") orelse .null;

    if (std.mem.eql(u8, method, "initialize")) {
        const supported = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };
        const asked = str(field(params, "protocolVersion")) orelse "2024-11-05";
        const version = for (supported) |v| {
            if (std.mem.eql(u8, v, asked)) break v;
        } else "2024-11-05";
        const result = try std.fmt.allocPrint(c.gpa,
            \\{{"protocolVersion":"{s}","capabilities":{{"logging":{{}},"prompts":{{"listChanged":true}},"tools":{{"listChanged":true}}}},"serverInfo":{{"name":"zile","version":"0.1.0"}}}}
        , .{version});
        defer c.gpa.free(result);
        c.reply(conn, id_json, result);
        c.ready = true;
        c.flushMentions();
        ed.setMessage(.info, "Claude Code connected", .{});
    } else if (std.mem.eql(u8, method, "tools/list")) {
        c.reply(conn, id_json, tools_json);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        c.reply(conn, id_json, "{\"prompts\":[]}");
    } else if (std.mem.eql(u8, method, "resources/list")) {
        c.reply(conn, id_json, "{\"resources\":[]}");
    } else if (std.mem.eql(u8, method, "ping")) {
        c.reply(conn, id_json, "{}");
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const name = str(field(params, "name")) orelse return c.replyError(conn, id_json, -32602, "missing tool name");
        try c.callTool(ed, conn, id_json, name, field(params, "arguments") orelse .null);
    } else {
        c.replyError(conn, id_json, -32601, "Method not found");
    }
}

fn reply(c: *Claude, conn: u32, id_json: []const u8, result: []const u8) void {
    const msg = std.mem.concat(c.gpa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":", id_json, ",\"result\":", result, "}" }) catch return;
    defer c.gpa.free(msg);
    c.server.send(conn, msg);
}

fn replyError(c: *Claude, conn: u32, id_json: []const u8, code: i32, message: []const u8) void {
    const err = std.json.Stringify.valueAlloc(c.gpa, .{ .code = code, .message = message }, .{}) catch return;
    defer c.gpa.free(err);
    const msg = std.mem.concat(c.gpa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"id\":", id_json, ",\"error\":", err, "}" }) catch return;
    defer c.gpa.free(msg);
    c.server.send(conn, msg);
}

/// A tool result: text blocks.
fn replyTexts(c: *Claude, conn: u32, id_json: []const u8, texts: []const []const u8) void {
    var content: std.ArrayList(struct { type: []const u8, text: []const u8 }) = .empty;
    defer content.deinit(c.gpa);
    for (texts) |t| content.append(c.gpa, .{ .type = "text", .text = t }) catch return;
    const result = std.json.Stringify.valueAlloc(c.gpa, .{ .content = content.items }, .{}) catch return;
    defer c.gpa.free(result);
    c.reply(conn, id_json, result);
}

/// A tool result: one text block holding `value` as JSON.
fn replyJson(c: *Claude, conn: u32, id_json: []const u8, value: anytype) void {
    const text = std.json.Stringify.valueAlloc(c.gpa, value, .{}) catch return;
    defer c.gpa.free(text);
    c.replyTexts(conn, id_json, &.{text});
}

fn notify(c: *Claude, method: []const u8, params_json: []const u8) void {
    const msg = std.mem.concat(c.gpa, u8, &.{ "{\"jsonrpc\":\"2.0\",\"method\":\"", method, "\",\"params\":", params_json, "}" }) catch return;
    defer c.gpa.free(msg);
    c.server.send(0, msg);
}

const tools_json =
    \\{"tools":[
    \\{"name":"openDiff","description":"Show a proposed change to a file as a diff in the editor; blocks until the user accepts (FILE_SAVED + the final text) or rejects (DIFF_REJECTED).","inputSchema":{"type":"object","properties":{"old_file_path":{"type":"string"},"new_file_path":{"type":"string"},"new_file_contents":{"type":"string"},"tab_name":{"type":"string"}},"required":["old_file_path","new_file_path","new_file_contents","tab_name"],"additionalProperties":false}},
    \\{"name":"closeAllDiffTabs","description":"Close every diff shown in the editor.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"openFile","description":"Open a file in the editor, optionally selecting text in it.","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"},"preview":{"type":"boolean"},"startText":{"type":"string"},"endText":{"type":"string"},"selectToEndOfLine":{"type":"boolean"},"makeFrontmost":{"type":"boolean"}},"required":["filePath"]}},
    \\{"name":"getDiagnostics","description":"Language server diagnostics (errors, warnings) for a file, or for all open files.","inputSchema":{"type":"object","properties":{"uri":{"type":"string"}}}},
    \\{"name":"getCurrentSelection","description":"The current selection in the editor.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"getLatestSelection","description":"The most recent selection in the editor.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"getOpenEditors","description":"The files open in the editor.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"getWorkspaceFolders","description":"The project folders open in the editor.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"checkDocumentDirty","description":"Whether a file has unsaved changes in the editor.","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"}},"required":["filePath"]}},
    \\{"name":"saveDocument","description":"Save a file open in the editor.","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"}},"required":["filePath"]}}
    \\]}
;

fn callTool(c: *Claude, ed: *Editor, conn: u32, id_json: []const u8, name: []const u8, args: std.json.Value) !void {
    if (std.mem.eql(u8, name, "openDiff")) {
        const path = str(field(args, "new_file_path")) orelse str(field(args, "old_file_path")) orelse
            return c.replyError(conn, id_json, -32602, "missing file path");
        const contents = str(field(args, "new_file_contents")) orelse return c.replyError(conn, id_json, -32602, "missing contents");
        const tab = str(field(args, "tab_name")) orelse path;
        // A new proposal under the same tab name replaces the old one.
        c.closeDiffByTab(ed, tab, true);
        const buffer = try claude_panel.openProposal(ed, path, contents);
        try c.diffs.append(c.gpa, .{
            .conn = conn,
            .id = try c.gpa.dupe(u8, id_json),
            .tab_name = try c.gpa.dupe(u8, tab),
            .path = try c.gpa.dupe(u8, path),
            .buffer = buffer,
        });
        // No reply yet: Claude waits for accept / reject.
    } else if (std.mem.eql(u8, name, "close_tab")) {
        if (str(field(args, "tab_name"))) |tab| c.closeDiffByTab(ed, tab, true);
        claude_panel.checkDiskChanges(ed);
        c.replyTexts(conn, id_json, &.{"TAB_CLOSED"});
    } else if (std.mem.eql(u8, name, "closeAllDiffTabs")) {
        const n = c.diffs.items.len;
        while (c.diffs.items.len > 0) c.closeDiff(ed, c.diffs.items.len - 1, true);
        claude_panel.checkDiskChanges(ed);
        var buf: [48]u8 = undefined;
        c.replyTexts(conn, id_json, &.{std.fmt.bufPrint(&buf, "CLOSED_{d}_DIFF_TABS", .{n}) catch "CLOSED_DIFF_TABS"});
    } else if (std.mem.eql(u8, name, "openFile")) {
        const path = str(field(args, "filePath")) orelse return c.replyError(conn, id_json, -32602, "missing filePath");
        try claude_panel.openFromClaude(ed, path, str(field(args, "startText")));
        var buf: [1024]u8 = undefined;
        c.replyTexts(conn, id_json, &.{std.fmt.bufPrint(&buf, "Opened file: {s}", .{path}) catch "Opened file"});
    } else if (std.mem.eql(u8, name, "getDiagnostics")) {
        const json = try claude_panel.diagnosticsJson(ed, c.gpa, str(field(args, "uri")));
        defer c.gpa.free(json);
        c.replyTexts(conn, id_json, &.{json});
    } else if (std.mem.eql(u8, name, "getCurrentSelection") or std.mem.eql(u8, name, "getLatestSelection")) {
        const sel = c.last_selection.items;
        c.replyTexts(conn, id_json, &.{if (sel.len > 0) sel else "{\"success\":false,\"message\":\"No active editor\"}"});
    } else if (std.mem.eql(u8, name, "getOpenEditors")) {
        const json = try claude_panel.openEditorsJson(ed, c.gpa);
        defer c.gpa.free(json);
        c.replyTexts(conn, id_json, &.{json});
    } else if (std.mem.eql(u8, name, "getWorkspaceFolders")) {
        var folders: std.ArrayList(struct { name: []const u8, path: []const u8 }) = .empty;
        defer folders.deinit(c.gpa);
        for (ed.projects.items) |p| try folders.append(c.gpa, .{ .name = p.name(), .path = p.root });
        c.replyJson(conn, id_json, .{ .success = true, .folders = folders.items, .rootPath = project_ops.projectRoot(ed) });
    } else if (std.mem.eql(u8, name, "checkDocumentDirty")) {
        const path = str(field(args, "filePath")) orelse return c.replyError(conn, id_json, -32602, "missing filePath");
        const b = claude_panel.bufferForPath(ed, path);
        c.replyJson(conn, id_json, .{ .success = b != null, .filePath = path, .isDirty = if (b) |x| x.modified else false, .isUntitled = false });
    } else if (std.mem.eql(u8, name, "saveDocument")) {
        const path = str(field(args, "filePath")) orelse return c.replyError(conn, id_json, -32602, "missing filePath");
        const b = claude_panel.bufferForPath(ed, path) orelse return c.replyJson(conn, id_json, .{ .success = false, .message = "not open" });
        file_ops.saveBufferNow(ed, b);
        c.replyJson(conn, id_json, .{ .success = true, .filePath = path, .saved = true });
    } else {
        var buf: [128]u8 = undefined;
        c.replyError(conn, id_json, -32601, std.fmt.bufPrint(&buf, "Tool not found: {s}", .{name}) catch "Tool not found");
    }
}

// ---------------------------------------------------------------------------
// Diffs

/// The proposal shown in `b`, if it is one.
pub fn diffFor(c: *Claude, b: *const Buffer) ?usize {
    for (c.diffs.items, 0..) |d, i| if (d.buffer == b) return i;
    return null;
}

/// The user accepted (`SPC a y`) or rejected (`SPC a n`) proposal `i`.
/// Accepting answers with the proposal as it now reads (it may have been
/// edited); Claude writes the file, and the editor reloads it.
pub fn resolve(c: *Claude, ed: *Editor, i: usize, accept: bool) void {
    const d = c.diffs.items[i];
    if (accept) {
        const t = &d.buffer.text;
        const text = std.mem.concat(c.gpa, u8, &.{ t.slice(0, t.len()), if (d.buffer.final_newline and t.len() > 0) "\n" else "" }) catch return;
        defer c.gpa.free(text);
        c.replyTexts(d.conn, d.id, &.{ "FILE_SAVED", text });
    } else {
        c.replyTexts(d.conn, d.id, &.{"DIFF_REJECTED"});
    }
    c.closeDiff(ed, i, false);
    ed.setMessage(.info, "{s} Claude's change to {s}", .{ if (accept) "accepted" else "rejected", std.fs.path.basename(d.path) });
}

/// Removes proposal `i`; if still unanswered and `reject`, answers it
/// rejected (so Claude doesn't wait forever).
fn closeDiff(c: *Claude, ed: *Editor, i: usize, reject_pending: bool) void {
    const d = c.diffs.orderedRemove(i);
    if (reject_pending) c.replyTexts(d.conn, d.id, &.{"DIFF_REJECTED"});
    claude_panel.closeProposal(ed, d.buffer, d.path);
    c.freeDiff(d);
}

fn closeDiffByTab(c: *Claude, ed: *Editor, tab: []const u8, reject_pending: bool) void {
    var i = c.diffs.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, c.diffs.items[i].tab_name, tab)) c.closeDiff(ed, i, reject_pending);
    }
}

fn connectionClosed(c: *Claude, ed: *Editor, conn: u32) void {
    var i = c.diffs.items.len;
    while (i > 0) {
        i -= 1;
        if (c.diffs.items[i].conn == conn) c.closeDiff(ed, i, false);
    }
    if (c.server.connected() == 0) c.ready = false;
}

// ---------------------------------------------------------------------------
// Selection and mentions

/// Sends `selection_changed` when the file, selection or cursor changed.
fn shareSelection(c: *Claude, ed: *Editor) void {
    if (!c.ready) return;
    const json = claude_panel.selectionJson(ed, c.gpa) orelse return;
    defer c.gpa.free(json);
    if (std.mem.eql(u8, json, c.last_selection.items)) return;
    c.last_selection.clearRetainingCapacity();
    c.last_selection.appendSlice(c.gpa, json) catch return;
    c.notify("selection_changed", json);
}

/// `@path#Lstart-end` in Claude's prompt (lines 0-based, inclusive; null
/// for the whole file). Sent once a client is connected.
pub fn mention(c: *Claude, path: []const u8, lines: ?[2]usize) void {
    const json = if (lines) |l|
        std.json.Stringify.valueAlloc(c.gpa, .{ .filePath = path, .lineStart = l[0], .lineEnd = l[1] }, .{}) catch return
    else
        std.json.Stringify.valueAlloc(c.gpa, .{ .filePath = path }, .{}) catch return;
    if (!c.ready) {
        c.queued.append(c.gpa, json) catch c.gpa.free(json);
        return;
    }
    defer c.gpa.free(json);
    c.notify("at_mentioned", json);
}

fn flushMentions(c: *Claude) void {
    for (c.queued.items) |q| {
        c.notify("at_mentioned", q);
        c.gpa.free(q);
    }
    c.queued.clearRetainingCapacity();
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}
