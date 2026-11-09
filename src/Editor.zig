//! All editor state, owned by the main thread. No rendering or platform code:
//! the UI reads this state, and the platform layer feeds `handleKey`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Buffer = @import("core/Buffer.zig");
const Text = @import("core/Text.zig");
const motions = @import("core/motions.zig");
const keys = @import("input/keys.zig");
const KeyEvent = keys.KeyEvent;
const km = @import("input/keymap.zig");
const commands = @import("commands.zig");
const Picker = @import("picker/Picker.zig");
const Registers = @import("Registers.zig");
const LineInput = @import("input/LineInput.zig");
const search = @import("core/search.zig");
const Folds = @import("core/Folds.zig");
const Lsp = @import("lsp/Lsp.zig");
const Completion = @import("lsp/Completion.zig");
const syntax_objects = @import("syntax/objects.zig");
const operators = @import("operators.zig");

const Editor = @This();

pub const Mode = km.Mode;

pub const Options = struct {
    tab_width: usize = 4,
    /// Insert spaces for <Tab> in insert mode.
    expand_tab: bool = true,
    /// Lines kept visible above/below the cursor.
    scrolloff: usize = 4,
};

pub const View = struct {
    /// Byte offset into the buffer; always on a codepoint boundary.
    cursor: usize = 0,
    /// Sticky display column for vertical motion; null means "use the cursor's".
    want_col: ?usize = null,
    /// First visible line.
    top: usize = 0,
    /// First visible display column.
    left: usize = 0,
    /// Visible text area in cells (set by the UI each frame).
    rows: usize = 24,
    cols: usize = 80,
    /// The other end of the visual selection.
    anchor: usize = 0,
};

/// An operator waiting for its motion (`d` in `dw`).
pub const PendingOp = struct {
    op: operators.Operator,
    count: usize,
    has_count: bool,
    register: ?u8,
};

pub const SearchPrompt = struct {
    input: LineInput = .{},
    forward: bool,
    /// Where the cursor and view were, restored on <Esc>.
    origin: usize,
    origin_top: usize,
    return_mode: Mode,
    had_highlight: bool,
    kind: PromptKind = .search,
};

pub const PromptKind = enum {
    /// `/` `?`: incremental search.
    search,
    /// `s`: jump as soon as only one match is left on screen.
    snipe,
    /// `SPC c .`: the new name for the symbol at `origin`.
    rename,
};

/// A command waiting for a character argument (`f` in `fx`, `r`, `q`, `@`).
const AwaitingChar = struct {
    cmd: *const commands.Command,
    count: usize,
    has_count: bool,
    register: ?u8,
};

pub const Message = struct {
    pub const Kind = enum { info, err };
    kind: Kind = .info,
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(m: *const Message) []const u8 {
        return m.buf[0..m.len];
    }
};

gpa: Allocator,
io: Io,
/// Absolute working directory; buffer paths inside it are stored relative.
cwd: [:0]u8,
options: Options = .{},
/// All open buffers (owned). `buffer` is the one being shown.
buffers: std.ArrayList(*Buffer) = .empty,
buffer: *Buffer,
/// Bumped on every buffer switch, for most-recently-used ordering.
use_counter: u64 = 0,
view: View = .{},
mode: Mode = .normal,
keymap: km.Keymap,

picker: ?*Picker = null,
/// The last closed picker, for `resume_picker`.
resume_kind: ?Picker.Kind = null,
resume_query: std.ArrayList(u8) = .empty,
/// Wakes the UI loop from worker threads (glfw.wake in the app, no-op in tests).
wake_fn: *const fn () void = noWake,

pending: [km.max_sequence]KeyEvent = undefined,
pending_len: usize = 0,
/// Count typed before a command; 0 means none.
count: usize = 0,

registers: Registers,
/// Register chosen with a `"x` prefix for the next command.
register: ?u8 = null,
awaiting_register: bool = false,
awaiting_char: ?AwaitingChar = null,
op: ?PendingOp = null,
/// Visual mode selects whole lines (`V`).
visual_line: bool = false,
/// Last f/F/t/T, for `;` and `,`.
last_find: ?motions.Find = null,

// Dot repeat: the keys of the change in progress and of the last one.
capturing: bool = false,
capture_repeatable: bool = false,
capture_count: usize = 0,
change_keys: std.ArrayList(KeyEvent) = .empty,
last_change: std.ArrayList(KeyEvent) = .empty,
last_change_count: usize = 0,

// Macros.
macro_register: ?u8 = null,
macro_keys: std.ArrayList(KeyEvent) = .empty,
last_macro: ?u8 = null,
/// Keys to process before new input (macro playback, `.`).
queue: std.ArrayList(KeyEvent) = .empty,

/// The `/` or `?` prompt while it is open.
search_prompt: ?SearchPrompt = null,
last_search: std.ArrayList(u8) = .empty,
last_search_forward: bool = true,
last_search_whole_word: bool = false,
/// Highlight matches of the last search (cleared with <Esc>).
search_highlight: bool = false,

/// Running language servers, by index into `Lsp.servers`, started on demand.
lsps: [Lsp.servers.len]?*Lsp = @splat(null),
/// A server could not be started or exited; don't keep retrying it.
lsp_failed: [Lsp.servers.len]bool = @splat(false),
/// The outline shown by the symbols picker (`SPC c l`).
symbols: std.ArrayList(syntax_objects.Symbol) = .empty,
/// Results of the last definition/references request, for the picker.
locations: std.ArrayList(Lsp.Location) = .empty,
/// Hover text shown near the cursor until the next key.
hover: ?[]u8 = null,
completion: ?Completion = null,
/// Word start a completion was last requested for (avoids re-asking per key).
completion_asked: ?usize = null,

/// Keys of the command being typed, for the status line (vim's showcmd).
showcmd: [16]KeyEvent = undefined,
showcmd_len: usize = 0,

message: Message = .{},
should_quit: bool = false,

fn noWake() void {}

/// Starts with one empty scratch buffer; `openFile` replaces it while untouched.
pub fn init(gpa: Allocator, io: Io) !Editor {
    var keymap: km.Keymap = .init(gpa);
    errdefer keymap.deinit();
    try keymap.loadDefaults();

    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    errdefer gpa.free(cwd);

    const scratch = try gpa.create(Buffer);
    errdefer gpa.destroy(scratch);
    scratch.* = try Buffer.initEmpty(gpa);
    errdefer scratch.deinit(gpa);

    var buffers: std.ArrayList(*Buffer) = .empty;
    try buffers.append(gpa, scratch);
    return .{
        .gpa = gpa,
        .io = io,
        .cwd = cwd,
        .buffers = buffers,
        .buffer = scratch,
        .keymap = keymap,
        .registers = .init(gpa),
    };
}

pub fn deinit(ed: *Editor) void {
    if (ed.picker) |p| p.destroy();
    for (ed.lsps) |maybe| if (maybe) |l| l.deinit();
    ed.clearLocations();
    ed.locations.deinit(ed.gpa);
    ed.clearSymbols();
    ed.symbols.deinit(ed.gpa);
    if (ed.hover) |h| ed.gpa.free(h);
    ed.closeCompletion();
    for (ed.buffers.items) |b| {
        b.deinit(ed.gpa);
        ed.gpa.destroy(b);
    }
    ed.buffers.deinit(ed.gpa);
    ed.resume_query.deinit(ed.gpa);
    ed.registers.deinit();
    if (ed.search_prompt) |*sp| sp.input.deinit(ed.gpa);
    ed.last_search.deinit(ed.gpa);
    ed.change_keys.deinit(ed.gpa);
    ed.last_change.deinit(ed.gpa);
    ed.macro_keys.deinit(ed.gpa);
    ed.queue.deinit(ed.gpa);
    ed.gpa.free(ed.cwd);
    ed.keymap.deinit();
    ed.* = undefined;
}

/// Per-frame housekeeping: reparses and highlights the visible lines, and
/// picks up picker results from the worker.
pub fn tick(ed: *Editor) void {
    ed.tickLsp();
    if (ed.buffer.syntax) |*s| {
        const t = ed.text();
        s.update(t);
        const first = @min(ed.view.top, t.lineCount() - 1);
        // With closed folds the screen reaches past `top + rows` raw lines.
        const last_visible = ed.stepVisible(first, @intCast(ed.view.rows));
        const last = if (ed.foldAt(last_visible)) |f| f.last else last_visible;
        s.highlight(ed.gpa, t, t.lineStart(first), t.lineEnd(last)) catch {};
    }
    if (ed.picker) |p| {
        p.poll();
        p.updatePreview();
    }
}

/// Runs a command as if its key was pressed with no count (command picker).
pub fn runCommand(ed: *Editor, cmd: *const commands.Command) !void {
    if (cmd.takes_char) {
        ed.awaiting_char = .{ .cmd = cmd, .count = 1, .has_count = false, .register = null };
        return;
    }
    try cmd.run(.{ .ed = ed, .count = 1, .has_count = false });
}

pub fn text(ed: *Editor) *Text {
    return &ed.buffer.text;
}

// ---------------------------------------------------------------------------
// Input

pub fn handleKey(ed: *Editor, ev: KeyEvent) void {
    if (ed.macro_register != null) ed.macro_keys.append(ed.gpa, ev) catch {};
    ed.processKey(ev);
    // Macro playback and `.` queue keys; a runaway macro (one that calls
    // itself) is cut off.
    var budget: usize = 100_000;
    while (ed.queue.items.len > 0) : (budget -= 1) {
        if (budget == 0) {
            ed.queue.clearRetainingCapacity();
            ed.setMessage(.err, "macro stopped: too many keys (recursive macro?)", .{});
            break;
        }
        ed.processKey(ed.queue.orderedRemove(0));
    }
}

