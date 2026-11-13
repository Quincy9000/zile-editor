//! The language server's side of the editor: starting servers, sync, diagnostics, hover, completion.

const std = @import("std");
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const Lsp = @import("../lsp/Lsp.zig");
const syntax_objects = @import("../syntax/objects.zig");
const sql = @import("../sql.zig");
const formatting = @import("formatting.zig");
const notifications = @import("notifications.zig");
const Editor = @import("../Editor.zig");

/// A server that wouldn't start. Not installed: said when something needs it
/// (`gd`, `K`, rename...), not on opening a file. Anything else: said now.
pub fn serverStartFailed(ed: *Editor, i: usize, err: anyerror) void {
    ed.lsp_failed[i] = true;
    if (err == error.FileNotFound) {
        ed.lsp_missing[i] = true;
        return;
    }
    notifications.notify(ed, .err, "could not start {s}: {s}", .{ Lsp.servers[i].name, @errorName(err) });
}

pub fn tickLsp(ed: *Editor) void {
    // Start each language's server for each project, the first time one of
    // its files is open there.
    for (ed.buffers.items) |b| {
        const i = Lsp.serverFor(b) orelse continue;
        if (ed.lsp_failed[i] or lspFor(ed, b) != null) continue;
        // A Postgres server: once the file's database is known to be one.
        var database_url: ?[]const u8 = null;
        if (Lsp.servers[i].postgres) {
            if (b != ed.buffer) continue;
            const sc = ed.sql_schema orelse continue;
            const client = sql.clientFor(sc.url) orelse continue;
            if (client.client != .psql) continue;
            database_url = sc.url;
        }
        const l = Lsp.start(ed, i, Lsp.bufferRoot(b, ed.cwd), database_url) catch |err| {
            serverStartFailed(ed, i, err);
            continue;
        };
        ed.lsps.append(ed.gpa, l) catch l.deinit();
    }
    // Linters (eslint) beside them, in projects set up for them.
    for (ed.buffers.items) |b| for (Lsp.servers, 0..) |srv, i| {
        if (!srv.linter or ed.lsp_failed[i] or !Lsp.serves(i, b)) continue;
        const root = Lsp.bufferRoot(b, ed.cwd);
        const running = for (ed.lsps.items) |l| {
            if (l.index == i and l.wants(b)) break true;
        } else false;
        if (running or linterAbsent(ed, i, root)) continue;
        const l = Lsp.start(ed, i, root, null) catch |err| {
            serverStartFailed(ed, i, err);
            continue;
        };
        ed.lsps.append(ed.gpa, l) catch l.deinit();
    };
    var k = ed.lsps.items.len;
    while (k > 0) {
        k -= 1;
        const l = ed.lsps.items[k];
        l.sync(ed) catch {};
        if (!l.poll(ed)) {
            const i = l.index;
            l.deinit();
            _ = ed.lsps.orderedRemove(k);
            serverExited(ed, i);
        }
    }
}

/// A server's output ended: it crashed or quit. It's started again (the
/// next tick, with its files reopened), a few times; the notification says
/// why, from the last line of its log.
pub const max_lsp_restarts = 3;

pub fn serverExited(ed: *Editor, i: usize) void {
    const name = Lsp.servers[i].name;
    var why_buf: [200]u8 = undefined;
    const why = serverLogTail(ed, i, &why_buf);
    const sep: []const u8 = if (why.len > 0) ": " else "";
    if (ed.lsp_restarts[i] < max_lsp_restarts) {
        ed.lsp_restarts[i] += 1;
        notifications.notify(ed, .err, "{s} exited{s}{s} (restarting)", .{ name, sep, why });
        return;
    }
    ed.lsp_failed[i] = true;
    const log = Lsp.logPath(ed.gpa, i);
    defer if (log) |p| ed.gpa.free(p);
    notifications.notify(ed, .err, "{s} exited again{s}{s}; not restarting it (its log: {s})", .{ name, sep, why, log orelse "none" });
}

/// The last non-blank line of server `i`'s log, cut to fit `buf`.
pub fn serverLogTail(ed: *Editor, i: usize, buf: []u8) []const u8 {
    const path = Lsp.logPath(ed.gpa, i) orelse return "";
    defer ed.gpa.free(path);
    const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(1 << 20)) catch return "";
    defer ed.gpa.free(data);
    var it = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (l.len == 0) continue;
        const n = @min(l.len, buf.len);
        @memcpy(buf[0..n], l[0..n]);
        return buf[0..n];
    }
    return "";
}

/// Whether linter `index` has no config in project `root` (checked once
/// per project: it isn't started there).
pub fn linterAbsent(ed: *Editor, index: usize, root: []const u8) bool {
    var key_buf: [Io.Dir.max_path_bytes + 8]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ index, root }) catch return true;
    if (ed.linter_checked.get(key)) |absent| return absent;
    const absent = for (Lsp.servers[index].markers) |m| {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, m }) catch continue;
        if (formatting.fileExists(ed, p)) break false;
    } else true;
    const owned = ed.gpa.dupe(u8, key) catch return absent;
    ed.linter_checked.put(ed.gpa, owned, absent) catch ed.gpa.free(owned);
    return absent;
}

