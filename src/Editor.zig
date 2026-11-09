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
const diff = @import("git/diff.zig");
const Git = @import("git/Git.zig");
const GitJob = @import("git/Job.zig");
const Lsp = @import("lsp/Lsp.zig");
const Completion = @import("lsp/Completion.zig");
const syntax_objects = @import("syntax/objects.zig");
const operators = @import("operators.zig");
const pairs = @import("pairs.zig");
pub const Windows = @import("Windows.zig");
pub const Terminal = @import("terminal/Terminal.zig");
const Pty = @import("terminal/Pty.zig");
const RunMemory = @import("terminal/RunMemory.zig");
pub const run_errors_mod = @import("terminal/errors.zig");
const textobjects = @import("core/textobjects.zig");

const Editor = @This();

pub const Mode = km.Mode;

pub const Options = struct {
    tab_width: usize = 4,
    /// Insert spaces for <Tab> in insert mode.
    expand_tab: bool = true,
    /// Lines kept visible above/below the cursor.
    scrolloff: usize = 4,
    // Toggles (SPC t ...):
    /// Show deleted/changed HEAD lines as ghost lines.
    ghost_lines: bool = true,
    /// Line numbers relative to the cursor line.
    relative_numbers: bool = false,
    /// Diagnostic messages after the end of lines.
    diagnostic_text: bool = true,
    /// Close brackets and quotes as they are typed.
    auto_pairs: bool = true,
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
    /// When set, the top row is this ghost line shown before line `top`.
    top_ghost: ?u32 = null,
};

/// A screen row: a text line (a closed fold counts as one), or one of the
/// ghost lines (old HEAD lines of a git hunk) shown before text line `line`.
pub const Row = struct {
    line: usize,
    ghost: ?u32 = null,

    pub fn eql(a: Row, b: Row) bool {
        return a.line == b.line and a.ghost == b.ghost;
    }

    /// Whether `a` is above `b` on screen.
    pub fn before(a: Row, b: Row) bool {
        if (a.line != b.line) return a.line < b.line;
        const ka = a.ghost orelse return false;
        const kb = b.ghost orelse return true;
        return ka < kb;
    }
};

/// The cursor while it is on a ghost line (read-only; yankable).
pub const GhostCursor = struct {
    /// The text line the ghost lines are shown before.
    line: usize,
    /// Which ghost line.
    k: u32,
    /// Byte column in the ghost line.
    col: usize,
    /// Visual selection over ghost lines: the anchor's index.
    anchor: ?u32 = null,
};

/// A place in the jumplist. `buffer` is null once that buffer is closed;
/// `path` (owned) reopens it.
pub const Jump = struct {
    buffer: ?*Buffer,
    path: ?[]u8,
    pos: usize,
};

/// A cursor besides the primary one: position, visual anchor, wanted column.
pub const Cursor = struct {
    pos: usize,
    anchor: usize,
    want_col: ?usize = null,
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
    /// Where the cursor was if that was a ghost line.
    origin_ghost: ?GhostCursor = null,
    return_mode: Mode,
    had_highlight: bool,
    kind: PromptKind = .search,
};