/// Feeds a key notation string, e.g. "ihello<Esc>". For tests and scripting.
pub fn feed(ed: *Editor, notation: []const u8) keys.ParseError!void {
    var i: usize = 0;
    while (i < notation.len) {
        const end = try notationKeyEnd(notation, i);
        var buf: [1]KeyEvent = undefined;
        const seq = try keys.parseSequence(notation[i..end], &buf);
        ed.handleKey(seq[0]);
        i = end;
    }
}

/// End of the single key notation starting at `i` ("x", "<C-w>", "é").
fn notationKeyEnd(notation: []const u8, i: usize) keys.ParseError!usize {
    if (notation[i] == '<') {
        if (std.mem.indexOfScalarPos(u8, notation, i, '>')) |close| return close + 1;
        return error.InvalidNotation;
    }
    const n = std.unicode.utf8ByteSequenceLength(notation[i]) catch return error.InvalidNotation;
    return @min(i + n, notation.len);
}

/// Queues key notation to run before new input (`count` times), ahead of
/// anything already queued so nested macros run in order.
fn queueNotation(ed: *Editor, notation: []const u8, count: usize) !void {
    var parsed: std.ArrayList(KeyEvent) = .empty;
    defer parsed.deinit(ed.gpa);
    for (0..count) |_| {
        var i: usize = 0;
        while (i < notation.len) {
            const end = try notationKeyEnd(notation, i);
            var buf: [1]KeyEvent = undefined;
            const seq = try keys.parseSequence(notation[i..end], &buf);
            try parsed.append(ed.gpa, seq[0]);
            i = end;
        }
    }
    try ed.queue.insertSlice(ed.gpa, 0, parsed.items);
}

fn processKey(ed: *Editor, ev: KeyEvent) void {
    // Hover text disappears on the next key.
    if (ed.hover) |h| {
        ed.gpa.free(h);
        ed.hover = null;
    }
    if (ed.mode != .insert and ed.mode != .picker and ed.mode != .search and ed.showcmd_len < ed.showcmd.len) {
        ed.showcmd[ed.showcmd_len] = ev;
        ed.showcmd_len += 1;
    }
    ed.handleKeyInner(ev) catch |err| {
        ed.setMessage(.err, "error: {s}", .{@errorName(err)});
        ed.resetCommand();
    };
    ed.afterKey();
    ed.clampToFolds();
    // Typing text (insert mode, a prompt) isn't a pending command.
    if (ed.mode == .insert or ed.mode == .search) ed.showcmd_len = 0;
    if (ed.completion != null) ed.refreshCompletion() catch ed.closeCompletion();
    if (ed.mode != .insert) ed.completion_asked = null;
    ed.scrollToCursor();
}

/// Nothing half-typed: no pending keys, count, register, operator or argument.
fn isIdle(ed: *const Editor) bool {
    return ed.mode != .insert and ed.mode != .operator and ed.mode != .search and ed.pending_len == 0 and ed.count == 0 and
        ed.register == null and !ed.awaiting_register and ed.awaiting_char == null;
}

/// Ends a command: commits the undo group and finishes dot-repeat capture.
fn afterKey(ed: *Editor) void {
    if (!ed.isIdle()) return;
    const b = ed.buffer;
    b.history.commit(ed.gpa) catch {};
    b.modified = b.history.isModified();
    if (ed.capturing) {
        if (ed.capture_repeatable) {
            ed.last_change.clearRetainingCapacity();
            ed.last_change.appendSlice(ed.gpa, ed.change_keys.items) catch {};
            ed.last_change_count = ed.capture_count;
        }
        ed.capturing = false;
    }
    ed.showcmd_len = 0;
}

/// Abandons a half-typed command (after an error or <Esc>).
pub fn resetCommand(ed: *Editor) void {
    ed.pending_len = 0;
    ed.count = 0;
    ed.register = null;
    ed.awaiting_register = false;
    ed.awaiting_char = null;
    ed.capture_repeatable = false;
    if (ed.mode == .operator) ed.setMode(.normal);
    ed.op = null;
}