/// The running main server for `b` (its language, in its project), if any.
pub fn lspFor(ed: *const Editor, b: *const Buffer) ?*Lsp {
    _ = Lsp.serverFor(b) orelse return null;
    for (ed.lsps.items) |l| if (!l.server().linter and l.wants(b)) return l;
    return null;
}

/// The current buffer's server, or a message saying why there is none.
pub fn languageServer(ed: *Editor) ?*Lsp {
    const i = Lsp.serverFor(ed.buffer) orelse {
        ed.setMessage(.err, "no language server for this file", .{});
        return null;
    };
    if (lspFor(ed, ed.buffer)) |l| return l;
    const name = Lsp.servers[i].name;
    if (ed.lsp_missing[i]) {
        ed.setMessage(.err, "{s} isn't installed", .{name});
    } else if (ed.lsp_failed[i]) ed.setMessage(.err, "{s} is not running", .{name}) else ed.setMessage(.info, "{s} is starting...", .{name});
    return null;
}

/// At most this many lists of diagnostics per buffer: the compile check's
/// and each server's.
pub const max_diagnostic_lists = 5;

/// The lists of diagnostics about `b` (each sorted by line, the most severe
/// first within a line): the compile check's, its main server's and its
/// linters'.
pub fn diagnosticLists(ed: *const Editor, b: *const Buffer, buf: *[max_diagnostic_lists][]const Lsp.Diagnostic) [][]const Lsp.Diagnostic {
    var n: usize = 0;
    for (ed.check_results.items) |r| if (r.buffer == b and r.diags.len > 0 and n < buf.len) {
        buf[n] = r.diags;
        n += 1;
    };
    const path = b.path orelse return buf[0..n];
    for (ed.lsps.items) |l| if (l.wants(b) and n < buf.len) {
        const d = l.diagnosticsFor(path);
        if (d.len == 0) continue;
        buf[n] = d;
        n += 1;
    };
    return buf[0..n];
}

/// Everything said about `b` in one list, by line. The slice is good until
/// the next call.
pub fn diagnostics(ed: *const Editor, b: *const Buffer) []const Lsp.Diagnostic {
    var buf: [max_diagnostic_lists][]const Lsp.Diagnostic = undefined;
    const lists = diagnosticLists(ed, b, &buf);
    if (lists.len == 0) return &.{};
    if (lists.len == 1) return lists[0];
    const self = @constCast(ed);
    self.merged_diagnostics.clearRetainingCapacity();
    for (lists) |d| self.merged_diagnostics.appendSlice(ed.gpa, d) catch return lists[0];
    Lsp.sortDiagnostics(self.merged_diagnostics.items);
    return self.merged_diagnostics.items;
}

/// Tells every running server that `b` is going away.
pub fn lspCloseBuffer(ed: *Editor, b: *Buffer) void {
    for (ed.lsps.items) |l| l.closeBuffer(b);
}

pub fn clearLocations(ed: *Editor) void {
    for (ed.locations.items) |loc| ed.gpa.free(loc.path);
    ed.locations.clearRetainingCapacity();
}

/// Jumps straight to a single location, or lists several in the picker.
pub fn showLocations(ed: *Editor, locs: []const Lsp.Location, what: []const u8) !void {
    if (locs.len == 0) return ed.setMessage(.info, "no {s} found", .{what});
    if (locs.len == 1) return ed.jumpTo(locs[0].path, locs[0].line, locs[0].col);
    clearLocations(ed);
    for (locs) |loc| {
        try ed.locations.append(ed.gpa, .{ .path = try ed.gpa.dupe(u8, loc.path), .line = loc.line, .col = loc.col });
    }
    try ed.openPicker(.locations, "");
}

pub fn clearSymbols(ed: *Editor) void {
    for (ed.symbols.items) |s| ed.gpa.free(s.name);
    ed.symbols.clearRetainingCapacity();
}

/// `SPC f s`: the current file's symbols, from the language server when it
/// handles this file, else from the syntax tree.
pub fn showSymbols(ed: *Editor) !void {
    if (lspFor(ed, ed.buffer)) |l| return l.requestSymbols(ed);
    const s = &(ed.buffer.syntax orelse return ed.setMessage(.err, "no symbols: unknown language", .{}));
    clearSymbols(ed);
    try syntax_objects.outline(ed.gpa, s, ed.text(), &ed.symbols);
    try openSymbols(ed);
}

/// Opens the picker on `symbols` (takes ownership of the list contents).
pub fn setSymbols(ed: *Editor, list: []const syntax_objects.Symbol) !void {
    clearSymbols(ed);
    try ed.symbols.appendSlice(ed.gpa, list);
    try openSymbols(ed);
}

pub fn openSymbols(ed: *Editor) !void {
    if (ed.symbols.items.len == 0) return ed.setMessage(.info, "no symbols in this file", .{});
    try ed.openPicker(.symbols, "");
}