pub const PromptKind = enum {
    /// `/` `?`: incremental search.
    search,
    /// `s`: jump as soon as only one match is left on screen.
    snipe,
    /// `SPC c r`: the new name for the symbol at `origin`.
    rename,
    /// Git: the commit message (commits all changes).
    git_commit,
    /// Git: the URL for remote `origin`.
    git_remote,
    /// File operations (`SPC f`): the path to open, save to, move to, copy to.
    new_file,
    save_as,
    rename_file,
    copy_file,
    /// `SPC r c`: any command; `SPC r r`: the code runner (prefilled with the
    /// project's last command, so <CR> runs it again).
    run_command,
    run_runner,

    /// One-line prompts shown in a centered box (not incremental searches).
    pub fn boxed(k: PromptKind) bool {
        return k != .search and k != .snipe;
    }

    pub fn title(k: PromptKind) []const u8 {
        return switch (k) {
            .search, .snipe => "",
            .rename => "Rename symbol",
            .git_commit => "Commit message (commits all changes)",
            .git_remote => "Remote URL (origin)",
            .new_file => "New file (path)",
            .save_as => "Save as",
            .rename_file => "Rename / move file to",
            .copy_file => "Copy file to",
            .run_command => "Run command",
            .run_runner => "Code runner (Enter runs it again)",
        };
    }
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
/// Window splits. The focused window's live state is `buffer` and `view`.
windows: Windows,
window: *Windows.Window,
/// Every window in reading order (rebuilt when the layout changes).
window_list: std.ArrayList(*Windows.Window) = .empty,
/// Bumped on every buffer switch, for most-recently-used ordering.
use_counter: u64 = 0,
view: View = .{},
mode: Mode = .normal,
keymap: km.Keymap,

picker: ?*Picker = null,
/// The last closed picker, for `resume_picker`.
resume_kind: ?Picker.Kind = null,
resume_query: std.ArrayList(u8) = .empty,
/// The folder the file browser (`SPC .`) shows: absolute, no trailing slash
/// (except the root), and its display form ("~/src/").
browse_dir: std.ArrayList(u8) = .empty,
browse_label: std.ArrayList(u8) = .empty,
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
/// Extra cursors (multicursor); the primary one is `view`. Each command
/// typed at the primary is replayed at each of these (see `replayAtCursors`).
cursors: std.ArrayList(Cursor) = .empty,
/// Keys of the command in progress at the primary, and the mode it began in.
multi_keys: std.ArrayList(KeyEvent) = .empty,
multi_start: struct { mode: Mode = .normal, visual_line: bool = false } = .{},
/// The command in progress runs at the primary only (undo, pickers, ...).
multi_once: bool = false,
/// Replaying a command at the extra cursors.
replaying: bool = false,
/// The primary cursor, set aside while replaying (edits still shift it).
primary_saved: ?Cursor = null,
/// The terminal popup's shell (`SPC o t`), kept running while hidden.
shell: ?*Terminal = null,
/// The last command run (`SPC r`), its terminal, and when it started.
run: ?*Terminal = null,
run_command: ?[]u8 = null,
run_started: Io.Timestamp = .zero,
/// The end of the run was reported (printed under its output).
run_reported: bool = true,
/// Errors found in the last run's output (`SPC r e`).
run_errors: std.ArrayList(run_errors_mod.Error) = .empty,
/// Which terminal the popup shows, if open. Keys go to it.
popup: ?enum { shell, run } = null,
/// The popup's size, kept current by the UI (new terminals start at it).
term_size: Pty.Size = .{ .cols = 80, .rows = 24 },
/// Terminal default colors (the UI sets them from the theme).
term_fg: ?Terminal.Rgb = null,
term_bg: ?Terminal.Rgb = null,
/// Where the code runner remembers commands (null: the default location).
run_memory_path: ?[]u8 = null,
/// Jumplist (`<C-o>` / `<C-i>`, `SPC s j`): places left by jumps, oldest
/// first. `jump_index` is the entry being visited, or `jumps.len` when not
/// moving through the list.
jumps: std.ArrayList(Jump) = .empty,
jump_index: usize = 0,
/// Surround in progress: the range `ys` will wrap, the pair `cs` replaces.
surround_range: operators.Range = .{ .start = 0, .end = 0 },
surround_from: u21 = 0,
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
/// The buffer a Yes/No confirmation (`SPC f D`) is about.
confirm_target: ?*Buffer = null,
/// Results of the last definition/references request, for the picker.
locations: std.ArrayList(Lsp.Location) = .empty,
/// Hover text shown near the cursor until the next key.
hover: ?[]u8 = null,
completion: ?Completion = null,
/// Word start a completion was last requested for (avoids re-asking per key).
completion_asked: ?usize = null,

/// Repository root (found the first time a file opens), and whether we looked.
git_root: ?[]u8 = null,
git_checked: bool = false,
/// Set while the cursor is on a ghost line.
ghost: ?GhostCursor = null,
/// The git command running in the background, if any.
git_job: ?*GitJob = null,

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
    var windows = try Windows.init(gpa, scratch);
    errdefer windows.deinit();
    var window_list: std.ArrayList(*Windows.Window) = .empty;
    try window_list.append(gpa, windows.root.kind.window);
    return .{
        .windows = windows,
        .window = windows.root.kind.window,
        .window_list = window_list,
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
    if (ed.shell) |t| t.destroy();
    if (ed.run) |t| t.destroy();
    if (ed.run_command) |cmd| ed.gpa.free(cmd);
    for (ed.run_errors.items) |e| e.deinit(ed.gpa);
    ed.run_errors.deinit(ed.gpa);
    if (ed.run_memory_path) |path| ed.gpa.free(path);
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
    ed.windows.deinit();
    ed.window_list.deinit(ed.gpa);
    ed.resume_query.deinit(ed.gpa);
    ed.browse_dir.deinit(ed.gpa);
    ed.browse_label.deinit(ed.gpa);
    ed.registers.deinit();
    if (ed.git_job) |j| j.destroy();
    if (ed.git_root) |r| ed.gpa.free(r);
    if (ed.search_prompt) |*sp| sp.input.deinit(ed.gpa);
    ed.last_search.deinit(ed.gpa);
    ed.change_keys.deinit(ed.gpa);
    ed.cursors.deinit(ed.gpa);
    ed.multi_keys.deinit(ed.gpa);
    for (ed.jumps.items) |j| if (j.path) |p| ed.gpa.free(p);
    ed.jumps.deinit(ed.gpa);
    ed.last_change.deinit(ed.gpa);
    ed.macro_keys.deinit(ed.gpa);
    ed.queue.deinit(ed.gpa);
    ed.gpa.free(ed.cwd);
    ed.keymap.deinit();
    ed.* = undefined;
}

/// Reparses the current buffer and highlights the lines its view shows,
/// and refreshes its git diff (each window calls this before drawing).
pub fn highlightView(ed: *Editor) void {
    ed.updateGit();
    if (ed.buffer.syntax) |*s| {
        const t = ed.text();
        s.update(t);
        const first = @min(ed.view.top, t.lineCount() - 1);
        // With closed folds the screen reaches past `top + rows` raw lines.
        const last_visible = ed.stepVisible(first, @intCast(ed.view.rows));
        const last = if (ed.foldAt(last_visible)) |f| f.last else last_visible;
        s.highlight(ed.gpa, t, t.lineStart(first), t.lineEnd(last)) catch {};
    }
}

/// State set aside while drawing an unfocused window (`peekWindow`).
pub const Peek = struct {
    buffer: *Buffer,
    view: View,
    ghost: ?GhostCursor,
    mode: Mode,
    cursors: usize,
};

/// Shows `w`'s buffer and view as current, for drawing it. Undo with `unpeekWindow`.
pub fn peekWindow(ed: *Editor, w: *Windows.Window) Peek {
    const saved: Peek = .{ .buffer = ed.buffer, .view = ed.view, .ghost = ed.ghost, .mode = ed.mode, .cursors = ed.cursors.items.len };
    ed.buffer = w.buffer;
    ed.view = w.view;
    ed.view.cursor = @min(ed.view.cursor, ed.text().len());
    ed.ghost = null;
    ed.mode = .normal;
    ed.cursors.items.len = 0;
    return saved;
}

pub fn unpeekWindow(ed: *Editor, p: Peek) void {
    ed.buffer = p.buffer;
    ed.view = p.view;
    ed.ghost = p.ghost;
    ed.mode = p.mode;
    ed.cursors.items.len = p.cursors;
}

/// Per-frame housekeeping: reparses and highlights the visible lines, and
/// picks up picker results from the worker.
pub fn tick(ed: *Editor) void {
    ed.tickLsp();
    ed.pollGitJob();
    ed.pollTerminals();
    ed.highlightView();
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
    if (ed.popupKey(ev)) return;
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
    // Ghost rows must reflect the latest edits (macros and `.` replay many
    // keys between frames). Cheap when nothing changed.
    ed.updateGit();
    // Hover text disappears on the next key.
    if (ed.hover) |h| {
        ed.gpa.free(h);
        ed.hover = null;
    }
    if (ed.mode != .insert and ed.mode != .picker and ed.mode != .search and ed.showcmd_len < ed.showcmd.len) {
        ed.showcmd[ed.showcmd_len] = ev;
        ed.showcmd_len += 1;
    }
    const multi = ed.cursors.items.len > 0;
    if (multi) {
        if (ed.multi_keys.items.len == 0) {
            ed.multi_start = .{ .mode = ed.mode, .visual_line = ed.visual_line };
            ed.multi_once = false;
        }
        ed.multi_keys.append(ed.gpa, ev) catch {};
    }
    ed.handleKeyInner(ev) catch |err| {
        ed.setMessage(.err, "error: {s}", .{@errorName(err)});
        ed.resetCommand();
    };
    if (multi) ed.multiAfterKey();
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
        // `Q` while recording stops the recording.
        if (cp == 'Q' and ed.mode == .normal and ed.macro_register != null) return ed.stopMacro();
    }

    // Start capturing a possible change for `.`.
    if (ed.mode == .normal and !ed.capturing and !ed.replaying and ed.pending_len == 0) {
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
            // Leader menus, undo, `.` and the like act once, not per cursor.
            if (cmd.jump and !ed.replaying and (ed.mode == .normal or ed.mode == .visual)) ed.pushJump();
            if (cmd.once or (seq.len > 1 and seq[0].key == .codepoint and seq[0].key.codepoint == ' ')) ed.multi_once = true;
            ed.pending_len = 0;
            ed.count = 0;
            ed.register = null;
            if (ed.ghost != null and !cmd.ghost) {
                // Ghost lines are read-only; other commands act on the text.
                if (cmd.repeat or ed.mode == .operator) {
                    ed.resetCommand();
                    return ed.setMessage(.err, "ghost lines are read-only: yy copies, SPC g r restores", .{});
                }
                ed.ghost = null;
                if (ed.mode == .visual) ed.exitVisual();
            }
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
                    if (!try pairs.typed(ed, cp)) try ed.insertCodepoint(cp);
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
    if (ed.cursors.items.len > 0 or ed.replaying) return; // completion is single-cursor
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
// Git

/// Loads `b`'s HEAD version for diffing, if it is tracked in a repository.
fn loadGitBase(ed: *Editor, b: *Buffer) void {
    const path = b.path orelse return;
    if (!ed.git_checked) {
        ed.git_checked = true;
        ed.git_root = Git.repoRoot(ed.gpa, ed.io, ed.cwd);
    }
    const root = ed.git_root orelse return;
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    const raw = Git.headVersion(ed.gpa, ed.io, root, abs) orelse return;
    defer ed.gpa.free(raw);
    const norm = Git.normalize(ed.gpa, raw) catch return;
    defer ed.gpa.free(norm);
    const base = Text.init(ed.gpa, norm) catch return;
    if (b.git) |*g| g.deinit(ed.gpa);
    b.git = .{ .base = base };
}

// Simple git actions (SPC g g): each runs in the background.

/// Whether we are in a repository (says so if not).
pub fn inRepo(ed: *Editor) bool {
    if (!ed.git_checked) {
        ed.git_checked = true;
        ed.git_root = Git.repoRoot(ed.gpa, ed.io, ed.cwd);
    }
    if (ed.git_root != null) return true;
    ed.setMessage(.info, "not in a git repository", .{});
    return false;
}

fn startGitJob(ed: *Editor, kind: GitJob.Kind, busy: []const u8, steps: []const []const []const u8) !void {
    if (!ed.inRepo()) return;
    if (ed.git_job != null) return ed.setMessage(.info, "git is still busy...", .{});
    ed.git_job = try GitJob.start(ed.gpa, ed.io, kind, ed.git_root.?, steps, ed.wake_fn);
    ed.setMessage(.info, "git: {s}...", .{busy});
}

/// Reports a finished job and refreshes what it changed.
fn pollGitJob(ed: *Editor) void {
    const job = ed.git_job orelse return;
    if (!job.done.load(.acquire)) return;
    ed.git_job = null;
    defer job.destroy();
    if (!job.ok) {
        const hint: []const u8 = if (job.kind == .push and std.mem.indexOf(u8, job.message, "origin") != null)
            "  (set one with SPC g g > Set remote URL)"
        else
            "";
        return ed.setMessage(.err, "git: {s}{s}", .{ job.message, hint });
    }
    switch (job.kind) {
        .commit => ed.setMessage(.info, "committed: {s}", .{job.message}),
        .push => ed.setMessage(.info, "pushed", .{}),
        .pull => ed.setMessage(.info, "pulled: {s}", .{job.message}),
        .switch_branch, .create_branch => ed.setMessage(.info, "{s}", .{job.message}),
        .set_remote => ed.setMessage(.info, "remote origin set", .{}),
    }
    // Files may have changed on disk; HEAD has moved.
    if (job.kind == .pull or job.kind == .switch_branch or job.kind == .create_branch) ed.reloadFromDisk();
    ed.reloadGit();
}

/// Re-reads every unmodified buffer from disk (after a pull or branch switch).
fn reloadFromDisk(ed: *Editor) void {
    for (ed.buffers.items) |b| {
        if (b.path == null or b.modified) continue;
        ed.reloadBuffer(b) catch continue;
    }
}

/// Replaces `b`'s text with the file on disk (discarding unsaved changes).
pub fn reloadBuffer(ed: *Editor, b: *Buffer) !void {
    const path = b.path orelse return error.NoPath;
    var fresh = try Buffer.load(ed.gpa, ed.io, path);
    const cursor = if (b == ed.buffer) ed.view.cursor else b.saved.cursor;
    ed.lspCloseBuffer(b);
    const saved = b.saved;
    const last_used = b.last_used;
    b.deinit(ed.gpa);
    fresh.saved = saved;
    fresh.last_used = last_used;
    b.* = fresh;
    ed.loadGitBase(b);
    for (ed.window_list.items) |w| if (w != ed.window and w.buffer == b) {
        w.view.cursor = @min(w.view.cursor, b.text.len());
        w.view.anchor = w.view.cursor;
    };
    if (b == ed.buffer) {
        ed.cursors.clearRetainingCapacity();
        ed.setCursor(@min(cursor, b.text.len()));
    }
}

/// Commit: asks for a message (saving open files first).
pub fn gitCommitPrompt(ed: *Editor) void {
    if (!ed.inRepo()) return;
    ed.startSearch(true, .git_commit);
}

fn finishGitCommit(ed: *Editor) !void {
    const message = try ed.takePromptText() orelse return;
    defer ed.gpa.free(message);
    if (std.mem.trim(u8, message, " ").len == 0) return ed.setMessage(.info, "commit cancelled: empty message", .{});
    // Commit what you see: save modified files first.
    for (ed.buffers.items) |b| if (b.modified and b.path != null) {
        _ = b.save(ed.gpa, ed.io) catch {};
        if (ed.lspFor(b)) |l| l.didSave(b);
    };
    try ed.startGitJob(.commit, "committing", &.{
        &.{ "git", "add", "-A" },
        &.{ "git", "commit", "-m", message },
    });
}

pub fn gitPush(ed: *Editor) !void {
    try ed.startGitJob(.push, "pushing", &.{&.{ "git", "push", "-u", "origin", "HEAD" }});
}

pub fn gitPull(ed: *Editor) !void {
    try ed.startGitJob(.pull, "pulling", &.{&.{ "git", "pull", "--ff-only" }});
}

pub fn gitSwitch(ed: *Editor, name: []const u8, create: bool) !void {
    if (create) {
        try ed.startGitJob(.create_branch, "creating branch", &.{&.{ "git", "switch", "-c", name }});
    } else {
        try ed.startGitJob(.switch_branch, "switching branch", &.{&.{ "git", "switch", name }});
    }
}

/// Set remote: asks for the URL, prefilled with the current one.
pub fn gitRemotePrompt(ed: *Editor) !void {
    if (!ed.inRepo()) return;
    ed.startSearch(true, .git_remote);
    if (Git.originUrl(ed.gpa, ed.io, ed.git_root.?)) |url| {
        defer ed.gpa.free(url);
        try ed.search_prompt.?.input.set(ed.gpa, url);
    }
}

fn finishGitRemote(ed: *Editor) !void {
    const url = try ed.takePromptText() orelse return;
    defer ed.gpa.free(url);
    const trimmed = std.mem.trim(u8, url, " ");
    if (trimmed.len == 0) return;
    const has_origin = if (Git.originUrl(ed.gpa, ed.io, ed.git_root.?)) |u| blk: {
        ed.gpa.free(u);
        break :blk true;
    } else false;
    if (has_origin) {
        try ed.startGitJob(.set_remote, "setting remote", &.{&.{ "git", "remote", "set-url", "origin", trimmed }});
    } else {
        try ed.startGitJob(.set_remote, "adding remote", &.{&.{ "git", "remote", "add", "origin", trimmed }});
    }
}

/// Closes a boxed prompt and returns its text (owned), restoring the mode.
fn takePromptText(ed: *Editor) !?[]u8 {
    var sp = ed.search_prompt orelse return null;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.view.cursor = sp.origin;
    return try ed.gpa.dupe(u8, sp.input.items());
}

/// Re-reads HEAD for every buffer (after committing outside the editor).
pub fn reloadGit(ed: *Editor) void {
    for (ed.buffers.items) |b| {
        if (b.git) |*g| g.deinit(ed.gpa);
        b.git = null;
        ed.loadGitBase(b);
    }
    ed.updateGit();
}

/// Recomputes the current buffer's diff if it changed.
pub fn updateGit(ed: *Editor) void {
    const b = ed.buffer;
    if (b.git) |*g| g.update(ed.gpa, &b.text, b.edit_version) catch {};
    ed.validateGhost();
}

/// The hunk at the cursor: the one whose ghost line it is on, whose new lines
/// contain its line, or a deletion right next to it.
pub fn hunkAtCursor(ed: *Editor) ?diff.Hunk {
    if (ed.ghost) |g| return ed.ghostHunk(g.line);
    const g = ed.buffer.git orelse return null;
    const line = ed.cursorLine();
    for (g.hunks.items) |h| {
        if (h.new_count > 0 and line >= h.new_start and line < h.new_start + h.new_count) return h;
        if (h.new_count == 0 and (line == h.new_start or line + 1 == h.new_start)) return h;
    }
    return null;
}

/// Puts a hunk's HEAD text back in place of the buffer's version (undoable).
pub fn restoreHunk(ed: *Editor, h: diff.Hunk) !void {
    const g = &(ed.buffer.git orelse return);
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(ed.gpa);
    for (0..h.old_count) |i| {
        if (i > 0) try old.append(ed.gpa, '\n');
        try old.appendSlice(ed.gpa, g.baseLine(h.old_start + i));
    }
    ed.ghost = null;
    const t = ed.text();
    if (h.new_count > 0) {
        var start = t.lineStart(h.new_start);
        var end = t.lineEnd(h.new_start + h.new_count - 1);
        if (h.old_count == 0) {
            // Pure addition: remove the lines and one line break.
            if (end < t.len()) end += 1 else if (start > 0) start -= 1;
            try ed.deleteRange(start, end);
        } else {
            try ed.deleteRange(start, end);
            try ed.insertAt(start, old.items);
        }
    } else if (h.new_start < t.lineCount() and t.len() > 0) {
        try old.append(ed.gpa, '\n');
        try ed.insertAt(t.lineStart(h.new_start), old.items);
    } else {
        const at = t.len();
        if (at > 0) try old.insert(ed.gpa, 0, '\n');
        try ed.insertAt(at, old.items);
    }
    ed.setCursor(motions.firstNonBlank(t, @min(h.new_start, t.lineCount() - 1)));
    ed.updateGit();
}

/// Jumps to the next/previous hunk's first line.
pub fn jumpHunk(ed: *Editor, forward: bool) void {
    const g = ed.buffer.git orelse return ed.setMessage(.info, "not in a git repository", .{});
    const line = ed.cursorLine();
    var target: ?usize = null;
    for (g.hunks.items) |h| {
        const at: usize = h.new_start;
        if (forward and at > line) {
            target = at;
            break;
        }
        if (!forward and at < line) target = at;
    }
    const t = ed.text();
    const l = @min(target orelse return ed.setMessage(.info, "no more changes", .{}), t.lineCount() - 1);
    ed.ghost = null;
    ed.revealLine(l);
    ed.setCursor(motions.firstNonBlank(t, l));
}

/// Yanks ghost lines `from..to` (inclusive) before `line`, linewise.
pub fn yankGhostLines(ed: *Editor, line: usize, from: u32, to: u32, register: ?u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ed.gpa);
    var k = @min(from, to);
    while (k <= @max(from, to)) : (k += 1) {
        try buf.appendSlice(ed.gpa, ed.ghostText(line, k));
        try buf.append(ed.gpa, '\n');
    }
    try ed.registers.store(register, .yank, buf.items, true);
    ed.setMessage(.info, "yanked {d} ghost line(s)", .{@max(from, to) - @min(from, to) + 1});
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
        .origin_ghost = ed.ghost,
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
    if (sp.kind.boxed()) return;
    ed.view.cursor = sp.origin;
    ed.view.top = sp.origin_top;
    ed.ghost = sp.origin_ghost;
    const pattern = search.Pattern.init(sp.input.items(), false);
    if (ed.promptUsesRows(sp)) {
        // Ghost lines on screen: matches in them count too.
        if (sp.kind == .snipe) {
            if (ed.onlyVisibleRowMatch(pattern)) |rp| return ed.finishSearchRow(rp);
        }
        const m = ed.searchRows(pattern, ed.promptOrigin(sp), sp.forward) orelse return;
        ed.setRowPos(m.pos);
        ed.search_highlight = true;
        return;
    }
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
    if (sp.return_mode != .operator) ed.pushJumpAt(sp.origin);
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
    switch (sp.kind) {
        .rename => return ed.finishRename(),
        .git_commit => return ed.finishGitCommit(),
        .git_remote => return ed.finishGitRemote(),
        .new_file, .save_as, .rename_file, .copy_file => |k| return ed.finishFilePrompt(k),
        .run_command, .run_runner => |k| return ed.finishRunPrompt(k),
        .search, .snipe => {},
    }
    if (sp.input.items().len > 0) {
        try ed.last_search.resize(ed.gpa, 0);
        try ed.last_search.appendSlice(ed.gpa, sp.input.items());
        ed.last_search_whole_word = false;
    }
    ed.last_search_forward = sp.forward;
    if (ed.promptUsesRows(sp)) {
        const pattern = search.Pattern.init(ed.last_search.items, false);
        const m = ed.searchRows(pattern, ed.promptOrigin(sp), sp.forward) orelse {
            ed.setMessage(.err, "pattern not found: {s}", .{ed.last_search.items});
            return ed.cancelSearch();
        };
        return ed.finishSearchRow(m.pos);
    }
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
    ed.ghost = sp.origin_ghost;
    ed.search_highlight = sp.had_highlight;
    if (sp.return_mode == .operator) ed.resetCommand();
}

// Search over rows (text and ghost lines), used when ghost lines are shown.

pub const RowPos = struct { row: Row, col: usize };

/// Whether search should include ghost lines: from normal mode, with ghost
/// lines present or the cursor on one (after an operator, text only).
pub fn usesRows(ed: *const Editor) bool {
    return ed.ghost != null or ed.hasGhosts();
}

fn promptUsesRows(ed: *const Editor, sp: *const SearchPrompt) bool {
    return sp.return_mode == .normal and (sp.origin_ghost != null or ed.hasGhosts());
}

fn promptOrigin(ed: *const Editor, sp: *const SearchPrompt) RowPos {
    if (sp.origin_ghost) |g| return .{ .row = .{ .line = g.line, .ghost = g.k }, .col = g.col };
    const t = &ed.buffer.text;
    const line = t.lineOf(sp.origin);
    return .{ .row = .{ .line = line }, .col = sp.origin - t.lineStart(line) };
}

/// The text of a row.
pub fn rowText(ed: *const Editor, r: Row) []const u8 {
    if (r.ghost) |k| return ed.ghostText(r.line, k);
    return ed.buffer.text.lineSlice(@min(r.line, ed.buffer.text.lineCount() - 1));
}

/// Rows in file order including lines inside closed folds (search looks there).
fn nextRowAll(ed: *const Editor, r: Row) Row {
    const n = ed.buffer.text.lineCount();
    if (r.ghost) |k| {
        const h = ed.ghostHunk(r.line) orelse return .{ .line = @min(r.line, n - 1) };
        if (k + 1 < h.old_count) return .{ .line = r.line, .ghost = k + 1 };
        return if (r.line < n) .{ .line = r.line } else r;
    }
    if (ed.ghostHunk(r.line + 1) != null) return .{ .line = r.line + 1, .ghost = 0 };
    return if (r.line + 1 < n) .{ .line = r.line + 1 } else r;
}

fn prevRowAll(ed: *const Editor, r: Row) Row {
    if (r.ghost) |k| {
        if (k > 0) return .{ .line = r.line, .ghost = k - 1 };
        return if (r.line == 0) r else .{ .line = r.line - 1 };
    }
    if (ed.ghostHunk(r.line)) |h| return .{ .line = r.line, .ghost = h.old_count - 1 };
    return if (r.line == 0) r else .{ .line = r.line - 1 };
}

fn firstRowAll(ed: *const Editor) Row {
    return if (ed.ghostHunk(0) != null) .{ .line = 0, .ghost = 0 } else .{ .line = 0 };
}

fn lastRowAll(ed: *const Editor) Row {
    const n = ed.buffer.text.lineCount();
    if (ed.ghostHunk(n)) |h| return .{ .line = n, .ghost = h.old_count - 1 };
    return .{ .line = n - 1 };
}

/// The next match of `p` from `from` over rows in file order, wrapping.
pub fn searchRows(ed: *const Editor, p: search.Pattern, from: RowPos, forward: bool) ?struct { pos: RowPos, wrapped: bool } {
    if (p.needle.len == 0) return null;
    var ghost_total: usize = 0;
    if (ed.buffer.git) |g| for (g.hunks.items) |h| {
        ghost_total += h.old_count;
    };
    const limit = 2 * (ed.buffer.text.lineCount() + ghost_total) + 4;
    var r = from.row;
    var first = true;
    var wrapped = false;
    for (0..limit) |_| {
        const line = ed.rowText(r);
        const m = if (forward)
            (if (first) p.forward(line, from.col + 1) else p.forward(line, 0))
        else
            (if (first) p.backward(line, from.col) else p.backward(line, line.len));
        if (m) |col| return .{ .pos = .{ .row = r, .col = col }, .wrapped = wrapped };
        first = false;
        const next = if (forward) ed.nextRowAll(r) else ed.prevRowAll(r);
        if (next.eql(r)) {
            r = if (forward) ed.firstRowAll() else ed.lastRowAll();
            wrapped = true;
        } else r = next;
    }
    return null;
}

/// The cursor as a row position.
pub fn rowPos(ed: *const Editor) RowPos {
    if (ed.ghost) |g| return .{ .row = .{ .line = g.line, .ghost = g.k }, .col = g.col };
    const t = &ed.buffer.text;
    const line = t.lineOf(ed.view.cursor);
    return .{ .row = .{ .line = line }, .col = ed.view.cursor - t.lineStart(line) };
}

/// Moves the cursor to a row position (opening folds around it).
pub fn setRowPos(ed: *Editor, rp: RowPos) void {
    if (rp.row.ghost) |k| {
        if (rp.row.line > 0) ed.revealLine(rp.row.line - 1);
        const anchor = if (ed.ghost) |g| (if (g.line == rp.row.line) g.anchor else null) else null;
        ed.ghost = .{ .line = rp.row.line, .k = k, .col = rp.col, .anchor = anchor };
        ed.view.want_col = rp.col;
        return;
    }
    ed.ghost = null;
    const t = ed.text();
    ed.revealLine(rp.row.line);
    ed.setCursor(t.lineStart(rp.row.line) + @min(rp.col, t.lineLen(rp.row.line)));
}

/// `n`/`N` over rows: the [count]th match of the last search.
pub fn searchNextRows(ed: *Editor, reverse: bool, count: usize) ?RowPos {
    if (ed.last_search.items.len == 0) {
        ed.setMessage(.err, "no previous search", .{});
        return null;
    }
    const pattern = search.Pattern.init(ed.last_search.items, ed.last_search_whole_word);
    const forward = ed.last_search_forward != reverse;
    var pos = ed.rowPos();
    var wrapped = false;
    for (0..count) |_| {
        const m = ed.searchRows(pattern, pos, forward) orelse {
            ed.setMessage(.err, "pattern not found: {s}", .{ed.last_search.items});
            return null;
        };
        pos = m.pos;
        wrapped = wrapped or m.wrapped;
    }
    ed.search_highlight = true;
    const prefix: u8 = if (ed.last_search_forward) '/' else '?';
    ed.setMessage(.info, "{c}{s}{s}", .{ prefix, ed.last_search.items, if (wrapped) "  search wrapped" else "" });
    return pos;
}

/// The only match of `p` on screen (text and ghost rows), if exactly one.
fn onlyVisibleRowMatch(ed: *const Editor, p: search.Pattern) ?RowPos {
    if (p.needle.len == 0) return null;
    var found: ?RowPos = null;
    var r = ed.topRow();
    for (0..ed.view.rows) |i| {
        if (i > 0) {
            const next = ed.nextRow(r);
            if (next.eql(r)) break;
            r = next;
        }
        const line = ed.rowText(r);
        var at: usize = 0;
        while (p.forward(line, at)) |m| : (at = m + 1) {
            if (found != null) return null;
            found = .{ .row = r, .col = m };
        }
    }
    return found;
}

/// Like `finishSearch`, landing on a row position (possibly a ghost line).
fn finishSearchRow(ed: *Editor, rp: RowPos) !void {
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
    ed.view.top = sp.origin_top;
    if (sp.return_mode != .operator) ed.pushJumpAt(sp.origin);
    ed.setRowPos(rp);
}

/// The pattern to highlight: the prompt while typing, else the last search.
pub fn searchPattern(ed: *const Editor) ?search.Pattern {
    if (ed.search_prompt) |*sp| {
        if (sp.kind.boxed()) return null;
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

/// Waits for the character naming the next step of a surround (`ys`, `ds`,
/// `cs`, visual `S`): runs command `name` with it.
pub fn awaitChar(ed: *Editor, comptime name: []const u8, count: usize) void {
    const cmd = comptime commands.find(name) orelse @compileError("no command " ++ name);
    ed.awaiting_char = .{ .cmd = cmd, .count = count, .has_count = false, .register = null };
}

/// `ys{motion}`: the range is known; the pair character comes next.
pub fn awaitSurroundChar(ed: *Editor, r: operators.Range) void {
    ed.surround_range = r;
    ed.awaitChar("surround_add", 1);
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
    if (ed.ghost) |*g| g.anchor = null;
    ed.placeCursor(ed.view.cursor);
}

/// The visual selection as an operator range (inclusive of the cursor char).
pub fn visualRange(ed: *Editor) operators.Range {
    return ed.selectionRange(ed.view.anchor, ed.view.cursor);
}

/// The visual selection between anchor `a` and cursor `c`.
pub fn selectionRange(ed: *Editor, a: usize, c: usize) operators.Range {
    const t = ed.text();
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
    // Drop the `Q` that stopped the recording.
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
    ed.cursors.clearRetainingCapacity(); // their positions no longer apply
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
    ed.cursors.clearRetainingCapacity();
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
    ed.setCursorRow(ed.stepRows(ed.cursorRow(), delta));
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

// Rows: text lines plus ghost lines.

/// The git hunk whose old lines show as ghost lines before text line `line`.
pub fn ghostHunk(ed: *const Editor, line: usize) ?diff.Hunk {
    if (!ed.options.ghost_lines) return null;
    const g = ed.buffer.git orelse return null;
    for (g.hunks.items) |h| {
        if (h.old_count == 0) continue;
        const at = h.new_start + h.new_count;
        if (at == line) return h;
        if (at > line) break;
    }
    return null;
}

pub fn hasGhosts(ed: *const Editor) bool {
    if (!ed.options.ghost_lines) return false;
    const g = ed.buffer.git orelse return false;
    for (g.hunks.items) |h| if (h.old_count > 0) return true;
    return false;
}

/// The text of ghost line `k` before text line `line`.
pub fn ghostText(ed: *const Editor, line: usize, k: u32) []const u8 {
    const h = ed.ghostHunk(line) orelse return "";
    return ed.buffer.git.?.baseLine(h.old_start + k);
}

pub fn nextRow(ed: *const Editor, r: Row) Row {
    const n = ed.buffer.text.lineCount();
    if (r.ghost) |k| {
        const h = ed.ghostHunk(r.line) orelse return .{ .line = @min(r.line, n - 1) };
        if (k + 1 < h.old_count) return .{ .line = r.line, .ghost = k + 1 };
        return if (r.line < n) .{ .line = r.line } else r;
    }
    const after = (if (ed.foldAt(r.line)) |f| f.last else r.line) + 1;
    if (ed.ghostHunk(after) != null) return .{ .line = after, .ghost = 0 };
    return if (after < n) .{ .line = after } else r;
}

pub fn prevRow(ed: *const Editor, r: Row) Row {
    if (r.ghost) |k| {
        if (k > 0) return .{ .line = r.line, .ghost = k - 1 };
        return if (r.line == 0) r else .{ .line = ed.visibleLine(r.line - 1) };
    }
    if (ed.ghostHunk(r.line)) |h| return .{ .line = r.line, .ghost = h.old_count - 1 };
    return if (r.line == 0) r else .{ .line = ed.visibleLine(r.line - 1) };
}

/// The row `delta` rows away from `r` (stops at the ends).
pub fn stepRows(ed: *const Editor, r: Row, delta: isize) Row {
    if (ed.buffer.folds.isEmpty() and !ed.hasGhosts() and r.ghost == null) {
        return .{ .line = ed.stepVisible(r.line, delta) };
    }
    var cur = r;
    var n = @abs(delta);
    while (n > 0) : (n -= 1) {
        const next = if (delta > 0) ed.nextRow(cur) else ed.prevRow(cur);
        if (next.eql(cur)) break;
        cur = next;
    }
    return cur;
}

/// Screen rows from `a` down to `b`, counting at most `cap`.
pub fn rowsFrom(ed: *const Editor, a: Row, b: Row, cap: usize) usize {
    if (!a.before(b)) return 0;
    if (ed.buffer.folds.isEmpty() and !ed.hasGhosts() and a.ghost == null and b.ghost == null) {
        return @min(b.line - a.line, cap);
    }
    var cur = a;
    var rows: usize = 0;
    while (cur.before(b) and rows < cap) : (rows += 1) {
        const next = ed.nextRow(cur);
        if (next.eql(cur)) break;
        cur = next;
    }
    return rows;
}

/// Screen rows from line `a` down to line `b`, counting at most `cap`.
pub fn rowsBetween(ed: *const Editor, a: usize, b: usize, cap: usize) usize {
    return ed.rowsFrom(.{ .line = a }, .{ .line = b }, cap);
}

pub fn topRow(ed: *const Editor) Row {
    return .{ .line = ed.view.top, .ghost = ed.view.top_ghost };
}

pub fn setTop(ed: *Editor, r: Row) void {
    ed.view.top = r.line;
    ed.view.top_ghost = r.ghost;
}

pub fn cursorRow(ed: *const Editor) Row {
    if (ed.ghost) |g| return .{ .line = g.line, .ghost = g.k };
    return .{ .line = ed.visibleLine(ed.buffer.text.lineOf(ed.view.cursor)) };
}

/// The screen row of `r`, if it is on screen.
pub fn rowOnScreen(ed: *const Editor, r: Row) ?usize {
    const top = ed.topRow();
    if (r.before(top)) return null;
    const row = ed.rowsFrom(top, r, ed.view.rows);
    return if (row < ed.view.rows) row else null;
}

/// The screen row of text `line`, if it is on screen.
pub fn screenRow(ed: *const Editor, line: usize) ?usize {
    return ed.rowOnScreen(.{ .line = ed.visibleLine(line) });
}

/// Moves the cursor to a row: a ghost row puts it on that ghost line.
pub fn setCursorRow(ed: *Editor, r: Row) void {
    const col = ed.view.want_col orelse (if (ed.ghost) |g| g.col else ed.cursorCol());
    if (r.ghost) |k| {
        const len = ed.ghostText(r.line, k).len;
        const anchor = if (ed.ghost) |g| (if (g.line == r.line) g.anchor else null) else null;
        ed.ghost = .{ .line = r.line, .k = k, .col = @min(col, len -| 1), .anchor = anchor };
        ed.view.want_col = col;
    } else {
        ed.ghost = null;
        ed.gotoLine(r.line);
        ed.view.want_col = col;
    }
}

/// Drops the ghost cursor if its hunk went away (edits, restore, toggle).
fn validateGhost(ed: *Editor) void {
    const g = ed.ghost orelse return;
    const h = ed.ghostHunk(g.line) orelse {
        ed.ghost = null;
        return;
    };
    if (g.k >= h.old_count) ed.ghost = null;
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
    const r = ed.stepRows(ed.topRow(), @intCast(row));
    if (r.ghost != null) {
        ed.view.want_col = ed.view.left + col;
        return ed.setCursorRow(r);
    }
    ed.ghost = null;
    const off = motions.byteAtCol(t.lineSlice(r.line), ed.view.left + col, ed.options.tab_width);
    ed.setCursor(t.lineStart(r.line) + off);
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
    const cur = ed.cursorRow();
    const so = ed.effectiveScrolloff();
    // Keep `top` on a row that exists (folds and hunks change).
    var top = ed.topRow();
    top.line = ed.visibleLine(@min(top.line, ed.text().lineCount() -| 1));
    if (top.ghost) |k| {
        const h = ed.ghostHunk(top.line);
        if (h == null or k >= h.?.old_count) top.ghost = null;
    }
    ed.setTop(top);
    if (cur.before(top) or ed.rowsFrom(top, cur, so) < so) {
        ed.setTop(ed.stepRows(cur, -@as(isize, @intCast(so))));
    } else if (ed.rowsFrom(top, cur, v.rows) + so >= v.rows) {
        ed.setTop(ed.stepRows(cur, -@as(isize, @intCast(v.rows -| (so + 1)))));
    }

    const col = if (ed.ghost) |g| g.col else ed.cursorCol();
    if (col < v.left) v.left = col;
    if (col >= v.left + v.cols) v.left = col + 1 - v.cols;
}

/// Scrolls the view by `delta` lines, dragging the cursor along when it
/// would leave the screen (vim's <C-e>/<C-y> and mouse wheel behavior).
pub fn scrollLines(ed: *Editor, delta: isize) void {
    const v = &ed.view;
    const top = ed.stepRows(ed.topRow(), delta);
    ed.setTop(top);

    const so = ed.effectiveScrolloff();
    const cur = ed.cursorRow();
    const at_start = ed.prevRow(top).eql(top);
    const lo = if (at_start) top else ed.stepRows(top, @intCast(so));
    const hi = ed.stepRows(top, @intCast(v.rows -| (so + 1)));
    if (cur.before(lo)) {
        ed.setCursorRow(lo);
    } else if (hi.before(cur) and !hi.before(lo)) ed.setCursorRow(hi);
}

// ---------------------------------------------------------------------------
// Editing primitives

/// Inserts at `pos`, recording it for undo. Leaves the cursor alone.
pub fn insertAt(ed: *Editor, pos: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try ed.buffer.history.recordInsert(ed.gpa, pos, bytes, ed.view.cursor);
    try ed.buffer.insert(ed.gpa, pos, bytes);
    ed.buffer.modified = true;
    ed.shiftCursors(pos, pos, bytes.len);
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
    ed.shiftCursors(start, end, 0);
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
        ed.loadGitBase(cur);
        ed.activate(cur);
        return;
    }
    errdefer loaded.deinit(ed.gpa);
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = loaded;
    try ed.buffers.append(ed.gpa, b);
    ed.loadGitBase(b);
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
    ed.pushJump();
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
    ed.cursors.clearRetainingCapacity();
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
        for (ed.window_list.items) |w| w.view = .{ .rows = w.view.rows, .cols = w.view.cols };
        ed.activate(b);
        return;
    }
    _ = ed.buffers.orderedRemove(ed.bufferIndex(b));
    ed.forgetJumps(b);
    var next = ed.buffers.items[0];
    for (ed.buffers.items) |o| {
        if (o.last_used > next.last_used) next = o;
    }
    // Windows showing it show the most recent other buffer instead.
    for (ed.window_list.items) |w| if (w != ed.window and w.buffer == b) {
        w.buffer = next;
        w.view = .{ .cursor = next.saved.cursor, .top = next.saved.top, .left = next.saved.left, .rows = w.view.rows, .cols = w.view.cols };
    };
    if (b == ed.buffer) ed.activate(next);
    b.deinit(ed.gpa);
    ed.gpa.destroy(b);
}

// ---------------------------------------------------------------------------
// Multicursor: commands typed at the primary cursor are replayed at the others.
//
// A command's keys are collected until it completes (the editor is idle
// again, or in insert mode), then fed again at every extra cursor with that
// cursor's position and the mode the command began in. In insert mode each
// key is a command of its own, so typing shows up everywhere as you type.
// Edits shift every stored cursor, so they stay put as text moves.

/// After each key: replays the command once it is complete.
fn multiAfterKey(ed: *Editor) void {
    if (ed.replaying) return;
    const done = ed.mode == .insert or ed.isIdle();
    if (!done) return;
    defer ed.multi_keys.clearRetainingCapacity();
    if (ed.multi_once or ed.mode == .picker or ed.cursors.items.len == 0) return;
    ed.replayAtCursors(ed.multi_keys.items);
}

fn saveCursor(ed: *const Editor) Cursor {
    return .{ .pos = ed.view.cursor, .anchor = ed.view.anchor, .want_col = ed.view.want_col };
}

fn replayAtCursors(ed: *Editor, keys_: []const KeyEvent) void {
    const final_mode = ed.mode;
    const final_visual_line = ed.visual_line;
    const final_highlight = ed.search_highlight;
    // `.` should repeat the primary's change, recorded once.
    const capturing = ed.capturing;
    const capture_repeatable = ed.capture_repeatable;
    ed.capturing = false;

    ed.primary_saved = ed.saveCursor();
    ed.replaying = true;
    for (0..ed.cursors.items.len) |i| {
        const c = ed.cursors.items[i];
        const len = ed.text().len();
        ed.view.cursor = @min(c.pos, len);
        ed.view.anchor = @min(c.anchor, len);
        ed.view.want_col = c.want_col;
        ed.mode = ed.multi_start.mode;
        ed.visual_line = ed.multi_start.visual_line;
        ed.op = null;
        ed.count = 0;
        ed.pending_len = 0;
        ed.register = null;
        ed.awaiting_register = false;
        ed.awaiting_char = null;
        for (keys_) |k| ed.handleKeyInner(k) catch {
            ed.resetCommand();
            break;
        };
        if (ed.search_prompt != null) ed.cancelSearch();
        ed.cursors.items[i] = ed.saveCursor();
    }
    ed.replaying = false;
    const p = ed.primary_saved.?;
    ed.primary_saved = null;
    ed.view.cursor = p.pos;
    ed.view.anchor = p.anchor;
    ed.view.want_col = p.want_col;
    ed.mode = final_mode;
    ed.visual_line = final_visual_line;
    ed.search_highlight = final_highlight;
    ed.op = null;
    ed.awaiting_char = null;
    ed.capturing = capturing;
    ed.capture_repeatable = capture_repeatable;
    ed.mergeCursors();
}

/// Keeps stored cursors on the same text when `[start, end)` is replaced by
/// `inserted` bytes (an insert has start == end, a delete inserted == 0).
fn shiftCursors(ed: *Editor, start: usize, end: usize, inserted: usize) void {
    const S = struct {
        fn shift(p: *usize, s: usize, e: usize, n: usize) void {
            if (p.* >= e and (p.* > s or n > 0)) {
                p.* = p.* - (e - s) + n;
            } else if (p.* > s) p.* = s;
        }
    };
    for (ed.cursors.items) |*c| {
        S.shift(&c.pos, start, end, inserted);
        S.shift(&c.anchor, start, end, inserted);
    }
    if (ed.primary_saved) |*c| {
        S.shift(&c.pos, start, end, inserted);
        S.shift(&c.anchor, start, end, inserted);
    }
    for (ed.jumps.items) |*j| if (j.buffer == ed.buffer) S.shift(&j.pos, start, end, inserted);
    // Other windows on this buffer keep their place too.
    for (ed.window_list.items) |w| if (w != ed.window and w.buffer == ed.buffer) {
        S.shift(&w.view.cursor, start, end, inserted);
        S.shift(&w.view.anchor, start, end, inserted);
    };
}

/// Drops cursors that landed on the primary or on each other.
fn mergeCursors(ed: *Editor) void {
    const len = ed.text().len();
    var out: usize = 0;
    outer: for (ed.cursors.items) |c| {
        var cc = c;
        cc.pos = @min(cc.pos, len);
        cc.anchor = @min(cc.anchor, len);
        if (cc.pos == ed.view.cursor) continue;
        for (ed.cursors.items[0..out]) |o| if (o.pos == cc.pos) continue :outer;
        ed.cursors.items[out] = cc;
        out += 1;
    }
    ed.cursors.items.len = out;
}

/// Leaves a cursor where the primary is (before the primary moves on).
pub fn addCursorHere(ed: *Editor) !void {
    try ed.cursors.append(ed.gpa, ed.saveCursor());
}

pub fn clearCursors(ed: *Editor) void {
    ed.cursors.clearRetainingCapacity();
}

pub fn removeLastCursor(ed: *Editor) void {
    if (ed.cursors.pop()) |c| {
        ed.view.cursor = c.pos;
        ed.view.anchor = c.anchor;
        ed.placeCursor(c.pos);
    }
}

fn reportCursors(ed: *Editor) void {
    ed.setMessage(.info, "{d} cursors (qq or Esc removes them)", .{ed.cursors.items.len + 1});
}

/// What `gzn`/`gzm` look for: the charwise selection, else the word under
/// the cursor (whole words only).
fn matchTarget(ed: *Editor) ?struct { start: usize, end: usize, whole: bool } {
    const t = ed.text();
    if (ed.mode == .visual and !ed.visual_line) {
        const r = ed.visualRange();
        if (r.end > r.start) return .{ .start = r.start, .end = r.end, .whole = false };
        return null;
    }
    const r = textobjects.word(t, ed.view.cursor, .inner, false, 1) orelse return null;
    if (r.end == r.start or !search.isWord(t.byteAt(r.start))) return null;
    return .{ .start = r.start, .end = r.end, .whole = true };
}

/// `qn` / `qN` / `qs` / `qa`: a cursor on the next/previous match of the
/// word (or selection), skipping one, or on every match.
pub fn cursorAtMatch(ed: *Editor, how: enum { next, previous, skip, all }) !void {
    const target = ed.matchTarget() orelse return ed.setMessage(.info, "no word under the cursor", .{});
    const t = ed.text();
    const hay = t.slice(0, t.len());
    const needle = try ed.gpa.dupe(u8, hay[target.start..target.end]);
    defer ed.gpa.free(needle);
    const pattern = search.Pattern.init(needle, target.whole);
    const visual = ed.mode == .visual;
    // Where the primary sits inside the match (kept at each new cursor).
    const offset = ed.view.cursor - target.start;
    const anchor_offset = ed.view.anchor -| target.start;
    const place = struct {
        fn at(m: usize, off: usize, aoff: usize, vis: bool) Cursor {
            return .{ .pos = m + off, .anchor = if (vis) m + aoff else m + off };
        }
    }.at;

    if (how == .all) {
        var from: usize = 0;
        while (pattern.forward(hay, from)) |m| : (from = m + 1) {
            if (m == target.start) continue;
            try ed.cursors.append(ed.gpa, place(m, offset, anchor_offset, visual));
        }
        ed.mergeCursors();
        return ed.reportCursors();
    }
    const m = pattern.next(hay, target.start, how != .previous) orelse return;
    if (m.pos == target.start) return ed.setMessage(.info, "no other match", .{});
    if (how != .skip) try ed.addCursorHere();
    const c = place(m.pos, offset, anchor_offset, visual);
    ed.view.cursor = c.pos;
    ed.view.anchor = c.anchor;
    ed.view.want_col = null;
    ed.revealLine(t.lineOf(c.pos));
    ed.mergeCursors();
    ed.reportCursors();
}

/// Visual `I` / `A` (and `qI` / `qA`): a cursor at the start (first
/// non-blank) or end of every selected line. `insert` starts typing there.
pub fn cursorsOnLines(ed: *Editor, at_end: bool, insert: bool) !void {
    if (ed.mode != .visual) return;
    const t = ed.text();
    const first = t.lineOf(@min(ed.view.anchor, ed.view.cursor));
    const last = t.lineOf(@max(ed.view.anchor, ed.view.cursor));
    ed.exitVisual();
    ed.clearCursors();
    var line = last;
    while (true) : (line -= 1) {
        const ls = t.lineStart(line);
        const le = t.lineEnd(line);
        const pos = if (!at_end) motions.firstNonBlank(t, line) else if (insert or le == ls) le else motions.prevChar(t, le);
        if (line == first) {
            ed.view.cursor = pos;
            ed.view.anchor = pos;
            break;
        }
        try ed.cursors.append(ed.gpa, .{ .pos = pos, .anchor = pos });
    }
    if (insert) ed.setMode(.insert) else ed.placeCursor(ed.view.cursor);
    ed.reportCursors();
}

/// <Tab> in the snipe (`s`) or search (`/`) prompt: a cursor on every match
/// (on screen for snipe, in the file for search), each match selected, so
/// `c` changes them all and <Esc> leaves plain cursors.
pub fn cursorsFromPrompt(ed: *Editor) !void {
    const sp = ed.search_prompt orelse return;
    if (sp.kind != .search and sp.kind != .snipe) return;
    const needle = try ed.gpa.dupe(u8, sp.input.items());
    defer ed.gpa.free(needle);
    if (needle.len == 0) return;
    const t = ed.text();
    var from: usize = 0;
    var to = t.len();
    if (sp.kind == .snipe) {
        from = t.lineStart(@min(sp.origin_top, t.lineCount() - 1));
        to = t.lineEnd(@min(sp.origin_top + ed.view.rows, t.lineCount()) - 1);
    }
    ed.cancelSearch();
    const hay = t.slice(0, to);
    const pattern = search.Pattern.init(needle, false);
    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(ed.gpa);
    var i = from;
    while (pattern.forward(hay, i)) |m| : (i = m + needle.len) try matches.append(ed.gpa, m);
    if (matches.items.len == 0) return ed.setMessage(.info, "no matches", .{});

    // The primary takes the match nearest the cursor.
    var primary: usize = 0;
    for (matches.items, 0..) |m, k| {
        if (m <= ed.view.cursor) primary = k;
    }
    ed.clearCursors();
    if (ed.mode != .visual) ed.enterVisual(false);
    ed.visual_line = false;
    const last_off = motions.prevChar(t, matches.items[0] + needle.len) - matches.items[0];
    for (matches.items, 0..) |m, k| {
        const c: Cursor = .{ .pos = m + last_off, .anchor = m };
        if (k == primary) {
            ed.view.cursor = c.pos;
            ed.view.anchor = c.anchor;
        } else try ed.cursors.append(ed.gpa, c);
    }
    ed.reportCursors();
}

// ---------------------------------------------------------------------------
// Terminal popup (`SPC o t`) and running commands (`SPC r`).
//
// Both are terminals (a program on a PTY, emulated by libghostty-vt) shown
// in a popup over the editor. While the popup is open every key goes to the
// program, except <C-\> (hide) and, once a run has finished, q/<Esc>
// (close) and r (run again).

fn spawnTerminal(ed: *Editor, argv: []const []const u8) !*Terminal {
    const sz = ed.term_size;
    return Terminal.create(ed.gpa, ed.io, .{
        .argv = argv,
        .cwd = ed.cwd,
        .cols = sz.cols,
        .rows = sz.rows,
        .cell_w = sz.cell_w,
        .cell_h = sz.cell_h,
        .fg = ed.term_fg,
        .bg = ed.term_bg,
        .wake = ed.wake_fn,
    });
}

/// The terminal the popup shows.
pub fn popupTerminal(ed: *Editor) ?*Terminal {
    return switch (ed.popup orelse return null) {
        .shell => ed.shell,
        .run => ed.run,
    };
}

/// `SPC o t` / <C-\>: shows or hides the shell (started on first use).
pub fn toggleShell(ed: *Editor) !void {
    if (ed.popup == .shell) {
        ed.popup = null;
        return;
    }
    if (ed.shell == null) ed.shell = try ed.spawnTerminal(&.{Pty.userShell()});
    ed.popup = .shell;
}

/// `SPC r o`: shows the last run's output again.
pub fn showRunOutput(ed: *Editor) void {
    if (ed.run == null) return ed.setMessage(.info, "nothing has been run yet (SPC r r)", .{});
    ed.popup = .run;
}

fn isCtrlBackslash(ev: KeyEvent) bool {
    return ev.mods.ctrl and ev.key == .codepoint and ev.key.codepoint == '\\';
}

/// Keys while the popup is open (or <C-\> to open the shell). Returns
/// true when the key was used.
fn popupKey(ed: *Editor, ev: KeyEvent) bool {
    if (ed.popup == null) {
        if (isCtrlBackslash(ev) and ed.mode == .normal) {
            ed.toggleShell() catch |err| ed.setMessage(.err, "could not start the shell: {s}", .{@errorName(err)});
            return true;
        }
        return false;
    }
    const t = ed.popupTerminal() orelse {
        ed.popup = null;
        return false;
    };
    if (isCtrlBackslash(ev)) {
        ed.popup = null;
        return true;
    }
    // Shift+PageUp/PageDown: scroll through the output.
    if (ev.mods.shift and ev.key == .special and (ev.key.special == .page_up or ev.key.special == .page_down)) {
        const page: isize = @intCast(@max(t.rows, 2) - 1);
        t.scroll(if (ev.key.special == .page_up) -page else page);
        return true;
    }
    // Ctrl+Shift+V pastes the clipboard.
    if (ev.mods.ctrl and ev.mods.shift and ev.key == .codepoint and (ev.key.codepoint == 'v' or ev.key.codepoint == 'V')) {
        if (ed.registers.clipboard) |cb| if (cb.get(ed.gpa)) |clip| {
            defer ed.gpa.free(clip);
            t.paste(clip);
        };
        return true;
    }
    if (!t.isRunning()) {
        // A finished run: q/<Esc> closes, r runs it again; scrolling still works.
        if (ev.key == .special and ev.key.special == .escape) {
            ed.popup = null;
        } else if (ev.key == .codepoint and !ev.mods.blocksText()) switch (ev.key.codepoint) {
            'q' => ed.popup = null,
            'r' => if (ed.popup == .run) ed.rerun() catch |err| ed.setMessage(.err, "could not run: {s}", .{@errorName(err)}),
            'e' => if (ed.popup == .run) {
                ed.popup = null;
                ed.showRunErrors() catch |err| ed.setMessage(.err, "{s}", .{@errorName(err)});
            },
            'k' => t.scroll(-1),
            'j' => t.scroll(1),
            else => {},
        };
        return true;
    }
    t.sendKey(ev);
    return true;
}

/// `SPC r c` (empty prompt) / `SPC r r` (prefilled with the last command).
pub fn runPrompt(ed: *Editor, runner: bool) !void {
    ed.startSearch(true, if (runner) .run_runner else .run_command);
    if (!runner) return;
    const last = ed.loadRunnerCommand() orelse return;
    defer ed.gpa.free(last);
    try ed.search_prompt.?.input.set(ed.gpa, last);
}

fn runMemoryPath(ed: *Editor) ?[]const u8 {
    if (ed.run_memory_path == null) ed.run_memory_path = RunMemory.defaultPath(ed.gpa);
    return ed.run_memory_path;
}

fn projectDir(ed: *Editor) []const u8 {
    return ed.git_root orelse ed.cwd;
}

/// This project's remembered runner command. Caller frees.
fn loadRunnerCommand(ed: *Editor) ?[]u8 {
    const path = ed.runMemoryPath() orelse return null;
    return RunMemory.load(ed.gpa, ed.io, path, ed.projectDir());
}

fn finishRunPrompt(ed: *Editor, kind: PromptKind) !void {
    const raw = try ed.takePromptText() orelse return;
    defer ed.gpa.free(raw);
    const cmd = std.mem.trim(u8, raw, " \t");
    if (cmd.len == 0) return;
    if (kind == .run_runner) if (ed.runMemoryPath()) |path| RunMemory.save(ed.gpa, ed.io, path, ed.projectDir(), cmd);
    try ed.startRun(cmd);
}

/// `SPC r R`: the runner's command again, without asking.
pub fn runAgain(ed: *Editor) !void {
    const cmd = ed.loadRunnerCommand() orelse return ed.runPrompt(true);
    defer ed.gpa.free(cmd);
    try ed.startRun(cmd);
}

fn rerun(ed: *Editor) !void {
    const cmd = try ed.gpa.dupe(u8, ed.run_command orelse return);
    defer ed.gpa.free(cmd);
    try ed.startRun(cmd);
}

/// Saves open files, then runs `cmd` through the user's shell in the popup
/// (replacing the previous run, stopping it if it is still going).
pub fn startRun(ed: *Editor, cmd: []const u8) !void {
    for (ed.buffers.items) |b| if (b.modified and b.path != null) {
        _ = b.save(ed.gpa, ed.io) catch {};
        if (ed.lspFor(b)) |l| l.didSave(b);
    };
    const owned = try ed.gpa.dupe(u8, cmd);
    errdefer ed.gpa.free(owned);
    const t = try ed.spawnTerminal(&.{ Pty.userShell(), "-c", cmd });
    if (ed.run) |old| old.destroy();
    if (ed.run_command) |old| ed.gpa.free(old);
    ed.run = t;
    ed.run_command = owned;
    ed.run_started = Io.Timestamp.now(ed.io, .awake);
    ed.run_reported = false;
    ed.popup = .run;
}

/// Finds `path:line:col` errors in the finished run's output.
fn collectRunErrors(ed: *Editor, t: *Terminal) void {
    for (ed.run_errors.items) |e| e.deinit(ed.gpa);
    ed.run_errors.clearRetainingCapacity();
    const out = t.copyOutput(ed.gpa) catch return;
    defer ed.gpa.free(out);
    const S = struct {
        fn exists(e: *Editor, path: []const u8) bool {
            return e.fileExists(path);
        }
    };
    run_errors_mod.parse(ed.gpa, out, ed, S.exists, &ed.run_errors) catch {};
}

/// `SPC r e`: the last run's errors in a picker; <CR> jumps to one.
pub fn showRunErrors(ed: *Editor) !void {
    if (ed.run == null) return ed.setMessage(.info, "nothing has been run yet (SPC r r)", .{});
    if (ed.run_errors.items.len == 0) return ed.setMessage(.info, "no errors in the last run", .{});
    try ed.openPicker(.run_errors, "");
}

/// Seconds since the run started (or how long it took, once reported).
pub fn runSeconds(ed: *Editor) f64 {
    const ns = ed.run_started.durationTo(Io.Timestamp.now(ed.io, .awake)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

/// Notices finished programs: a run prints how it ended; an exited shell
/// closes its popup.
fn pollTerminals(ed: *Editor) void {
    if (ed.run) |t| if (!ed.run_reported and !t.isRunning()) {
        ed.run_reported = true;
        const secs = ed.runSeconds();
        ed.collectRunErrors(t);
        const n = ed.run_errors.items.len;
        var buf: [160]u8 = undefined;
        const ok = t.exit_code == 0;
        var errs_buf: [48]u8 = undefined;
        const errs: []const u8 = if (n > 0) std.fmt.bufPrint(&errs_buf, "   e: {d} error{s}", .{ n, if (n == 1) "" else "s" }) catch "" else "";
        const line = std.fmt.bufPrint(&buf, "\r\n\x1b[1;{s}m{s} exited {d}\x1b[0;2m in {d:.2}s{s}   r: run again   q: close\x1b[0m", .{
            if (ok) "32" else "31", if (ok) "✓" else "✗", t.exit_code, secs, errs,
        }) catch "";
        t.print(line);
        if (n > 0) {
            ed.setMessage(if (ok) .info else .err, "{s}: exited {d} in {d:.2}s, {d} error{s} (SPC r e lists them)", .{ ed.run_command orelse "", t.exit_code, secs, n, if (n == 1) "" else "s" });
        } else {
            ed.setMessage(if (ok) .info else .err, "{s}: exited {d} in {d:.2}s (SPC r o shows the output)", .{ ed.run_command orelse "", t.exit_code, secs });
        }
    };
    if (ed.shell) |t| if (!t.isRunning()) {
        t.destroy();
        ed.shell = null;
        if (ed.popup == .shell) ed.popup = null;
    };
}

// ---------------------------------------------------------------------------
// Jumplist: where you were before each jump. `<C-o>` goes back, `<C-i>`
// forward, `SPC s j` lists them. One entry per line (the newest wins).

const max_jumps = 100;

/// Records the cursor's place before a jump.
pub fn pushJump(ed: *Editor) void {
    ed.pushJumpAt(ed.view.cursor);
}

pub fn pushJumpAt(ed: *Editor, pos: usize) void {
    if (ed.replaying) return;
    const b = ed.buffer;
    const t = ed.text();
    const p = @min(pos, t.len());
    const line = t.lineOf(p);
    var i: usize = 0;
    while (i < ed.jumps.items.len) {
        const j = ed.jumps.items[i];
        if (j.buffer == b and t.lineOf(@min(j.pos, t.len())) == line) {
            if (j.path) |jp| ed.gpa.free(jp);
            _ = ed.jumps.orderedRemove(i);
        } else i += 1;
    }
    if (ed.jumps.items.len >= max_jumps) {
        if (ed.jumps.items[0].path) |jp| ed.gpa.free(jp);
        _ = ed.jumps.orderedRemove(0);
    }
    const path = if (b.path) |bp| ed.gpa.dupe(u8, bp) catch null else null;
    ed.jumps.append(ed.gpa, .{ .buffer = b, .path = path, .pos = p }) catch {
        if (path) |jp| ed.gpa.free(jp);
    };
    ed.jump_index = ed.jumps.items.len;
}

/// `<C-o>`: back to an older place.
pub fn jumpOlder(ed: *Editor, count: usize) !void {
    if (ed.jump_index >= ed.jumps.items.len) {
        // Leaving the newest place: remember it, so `<C-i>` comes back.
        ed.pushJump();
        ed.jump_index = ed.jumps.items.len - 1;
    }
    if (count > ed.jump_index) return ed.setMessage(.info, "at the oldest jump", .{});
    try ed.goJump(ed.jump_index - count);
}

/// `<C-i>` / `<Tab>`: forward to a newer place.
pub fn jumpNewer(ed: *Editor, count: usize) !void {
    const target = ed.jump_index + count;
    if (target >= ed.jumps.items.len) return ed.setMessage(.info, "at the newest jump", .{});
    try ed.goJump(target);
}

/// Goes to jump `i` (reopening its file if its buffer was closed).
pub fn goJump(ed: *Editor, i: usize) !void {
    const j = ed.jumps.items[i];
    ed.jump_index = i;
    if (j.buffer) |b| {
        ed.switchTo(b);
    } else if (j.path) |p| {
        try ed.openFile(p);
        // Entries for that file point at the new buffer again.
        for (ed.jumps.items) |*o| if (o.buffer == null and o.path != null and std.mem.eql(u8, o.path.?, p)) {
            o.buffer = ed.buffer;
        };
    } else return;
    const t = ed.text();
    const pos = @min(j.pos, t.len());
    ed.revealLine(t.lineOf(pos));
    ed.setCursor(pos);
}

/// A closed buffer's jumps keep their file path (or go, for scratch buffers).
fn forgetJumps(ed: *Editor, b: *Buffer) void {
    var i: usize = 0;
    while (i < ed.jumps.items.len) {
        const j = &ed.jumps.items[i];
        if (j.buffer == b) {
            j.buffer = null;
            if (j.path == null) {
                _ = ed.jumps.orderedRemove(i);
                if (ed.jump_index > i) ed.jump_index -= 1;
                continue;
            }
        }
        i += 1;
    }
    ed.jump_index = @min(ed.jump_index, ed.jumps.items.len);
}

// ---------------------------------------------------------------------------
// Windows (SPC w): splits showing buffers, each with its own view.

fn refreshWindowList(ed: *Editor) void {
    ed.windows.list(&ed.window_list) catch {};
}

/// The buffer and view `w` shows (the live ones for the focused window).
pub fn windowBuffer(ed: *Editor, w: *Windows.Window) *Buffer {
    return if (w == ed.window) ed.buffer else w.buffer;
}

pub fn windowView(ed: *Editor, w: *Windows.Window) *View {
    return if (w == ed.window) &ed.view else &w.view;
}

/// Moves focus to `w`, keeping the current window's state in it.
pub fn focusWindow(ed: *Editor, w: *Windows.Window) void {
    if (w == ed.window) return;
    ed.window.view = ed.view;
    ed.window.buffer = ed.buffer;
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    ed.loadWindow(w);
}

fn loadWindow(ed: *Editor, w: *Windows.Window) void {
    ed.window = w;
    ed.cursors.clearRetainingCapacity();
    ed.ghost = null;
    if (ed.mode == .visual or ed.mode == .operator) ed.mode = .normal;
    ed.op = null;
    ed.buffer = w.buffer;
    ed.view = w.view;
    ed.use_counter += 1;
    ed.buffer.last_used = ed.use_counter;
    ed.placeCursor(@min(ed.view.cursor, ed.text().len()));
    ed.scrollToCursor();
}

/// `SPC w s` + direction: a new window on that side, showing this buffer.
pub fn splitWindow(ed: *Editor, dir: Windows.Dir) !void {
    const nw = try ed.windows.split(ed.window, dir, ed.view, ed.buffer);
    ed.refreshWindowList();
    ed.focusWindow(nw);
}

/// `SPC w d`: closes the focused window (not the last one).
pub fn closeWindow(ed: *Editor) void {
    const closing = ed.window;
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    const target = ed.windows.close(closing) orelse
        return ed.setMessage(.info, "this is the last window (SPC q q quits)", .{});
    ed.refreshWindowList();
    ed.loadWindow(target);
}

/// `SPC w o`: closes every other window.
pub fn onlyWindow(ed: *Editor) !void {
    try ed.windows.only(ed.window);
    ed.refreshWindowList();
}

/// `SPC w h/j/k/l`: focus the window on that side.
pub fn focusDirection(ed: *Editor, dir: Windows.Dir) void {
    const w = ed.windows.neighbor(ed.window, dir) orelse return;
    ed.focusWindow(w);
}

/// `SPC w w`: the next window, wrapping around.
pub fn focusNext(ed: *Editor) void {
    ed.focusWindow(ed.windows.next(ed.window));
}

// ---------------------------------------------------------------------------
// File operations (SPC f): each asks for a path in a boxed prompt.

/// Opens the prompt for `kind`, prefilled with the current path (or, for a
/// new file, the current file's folder) so it only needs editing.
pub fn filePrompt(ed: *Editor, kind: PromptKind) !void {
    const path = ed.buffer.path;
    if (path == null and (kind == .rename_file or kind == .copy_file))
        return ed.setMessage(.info, "this buffer has no file yet: SPC f S saves it as one", .{});
    ed.startSearch(true, kind);
    const prefill: []const u8 = if (path) |p| switch (kind) {
        .new_file => p[0 .. if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| i + 1 else 0],
        else => p,
    } else "";
    try ed.search_prompt.?.input.set(ed.gpa, prefill);
}

fn finishFilePrompt(ed: *Editor, kind: PromptKind) !void {
    const raw = try ed.takePromptText() orelse return;
    defer ed.gpa.free(raw);
    const typed = std.mem.trim(u8, raw, " ");
    if (typed.len == 0 or typed[typed.len - 1] == '/') return ed.setMessage(.info, "cancelled: no file name", .{});
    const path = try ed.normalizePath(typed);
    defer ed.gpa.free(path);
    if (kind == .new_file) {
        try ed.openFile(path);
        if (!ed.fileExists(path)) ed.setMessage(.info, "new file \"{s}\" (created when saved)", .{path});
        return;
    }
    const b = ed.buffer;
    if (b.path) |p| if (std.mem.eql(u8, p, path)) {
        if (kind == .save_as) return ed.saveCurrent();
        return ed.setMessage(.info, "that is already its name", .{});
    };
    // Never clobber another file (or an open buffer that will become one).
    if (ed.fileExists(path) or ed.findBuffer(path) != null)
        return ed.setMessage(.err, "\"{s}\" already exists", .{path});
    switch (kind) {
        .save_as => {
            const n = ed.writeBufferTo(b, path) orelse return;
            try ed.setBufferPath(b, path);
            ed.setMessage(.info, "saved as \"{s}\" ({d}B)", .{ path, n });
        },
        .rename_file => {
            const old = b.path.?;
            if (ed.fileExists(old)) {
                if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(ed.io, dir) catch {};
                Io.Dir.rename(Io.Dir.cwd(), old, Io.Dir.cwd(), path, ed.io) catch |err|
                    return ed.setMessage(.err, "could not rename: {s}", .{@errorName(err)});
            }
            ed.setMessage(.info, "renamed \"{s}\" -> \"{s}\"", .{ old, path });
            try ed.setBufferPath(b, path); // frees `old`, so after the message
        },
        .copy_file => {
            _ = ed.writeBufferTo(b, path) orelse return;
            try ed.openFile(path);
            ed.setMessage(.info, "copied to \"{s}\"", .{path});
        },
        else => unreachable,
    }
}

/// Writes `b`'s text to `path` without changing which file it belongs to.
/// Null (with a message) on failure.
fn writeBufferTo(ed: *Editor, b: *Buffer, path: []const u8) ?usize {
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
fn setBufferPath(ed: *Editor, b: *Buffer, path: []const u8) !void {
    const owned = try ed.gpa.dupe(u8, path);
    ed.lspCloseBuffer(b);
    if (b.path) |p| ed.gpa.free(p);
    b.path = owned;
    if (b.syntax) |*s| s.deinit(ed.gpa);
    b.syntax = @import("syntax/Syntax.zig").forPath(path);
    if (b.git) |*g| g.deinit(ed.gpa);
    b.git = null;
    ed.loadGitBase(b);
    if (b == ed.buffer) ed.updateGit();
}

/// `SPC f D`: asks (in a Yes/No picker) before deleting the current file.
pub fn deleteFilePrompt(ed: *Editor) !void {
    const path = ed.buffer.path orelse return ed.setMessage(.info, "this buffer has no file", .{});
    if (!ed.fileExists(path)) return ed.setMessage(.info, "\"{s}\" is not on disk", .{path});
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

/// `SPC f y` / `SPC f Y`: the file's path, relative or absolute, to the clipboard.
pub fn yankPath(ed: *Editor, absolute: bool) !void {
    const path = ed.buffer.path orelse return ed.setMessage(.info, "this buffer has no file", .{});
    const out = if (absolute) try ed.absolutePath(path) else try ed.gpa.dupe(u8, path);
    defer ed.gpa.free(out);
    try ed.registers.store(null, .yank, out, false);
    ed.setMessage(.info, "yanked \"{s}\"", .{out});
}

/// `SPC f s`: writes the current buffer; one without a file asks for a name.
pub fn saveCurrent(ed: *Editor) !void {
    const b = ed.buffer;
    if (b.path == null) return ed.filePrompt(.save_as);
    const n = b.save(ed.gpa, ed.io) catch |err|
        return ed.setMessage(.err, "could not save \"{s}\": {s}", .{ b.displayName(), @errorName(err) });
    ed.setMessage(.info, "\"{s}\" {d}L, {d}B written", .{ b.displayName(), b.text.lineCount(), n });
    if (ed.lspFor(b)) |l| l.didSave(b);
}

fn fileExists(ed: *Editor, path: []const u8) bool {
    Io.Dir.cwd().access(ed.io, path, .{}) catch return false;
    return true;
}

fn findBuffer(ed: *Editor, path: []const u8) ?*Buffer {
    for (ed.buffers.items) |b| if (b.path) |p| if (std.mem.eql(u8, p, path)) return b;
    return null;
}

/// `SPC b N`: a new empty scratch buffer.
pub fn newBuffer(ed: *Editor) !void {
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try ed.buffers.append(ed.gpa, b);
    ed.switchTo(b);
}

/// `SPC b l`: back to the previous buffer (the most recently used other one).
pub fn lastBuffer(ed: *Editor) !void {
    const order = try ed.buffersByRecency(ed.gpa);
    defer ed.gpa.free(order);
    if (order.len < 2) return ed.setMessage(.info, "no other buffer", .{});
    ed.switchTo(order[0]);
}

/// `SPC b O`: kills every other buffer without unsaved changes.
pub fn killOtherBuffers(ed: *Editor) !void {
    var kept: usize = 0;
    var i: usize = 0;
    while (i < ed.buffers.items.len) {
        const b = ed.buffers.items[i];
        if (b == ed.buffer) {
            i += 1;
        } else if (b.modified) {
            kept += 1;
            i += 1;
        } else try ed.killBuffer(b);
    }
    if (kept > 0) ed.setMessage(.info, "kept {d} buffer(s) with unsaved changes", .{kept}) else ed.setMessage(.info, "killed other buffers", .{});
}

/// `SPC b S`: saves every modified buffer that has a file.
pub fn saveAll(ed: *Editor) void {
    var n: usize = 0;
    for (ed.buffers.items) |b| if (b.modified and b.path != null) {
        _ = b.save(ed.gpa, ed.io) catch |err| {
            ed.setMessage(.err, "could not save \"{s}\": {s}", .{ b.displayName(), @errorName(err) });
            return;
        };
        if (ed.lspFor(b)) |l| l.didSave(b);
        n += 1;
    };
    ed.setMessage(.info, "saved {d} buffer(s)", .{n});
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

// File browser: the picker on one folder at a time.

/// `SPC .`: browses the current file's folder (else the working directory).
pub fn browse(ed: *Editor) !void {
    const start = if (ed.buffer.path) |p| blk: {
        const abs = try ed.absolutePath(p);
        defer ed.gpa.free(abs);
        break :blk try ed.gpa.dupe(u8, std.fs.path.dirname(abs) orelse "/");
    } else try ed.gpa.dupe(u8, ed.cwd);
    defer ed.gpa.free(start);
    try ed.setBrowseDir(start);
    try ed.openPicker(.browse, "");
}

/// Enters folder `name` (relative to the browsed one, or absolute).
pub fn browseInto(ed: *Editor, name: []const u8) !void {
    const target = try std.fs.path.resolve(ed.gpa, &.{ ed.browse_dir.items, name });
    defer ed.gpa.free(target);
    var dir = Io.Dir.cwd().openDir(ed.io, target, .{ .iterate = true }) catch |err|
        return ed.setMessage(.err, "can't open {s}: {s}", .{ target, @errorName(err) });
    dir.close(ed.io);
    try ed.setBrowseDir(target);
    if (ed.picker) |p| if (p.base == .browse) return p.restart(null);
    try ed.openPicker(.browse, "");
}

/// Goes up one folder, selecting the one we came from.
pub fn browseUp(ed: *Editor) !void {
    const cur = ed.browse_dir.items;
    const parent = std.fs.path.dirname(cur) orelse return; // at the root
    var came_from: [Io.Dir.max_name_bytes + 1]u8 = undefined;
    const sel = try std.fmt.bufPrint(&came_from, "{s}/", .{std.fs.path.basename(cur)});
    const up = try ed.gpa.dupe(u8, parent);
    defer ed.gpa.free(up);
    try ed.setBrowseDir(up);
    if (ed.picker) |p| try p.restart(sel);
}

/// An owned absolute path for `name` inside the browsed folder.
pub fn browsePath(ed: *Editor, name: []const u8) ![]u8 {
    return std.fs.path.join(ed.gpa, &.{ ed.browse_dir.items, name });
}

fn setBrowseDir(ed: *Editor, dir: []const u8) !void {
    ed.browse_dir.clearRetainingCapacity();
    try ed.browse_dir.appendSlice(ed.gpa, dir);
    // The display form: "~" for home, always ending in "/".
    ed.browse_label.clearRetainingCapacity();
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len > 1 and std.mem.startsWith(u8, dir, home) and
        (dir.len == home.len or dir[home.len] == '/'))
    {
        try ed.browse_label.append(ed.gpa, '~');
        try ed.browse_label.appendSlice(ed.gpa, dir[home.len..]);
    } else try ed.browse_label.appendSlice(ed.gpa, dir);
    if (ed.browse_label.items[ed.browse_label.items.len - 1] != '/') try ed.browse_label.append(ed.gpa, '/');
}

/// Accepts the selected row: closes the picker, then acts on the choice
/// (which may open another picker).
pub fn acceptPicker(ed: *Editor) !void {
    const p = ed.picker orelse return;
    const choice = try p.choice();
    defer choice.deinit(ed.gpa);
    ed.closePicker();
    // Pickers that take you somewhere are jumps.
    const kind: ?Picker.Kind = switch (choice) {
        .none => null,
        .item => |c| c.kind,
        .create => |c| c.kind,
    };
    if (kind) |k| switch (k) {
        .files, .buffers, .lines, .grep, .locations, .diagnostics, .symbols, .git_changes => ed.pushJump(),
        else => {},
    };
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
    try ed.feed(">savefi");
    try testing.expectEqual(.commands, ed.picker.?.kind);
    try testing.expectEqualStrings("savefi", ed.picker.?.activeQuery());
    ed.picker.?.sync();
    try testing.expectEqualStrings("save_file", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc>");
    try testing.expectEqual(.normal, ed.mode);
    try ed.feed("<Space>'");
    try testing.expectEqualStrings(">savefi", ed.picker.?.query.items());
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
    try ed.feed("QaA.<Esc>jQ");
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
    // (`ds`/`cs`/`ys` are surround; other operators take the snipe motion.)
    try ed.feed("gUsg");
    try expectText(&ed, "ALPHA BETA gamma");
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

/// An editor whose buffer is diffed against `head` (as if from git).
fn ghostEditor(head: []const u8, current: []const u8) !Editor {
    var ed = try testEditor(current);
    errdefer ed.deinit();
    ed.buffer.git = .{ .base = try Text.init(ed.gpa, head) };
    ed.buffer.edit_version += 1;
    ed.updateGit();
    return ed;
}

test "ghost lines: j/k walk onto them, yy yanks, edits are refused, SPC g r restores" {
    var ed = try ghostEditor("a\nold b\nc\ngone\nd", "a\nnew b\nc\nd");
    defer ed.deinit();
    ed.git_root = try ed.gpa.dupe(u8, "/repo"); // pretend we're in a repo
    // Rows: a, new b, [old b], c, [gone], d
    try ed.feed("jj");
    try testing.expect(ed.ghost != null);
    try testing.expectEqualStrings("old b", ed.ghostText(ed.ghost.?.line, ed.ghost.?.k));
    try ed.feed("yy");
    try testing.expectEqualStrings("old b\n", ed.registers.get(null).?.text);
    try ed.feed("x"); // read-only
    try expectText(&ed, "a\nnew b\nc\nd");
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("jj");
    try testing.expectEqualStrings("gone", ed.ghostText(ed.ghost.?.line, ed.ghost.?.k));
    try ed.feed("j");
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(3, ed.cursorLine()); // "d"

    // Restore the changed line, then the deleted one.
    try ed.feed("gg<Space>gn<Space>gr");
    try expectText(&ed, "a\nold b\nc\nd");
    try ed.feed("<Space>gn<Space>gr");
    try expectText(&ed, "a\nold b\nc\ngone\nd");
    try ed.feed("u");
    try expectText(&ed, "a\nold b\nc\nd");

    try ed.feed("<Space>tg"); // ghost lines off: j skips them
    try ed.feed("ggjj");
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(2, ed.cursorLine());
}

test "ghost lines: V selects several, y yanks them" {
    var ed = try ghostEditor("x\nold1\nold2\nold3\ny", "x\ny");
    defer ed.deinit();
    try ed.feed("jVjjy");
    try testing.expectEqualStrings("old1\nold2\nold3\n", ed.registers.get(null).?.text);
    try testing.expectEqual(.normal, ed.mode);
}

test "ghost lines: w / e / b move word by word through them" {
    var ed = try ghostEditor("a\nold one two\nc", "a\nnew\nc");
    defer ed.deinit();
    // Rows: a, new, [old one two], c
    try ed.feed("jw"); // from "new": into the ghost line's first word
    try testing.expect(ed.ghost != null);
    try testing.expectEqual(0, ed.ghost.?.col);
    try ed.feed("w");
    try testing.expectEqual(4, ed.ghost.?.col); // "one"
    try ed.feed("e");
    try testing.expectEqual(6, ed.ghost.?.col); // end of "one"
    try ed.feed("w");
    try testing.expectEqual(8, ed.ghost.?.col); // "two"
    try ed.feed("w"); // past the end: on to the text line "c"
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(2, ed.cursorLine());
    try ed.feed("b"); // back into the ghost line's last word
    try testing.expectEqual(8, ed.ghost.?.col);
    try ed.feed("bb");
    try testing.expectEqual(0, ed.ghost.?.col);
    try ed.feed("b"); // back out to "new"
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(1, ed.cursorLine());
    // With an operator, w stays on text.
    try ed.feed("ggdw");
    try expectText(&ed, "\nnew\nc");
}

test "ghost lines: /, n, N, f and snipe reach into them" {
    var ed = try ghostEditor("x = 1\nold needle here\ny = 2", "x = 1\ny = 2");
    defer ed.deinit();
    // Rows: "x = 1", [old needle here], "y = 2"
    try ed.feed("/needle<CR>");
    try testing.expect(ed.ghost != null);
    try testing.expectEqual(4, ed.ghost.?.col);
    try ed.feed("fh"); // f within the ghost line
    try testing.expectEqual(11, ed.ghost.?.col);
    try ed.feed("gg/=<CR>"); // the "=" later on the same text line
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(2, ed.cursorCol());
    try ed.feed("gg");
    try ed.feed("/e<CR>"); // first 'e' after line 0's start: the ghost line
    try testing.expect(ed.ghost != null);
    try ed.feed("n");
    try testing.expect(ed.ghost != null); // more e's in the ghost line
    try ed.feed("N");
    try testing.expect(ed.ghost != null);
    try ed.feed("<Esc>gg");
    try ed.feed("sh"); // the only 'h' on screen is in the ghost line: jumps
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(11, ed.ghost.?.col);
    try ed.feed("<Esc>gg/zzz<Esc>"); // Esc returns to where we were
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(0, ed.cursorLine());
}

test "git: commit from the editor in a real repository" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const git = struct {
        fn run(d: []const u8, args: []const []const u8) ![]u8 {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(testing.allocator);
            try argv.appendSlice(testing.allocator, &.{ "git", "-C", d });
            try argv.appendSlice(testing.allocator, args);
            const r = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items });
            testing.allocator.free(r.stderr);
            return r.stdout;
        }
    }.run;
    for ([_][]const []const u8{
        &.{ "init", "-q", "-b", "main" },
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| gpa.free(try git(dir, args));

    var ed = try testEditor("");
    defer ed.deinit();
    ed.git_checked = true;
    ed.git_root = try gpa.dupe(u8, dir);
    const file = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{dir});
    defer gpa.free(file);
    try ed.openFile(file);
    try ed.feed("ihello<Esc>");

    try ed.feed("<Space>gcfirst commit<CR>");
    try testing.expect(!ed.buffer.modified); // saved before committing
    while (ed.git_job) |job| {
        if (job.done.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    ed.tick();
    try testing.expectEqual(.info, ed.message.kind);
    const log = try git(dir, &.{ "log", "--format=%s" });
    defer gpa.free(log);
    try testing.expectEqualStrings("first commit\n", log);
}

test "files: save as, rename, copy, delete, new" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const at = struct {
        fn path(d: []const u8, name: []const u8) ![]u8 {
            return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ d, name });
        }
    }.path;
    const a = try at(dir, "a.txt");
    defer gpa.free(a);
    const b = try at(dir, "sub/b.zig");
    defer gpa.free(b);
    const c = try at(dir, "c.zig");
    defer gpa.free(c);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.git_checked = true; // no repository

    // A scratch buffer: SPC f s asks for a name, then saves there.
    try ed.feed("ihello<Esc><Space>fs");
    try testing.expectEqual(PromptKind.save_as, ed.search_prompt.?.kind);
    try ed.search_prompt.?.input.set(gpa, a);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, a, ed.buffer.path.?));
    try testing.expect(!ed.buffer.modified);
    const saved = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(1024));
    defer gpa.free(saved);
    try testing.expectEqualStrings("hello\n", saved);

    // Rename into a new folder: the file moves and the language follows.
    try ed.feed("<Space>fR");
    try testing.expect(std.mem.endsWith(u8, a, ed.search_prompt.?.input.items())); // prefilled
    try ed.search_prompt.?.input.set(gpa, b);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, b, ed.buffer.path.?));
    try testing.expect(ed.buffer.syntax != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "a.txt", .{}));
    try tmp.dir.access(io, "sub/b.zig", .{});

    // Copy: writes a copy (unsaved edits included) and opens it; the
    // original keeps its unsaved state.
    try ed.feed("A!<Esc><Space>fC");
    try ed.search_prompt.?.input.set(gpa, c);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, c, ed.buffer.path.?));
    try testing.expectEqualStrings("hello!", ed.text().slice(0, ed.text().len()));
    try testing.expect(ed.buffers.items[0].modified);

    // Refuses to overwrite an existing file.
    try ed.feed("<Space>fS");
    try ed.search_prompt.?.input.set(gpa, b);
    try ed.feed("<CR>");
    try testing.expectEqual(.err, ed.message.kind);
    try testing.expect(std.mem.endsWith(u8, c, ed.buffer.path.?));

    // Delete: "No" keeps it, "Yes" removes it and closes the buffer.
    try ed.feed("<Space>fD<CR>");
    try tmp.dir.access(io, "c.zig", .{});
    try ed.feed("<Space>fDyes<CR>");
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "c.zig", .{}));
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expect(std.mem.endsWith(u8, b, ed.buffer.path.?));

    // New file: prefilled with the current folder; created on first save.
    try ed.feed("<Space>fn");
    try testing.expect(std.mem.endsWith(u8, ed.search_prompt.?.input.items(), "sub/"));
    try ed.feed("new.txt<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "sub/new.txt"));
    try testing.expectEqual(2, ed.buffers.items.len);
}