fn handleKeyInner(ed: *Editor, ev: KeyEvent) !void {
    // A message stays up until the next command starts.
    if (ed.isIdle() and ed.mode != .picker) ed.clearMessage();

    // `"x`: the register for the next command.
    if (ed.awaiting_register) {
        ed.awaiting_register = false;
        if (ev.text()) |cp| if (Registers.isValidName(cp)) {
            ed.register = @intCast(cp);
            return;
        };
        return ed.resetCommand();
    }

    // The character argument of f/t/r/q/@.
    if (ed.awaiting_char) |a| {
        ed.awaiting_char = null;
        const cp = ev.text() orelse return ed.resetCommand();
        if (ed.capturing) try ed.change_keys.append(ed.gpa, ev);
        return a.cmd.run(.{ .ed = ed, .count = a.count, .has_count = a.has_count, .register = a.register, .char = cp });
    }

    const commandish = ed.mode == .normal or ed.mode == .visual or ed.mode == .operator;
    const plain = !ev.mods.blocksText() and ev.key == .codepoint;
    if (commandish and ed.pending_len == 0 and plain) {
        const cp = ev.key.codepoint;
        // Counts: "3w", "d2w". A leading 0 is the line_start motion.
        if ((cp >= '1' and cp <= '9') or (cp == '0' and ed.count > 0)) {
            ed.count = ed.count *| 10 +| (cp - '0');
            if (ed.capturing and ed.mode == .operator) try ed.change_keys.append(ed.gpa, ev);
            return;
        }
        if (cp == '"' and ed.mode != .operator) {
            ed.awaiting_register = true;
            return;
        }
        // `q` while recording stops the recording.
        if (cp == 'q' and ed.mode == .normal and ed.macro_register != null) return ed.stopMacro();
    }

    // Start capturing a possible change for `.`.
    if (ed.mode == .normal and !ed.capturing and ed.pending_len == 0) {
        ed.capturing = true;
        ed.capture_repeatable = false;
        ed.capture_count = ed.count;
        ed.change_keys.clearRetainingCapacity();
    }
    if (ed.capturing) try ed.change_keys.append(ed.gpa, ev);

    if (ed.pending_len == ed.pending.len) ed.pending_len = 0;
    ed.pending[ed.pending_len] = ev;
    ed.pending_len += 1;
    const seq = ed.pending[0..ed.pending_len];

    switch (ed.keymap.lookup(ed.mode, seq)) {
        .prefix => return,
        .command => |cmd| {
            var count = ed.count;
            var has_count = count != 0;
            // In operator-pending mode the counts multiply: 2d3w = 6 words.
            if (ed.mode == .operator) if (ed.op) |op| if (op.has_count) {
                count = @max(count, 1) * op.count;
                has_count = true;
            };
            const register = ed.register;
            ed.pending_len = 0;
            ed.count = 0;
            ed.register = null;
            if (cmd.repeat) ed.capture_repeatable = true;
            if (cmd.takes_char) {
                ed.awaiting_char = .{ .cmd = cmd, .count = @max(count, 1), .has_count = has_count, .register = register };
                return;
            }
            try cmd.run(.{
                .ed = ed,
                .count = @max(count, 1),
                .has_count = has_count,
                .register = register,
            });
        },
        .none => {
            ed.pending_len = 0;
            ed.count = 0;
            // Unbound keys in insert and picker modes are text, including any
            // keys held back as a possible multi-key binding prefix.
            switch (ed.mode) {
                .normal, .visual => ed.register = null,
                .operator => ed.resetCommand(),
                .insert => for (seq) |k| if (k.text()) |cp| {
                    try ed.insertCodepoint(cp);
                    ed.afterTyped(cp);
                },
                .picker, .search => {
                    const input = ed.activeInput() orelse return;
                    for (seq) |k| if (k.text()) |cp| try input.insert(ed.gpa, cp);
                    try ed.inputChanged();
                },
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Language server

fn tickLsp(ed: *Editor) void {
    // Start each server the first time a file of its language is open.
    for (ed.buffers.items) |b| {
        const i = Lsp.serverFor(b) orelse continue;
        if (ed.lsps[i] != null or ed.lsp_failed[i]) continue;
        ed.lsps[i] = Lsp.start(ed, i) catch |err| blk: {
            ed.lsp_failed[i] = true;
            ed.setMessage(.err, "could not start {s}: {s}", .{ Lsp.servers[i].name, @errorName(err) });
            break :blk null;
        };
    }
    for (&ed.lsps, 0..) |*slot, i| {
        const l = slot.* orelse continue;
        l.sync(ed) catch {};
        if (!l.poll(ed)) {
            l.deinit();
            slot.* = null;
            ed.lsp_failed[i] = true;
            ed.setMessage(.err, "{s} exited", .{Lsp.servers[i].name});
        }
    }
}

/// The running server for `b`'s language, if any.
pub fn lspFor(ed: *const Editor, b: *const Buffer) ?*Lsp {
    const i = Lsp.serverFor(b) orelse return null;
    return ed.lsps[i];
}

/// The current buffer's server, or a message saying why there is none.
pub fn languageServer(ed: *Editor) ?*Lsp {
    const i = Lsp.serverFor(ed.buffer) orelse {
        ed.setMessage(.err, "no language server for this file", .{});
        return null;
    };
    if (ed.lsps[i]) |l| return l;
    const name = Lsp.servers[i].name;
    if (ed.lsp_failed[i]) ed.setMessage(.err, "{s} is not running", .{name}) else ed.setMessage(.info, "{s} is starting...", .{name});
    return null;
}

pub fn diagnostics(ed: *const Editor, b: *const Buffer) []const Lsp.Diagnostic {
    const l = ed.lspFor(b) orelse return &.{};
    return l.diagnosticsFor(b.path orelse return &.{});
}

/// Tells every running server that `b` is going away.
fn lspCloseBuffer(ed: *Editor, b: *Buffer) void {
    for (ed.lsps) |maybe| if (maybe) |l| l.closeBuffer(b);
}

fn clearLocations(ed: *Editor) void {
    for (ed.locations.items) |loc| ed.gpa.free(loc.path);
    ed.locations.clearRetainingCapacity();
}

/// Jumps straight to a single location, or lists several in the picker.
pub fn showLocations(ed: *Editor, locs: []const Lsp.Location, what: []const u8) !void {
    if (locs.len == 0) return ed.setMessage(.info, "no {s} found", .{what});
    if (locs.len == 1) return ed.jumpTo(locs[0].path, locs[0].line, locs[0].col);
    ed.clearLocations();
    for (locs) |loc| {
        try ed.locations.append(ed.gpa, .{ .path = try ed.gpa.dupe(u8, loc.path), .line = loc.line, .col = loc.col });
    }
    try ed.openPicker(.locations, "");
}

fn clearSymbols(ed: *Editor) void {
    for (ed.symbols.items) |s| ed.gpa.free(s.name);
    ed.symbols.clearRetainingCapacity();
}

/// `SPC c l`: the current file's symbols, from the language server when it
/// handles this file, else from the syntax tree.
pub fn showSymbols(ed: *Editor) !void {
    if (ed.lspFor(ed.buffer)) |l| return l.requestSymbols(ed);
    const s = &(ed.buffer.syntax orelse return ed.setMessage(.err, "no symbols: unknown language", .{}));
    ed.clearSymbols();
    try syntax_objects.outline(ed.gpa, s, ed.text(), &ed.symbols);
    try ed.openSymbols();
}

/// Opens the picker on `symbols` (takes ownership of the list contents).
pub fn setSymbols(ed: *Editor, list: []const syntax_objects.Symbol) !void {
    ed.clearSymbols();
    try ed.symbols.appendSlice(ed.gpa, list);
    try ed.openSymbols();
}

fn openSymbols(ed: *Editor) !void {
    if (ed.symbols.items.len == 0) return ed.setMessage(.info, "no symbols in this file", .{});
    try ed.openPicker(.symbols, "");
}

pub fn showHover(ed: *Editor, content: []const u8) !void {
    if (ed.hover) |h| ed.gpa.free(h);
    ed.hover = try ed.gpa.dupe(u8, content);
}

pub fn closeCompletion(ed: *Editor) void {
    if (ed.completion) |*c| c.deinit(ed.gpa);
    ed.completion = null;
}

fn isIdent(b: u8) bool {
    return b == '_' or b == '@' or std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// Start of the identifier ending at the cursor.
fn wordStart(ed: *Editor) usize {
    const t = ed.text();
    const ls = t.lineStart(ed.cursorLine());
    var p = ed.view.cursor;
    while (p > ls and isIdent(t.byteAt(p - 1))) p -= 1;
    return p;
}

/// After typing in insert mode: asks for completions after one of the
/// server's trigger characters (`.`, `::`, `->`...) or two identifier chars.
fn afterTyped(ed: *Editor, cp: u21) void {
    const l = ed.lspFor(ed.buffer) orelse return;
    const trigger = l.isTrigger(cp);
    // A trigger starts a new list even if a popup is open.
    if (trigger) ed.closeCompletion();
    if (ed.completion != null) return;
    const start = ed.wordStart();
    const ask = trigger or (cp < 0x80 and isIdent(@intCast(cp)) and ed.view.cursor - start >= 2);
    if (!ask or ed.completion_asked == start) return;
    ed.completion_asked = start;
    l.requestCompletion(ed, start) catch {};
}

/// Manual trigger (<C-n> / <C-Space> in insert mode).
pub fn requestCompletion(ed: *Editor) !void {
    const l = ed.languageServer() orelse return;
    const start = ed.wordStart();
    ed.completion_asked = start;
    try l.requestCompletion(ed, start);
}

/// A completion reply arrived: show it if the cursor is still on that word.
pub fn showCompletion(ed: *Editor, b: *Buffer, word_start: usize, result: std.json.Value) !void {
    if (b != ed.buffer or ed.mode != .insert or ed.view.cursor < word_start) return;
    if (ed.text().lineOf(word_start) != ed.cursorLine()) return;
    ed.closeCompletion();
    ed.completion = try Completion.fromJson(ed.gpa, result, word_start);
    try ed.refreshCompletion();
}

/// Re-filters the popup for the text typed so far, closing it when the
/// cursor left the word or nothing matches.
fn refreshCompletion(ed: *Editor) !void {
    const c = &(ed.completion orelse return);
    const t = ed.text();
    const valid = ed.mode == .insert and ed.view.cursor >= c.word_start and
        t.lineOf(c.word_start) == ed.cursorLine();
    if (!valid) return ed.closeCompletion();
    const typed = t.slice(c.word_start, ed.view.cursor);
    for (typed) |b| if (!isIdent(b)) return ed.closeCompletion();
    try c.filter(ed.gpa, typed);
    if (c.shown.items.len == 0) ed.closeCompletion();
}

/// Replaces the typed word with the selected item.
pub fn acceptCompletion(ed: *Editor) !void {
    const c = &(ed.completion orelse return);
    const item = c.current() orelse return ed.closeCompletion();
    const insert = try ed.gpa.dupe(u8, item.insert);
    defer ed.gpa.free(insert);
    const start = c.word_start;
    ed.closeCompletion();
    try ed.deleteRange(start, ed.view.cursor);
    try ed.insertText(insert);
}

// ---------------------------------------------------------------------------
// Prompts and search

/// The text input that has focus (picker query or search prompt).
pub fn activeInput(ed: *Editor) ?*LineInput {
    return switch (ed.mode) {
        .picker => if (ed.picker) |p| &p.query else null,
        .search => if (ed.search_prompt) |*sp| &sp.input else null,
        else => null,
    };
}

/// Call after editing `activeInput()`.
pub fn inputChanged(ed: *Editor) !void {
    switch (ed.mode) {
        .picker => if (ed.picker) |p| try p.queryChanged(),
        .search => try ed.searchIncremental(),
        else => {},
    }
}

/// Opens the `/` / `?` prompt, or the `s` snipe prompt. Works from normal,
/// visual and operator-pending mode (`d/foo`, `ds`).
pub fn startSearch(ed: *Editor, forward: bool, kind: PromptKind) void {
    ed.search_prompt = .{
        .forward = forward,
        .origin = ed.view.cursor,
        .origin_top = ed.view.top,
        .return_mode = ed.mode,
        .had_highlight = ed.search_highlight,
        .kind = kind,
    };
    ed.mode = .search;
}

/// Opens the rename prompt, prefilled with the identifier under the cursor.
pub fn startRename(ed: *Editor) !void {
    if (ed.languageServer() == null) return;
    const t = ed.text();
    const r = @import("core/textobjects.zig").word(t, ed.view.cursor, .inner, false, 1) orelse
        return ed.setMessage(.err, "no symbol under cursor", .{});
    const name = t.slice(r.start, r.end);
    if (name.len == 0 or !search.isWord(name[0])) return ed.setMessage(.err, "no symbol under cursor", .{});
    ed.startSearch(true, .rename);
    try ed.search_prompt.?.input.set(ed.gpa, name);
}

/// Sends the rename typed into the prompt.
fn finishRename(ed: *Editor) !void {
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.view.cursor = sp.origin;
    const new_name = sp.input.items();
    if (new_name.len == 0) return;
    const l = ed.languageServer() orelse return;
    try l.requestRename(ed, sp.origin, new_name);
}

/// Applies edits from the language server (a rename): opens each file,
/// applies its edits bottom-up as one undo step, then returns to the buffer
/// the cursor was in.
pub fn applyEdits(ed: *Editor, edits: []const Lsp.TextEdit) !void {
    if (edits.len == 0) return ed.setMessage(.info, "nothing to change", .{});
    const home = ed.buffer;
    const home_cursor = ed.view.cursor;
    var files: usize = 0;
    const done = try ed.gpa.alloc(bool, edits.len);
    defer ed.gpa.free(done);
    @memset(done, false);
    for (edits, 0..) |first, i| {
        if (done[i]) continue;
        try ed.openFile(first.path);
        files += 1;
        // This file's edits, last first, so earlier positions stay valid.
        var mine: std.ArrayList(Lsp.TextEdit) = .empty;
        defer mine.deinit(ed.gpa);
        for (edits[i..], i..) |e, j| if (std.mem.eql(u8, e.path, first.path)) {
            try mine.append(ed.gpa, e);
            done[j] = true;
        };
        std.mem.sort(Lsp.TextEdit, mine.items, {}, struct {
            fn later(_: void, a: Lsp.TextEdit, b: Lsp.TextEdit) bool {
                return if (a.start_line != b.start_line) a.start_line > b.start_line else a.start_col > b.start_col;
            }
        }.later);
        for (mine.items) |e| {
            const start = ed.offsetOf(e.start_line, e.start_col);
            const end = ed.offsetOf(e.end_line, e.end_col);
            try ed.deleteRangeKeepCursor(start, @max(start, end));
            try ed.insertAt(start, e.text);
        }
        try ed.buffer.history.commit(ed.gpa);
        ed.buffer.modified = ed.buffer.history.isModified();
    }
    ed.switchTo(home);
    ed.setCursor(home_cursor);
    ed.setMessage(.info, "renamed: {d} edit(s) in {d} file(s) (SPC f s to save)", .{ edits.len, files });
}

/// Byte offset of a (line, column) position, clamped to the text.
fn offsetOf(ed: *Editor, line: usize, col: usize) usize {
    const t = ed.text();
    if (line >= t.lineCount()) return t.len();
    return t.lineStart(line) + @min(col, t.lineLen(line));
}

/// Moves to the first match as the pattern is typed (back to the origin when
/// there is none). A snipe jumps once a single match is left on screen.
fn searchIncremental(ed: *Editor) !void {
    const sp = &(ed.search_prompt orelse return);
    const t = ed.text();
    const hay = t.slice(0, t.len());
    if (sp.kind == .rename) return;
    ed.view.cursor = sp.origin;
    ed.view.top = sp.origin_top;
    const pattern = search.Pattern.init(sp.input.items(), false);
    if (sp.kind == .snipe) {
        if (ed.onlyVisibleMatch(pattern)) |pos| return ed.finishSearch(pos);
    }
    const m = pattern.next(hay, sp.origin, sp.forward) orelse return;
    ed.view.cursor = m.pos;
    ed.search_highlight = true;
}

/// The position of the match of `pattern` if it is the only one on screen.
fn onlyVisibleMatch(ed: *Editor, pattern: search.Pattern) ?usize {
    if (pattern.needle.len == 0) return null;
    const t = ed.text();
    const first = @min(ed.view.top, t.lineCount() - 1);
    const last = @min(ed.view.top + ed.view.rows, t.lineCount()) - 1;
    const start = t.lineStart(first);
    const visible = t.slice(start, t.lineEnd(last));
    const m = pattern.forward(visible, 0) orelse return null;
    if (pattern.forward(visible, m + 1) != null) return null;
    return start + m;
}

/// Closes the prompt (keeping its text as the last search for `n`/`N`) and
/// moves to `pos`, or applies the pending operator up to it.
fn finishSearch(ed: *Editor, pos: usize) !void {
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    if (sp.input.items().len > 0) {
        try ed.last_search.resize(ed.gpa, 0);
        try ed.last_search.appendSlice(ed.gpa, sp.input.items());
        ed.last_search_whole_word = false;
    }
    ed.last_search_forward = sp.forward;
    ed.search_highlight = true;
    ed.mode = sp.return_mode;
    ed.view.cursor = sp.origin;
    ed.view.top = sp.origin_top;
    if (sp.return_mode == .operator) {
        return ed.applyPending(operators.motionRange(ed.text(), sp.origin, pos, .exclusive));
    }
    ed.revealLine(ed.text().lineOf(pos));
    ed.setCursor(pos);
}

/// <CR>: the next match from where the prompt opened (an empty pattern
/// repeats the last search, like vim).
pub fn acceptSearch(ed: *Editor) !void {
    const sp = &(ed.search_prompt orelse return);
    if (sp.kind == .rename) return ed.finishRename();
    if (sp.input.items().len > 0) {
        try ed.last_search.resize(ed.gpa, 0);
        try ed.last_search.appendSlice(ed.gpa, sp.input.items());
        ed.last_search_whole_word = false;
    }
    ed.last_search_forward = sp.forward;
    const pos = ed.searchNext(sp.origin, false, 1) orelse return ed.cancelSearch();
    try ed.finishSearch(pos);
}

pub fn cancelSearch(ed: *Editor) void {
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.view.cursor = sp.origin;
    ed.view.top = sp.origin_top;
    ed.search_highlight = sp.had_highlight;
    if (sp.return_mode == .operator) ed.resetCommand();
}

/// The pattern to highlight: the prompt while typing, else the last search.
pub fn searchPattern(ed: *const Editor) ?search.Pattern {
    if (ed.search_prompt) |*sp| {
        if (sp.kind == .rename) return null;
        return search.Pattern.init(sp.input.items(), false);
    }
    if (!ed.search_highlight or ed.last_search.items.len == 0) return null;
    return search.Pattern.init(ed.last_search.items, ed.last_search_whole_word);
}

/// The [count]th match of the last search from `from` (`reverse` flips its
/// direction, for `N`). Reports wrapping and "[i/n]" in the status line.
pub fn searchNext(ed: *Editor, from: usize, reverse: bool, count: usize) ?usize {
    if (ed.last_search.items.len == 0) {
        ed.setMessage(.err, "no previous search", .{});
        return null;
    }
    const t = ed.text();
    const hay = t.slice(0, t.len());
    const pattern = search.Pattern.init(ed.last_search.items, ed.last_search_whole_word);
    const forward = ed.last_search_forward != reverse;
    var pos = from;
    var wrapped = false;
    for (0..count) |_| {
        const m = pattern.next(hay, pos, forward) orelse {
            ed.setMessage(.err, "pattern not found: {s}", .{ed.last_search.items});
            return null;
        };
        pos = m.pos;
        wrapped = wrapped or m.wrapped;
    }
    ed.search_highlight = true;
    const where = pattern.position(hay, pos);
    const prefix: u8 = if (ed.last_search_forward) '/' else '?';
    if (wrapped) {
        ed.setMessage(.info, "{c}{s}  [{d}/{d}]  search wrapped", .{ prefix, ed.last_search.items, where.index, where.total });
    } else {
        ed.setMessage(.info, "{c}{s}  [{d}/{d}]", .{ prefix, ed.last_search.items, where.index, where.total });
    }
    return pos;
}

/// `*` / `#`: searches for the word under the cursor.
pub fn searchWord(ed: *Editor, forward: bool, count: usize) !void {
    const t = ed.text();
    const r = @import("core/textobjects.zig").word(t, ed.view.cursor, .inner, false, 1) orelse return;
    const word = t.slice(r.start, r.end);
    if (word.len == 0 or !search.isWord(word[0])) return ed.setMessage(.err, "no word under cursor", .{});
    try ed.last_search.resize(ed.gpa, 0);
    try ed.last_search.appendSlice(ed.gpa, word);
    ed.last_search_forward = forward;
    ed.last_search_whole_word = true;
    if (ed.searchNext(r.start, false, count)) |pos| ed.setCursor(pos);
}

// ---------------------------------------------------------------------------
// Operators, visual mode, dot repeat, macros

pub fn beginOperator(ed: *Editor, op: operators.Operator, c: commands.Context) void {
    ed.op = .{ .op = op, .count = c.count, .has_count = c.has_count, .register = c.register };
    ed.mode = .operator;
}

/// Applies the pending operator to `r` (called by motions and text objects in
/// operator-pending mode).
pub fn applyPending(ed: *Editor, r: operators.Range) !void {
    const op = ed.op orelse return;
    ed.op = null;
    ed.mode = .normal;
    try operators.apply(ed, op.op, r, op.register);
}

pub fn pendingOperator(ed: *const Editor) ?operators.Operator {
    return if (ed.op) |o| o.op else null;
}

pub fn enterVisual(ed: *Editor, line: bool) void {
    ed.mode = .visual;
    ed.visual_line = line;
    ed.view.anchor = ed.view.cursor;
}

pub fn exitVisual(ed: *Editor) void {
    ed.mode = .normal;
    ed.placeCursor(ed.view.cursor);
}

/// The visual selection as an operator range (inclusive of the cursor char).
pub fn visualRange(ed: *Editor) operators.Range {
    const t = ed.text();
    const a = ed.view.anchor;
    const c = ed.view.cursor;
    if (ed.visual_line) return operators.linesRange(t, t.lineOf(@min(a, c)), t.lineOf(@max(a, c)));
    const last = @max(a, c);
    return .{ .start = @min(a, c), .end = if (last < t.len()) motions.nextChar(t, last) else last };
}

/// Selects `r` in visual mode (text objects in visual mode).
pub fn selectRange(ed: *Editor, r: operators.Range) void {
    const t = ed.text();
    if (r.linewise) ed.visual_line = true;
    ed.view.anchor = r.start;
    ed.view.cursor = if (r.end > r.start) motions.prevChar(t, r.end) else r.start;
}

/// `.`: replays the last change, with `count` replacing its count if given.
pub fn repeatLastChange(ed: *Editor, count: usize, has_count: bool) !void {
    if (ed.last_change.items.len == 0) return;
    var keys_buf: std.ArrayList(KeyEvent) = .empty;
    defer keys_buf.deinit(ed.gpa);
    const n = if (has_count) count else ed.last_change_count;
    if (n > 0) {
        var digits: [20]u8 = undefined;
        for (std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable) |d| try keys_buf.append(ed.gpa, KeyEvent.char(d));
    }
    try keys_buf.appendSlice(ed.gpa, ed.last_change.items);
    try ed.queue.insertSlice(ed.gpa, 0, keys_buf.items);
}

pub fn startMacro(ed: *Editor, register: u21) void {
    const r = std.ascii.toLower(std.math.cast(u8, register) orelse return);
    if (r < 'a' or r > 'z') return ed.setMessage(.err, "macros record into a-z", .{});
    ed.macro_register = r;
    ed.macro_keys.clearRetainingCapacity();
}

fn stopMacro(ed: *Editor) !void {
    const r = ed.macro_register orelse return;
    ed.macro_register = null;
    // Drop the `q` that stopped the recording.
    const recorded = ed.macro_keys.items[0..ed.macro_keys.items.len -| 1];
    var out: std.Io.Writer.Allocating = .init(ed.gpa);
    defer out.deinit();
    for (recorded) |k| try k.format(&out.writer);
    try ed.registers.setNamed(r, out.written());
    ed.last_macro = r;
    ed.setMessage(.info, "recorded @{c}", .{r});
}

pub fn playMacro(ed: *Editor, register: u21, count: usize) !void {
    const r: u8 = if (register == '@') ed.last_macro orelse return else std.math.cast(u8, register) orelse return;
    const v = ed.registers.get(r) orelse return ed.setMessage(.err, "register {c} is empty", .{r});
    ed.last_macro = r;
    try ed.queueNotation(v.text, count);
}

pub fn undo(ed: *Editor, count: usize) !void {
    const b = ed.buffer;
    try b.history.commit(ed.gpa);
    for (0..count) |_| {
        const cursor = try b.history.undo(ed.gpa, b) orelse {
            ed.setMessage(.info, "already at oldest change", .{});
            break;
        };
        ed.setCursor(cursor);
    }
}

pub fn redo(ed: *Editor, count: usize) !void {
    const b = ed.buffer;
    for (0..count) |_| {
        const cursor = try b.history.redo(ed.gpa, b) orelse {
            ed.setMessage(.info, "already at newest change", .{});
            break;
        };
        ed.setCursor(cursor);
    }
}

/// Keys typed so far toward a multi-key binding.
pub fn pendingKeys(ed: *const Editor) []const KeyEvent {
    return ed.pending[0..ed.pending_len];
}

/// Everything typed for the command in progress ("2d", "\"ay"), for the status line.
pub fn showcmdKeys(ed: *const Editor) []const KeyEvent {
    return ed.showcmd[0..ed.showcmd_len];
}

/// The which-key menu for the keys typed so far (empty when nothing is pending).
pub fn whichKey(ed: *const Editor, out: []km.Continuation) []km.Continuation {
    if (ed.pending_len == 0) return out[0..0];
    return ed.keymap.continuations(ed.mode, ed.pendingKeys(), out);
}

// ---------------------------------------------------------------------------
// Cursor

pub fn cursorLine(ed: *Editor) usize {
    return ed.text().lineOf(ed.view.cursor);
}

pub fn cursorCol(ed: *Editor) usize {
    const t = ed.text();
    const line = t.lineOf(ed.view.cursor);
    return motions.displayCol(t.lineSlice(line), ed.view.cursor - t.lineStart(line), ed.options.tab_width);
}

/// Moves the cursor, clamping it for the current mode. Resets the sticky column.
pub fn setCursor(ed: *Editor, pos: usize) void {
    ed.placeCursor(pos);
    ed.view.want_col = null;
}

fn placeCursor(ed: *Editor, pos: usize) void {
    const t = ed.text();
    var p = @min(pos, t.len());
    p = motions.charStart(t, p);
    if (ed.mode != .insert) p = motions.clampNormal(t, p);
    ed.view.cursor = p;
}

/// Moves to `line`, keeping the sticky display column.
pub fn gotoLine(ed: *Editor, line: usize) void {
    const t = ed.text();
    const target = @min(line, t.lineCount() - 1);
    const col = ed.view.want_col orelse ed.cursorCol();
    const off = motions.byteAtCol(t.lineSlice(target), col, ed.options.tab_width);
    ed.placeCursor(t.lineStart(target) + off);
    ed.view.want_col = col;
}

pub fn moveLines(ed: *Editor, delta: isize) void {
    ed.gotoLine(ed.stepVisible(ed.cursorLine(), delta));
}

// ---------------------------------------------------------------------------
// Folds: a closed fold shows as one line; everything that counts lines on
// screen goes through these.

/// The closed fold hiding `line` (outermost), if any.
pub fn foldAt(ed: *const Editor, line: usize) ?Folds.Lines {
    if (ed.buffer.folds.isEmpty()) return null;
    return ed.buffer.folds.region(&ed.buffer.text, line);
}

/// The line that represents `line` on screen (its fold's first line).
pub fn visibleLine(ed: *const Editor, line: usize) usize {
    return if (ed.foldAt(line)) |f| f.first else line;
}

/// The line `delta` visible lines away from `line`, clamped to the text.
pub fn stepVisible(ed: *const Editor, line: usize, delta: isize) usize {
    const last = ed.buffer.text.lineCount() - 1;
    if (ed.buffer.folds.isEmpty()) {
        return @intCast(std.math.clamp(@as(isize, @intCast(line)) + delta, 0, @as(isize, @intCast(last))));
    }
    var l = ed.visibleLine(@min(line, last));
    var n = @abs(delta);
    while (n > 0) : (n -= 1) {
        if (delta > 0) {
            const end = if (ed.foldAt(l)) |f| f.last else l;
            if (end >= last) break;
            l = end + 1;
        } else {
            if (l == 0) break;
            l = ed.visibleLine(l - 1);
        }
    }
    return l;
}

/// Screen rows from line `a` down to line `b`, counting at most `cap`.
pub fn rowsBetween(ed: *const Editor, a: usize, b: usize, cap: usize) usize {
    if (b <= a) return 0;
    if (ed.buffer.folds.isEmpty()) return @min(b - a, cap);
    var l = ed.visibleLine(a);
    const target = ed.visibleLine(b);
    var rows: usize = 0;
    while (l < target and rows < cap) : (rows += 1) {
        const next = ed.stepVisible(l, 1);
        if (next == l) break;
        l = next;
    }
    return rows;
}

/// The screen row of `line`, if it is on screen.
pub fn screenRow(ed: *const Editor, line: usize) ?usize {
    const l = ed.visibleLine(line);
    if (l < ed.view.top) return null;
    const row = ed.rowsBetween(ed.view.top, l, ed.view.rows);
    return if (row < ed.view.rows) row else null;
}

/// Opens the folds hiding `line` (jumps land on visible text).
pub fn revealLine(ed: *Editor, line: usize) void {
    _ = ed.buffer.folds.open(&ed.buffer.text, line, true);
}

/// Keeps the cursor off hidden lines: in insert mode the fold opens, otherwise
/// the cursor moves to the fold's first line.
fn clampToFolds(ed: *Editor) void {
    const line = ed.cursorLine();
    const f = ed.foldAt(line) orelse return;
    if (ed.mode == .insert) return ed.revealLine(line);
    if (line != f.first) ed.setCursor(motions.firstNonBlank(ed.text(), f.first));
}

/// Extends a linewise range to whole folds at either end (`dd` on a closed
/// fold deletes the fold).
pub fn extendToFolds(ed: *const Editor, r: operators.Range) operators.Range {
    if (!r.linewise or ed.buffer.folds.isEmpty()) return r;
    const t = &ed.buffer.text;
    var first = t.lineOf(r.start);
    var last = t.lineOf(r.end);
    if (ed.foldAt(first)) |f| first = f.first;
    if (ed.foldAt(last)) |f| last = f.last;
    return operators.linesRange(t, first, last);
}

/// Places the cursor at a cell of the text area (mouse click).
pub fn clickCell(ed: *Editor, row: usize, col: usize) void {
    const t = ed.text();
    const line = ed.stepVisible(ed.view.top, @intCast(row));
    const off = motions.byteAtCol(t.lineSlice(line), ed.view.left + col, ed.options.tab_width);
    ed.setCursor(t.lineStart(line) + off);
}

// ---------------------------------------------------------------------------
// Scrolling

pub fn setViewSize(ed: *Editor, rows: usize, cols: usize) void {
    ed.view.rows = @max(rows, 1);
    ed.view.cols = @max(cols, 1);
    ed.scrollToCursor();
}

pub fn effectiveScrolloff(ed: *const Editor) usize {
    return @min(ed.options.scrolloff, (ed.view.rows -| 1) / 2);
}

/// Adjusts the viewport so the cursor is visible with `scrolloff` margin.
pub fn scrollToCursor(ed: *Editor) void {
    const v = &ed.view;
    const line = ed.visibleLine(ed.cursorLine());
    const so = ed.effectiveScrolloff();
    v.top = ed.visibleLine(@min(v.top, ed.text().lineCount() -| 1));
    if (line < v.top or ed.rowsBetween(v.top, line, so) < so) {
        v.top = ed.stepVisible(line, -@as(isize, @intCast(so)));
    } else if (ed.rowsBetween(v.top, line, v.rows) + so >= v.rows) {
        v.top = ed.stepVisible(line, -@as(isize, @intCast(v.rows -| (so + 1))));
    }

    const col = ed.cursorCol();
    if (col < v.left) v.left = col;
    if (col >= v.left + v.cols) v.left = col + 1 - v.cols;
}

/// Scrolls the view by `delta` lines, dragging the cursor along when it
/// would leave the screen (vim's <C-e>/<C-y> and mouse wheel behavior).
pub fn scrollLines(ed: *Editor, delta: isize) void {
    const v = &ed.view;
    v.top = ed.stepVisible(v.top, delta);

    const so = ed.effectiveScrolloff();
    const line = ed.visibleLine(ed.cursorLine());
    const lo = if (v.top == 0) 0 else ed.stepVisible(v.top, @intCast(so));
    const hi = ed.stepVisible(v.top, @intCast(v.rows -| (so + 1)));
    if (line < lo) ed.gotoLine(lo) else if (line > hi and hi >= lo) ed.gotoLine(hi);
}

// ---------------------------------------------------------------------------
// Editing primitives

/// Inserts at `pos`, recording it for undo. Leaves the cursor alone.
pub fn insertAt(ed: *Editor, pos: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try ed.buffer.history.recordInsert(ed.gpa, pos, bytes, ed.view.cursor);
    try ed.buffer.insert(ed.gpa, pos, bytes);
    ed.buffer.modified = true;
}

/// Inserts at the cursor and moves the cursor past the text.
pub fn insertText(ed: *Editor, bytes: []const u8) !void {
    const pos = ed.view.cursor;
    try ed.insertAt(pos, bytes);
    ed.view.cursor = pos + bytes.len;
    ed.view.want_col = null;
}

pub fn insertCodepoint(ed: *Editor, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try ed.insertText(buf[0..n]);
}

/// Deletes `[start, end)`, recording it for undo, and puts the cursor at `start`.
pub fn deleteRange(ed: *Editor, start: usize, end: usize) !void {
    try ed.deleteRangeKeepCursor(start, end);
    ed.setCursor(start);
}

/// Deletes `[start, end)`, recording it for undo. The cursor keeps its
/// position relative to the text around it.
pub fn deleteRangeKeepCursor(ed: *Editor, start: usize, end: usize) !void {
    if (start >= end) return;
    const t = ed.text();
    try ed.buffer.history.recordDelete(ed.gpa, start, t.slice(start, end), ed.view.cursor);
    ed.buffer.delete(start, end);
    ed.buffer.modified = true;
    const c = ed.view.cursor;
    if (c >= end) ed.view.cursor = c - (end - start) else if (c > start) ed.view.cursor = start;
}

pub fn setMode(ed: *Editor, mode: Mode) void {
    ed.mode = mode;
    ed.placeCursor(ed.view.cursor);
}

// ---------------------------------------------------------------------------
// Buffers

/// Opens `path` (relative to the cwd or absolute), or switches to it if it is
/// already open. A missing file opens empty and is created on save.
pub fn openFile(ed: *Editor, path: []const u8) !void {
    const norm = try ed.normalizePath(path);
    defer ed.gpa.free(norm);
    for (ed.buffers.items) |b| {
        if (b.path) |bp| if (std.mem.eql(u8, bp, norm)) return ed.switchTo(b);
    }

    var loaded = try Buffer.load(ed.gpa, ed.io, norm);
    // Replace an untouched scratch buffer instead of keeping it around, like vim.
    const cur = ed.buffer;
    if (cur.path == null and !cur.modified and cur.text.len() == 0) {
        ed.lspCloseBuffer(cur);
        cur.deinit(ed.gpa);
        cur.* = loaded;
        ed.use_counter += 1;
        cur.last_used = ed.use_counter;
        ed.activate(cur);
        return;
    }
    errdefer loaded.deinit(ed.gpa);
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = loaded;
    try ed.buffers.append(ed.gpa, b);
    ed.switchTo(b);
}

/// `relativePath` for paths the user typed (relative or absolute).
pub fn relativePath(ed: *Editor, path: []const u8) Allocator.Error![]u8 {
    return ed.normalizePath(path);
}

/// An owned absolute path for a buffer path.
pub fn absolutePath(ed: *Editor, path: []const u8) Allocator.Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return ed.gpa.dupe(u8, path);
    return std.fs.path.join(ed.gpa, &.{ ed.cwd, path });
}

/// Opens `path` and puts the cursor at (`line`, `col`), both 0-based.
pub fn jumpTo(ed: *Editor, path: []const u8, line: usize, col: usize) !void {
    try ed.openFile(path);
    const t = ed.text();
    const l = @min(line, t.lineCount() - 1);
    ed.revealLine(l);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
}

/// Paths inside the cwd are stored relative to it, without "./".
fn normalizePath(ed: *Editor, path: []const u8) Allocator.Error![]u8 {
    var p = path;
    if (std.fs.path.isAbsolute(p) and std.mem.startsWith(u8, p, ed.cwd) and
        p.len > ed.cwd.len and p[ed.cwd.len] == '/')
    {
        p = p[ed.cwd.len + 1 ..];
    }
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return ed.gpa.dupe(u8, p);
}

pub fn switchTo(ed: *Editor, b: *Buffer) void {
    if (b == ed.buffer) return;
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    ed.use_counter += 1;
    b.last_used = ed.use_counter;
    ed.activate(b);
}

/// Shows `b` with its saved view, without saving the current one.
fn activate(ed: *Editor, b: *Buffer) void {
    if (ed.mode == .visual or ed.mode == .operator) ed.mode = .normal;
    ed.op = null;
    ed.buffer = b;
    ed.view.cursor = b.saved.cursor;
    ed.view.top = b.saved.top;
    ed.view.left = b.saved.left;
    ed.view.want_col = null;
    if (ed.mode == .insert) ed.mode = .normal;
    ed.placeCursor(ed.view.cursor);
    ed.scrollToCursor();
}

/// Closes `b`. Refuses (with a message) if it has unsaved changes. Closing the
/// last buffer leaves an empty scratch buffer.
pub fn killBuffer(ed: *Editor, b: *Buffer) !void {
    if (b.modified) {
        ed.setMessage(.err, "\"{s}\" has unsaved changes: SPC f s to save it first", .{b.displayName()});
        return;
    }
    ed.lspCloseBuffer(b);
    if (ed.buffers.items.len == 1) {
        const fresh = try Buffer.initEmpty(ed.gpa);
        b.deinit(ed.gpa);
        b.* = fresh;
        ed.activate(b);
        return;
    }
    _ = ed.buffers.orderedRemove(ed.bufferIndex(b));
    if (b == ed.buffer) {
        var next = ed.buffers.items[0];
        for (ed.buffers.items) |o| {
            if (o.last_used > next.last_used) next = o;
        }
        ed.activate(next);
    }
    b.deinit(ed.gpa);
    ed.gpa.destroy(b);
}

pub fn bufferIndex(ed: *const Editor, b: *const Buffer) usize {
    for (ed.buffers.items, 0..) |o, i| if (o == b) return i;
    unreachable;
}

/// Cycles through buffers in list order.
pub fn cycleBuffer(ed: *Editor, delta: isize) void {
    const n: isize = @intCast(ed.buffers.items.len);
    const i: isize = @intCast(ed.bufferIndex(ed.buffer));
    ed.switchTo(ed.buffers.items[@intCast(@mod(i + delta, n))]);
}

/// Most recently used first, the current buffer last (so the top entry is
/// "the buffer before this one"). Caller frees the slice.
pub fn buffersByRecency(ed: *Editor, gpa: Allocator) Allocator.Error![]*Buffer {
    const out = try gpa.dupe(*Buffer, ed.buffers.items);
    std.mem.sort(*Buffer, out, ed.buffer, struct {
        fn lessThan(current: *Buffer, a: *Buffer, b: *Buffer) bool {
            if (a == current) return false;
            if (b == current) return true;
            return a.last_used > b.last_used;
        }
    }.lessThan);
    return out;
}

/// Where `b`'s cursor is (live for the current buffer, saved for others).
pub fn cursorOf(ed: *const Editor, b: *const Buffer) usize {
    return if (b == ed.buffer) ed.view.cursor else b.saved.cursor;
}

// ---------------------------------------------------------------------------
// Picker

pub fn openPicker(ed: *Editor, kind: Picker.Kind, query: []const u8) !void {
    ed.closePicker();
    ed.picker = try Picker.create(ed, kind, query);
    ed.mode = .picker;
}

pub fn closePicker(ed: *Editor) void {
    const p = ed.picker orelse return;
    ed.resume_kind = p.base;
    ed.resume_query.clearRetainingCapacity();
    ed.resume_query.appendSlice(ed.gpa, p.query.items()) catch {};
    p.destroy();
    ed.picker = null;
    ed.mode = .normal;
}

/// Accepts the selected row: closes the picker, then acts on the choice
/// (which may open another picker).
pub fn acceptPicker(ed: *Editor) !void {
    const p = ed.picker orelse return;
    const choice = try p.choice();
    defer choice.deinit(ed.gpa);
    ed.closePicker();
    switch (choice) {
        .none => {},
        .item => |c| try @import("picker/sources.zig").accept(c.kind, ed, c.item),
        .create => |c| try @import("picker/sources.zig").create(c.kind, ed, c.query),
    }
}

// ---------------------------------------------------------------------------
// Status messages

pub fn setMessage(ed: *Editor, kind: Message.Kind, comptime fmt: []const u8, args: anytype) void {
    ed.message.kind = kind;
    const s = std.fmt.bufPrint(&ed.message.buf, fmt, args) catch blk: {
        const ellipsis = "...";
        @memcpy(ed.message.buf[ed.message.buf.len - ellipsis.len ..], ellipsis);
        break :blk ed.message.buf[0..];
    };
    ed.message.len = s.len;
}

pub fn clearMessage(ed: *Editor) void {
    ed.message.len = 0;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testEditor(content: []const u8) !Editor {
    var ed = try Editor.init(testing.allocator, testing.io);
    errdefer ed.deinit();
    try ed.text().insert(ed.gpa, 0, content);
    return ed;
}

fn expectText(ed: *Editor, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, ed.text().slice(0, ed.text().len()));
}

test "insert mode typing and escape" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ihello<Esc>");
    try expectText(&ed, "hello");
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(4, ed.view.cursor); // Esc steps back onto 'o'
}

test "counts and word motions" {
    var ed = try testEditor("one two three four");
    defer ed.deinit();
    try ed.feed("2w");
    try testing.expectEqual(8, ed.view.cursor);
    try ed.feed("b");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed("$");
    try testing.expectEqual(17, ed.view.cursor);
    try ed.feed("0");
    try testing.expectEqual(0, ed.view.cursor);
}

test "sticky column across short lines" {
    var ed = try testEditor("long line here\nab\nanother long line");
    defer ed.deinit();
    try ed.feed("10l");
    try testing.expectEqual(10, ed.cursorCol());
    try ed.feed("j");
    try testing.expectEqual(1, ed.cursorCol()); // clamped onto 'b'
    try ed.feed("j");
    try testing.expectEqual(10, ed.cursorCol()); // restored
}

test "open line keeps indentation" {
    var ed = try testEditor("    foo");
    defer ed.deinit();
    try ed.feed("obar<Esc>");
    try expectText(&ed, "    foo\n    bar");
    try ed.feed("Obaz<Esc>");
    try expectText(&ed, "    foo\n    baz\n    bar");
}

test "x, X and dd with counts" {
    var ed = try testEditor("abcdef\nline2\nline3\nline4");
    defer ed.deinit();
    try ed.feed("2x");
    try expectText(&ed, "cdef\nline2\nline3\nline4");
    try ed.feed("$X");
    try expectText(&ed, "cdf\nline2\nline3\nline4");
    try ed.feed("j2dd");
    try expectText(&ed, "cdf\nline4");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("dd");
    try expectText(&ed, "cdf");
    try ed.feed("dd");
    try expectText(&ed, "");
}

test "insert mode backspace joins lines and <C-w> deletes a word" {
    var ed = try testEditor("foo\nbar baz");
    defer ed.deinit();
    try ed.feed("jI<BS><Esc>");
    try expectText(&ed, "foobar baz");
    try ed.feed("A<C-w><Esc>");
    try expectText(&ed, "foobar ");
}

test "gg and G with counts" {
    var ed = try testEditor("a\n  b\nc\nd");
    defer ed.deinit();
    try ed.feed("G");
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("2G");
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expectEqual(2, ed.cursorCol()); // first non-blank
    try ed.feed("gg");
    try testing.expectEqual(0, ed.cursorLine());
}

test "leader menus: quit refuses unsaved changes, SPC q Q forces" {
    var ed = try testEditor("x");
    defer ed.deinit();
    try ed.feed("ia<Esc><Space>q");
    var out: [16]km.Continuation = undefined;
    try testing.expect(ed.whichKey(&out).len >= 2); // menu is open
    try ed.feed("q");
    try testing.expect(!ed.should_quit);
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("<Space>qQ");
    try testing.expect(ed.should_quit);
}

test "escape cancels a pending leader sequence" {
    var ed = try testEditor("abc");
    defer ed.deinit();
    try ed.feed("<Space>f<Esc>");
    try testing.expectEqual(0, ed.pending_len);
    try ed.feed("x"); // a plain command works again
    try expectText(&ed, "bc");
}

test "scrolling keeps the cursor in view" {
    var ed = try testEditor("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19");
    defer ed.deinit();
    ed.setViewSize(10, 80);
    try ed.feed("15j");
    try testing.expectEqual(15, ed.cursorLine());
    try testing.expect(ed.view.top <= 15 and 15 < ed.view.top + 10);
    ed.scrollLines(-100);
    try testing.expectEqual(0, ed.view.top);
    try testing.expect(ed.cursorLine() < 10);
}

test "command picker: fuzzy search and accept" {
    var ed = try testEditor("x");
    defer ed.deinit();
    try ed.feed("ia<Esc>"); // modified, so quit_without_saving is observable
    try ed.feed("<Space>:");
    try testing.expectEqual(.picker, ed.mode);
    try ed.feed("quitwo<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(ed.should_quit);
}

test "prefix switches sources; Esc closes and resume restores" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>");
    try testing.expectEqual(.files, ed.picker.?.kind);
    try ed.feed(">sav");
    try testing.expectEqual(.commands, ed.picker.?.kind);
    try testing.expectEqualStrings("sav", ed.picker.?.activeQuery());
    ed.picker.?.sync();
    try testing.expectEqualStrings("save_file", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc>");
    try testing.expectEqual(.normal, ed.mode);
    try ed.feed("<Space>'");
    try testing.expectEqualStrings(">sav", ed.picker.?.query.items());
}

test "buffers: open, switch back via picker, kill" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-missing-a.txt"); // replaces the scratch buffer
    try testing.expectEqual(1, ed.buffers.items.len);
    try ed.openFile("./edit-test-missing-b.txt");
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.openFile("edit-test-missing-b.txt"); // already open: no duplicate
    try testing.expectEqual(2, ed.buffers.items.len);

    try ed.feed("<Space>,<CR>"); // top entry is the previous buffer
    try testing.expectEqualStrings("edit-test-missing-a.txt", ed.buffer.path.?);

    try ed.feed("<Space>bk");
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expectEqualStrings("edit-test-missing-b.txt", ed.buffer.path.?);
}

test "file picker offers to create a missing file" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>no/such/file-xyz.txt");
    const p = ed.picker.?;
    p.sync();
    try testing.expectEqual(0, p.createRow().?);
    try ed.feed("<CR>");
    try testing.expectEqualStrings("no/such/file-xyz.txt", ed.buffer.path.?);
    try testing.expect(!ed.buffer.modified); // nothing written until saved
}

fn expectCursor(ed: *Editor, line: usize, col: usize) !void {
    try testing.expectEqual(line, ed.cursorLine());
    try testing.expectEqual(col, ed.cursorCol());
}

test "operators with motions" {
    var ed = try testEditor("one two three\nfour five");
    defer ed.deinit();
    try ed.feed("dw");
    try expectText(&ed, "two three\nfour five");
    try ed.feed("wdw"); // last word: keeps the line break
    try expectText(&ed, "two \nfour five");
    try ed.feed("ggd$");
    try expectText(&ed, "\nfour five");
    try ed.feed("jde");
    try expectText(&ed, "\n five");
    try ed.feed("u");
    try expectText(&ed, "\nfour five");
}

test "counts multiply and dd/yy/p are linewise" {
    var ed = try testEditor("a b c d e f g\nl2\nl3\nl4");
    defer ed.deinit();
    try ed.feed("2d2w");
    try expectText(&ed, "e f g\nl2\nl3\nl4");
    try ed.feed("j2yyGp");
    try expectText(&ed, "e f g\nl2\nl3\nl4\nl2\nl3");
    try expectCursor(&ed, 4, 0);
    try ed.feed("ggddP");
    try expectText(&ed, "e f g\nl2\nl3\nl4\nl2\nl3");
    try ed.feed("3dd");
    try expectText(&ed, "l4\nl2\nl3");
}

test "change: cw, ciw, cc, C keep vim's semantics" {
    var ed = try testEditor("    foo bar baz");
    defer ed.deinit();
    try ed.feed("wcwX<Esc>"); // cw stops at the end of the word
    try expectText(&ed, "    X bar baz");
    try ed.feed("wciwY<Esc>");
    try expectText(&ed, "    X Y baz");
    try ed.feed("ccnew<Esc>"); // cc keeps the indent
    try expectText(&ed, "    new");
    try ed.feed("0wCz<Esc>");
    try expectText(&ed, "    z");
}

test "text objects" {
    var ed = try testEditor("call(a, \"str ing\", [1, 2])");
    defer ed.deinit();
    try ed.feed("fsdi\"");
    try expectText(&ed, "call(a, \"\", [1, 2])");
    try ed.feed("f1ci[x<Esc>");
    try expectText(&ed, "call(a, \"\", [x])");
    try ed.feed("0f,da(");
    try expectText(&ed, "call");
}

test "f, t, ; and ," {
    var ed = try testEditor("a.b.c.d");
    defer ed.deinit();
    try ed.feed("f.");
    try testing.expectEqual(1, ed.view.cursor);
    try ed.feed(";;");
    try testing.expectEqual(5, ed.view.cursor);
    try ed.feed(",");
    try testing.expectEqual(3, ed.view.cursor);
    try ed.feed("0dt.");
    try expectText(&ed, ".b.c.d");
}

test "dot repeats changes, including inserts" {
    var ed = try testEditor("a1 a2 a3 a4");
    defer ed.deinit();
    try ed.feed("dw..");
    try expectText(&ed, "a4");
    try ed.feed("A!<Esc>.");
    try expectText(&ed, "a4!!");

    var ed2 = try testEditor("x\nx\nx");
    defer ed2.deinit();
    try ed2.feed("ciwyes<Esc>j.j.");
    try expectText(&ed2, "yes\nyes\nyes");
}

test "undo groups whole commands; redo; [+] clears at the saved state" {
    var ed = try testEditor("abc");
    defer ed.deinit();
    try ed.feed("Adef<Esc>");
    try testing.expect(ed.buffer.modified);
    try ed.feed("x");
    try expectText(&ed, "abcde");
    try ed.feed("u");
    try expectText(&ed, "abcdef");
    try ed.feed("u");
    try expectText(&ed, "abc");
    try testing.expect(!ed.buffer.modified);
    try ed.feed("<C-r><C-r>");
    try expectText(&ed, "abcde");
}

test "visual mode operators" {
    var ed = try testEditor("hello world\nsecond line\nthird");
    defer ed.deinit();
    try ed.feed("wvlld");
    try expectText(&ed, "hello ld\nsecond line\nthird");
    try ed.feed("jVy");
    try ed.feed("Gp");
    try expectText(&ed, "hello ld\nsecond line\nthird\nsecond line");
    try ed.feed("ggVjd");
    try expectText(&ed, "third\nsecond line");
    try ed.feed("viwU");
    try expectText(&ed, "THIRD\nsecond line");
}

test "registers: named, append, black hole" {
    var ed = try testEditor("alpha beta");
    defer ed.deinit();
    try ed.feed("\"ayiww\"Ayiw");
    try testing.expectEqualStrings("alphabeta", ed.registers.get('a').?.text);
    try ed.feed("\"_dw"); // black hole: the unnamed register still points at "a
    try testing.expectEqualStrings("alphabeta", ed.registers.get(null).?.text);
    try ed.feed("$\"ap");
    try expectText(&ed, "alpha alphabeta");
}

test "macros" {
    var ed = try testEditor("1\n2\n3\n4");
    defer ed.deinit();
    try ed.feed("qaA.<Esc>jq");
    try testing.expectEqual(null, ed.macro_register);
    try ed.feed("2@a");
    try expectText(&ed, "1.\n2.\n3.\n4");
    try ed.feed("@@");
    try expectText(&ed, "1.\n2.\n3.\n4.");
}

test "J, r, ~, >>, %" {
    var ed = try testEditor("foo(\n    bar)\nx");
    defer ed.deinit();
    try ed.feed("J");
    try expectText(&ed, "foo( bar)\nx");
    try ed.feed("0");
    try ed.runCommand(commands.get("replace_char")); // no key of its own anymore
    try ed.feed("F");
    try expectText(&ed, "Foo( bar)\nx");
    try ed.feed("l~");
    try expectText(&ed, "FOo( bar)\nx");
    try ed.feed(">>");
    try expectText(&ed, "    FOo( bar)\nx");
    try ed.feed("0%"); // first bracket on the line is '(' at 7; its partner is at 12
    try testing.expectEqual(12, ed.view.cursor);
    try ed.feed("<lt><lt>");
    try expectText(&ed, "FOo( bar)\nx");
}

test "search: incremental /, n, N, *, Esc restores, d/ as motion" {
    var ed = try testEditor("alpha beta\ngamma beta\nbeta alpha");
    defer ed.deinit();
    try ed.feed("/bet");
    try testing.expectEqual(.search, ed.mode);
    try testing.expectEqual(6, ed.view.cursor); // jumped while typing
    try ed.feed("<Esc>");
    try testing.expectEqual(0, ed.view.cursor); // restored
    try ed.feed("/beta<CR>");
    try testing.expectEqual(6, ed.view.cursor);
    try ed.feed("n");
    try testing.expectEqual(17, ed.view.cursor);
    try ed.feed("nn"); // wraps to the first match
    try testing.expectEqual(6, ed.view.cursor);
    try ed.feed("N");
    try testing.expectEqual(22, ed.view.cursor);
    try ed.feed("?gam<CR>");
    try testing.expectEqual(11, ed.view.cursor);
    try ed.feed("gg*"); // word under cursor: alpha
    try testing.expectEqual(27, ed.view.cursor);
    try ed.feed("ggdn"); // deletes up to the next "alpha"
    try expectText(&ed, "alpha");
}

test "search buffer picker jumps to the line" {
    var ed = try testEditor("one\ntwo\nthree");
    defer ed.deinit();
    try ed.feed("<Space>ssthr<CR>");
    try expectCursor(&ed, 2, 0);
}

test "il / al line objects (nvim's vil / val)" {
    var ed = try testEditor("first\n    second line  \nthird");
    defer ed.deinit();
    try ed.feed("jvild");
    try expectText(&ed, "first\n      \nthird");
    try ed.feed("u");
    try ed.feed("cilnew<Esc>");
    try expectText(&ed, "first\n    new  \nthird");
    try ed.feed("yal");
    try testing.expectEqualStrings("first\n    new  \nthird\n", ed.registers.get(null).?.text);
    try ed.feed("valc"); // change everything
    try ed.feed("gone<Esc>");
    try expectText(&ed, "gone");
}

test "snipe: jumps when one match is left, RET takes the first, n continues" {
    var ed = try testEditor("foo bar baz\nqux bar");
    defer ed.deinit();
    try ed.feed("sba");
    try testing.expectEqual(.search, ed.mode); // three matches: keep typing
    try ed.feed("z");
    try testing.expectEqual(.normal, ed.mode); // only "baz" left: jumped
    try testing.expectEqual(8, ed.view.cursor);

    try ed.feed("ggsbar<CR>");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed("n");
    try testing.expectEqual(16, ed.view.cursor);

    try ed.feed("ggsq<Esc>"); // only one 'q': jumps on the first key
    try testing.expectEqual(12, ed.view.cursor);
    try ed.feed("gg");
    try ed.feed("sw<Esc>"); // no 'w' anywhere: Esc puts the cursor back
    try testing.expectEqual(0, ed.view.cursor);
    try testing.expectEqual(.normal, ed.mode);
}

test "snipe and / work after an operator" {
    var ed = try testEditor("alpha beta gamma");
    defer ed.deinit();
    try ed.feed("dsg");
    try expectText(&ed, "gamma");
    try ed.feed("u0d/mm<CR>");
    try expectText(&ed, "mma");
}

test "applyEdits: a rename's edits land bottom-up as one undo step" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-rename.zig");
    try ed.insertAt(0, "const foo = 1;\nconst bar = foo + foo;");
    try ed.buffer.history.commit(ed.gpa);
    var p1 = "edit-test-rename.zig".*;
    var p2 = "edit-test-rename.zig".*;
    var p3 = "edit-test-rename.zig".*;
    var n1 = "total".*;
    var n2 = "total".*;
    var n3 = "total".*;
    const edits = [_]Lsp.TextEdit{
        .{ .path = &p1, .start_line = 0, .start_col = 6, .end_line = 0, .end_col = 9, .text = &n1 },
        .{ .path = &p2, .start_line = 1, .start_col = 12, .end_line = 1, .end_col = 15, .text = &n2 },
        .{ .path = &p3, .start_line = 1, .start_col = 18, .end_line = 1, .end_col = 21, .text = &n3 },
    };
    try ed.applyEdits(&edits);
    try expectText(&ed, "const total = 1;\nconst bar = total + total;");
    try ed.feed("u");
    try expectText(&ed, "const foo = 1;\nconst bar = foo + foo;");
}

test "SPC q s saves every modified buffer, then quits; SPC q q checks all buffers" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const a = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{dir});
    defer gpa.free(a);
    const b = try std.fmt.allocPrint(gpa, "{s}/b.txt", .{dir});
    defer gpa.free(b);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(a);
    try ed.feed("ialpha<Esc>");
    try ed.openFile(b);
    try ed.feed("ibeta<Esc><Space>bp"); // back to a.txt, which is saved? no: both modified
    try ed.feed("<Space>qq");
    try testing.expect(!ed.should_quit); // b.txt is unsaved even though a.txt is current
    try ed.feed("<Space>qs");
    try testing.expect(ed.should_quit);

    const saved_a = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(saved_a);
    try testing.expectEqualStrings("alpha\n", saved_a);
    const saved_b = try tmp.dir.readFileAlloc(io, "b.txt", gpa, .limited(64));
    defer gpa.free(saved_b);
    try testing.expectEqualStrings("beta\n", saved_b);
}