test "file browser: into folders, up, open, create" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.txt", .data = "hi\n" });
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    ed.git_checked = true;
    const readme = try std.fmt.allocPrint(gpa, "{s}/readme.txt", .{dir});
    defer gpa.free(readme);
    try ed.openFile(readme);

    const rows = struct {
        fn get(e: *Editor, i: usize) []const u8 {
            e.picker.?.sync();
            return e.picker.?.itemAt(i).?.text;
        }
    }.get;

    // Opens in the file's folder: folders first.
    try ed.feed("<Space>.");
    try testing.expectEqualStrings(dir, ed.browse_dir.items);
    try testing.expectEqualStrings("src/", rows(&ed, 0));
    try testing.expectEqualStrings("readme.txt", rows(&ed, 1));

    // `/` on a folder goes in; typing filters; <BS> edits, then goes up and
    // selects the folder we came from.
    try ed.feed("/");
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/src"));
    try testing.expectEqualStrings("deep/", rows(&ed, 0));
    try ed.feed("ma");
    try testing.expectEqualStrings("main.zig", rows(&ed, 0));
    try ed.feed("<BS><BS><BS>");
    try testing.expectEqualStrings(dir, ed.browse_dir.items);
    ed.picker.?.sync();
    try testing.expectEqual(0, ed.picker.?.selected); // "src/"
    try ed.feed("<Down><BS>");
    ed.picker.?.sync();
    // Up from tmp dir; then back down via <CR> on a folder.
    try ed.feed("<Esc><Space>.<CR>ma<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    try testing.expect(ed.picker == null);

    // A new name offers to create it in the browsed folder.
    try ed.feed("<Space>.new.zig<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/new.zig"));
}