test "syntax text objects: dif, daa, cia, vac" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-objects.zig"); // missing file: empty, but zig syntax
    try ed.insertAt(0, "fn f(a: u8, b: u8) void {\n    g(a, b);\n}");
    try ed.buffer.history.commit(ed.gpa);
    try ed.feed("fbdaa"); // on the parameter `b`: takes ", b: u8"
    try expectText(&ed, "fn f(a: u8) void {\n    g(a, b);\n}");
    try ed.feed("j^facia"); // first call argument
    try ed.feed("x<Esc>");
    try expectText(&ed, "fn f(a: u8) void {\n    g(x, b);\n}");
    try ed.feed("dif");
    try expectText(&ed, "fn f(a: u8) void {\n}");
    try ed.feed("u");
    try ed.feed("ggvac");
    try testing.expectEqual(.visual, ed.mode); // no class here: selection unchanged
}

test "dit / dat / cit on tags" {
    var ed = try testEditor("<ul><li>one</li><li>two</li></ul>");
    defer ed.deinit();
    try ed.feed("fndit");
    try expectText(&ed, "<ul><li></li><li>two</li></ul>");
    try ed.feed("fwcitTWO<Esc>");
    try expectText(&ed, "<ul><li></li><li>TWO</li></ul>");
    try ed.feed("0fOdat");
    try expectText(&ed, "<ul><li></li></ul>");
    try ed.feed("04ld2it"); // on <li>: li is level 1, ul level 2
    try expectText(&ed, "<ul></ul>");
}