test "dib / ci\" jump to the nearest pair ahead" {
    var ed = try testEditor("let v = foo(a, b);\nprint(\"old\")");
    defer ed.deinit();
    try ed.feed("dib");
    try expectText(&ed, "let v = foo();\nprint(\"old\")");
    try testing.expectEqual(12, ed.view.cursor);
    try ed.feed("ciqnew<Esc>");
    try expectText(&ed, "let v = foo();\nprint(\"new\")");
    try ed.feed("gg0va[");
    try testing.expectEqual(.visual, ed.mode); // no [] anywhere: nothing selected, no crash
}

test "autopairs: pair, step over, quotes, split blocks" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ifoo(a<Esc>");
    try expectText(&ed, "foo(a)");
    try ed.feed("cc<Esc>ifoo(a, \"x\")<Esc>"); // `"` pairs, then steps over; `)` steps over
    try expectText(&ed, "foo(a, \"x\")");
    try ed.feed("odon't (x<Esc>"); // no pair inside a word
    try expectText(&ed, "foo(a, \"x\")\ndon't (x)");
    try ed.feed("ofn f() {<CR>body<Esc>");
    try expectText(&ed, "foo(a, \"x\")\ndon't (x)\nfn f() {\n    body\n}");
    try ed.feed("<Space>tpGo(<Esc>"); // toggled off
    try expectText(&ed, "foo(a, \"x\")\ndon't (x)\nfn f() {\n    body\n}\n(");
}

test "surround: ys, yss, ds, cs, visual S, and dot" {
    var ed = try testEditor("say hello world");
    defer ed.deinit();
    try ed.feed("wysiw)");
    try expectText(&ed, "say (hello) world");
    try ed.feed("cs)]");
    try expectText(&ed, "say [hello] world");
    try ed.feed("cs]{");
    try expectText(&ed, "say { hello } world");
    try ed.feed("ds{");
    try expectText(&ed, "say hello world");
    try ed.feed("0ysiw\"3w."); // the cursor lands on the new opening quote
    try expectText(&ed, "\"say\" \"hello\" world");
    try ed.feed("0ds\"");
    try expectText(&ed, "say \"hello\" world");
    try ed.feed("0ds\""); // seeks the next pair
    try expectText(&ed, "say hello world");
    try ed.feed("yssb");
    try expectText(&ed, "(say hello world)");
    try ed.feed("0wviwS*");
    try expectText(&ed, "(*say* hello world)");
    try ed.feed("0d/hel<CR>");
    try expectText(&ed, "hello world)");
    try ed.feed("VS{");
    try expectText(&ed, "{\nhello world)\n}");
}

test "multicursor: visual I/A types on every line" {
    var ed = try testEditor("a\n  b\nc");
    defer ed.deinit();
    try ed.feed("VjjA,<Esc>");
    try expectText(&ed, "a,\n  b,\nc,");
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("<Esc>"); // removes the extra cursors
    try testing.expectEqual(0, ed.cursors.items.len);
    try ed.feed("ggVjjI- <Esc>");
    try expectText(&ed, "- a,\n  - b,\n- c,");
    // One undo step for the whole multi-cursor change.
    try ed.feed("u");
    try expectText(&ed, "a,\n  b,\nc,");
}