test "SPC c l without a language server: tree-sitter outline picker" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-symbols.zig");
    try ed.insertAt(0, "const A = struct {\n    fn one() void {}\n};\nfn two() void {}");
    try ed.buffer.history.commit(ed.gpa);
    try ed.feed("<Space>cl");
    try testing.expectEqual(.symbols, ed.picker.?.kind);
    try ed.feed("one<CR>");
    try expectCursor(&ed, 1, 4);
}

test "zz / zt / zb place the cursor line in the view" {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    for (0..100) |i| try lines.print(testing.allocator, "line {d}\n", .{i});
    var ed = try testEditor(lines.items[0 .. lines.items.len - 1]);
    defer ed.deinit();
    ed.setViewSize(21, 80);
    try ed.feed("50G");
    try ed.feed("zt");
    try testing.expectEqual(49 - ed.effectiveScrolloff(), ed.view.top);
    try ed.feed("zb");
    try testing.expectEqual(49 + ed.effectiveScrolloff() + 1 - 21, ed.view.top);
    try ed.feed("zz");
    try testing.expectEqual(49 - 10, ed.view.top);
    try ed.feed("80zz"); // count: center line 80
    try testing.expectEqual(79, ed.cursorLine());
    try testing.expectEqual(79 - 10, ed.view.top);
    try ed.feed("gg");
    try ed.feed("zz"); // can't scroll above the first line
    try testing.expectEqual(0, ed.view.top);
}

test "folds: zc/zo/za, j/k skip closed folds, dd deletes a fold, zf makes one" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-folds.zig");
    try ed.insertAt(0, "fn a() void {\n    x();\n    y();\n}\nfn b() void {}\nconst z = 1;");
    try ed.buffer.history.commit(ed.gpa);

    try ed.feed("jzc"); // inside a's body: closes the function (lines 0-3)
    try testing.expectEqual(Folds.Lines{ .first = 0, .last = 3 }, ed.foldAt(1).?);
    try testing.expectEqual(0, ed.cursorLine()); // moved to the fold's first line
    try ed.feed("j");
    try testing.expectEqual(4, ed.cursorLine()); // skipped the hidden lines
    try ed.feed("k");
    try testing.expectEqual(0, ed.cursorLine());
    try ed.feed("za");
    try testing.expectEqual(null, ed.foldAt(1));
    try ed.feed("za");
    try ed.feed("dd"); // deletes the whole closed fold
    try expectText(&ed, "fn b() void {}\nconst z = 1;");
    try ed.feed("u");
    try ed.feed("zR");
    try testing.expectEqual(null, ed.foldAt(1));

    try ed.feed("Gzfk"); // manual fold over the last two lines
    try testing.expectEqual(Folds.Lines{ .first = 4, .last = 5 }, ed.foldAt(5).?);
    try ed.feed("/z = <CR>"); // a search into a fold opens it
    try testing.expectEqual(null, ed.foldAt(5));
    try testing.expectEqual(5, ed.cursorLine());
}

test "zc on a struct's first line folds the struct" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-struct-fold.zig");
    try ed.insertAt(0, "const Foo = struct {\n    a: u8,\n    fn f() void {\n        g();\n    }\n};\nconst x = 1;");
    try ed.buffer.history.commit(ed.gpa);
    try ed.feed("zc");
    try testing.expectEqual(Folds.Lines{ .first = 0, .last = 5 }, ed.foldAt(1).?);
    try ed.feed("zo3Gzc"); // inside the method: its fold, not the struct's
    try testing.expectEqual(Folds.Lines{ .first = 2, .last = 4 }, ed.foldAt(3).?);
    try ed.feed("zc"); // again: the next level out, the struct
    try testing.expectEqual(Folds.Lines{ .first = 0, .last = 5 }, ed.foldAt(3).?);
}