test "multicursor: normal-mode commands run at every cursor" {
    var ed = try testEditor("foo: u32,\nbarbaz: u8,\nx: bool,");
    defer ed.deinit();
    try ed.feed("qjqj"); // three cursors down the column
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("0i.<Esc>f:C = 0,<Esc>");
    try expectText(&ed, ".foo = 0,\n.barbaz = 0,\n.x = 0,");
    try ed.feed("<Esc>dd");
    try testing.expectEqual(0, ed.cursors.items.len);
}

test "multicursor: gzn adds the next match, then ciw changes all" {
    var ed = try testEditor("let a = old; old(old_x); old");
    defer ed.deinit();
    try ed.feed("foqnqn");
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("ciwnew<Esc>");
    try expectText(&ed, "let a = new; new(old_x); new");
    try ed.feed("<Esc>uggfoqa");
    try testing.expectEqual(2, ed.cursors.items.len); // old_x is not the word
    try ed.feed("<Esc>");
}

test "multicursor: Tab in the snipe or search prompt makes cursors" {
    var ed = try testEditor("int a; int b;\nfloat c; int d;");
    defer ed.deinit();
    ed.view.rows = 10;
    try ed.feed("sint<Tab>");
    try testing.expectEqual(.visual, ed.mode);
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("cuint<Esc>");
    try expectText(&ed, "uint a; uint b;\nfloat c; uint d;");
    try ed.feed("<Esc>gg/uint<Tab><Esc>");
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("x"); // each cursor is on its match's last character
    try expectText(&ed, "uin a; uin b;\nfloat c; uin d;");
}

test "windows: split, move, edit in one shows in the other, close" {
    var ed = try testEditor("one\ntwo\nthree");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.feed("<Space>wsl"); // split right: focus moves to the new window
    try testing.expectEqual(2, ed.window_list.items.len);
    const right = ed.window;
    try ed.feed("G");
    try ed.feed("<Space>wh");
    try testing.expect(ed.window != right);
    try testing.expectEqual(0, ed.cursorLine()); // each window has its own cursor
    // Typing above shifts the other window's cursor with the text.
    try ed.feed("Onew<Esc>");
    try testing.expectEqual(3, right.view.cursor - ed.text().lineStart(3) + 3);
    try ed.feed("<Space>wl");
    try testing.expectEqual(right, ed.window);
    try testing.expectEqual(3, ed.cursorLine()); // still on "three"
    try ed.feed("<Space>ww"); // wraps to the first window
    try testing.expect(ed.window != right);
    try ed.feed("<Space>wsj<Space>wd<Space>wd");
    try testing.expectEqual(1, ed.window_list.items.len);
    try ed.feed("<Space>wd"); // the last window stays
    try testing.expectEqual(1, ed.window_list.items.len);
}

test "windows: killing a buffer shown in another window" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile("zile-test-a.txt");
    try ed.feed("<Space>wsl");
    try ed.openFile("zile-test-b.txt");
    const b = ed.buffer;
    try ed.feed("<Space>wh");
    try ed.feed("<Space>bb"); // flip to the other buffer: b, here too
    try testing.expectEqual(b, ed.buffer);
    try ed.feed("<Space>bk");
    // Both windows moved off the killed buffer.
    for (ed.window_list.items) |w| try testing.expect(ed.windowBuffer(w) != b);
}

test "buffers: new, last, kill others" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-a.txt");
    const a = ed.buffer;
    try ed.feed("<Space>bN");
    try testing.expect(ed.buffer != a);
    try ed.feed("<Space>bl");
    try testing.expectEqual(a, ed.buffer);
    try ed.feed("<Space>bN<Space>bN<Space>bO");
    try testing.expectEqual(1, ed.buffers.items.len);
}

test "jumplist: C-o / C-i, one entry per line, the picker" {
    var ed = try testEditor("a\nb\nc\nd\ne");
    defer ed.deinit();
    try ed.feed("jG"); // from line 2 to the end
    try ed.feed("gg"); // from the end to the top
    try ed.feed("/d<CR>"); // a search is a jump too
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("<C-o>");
    try testing.expectEqual(0, ed.cursorLine());
    try ed.feed("<C-o>");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("<C-o>");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<C-o>"); // nothing older
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<C-i><C-i><Tab>");
    try testing.expectEqual(3, ed.cursorLine()); // back where we started
    // Edits above keep entries on their text.
    try ed.feed("ggOnew<Esc>");
    try ed.feed("<C-o>");
    try testing.expectEqual(4, ed.cursorLine()); // "d" moved down a line
    // The picker lists newest first and goes where you pick.
    try ed.feed("<Space>sj");
    ed.picker.?.sync();
    try testing.expectEqual(.jumps, ed.picker.?.kind);
    try ed.feed("<CR>");
    try testing.expect(ed.picker == null);
}

fn waitForRun(ed: *Editor) void {
    while (ed.run.?.isRunning()) std.Thread.yield() catch {};
    ed.tick();
}

test "run: SPC r c shows output and how it ended; SPC r r remembers its command" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    ed.git_checked = true;
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });

    try ed.feed("<Space>rcecho hi; exit 4<CR>");
    try testing.expectEqual(.run, ed.popup.?);
    waitForRun(&ed);
    try testing.expectEqual(4, ed.run.?.exit_code);
    try testing.expectEqual(.err, ed.message.kind);
    const out = try ed.run.?.screenText(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "hi\n"));
    try testing.expect(std.mem.indexOf(u8, out, "exited 4") != null);
    try ed.feed("q");
    try testing.expectEqual(null, ed.popup);

    // The runner: first time empty, then prefilled with the last command.
    try ed.feed("<Space>rr");
    try testing.expectEqualStrings("", ed.search_prompt.?.input.items());
    try ed.feed("echo runner<CR>");
    waitForRun(&ed);
    try testing.expectEqual(0, ed.run.?.exit_code);
    try ed.feed("q<Space>rr");
    try testing.expectEqualStrings("echo runner", ed.search_prompt.?.input.items());
    try ed.feed("<CR>"); // Enter runs it again
    try testing.expectEqualStrings("echo runner", ed.run_command.?);
    waitForRun(&ed);
    try ed.feed("r"); // `r` in a finished run: once more
    waitForRun(&ed);
    try testing.expectEqual(0, ed.run.?.exit_code);
    try ed.feed("q<Space>ro"); // the output comes back
    try testing.expectEqual(.run, ed.popup.?);
}

test "terminal popup: keys go to the shell, Ctrl-\\ hides it and keeps it running" {
    var ed = try testEditor("text");
    defer ed.deinit();
    try ed.feed("<Space>ot");
    try testing.expectEqual(.shell, ed.popup.?);
    const shell = ed.shell.?;
    try ed.feed("<C-\\>");
    try testing.expectEqual(null, ed.popup);
    try testing.expect(shell.isRunning());
    try ed.feed("dd"); // back in the editor
    try expectText(&ed, "");
    try ed.feed("<C-\\>"); // the same shell again
    try testing.expectEqual(shell, ed.shell.?);
    try ed.feed("exit<CR>");
    while (shell.isRunning()) std.Thread.yield() catch {};
    ed.tick(); // an exited shell closes its popup
    try testing.expectEqual(null, ed.popup);
    try testing.expectEqual(null, ed.shell);
}

test "run errors: a failing run lists its errors; e and SPC r e open them; Enter jumps" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.git_checked = true;
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    try ed.feed("<Space>rcprintf 'src/main.zig:4:7: error: boom\\nnot/a/file.zig:1:1: error: x\\n'; exit 1<CR>");
    waitForRun(&ed);
    try testing.expectEqual(1, ed.run_errors.items.len); // only real files count
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("e"); // from the finished run's popup
    try testing.expectEqual(.run_errors, ed.picker.?.kind);
    ed.picker.?.sync();
    try testing.expectEqualStrings("error: boom", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    try testing.expectEqual(3, ed.cursorLine());
    try testing.expectEqual(6, ed.view.cursor - ed.text().lineStart(3));
    try ed.feed("<Space>re");
    try testing.expectEqual(.run_errors, ed.picker.?.kind);
}
