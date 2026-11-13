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
const Replace = @import("Replace.zig");
const sources = @import("picker/sources.zig");
const Completion = @import("lsp/Completion.zig");
const lsp_docs = @import("lsp/docs.zig");
const ResultGrid = @import("ResultGrid.zig");
const StoredData = @import("StoredData.zig");
const syntax_objects = @import("syntax/objects.zig");
const operators = @import("operators.zig");
const pairs = @import("pairs.zig");
const tags = @import("tags.zig");
const emmet = @import("emmet.zig");
const snippets = @import("snippets.zig");
const config = @import("config/config.zig");
const sql = @import("sql.zig");
const ZigCheck = @import("ZigCheck.zig");
const format = @import("format.zig");
const Ghost = @import("ai/Ghost.zig");
pub const Claude = @import("ai/Claude.zig");
const Syntax = @import("syntax/Syntax.zig");
const History = @import("core/History.zig");
const Snippet = @import("lsp/Snippet.zig");
pub const Windows = @import("Windows.zig");
pub const Project = @import("core/Project.zig");
pub const Terminal = @import("terminal/Terminal.zig");
const Pty = @import("terminal/Pty.zig");
const RunMemory = @import("terminal/RunMemory.zig");
const Debugger = @import("Debugger.zig");
const debugging = @import("debugging.zig");
pub const run_errors_mod = @import("terminal/errors.zig");
const textobjects = @import("core/textobjects.zig");
const textops = @import("textops.zig");
const indents = @import("core/indent.zig");
const comment = @import("core/comment.zig");
const Visits = @import("Visits.zig");
pub const ColorPicker = @import("ColorPicker.zig");
const hipatterns = @import("core/hipatterns.zig");
pub const Session = @import("Session.zig");
pub const Blame = @import("git/Blame.zig");
pub const blame = @import("editor/blame.zig");
pub const bracket_jumps = @import("editor/bracket_jumps.zig");
pub const color_wheel = @import("editor/color_wheel.zig");
pub const state_files = @import("editor/state_files.zig");
pub const formatting = @import("editor/formatting.zig");
pub const file_ops = @import("editor/file_ops.zig");
pub const notifications = @import("editor/notifications.zig");
pub const window_ops = @import("editor/window_ops.zig");
pub const project_ops = @import("editor/project_ops.zig");
pub const smooth_scrolling = @import("editor/smooth_scrolling.zig");
pub const inlay = @import("editor/inlay.zig");
pub const jumplist = @import("editor/jumplist.zig");
pub const indenting = @import("editor/indenting.zig");
pub const browser = @import("editor/browser.zig");
pub const picker_ops = @import("editor/picker_ops.zig");
pub const picker_query = @import("editor/picker_query.zig");
pub const claude_panel = @import("editor/claude_panel.zig");
pub const quickfix_list = @import("editor/quickfix_list.zig");
pub const run_popup = @import("editor/run_popup.zig");
pub const multicursor = @import("editor/multicursor.zig");
pub const borders = @import("editor/borders.zig");
pub const resting = @import("editor/resting.zig");
pub const row_model = @import("editor/row_model.zig");
pub const folding = @import("editor/folding.zig");
pub const code_motion = @import("editor/code_motion.zig");
pub const row_search = @import("editor/row_search.zig");
pub const replacing = @import("editor/replacing.zig");
pub const prompts = @import("editor/prompts.zig");
pub const git_ops = @import("editor/git_ops.zig");
pub const signature_help = @import("editor/signature_help.zig");
pub const snippet_ops = @import("editor/snippet_ops.zig");
pub const ai_ghost = @import("editor/ai_ghost.zig");
pub const lsp_actions = @import("editor/lsp_actions.zig");
pub const after_typing = @import("editor/after_typing.zig");
pub const sql_ops = @import("editor/sql_ops.zig");
pub const completion_ops = @import("editor/completion_ops.zig");
pub const lsp_ops = @import("editor/lsp_ops.zig");

const Editor = @This();
pub const RowPos = row_search.RowPos;
pub const GrowStep = code_motion.GrowStep;
pub const CursorRest = resting.CursorRest;
pub const MouseHover = resting.MouseHover;
pub const opensPlaces = picker_ops.opensPlaces;
pub const LineHint = inlay.LineHint;
pub const max_line_hints = inlay.max_line_hints;
pub const hint_debounce_ms = inlay.hint_debounce_ms;
pub const hintShift = inlay.hintShift;
pub const hintShiftBefore = inlay.hintShiftBefore;
pub const hintVisualToText = inlay.hintVisualToText;
pub const Zoom = window_ops.Zoom;
pub const freeDiagnosticList = state_files.freeDiagnosticList;
pub const autosave = state_files.autosave;

pub const Mode = km.Mode;

pub const Options = struct {
    tab_width: usize = 4,
    /// Insert spaces for <Tab> in insert mode.
    expand_tab: bool = true,
    /// Lines kept visible above/below the cursor.
    scrolloff: usize = 0,
    // Toggles (SPC t ...):
    /// Show deleted/changed HEAD lines as ghost lines.
    ghost_lines: bool = true,
    /// Line numbers relative to the cursor line.
    relative_numbers: bool = false,
    /// Diagnostic messages after the end of lines (wrapped onto rows under
    /// them). Off: diagnostics are underlined, and the message pops up with
    /// the cursor or the mouse resting on one (as in Neovim and Helix).
    diagnostic_text: bool = false,
    /// The font's ligatures (`->` `!=` `=>` as one sign) in the window; in a
    /// terminal, the terminal's own setting decides.
    ligatures: bool = true,
    /// Close brackets and quotes as they are typed.
    auto_pairs: bool = true,
    /// Format a file (language server, else its formatter) when saving it.
    format_on_save: bool = true,
    /// AI ghost completion while typing (a local model through Ollama).
    ai_complete: bool = true,
    /// Todo words and colour literals stand out (mini.hipatterns).
    highlight_patterns: bool = true,
    /// Other occurrences of the word under the cursor (mini.cursorword).
    cursor_word: bool = true,
    /// A guide line along the cursor's indent scope (mini.indentscope).
    indent_scope: bool = true,
    /// Trailing whitespace stands out (mini.trailspace).
    trailing_space: bool = true,
    /// Remove trailing whitespace when saving.
    trim_on_save: bool = false,
    /// Code lens: the server's notes above definitions (`3 references`).
    code_lens: bool = true,
    /// The Files picker's search of your home folder skips `.git` folders,
    /// `node_modules`, caches and build output (`SPC t`; off: everything
    /// `rg --files --hidden` lists).
    home_filter: bool = true,
    /// The first lines of the scopes the top of the window is inside stay
    /// pinned there (treesitter-context; `SPC t k`).
    sticky_context: bool = true,
    /// Long lines wrap onto more rows, at word boundaries, keeping their
    /// indent (`SPC t l`); no sideways scrolling then.
    wrap: bool = true,
    /// A modified file is written when you leave it (another buffer or
    /// window) or zile loses focus, as the nvim config's autosave.
    autosave: bool = true,
    /// File-type icons in pickers (needs a Nerd Font).
    icons: bool = true,
    /// Scrolling glides instead of jumping (windows only, not terminals).
    smooth_scroll: bool = true,
    /// Who last changed the cursor's line, after its end.
    git_blame: bool = false,
    /// Stopped in the debugger: the values a line uses, after its end.
    debug_values: bool = true,
    /// Type and parameter labels from the language server, drawn inside the
    /// code (inlay hints).
    inlay_hints: bool = true,
    /// Folders searched (three levels deep) for projects to offer in
    /// `SPC p p` besides the ones opened before. A setting once there is
    /// config; nowhere in tests.
    project_dirs: []const []const u8 = if (@import("builtin").is_test) &.{} else &.{"/mnt/code"},
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
    /// Which of `top`'s rows is at the top (wrapped lines, code lens).
    top_sub: u16 = 0,
    /// Smooth scrolling: rows the drawn text still is from `top` (positive
    /// after scrolling down: it is drawn that much lower, gliding to 0).
    scroll_offset: f32 = 0,
    /// The part of a line the wheel has scrolled past `top` (touchpads and
    /// smooth wheels move by fractions): shown, so the text follows the
    /// wheel exactly, and settled onto a whole line when the wheel rests.
    scroll_frac: f32 = 0,
    /// Seconds since the wheel last moved.
    scroll_idle: f32 = 0,
    /// The top and buffer `scroll_offset` was last brought up to date for.
    seen_top: usize = 0,
    seen_buffer: ?*const Buffer = null,

    /// How many rows lower than its place the text is drawn right now.
    pub fn drawOffset(v: *const View) f32 {
        return v.scroll_offset - v.scroll_frac;
    }
};

/// A screen row: a text line (a closed fold counts as one), or one of the
/// ghost lines (old HEAD lines of a git hunk) shown before text line `line`.
pub const Row = struct {
    line: usize,
    ghost: ?u32 = null,
    /// Which screen row of the line: its code lens row first (if any), then
    /// the pieces it wraps into (0 for a line on one row; always 0 for a
    /// ghost row).
    sub: u16 = 0,

    pub fn eql(a: Row, b: Row) bool {
        return a.line == b.line and a.ghost == b.ghost and a.sub == b.sub;
    }

    /// Whether `a` is above `b` on screen.
    pub fn before(a: Row, b: Row) bool {
        if (a.line != b.line) return a.line < b.line;
        // Ghost rows come before their line's own rows.
        if (a.ghost) |ka| {
            const kb = b.ghost orelse return true;
            return ka < kb;
        }
        if (b.ghost != null) return false;
        return a.sub < b.sub;
    }
};

/// One screen row of a line: visual columns `[start, end)` (inlay hints
/// counted), drawn `indent` cells in (a wrapped line's later rows line up
/// under its indentation).
pub const Seg = struct { start: usize, end: usize, indent: usize };

/// Most rows a line wraps into (longer lines get a last, cut-off row).
pub const max_segments = 64;

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

/// A mark (`m{letter}`): lower-case ones belong to their buffer, upper-case
/// ones are global and remember their file. `path` is owned.
pub const Mark = struct {
    name: u8,
    buffer: ?*Buffer,
    path: ?[]u8,
    pos: usize,
};

/// A code action offered by the language server (`SPC l a`). `title`,
/// `kind` and `json` (the action as the server sent it) are owned.
pub const CodeAction = struct {
    title: []u8,
    kind: []u8,
    json: []u8,
};

/// A project-wide symbol from the language server (`SPC f w`); owned strings.
pub const WorkspaceSymbol = struct {
    name: []u8,
    kind: []const u8,
    path: []u8,
    line: usize,
    col: usize,
};

/// `run`: it runs. `runner`: it runs as a runner command (remembered).
/// `debug`: it runs under gdb, and is what its runner command debugs as.
pub const CommandPurpose = enum { run, runner, debug };

/// A quickfix entry: a place (0-based line/col) and what's there.
pub const QuickfixItem = struct {
    /// Owned. A buffer path (relative to the cwd, or absolute).
    path: []u8,
    line: usize,
    col: usize,
    /// Owned.
    text: []u8,

    pub fn deinit(q: QuickfixItem, gpa: Allocator) void {
        gpa.free(q.path);
        gpa.free(q.text);
    }
};

/// Where a picker opens its choice: this window, or a new split on a side.
pub const OpenTarget = enum {
    here,
    right,
    below,
    left,
    above,

    pub fn dir(t: OpenTarget) ?Windows.Dir {
        return switch (t) {
            .here => null,
            .right => .right,
            .below => .down,
            .left => .left,
            .above => .up,
        };
    }
};

/// A gray suggestion at `pos`: `text` is what Tab would insert.
pub const AiSuggestion = struct {
    buffer: *Buffer,
    pos: usize,
    /// Owned.
    text: []u8,

    /// What's still ahead of the cursor (typing the suggestion keeps it).
    pub fn remaining(s: AiSuggestion, cursor: usize) []const u8 {
        return s.text[@min(cursor - s.pos, s.text.len)..];
    }
};

/// A signature: its label and the active parameter's range in it.
pub const SignatureHelp = struct {
    label: []u8,
    param_start: usize = 0,
    param_end: usize = 0,
    /// First line of the documentation (of the parameter, else the call).
    doc: []u8,

    pub fn deinit(s: SignatureHelp, gpa: Allocator) void {
        gpa.free(s.label);
        gpa.free(s.doc);
    }
};

/// Filling in a snippet's placeholders: <Tab> / <S-Tab> move between them;
/// typing over a fresh one replaces it.
pub const SnippetSession = struct {
    buffer: *Buffer,
    /// Byte ranges, kept in place through edits; the last may be the final
    /// cursor ($0).
    stops: [][2]usize,
    has_final: bool,
    current: usize = 0,
    /// The current placeholder still holds its default text: the first key
    /// typed replaces it.
    fresh: bool = false,
    /// Past the arguments, at the end of the call: one more <Tab> goes to
    /// the end of the statement, adding its `;`.
    at_end: bool = false,
    /// What was accepted is a call (a function), so it may end with `;`.
    is_call: bool = false,
    /// Our own snippets' defaults are code (`catch (${2:err})`): <Esc>
    /// keeps them. A server's argument placeholders go.
    keep_defaults: bool = false,
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

/// A yanked range, flashed (`flash_ms` long, fading) so you can see what
/// was taken.
pub const YankFlash = struct {
    buffer: *Buffer,
    start: usize,
    end: usize,
    linewise: bool,
    born: Io.Timestamp,

    pub const flash_ms = 250;

    /// 1 at the start, 0 when done.
    pub fn strength(f: YankFlash, now: Io.Timestamp) f32 {
        const ms: f32 = @floatFromInt(@divTrunc(f.born.durationTo(now).nanoseconds, std.time.ns_per_ms));
        return std.math.clamp(1 - @max(ms, 0) / flash_ms, 0, 1);
    }
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
    /// `select_in`: the selection the matches are looked for in.
    within_start: usize = 0,
    within_end: usize = 0,
};

/// A key shown after a snipe's match: pressing it jumps there.
pub const SnipeLabel = struct { pos: usize, end: usize, key: u8 };

/// The label keys, for the nearest match first: out from the middle of the
/// home row, then the row above, then the one below.
pub const snipe_keys = "ghfjdksla;tyrueiwoqpbnvmcxz";

pub const PromptKind = enum {
    /// `/` `?`: incremental search.
    search,
    /// `s`: jump as soon as only one match is left on screen.
    snipe,
    /// Visual `qf` (Helix's `s`): a cursor on every match inside the
    /// selection.
    select_in,
    /// `SPC l r`: the new name for the symbol at `origin`.
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
    /// `SPC ;`: any one-off shell command.
    run_command,
    /// `SPC a i`: an instruction for Claude about the selection.
    ask_claude,
    /// The file browser's own operations (`o` `n` `r` `m` in its list): a
    /// name for a new folder or file, a new name, a new place.
    browse_new_folder,
    browse_new_file,
    browse_rename,
    browse_move,
    /// `<C-r>` in the grep picker: the replacement for every match.
    replace,

    /// One-line prompts shown in a centered box (not incremental searches).
    pub fn boxed(k: PromptKind) bool {
        return k != .search and k != .snipe and k != .select_in;
    }

    pub fn title(k: PromptKind) []const u8 {
        return switch (k) {
            .search, .snipe, .select_in => "",
            .rename => "Rename symbol",
            .replace => "Replace",
            .git_commit => "Commit message (commits all changes)",
            .git_remote => "Remote URL (origin)",
            .new_file => "New file (path)",
            .save_as => "Save as",
            .rename_file => "Rename / move file to",
            .copy_file => "Copy file to",
            .run_command => "Run command",
            .ask_claude => "Ask Claude (about the selection)",
            .browse_new_folder => "New folder (name)",
            .browse_new_file => "New file (name)",
            .browse_rename => "Rename to",
            .browse_move => "Move to (path)",
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

pub const IndentGuide = struct {
    buffer: *const Buffer,
    scope: indents.Scope,
    /// The guide is drawn growing out from this line (where the cursor was
    /// when it appeared), since this moment.
    origin: usize = 0,
    born: Io.Timestamp = .zero,

    /// How many rows the guide has grown from its origin by `now`, each way
    /// (a fraction while a row is part drawn).
    pub fn reach(g: IndentGuide, now: Io.Timestamp) f32 {
        const ms: f32 = @floatFromInt(@divTrunc(g.born.durationTo(now).nanoseconds, std.time.ns_per_ms));
        return @max(ms, 0) / indent_guide_step_ms;
    }

    /// Still growing (as far as lines `top..bottom` on screen are concerned).
    pub fn growing(g: IndentGuide, now: Io.Timestamp, top: usize, bottom: usize) bool {
        const up = g.origin -| @max(g.scope.first, top);
        const down = @min(g.scope.last, bottom) -| g.origin;
        return g.reach(now) < @as(f32, @floatFromInt(@max(up, down)));
    }

    /// The same block (it may have grown or shrunk at its end while typing).
    pub fn same(a: ?IndentGuide, b: ?IndentGuide) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return x.buffer == y.buffer and x.scope.first == y.scope.first and x.scope.guide_col == y.scope.guide_col;
    }
};

/// How long the cursor's scope must stay the same before its guide is drawn
/// (mini.indentscope's `draw.delay`).
pub const indent_guide_delay_ms = 100;
/// The guide then grows a row every this many milliseconds (mini's
/// animation: 20 ms a step).
pub const indent_guide_step_ms = 20;

/// A notification shown at the top right for a few seconds (mini.notify):
/// things that happen on their own (a language server's progress, a git
/// command finishing), as opposed to the status line's answer to a key.
pub const Toast = struct {
    kind: Message.Kind = .info,
    /// Progress toasts are found again by key and updated in place.
    key: u64 = 0,
    /// Still in progress: stays up until it is done.
    busy: bool = false,
    expires: Io.Timestamp = .zero,
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub const lifetime_ms = 4000;
    pub const fade_ms = 500;

    pub fn text(t: *const Toast) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn set(t: *Toast, comptime fmt: []const u8, args: anytype) void {
        var w: Io.Writer = .fixed(&t.buf);
        w.print(fmt, args) catch {};
        t.len = w.buffered().len;
    }
};

/// A past message or notification (`SPC f n`). `text` is owned.
pub const HistoryEntry = struct {
    kind: Message.Kind,
    text: []u8,
};

const max_history = 200;
pub const max_toasts = 6;

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
/// A menu kept open by a sticky command (`SPC w r` resize mode).
sticky_menu: bool = false,
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
/// The terminal popup's shell (`SPC r t`), kept running while hidden.
shell: ?*Terminal = null,
/// The last command run (`SPC r`), its terminal, and when it started.
run: ?*Terminal = null,
run_command: ?[]u8 = null,
run_started: Io.Timestamp = .zero,
/// Where the last run ran (its project root; borrowed).
run_root: []const u8 = ".",
/// The memory `run_root` points into, once a command has run.
run_root_owned: ?[]u8 = null,
/// The end of the run was reported (printed under its output).
run_reported: bool = true,
/// The last run was under the debugger (`r` in its popup debugs it again).
run_debug: bool = false,
/// Debugging: the session, breakpoints, what to debug (debugging.zig).
dbg: debugging.State = .{},
/// The quickfix list (`]q` / `[q`, `SPC f q`): places to step through,
/// from a run's errors or a picker's results (`<C-q>`).
quickfix: std.ArrayList(QuickfixItem) = .empty,
quickfix_title: std.ArrayList(u8) = .empty,
/// The entry last visited, if any.
quickfix_index: ?usize = null,
/// Where the list came from. With none of your own (`none`, `live`) it is
/// the project's errors as the language server reports them right now,
/// rebuilt each time it is used; a run's errors or a picker's results
/// (`<C-q>`) stay until replaced or cleared (`x in the quickfix picker`).
quickfix_origin: enum { none, live, run, picked } = .none,
/// Stands in for the language servers' diagnostics (tests).
live_errors_override: ?[]const QuickfixItem = null,
/// Errors found in the last run's output (`SPC r e`).
run_errors: std.ArrayList(run_errors_mod.Error) = .empty,
/// The command editor (`SPC r c`): a small floating window with its own
/// scratch buffer, focused while open. Full vim editing works in it.
cmd_float: ?*Windows.Window = null,
/// The window to return to when the command editor closes.
cmd_return: ?*Windows.Window = null,
/// What Enter in the command editor does with the command.
cmd_purpose: CommandPurpose = .run,
/// For `.debug`: the runner command this is the debugger's version of
/// (owned).
cmd_from: ?[]u8 = null,
/// Which terminal the popup shows, if open. Keys go to it.
popup: ?enum { shell, run } = null,
/// The popup's size, kept current by the UI (new terminals start at it).
term_size: Pty.Size = .{ .cols = 80, .rows = 24 },
/// Text size: a zoom step the UI applies by reloading the font (+1/-1 pt
/// steps; `zoom_reset` back to the starting size).
zoom_request: i32 = 0,
zoom_reset: bool = false,
/// Terminal default colors (the UI sets them from the theme).
term_fg: ?Terminal.Rgb = null,
term_bg: ?Terminal.Rgb = null,
/// Where the code runner remembers commands (null: the default location).
run_memory_path: ?[]u8 = null,
/// Jumplist (`<C-o>` / `<C-i>`, `SPC f j`): places left by jumps, oldest
/// first. `jump_index` is the entry being visited, or `jumps.len` when not
/// moving through the list.
jumps: std.ArrayList(Jump) = .empty,
jump_index: usize = 0,
/// The language server's last answers for `SPC l a` and `SPC f w`.
code_actions: std.ArrayList(CodeAction) = .empty,
workspace_symbols: std.ArrayList(WorkspaceSymbol) = .empty,
/// Marks (`m{letter}`, `'{letter}`, `SPC f m`).
marks: std.ArrayList(Mark) = .empty,
/// Surround in progress: the range `ys` will wrap, the pair `cs` replaces.
surround_range: operators.Range = .{ .start = 0, .end = 0 },
/// `ga{motion}`: the lines to align once the character is typed.
align_range: operators.Range = .{ .start = 0, .end = 0 },
/// `gx`: the first of the two texts to exchange (dropped if the buffer is
/// edited before the second is picked).
exchange_mark: ?struct { buffer: *Buffer, version: u64, range: operators.Range } = null,
/// The colour wheel (`SPC l c`), while it is open: it takes every key.
color_picker: ?ColorPicker = null,
/// The indent scope guide: the scope drawn, and the one waiting to be
/// (a scope has to hold still for `indent_guide_delay_ms` before its guide
/// appears, so travelling through a file doesn't flash one per block).
indent_guide: ?IndentGuide = null,
indent_candidate: ?IndentGuide = null,
indent_since: Io.Timestamp = .zero,
/// The last key was an f/t jump: its other targets are highlighted.
find_shown: bool = false,
/// The last thing done was a find (`f`, `t`, `,`...), no change since: `.`
/// repeats the find instead of the last change.
find_dot: bool = false,
/// The same for a snipe (`t`): `.` / `,` go to the next / previous match.
snipe_dot: bool = false,
/// The keys that jump to a snipe's matches on screen, nearest match first
/// (`snipeLabels`).
snipe_label_buf: [snipe_keys.len]SnipeLabel = undefined,
snipe_label_count: usize = 0,
/// What was just yanked, lit for a moment.
yank_flash: ?YankFlash = null,
/// The screen column kept while moving up and down through wrapped lines,
/// valid while the cursor is still where that move left it.
wrap_want: ?struct { cursor: usize, screen: usize } = null,
/// A mouse press in progress: where it went down, and whether it has
/// selected anything (copied on release).
mouse_drag: ?struct {
    anchor: usize,
    selected: bool = false,
    /// Pressed on a ghost line: that hunk and line (the selection is whole
    /// ghost lines of that hunk), and the last one the pointer was on.
    ghost: ?struct { line: usize, k: u32, last: u32 } = null,
} = null,
/// The text last changed or yanked (`gV` selects it); edits made by one
/// command add up.
last_changed: ?struct { buffer: *Buffer, start: usize, end: usize, linewise: bool, group: u64 } = null,
/// Counts finished commands (one edit group each, for `last_changed`).
command_seq: u64 = 0,
/// A tag name being edited and its partner's (`tags.zig`): the partner
/// follows.
tag_link: ?tags.Link = null,
/// The partner is being changed (not an edit to link anew).
tag_mirroring: bool = false,
/// The colour scheme: an index into `theme_names` (set by the UI, which owns
/// the themes), and the one to go back to if the theme picker is cancelled.
theme_index: usize = 0,
theme_names: []const []const u8 = &.{},
theme_before: usize = 0,
/// Notifications on screen, and every message so far (`SPC f n`).
toasts: std.ArrayList(Toast) = .empty,
history: std.ArrayList(HistoryEntry) = .empty,
/// The time of the current frame (toasts expire against it).
now: Io.Timestamp = .zero,
/// Files visited before, across sessions (`SPC f r`, file picker order).
visits: Visits = .{},
/// `git blame` results per buffer (inline blame, `SPC t b`).
blames: std.ArrayList(struct { buffer: *Buffer, blame: *Blame }) = .empty,
/// Wheel movement not yet a whole line (with smooth scrolling off).
wheel_rest: f32 = 0,
/// Where state files go instead of `$XDG_STATE_HOME/zile` (tests).
state_dir: ?[]const u8 = null,
surround_from: u21 = 0,
op: ?PendingOp = null,
/// Visual mode selects whole lines (`V`).
visual_line: bool = false,
/// Where the cursor was when visual mode began: a yank goes back there.
visual_origin: usize = 0,
/// `Alt-u` grew the selection from these (`Alt-i` goes back), while the
/// selection is still `grown` in this buffer at this text version.
grow_stack: std.ArrayList(GrowStep) = .empty,
/// Vim editing of the picker's query in its normal mode: an operator
/// waiting (`d` `c` `y`), then `i` / `a` waiting for its object, and the
/// query as it was before each change (`u`).
query_op: ?u8 = null,
query_obj: ?u8 = null,
query_undo: std.ArrayList(struct { text: []u8, cursor: usize }) = .empty,
grown: ?struct { buffer: *Buffer, version: u64, range: textobjects.Range } = null,
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
/// Search and replace across the project (`<C-r>` in the grep picker),
/// while its prompt is open.
replace: ?*Replace = null,
/// The folder it searches (not owned), for going back to the grep picker.
replace_root: []const u8 = ".",
last_search: std.ArrayList(u8) = .empty,
last_search_forward: bool = true,
last_search_whole_word: bool = false,
/// Highlight matches of the last search (cleared with <Esc>).
search_highlight: bool = false,

/// Running language servers, by index into `Lsp.servers`, started on demand.
lsps: std.ArrayList(*Lsp) = .empty,
/// SQL completion's tables and columns, the SQL buffer they were last
/// looked up for, and whether a statement that changes tables has run.
sql_schema: ?*sql.Schema = null,
/// The last statement run with Ctrl-Enter: running, or its rows (kept for
/// the results picker to come back to).
sql_results: ?*sql.Results = null,
/// The "Stored data" row `x` was pressed on once (a second `x` clears it).
stored_confirm: ?u32 = null,
/// The results grid over the code (Ctrl-Enter's rows), while it is open.
grid: ?ResultGrid = null,
/// `sql_results` has finished and was shown (or said).
sql_results_seen: bool = true,
sql_checked: ?*const Buffer = null,
sql_reload: bool = false,
sql_fresh: bool = false,
/// A JS/TS save in progress (`saveChainNext`).
save_chain: ?struct { buffer: *Buffer, step: enum { start, fix_all, organize, done }, started: Io.Timestamp } = null,
/// Compile checks of standalone Zig files running, and their results by
/// buffer (merged into `diagnostics`).
zig_checks: std.ArrayList(struct { buffer: *Buffer, job: *ZigCheck }) = .empty,
check_results: std.ArrayList(struct { buffer: *Buffer, diags: []Lsp.Diagnostic, libc: bool }) = .empty,
/// Diagnostics of several servers for one file, merged (`diagnostics`).
merged_diagnostics: std.ArrayList(Lsp.Diagnostic) = .empty,
/// Linters looked for per project ("index:root" -> absent there).
linter_checked: std.StringHashMapUnmanaged(bool) = .empty,
/// A server could not be started or exited; don't keep retrying it.
lsp_failed: [Lsp.max_servers]bool = @splat(false),
/// Times each server was restarted after exiting (given up after a few).
lsp_restarts: [Lsp.max_servers]u8 = @splat(0),
/// The server's program isn't installed (said when an action needs it).
lsp_missing: [Lsp.max_servers]bool = @splat(false),
/// Formatters found missing on a save (said once per session).
format_missing_told: std.StringHashMapUnmanaged(void) = .empty,
/// The outline shown by the symbols picker (`SPC f s`).
symbols: std.ArrayList(syntax_objects.Symbol) = .empty,
/// The buffer a Yes/No confirmation (`SPC b x`) is about.
confirm_target: ?*Buffer = null,
/// The file browser's entry being renamed, moved or deleted, and the one
/// copied with `yy` (absolute paths; owned).
browse_target: ?[]u8 = null,
browse_clip: ?[]u8 = null,
/// Results of the last definition/references request, for the picker.
locations: std.ArrayList(Lsp.Location) = .empty,
/// Hover text shown near the cursor until the next key.
hover: ?[]u8 = null,
/// Where the mouse rests (diagnostics under it pop up).
mouse_hover: ?MouseHover = null,
/// Where the text cursor rests (diagnostics under it pop up).
cursor_rest: ?CursorRest = null,
/// The process's environment (a server started with a variable added gets
/// a copy); null in tests.
environ: ?*const std.process.Environ.Map = null,
/// The window border being dragged with the mouse.
border_drag: ?*Windows.Split = null,
completion: ?Completion = null,
/// The call the cursor is in (signature help), shown above it while typing.
signature: ?SignatureHelp = null,
/// Placeholders of an accepted snippet (function arguments) to fill in.
snippet: ?SnippetSession = null,
/// AI ghost completion: the worker (started on first use), the latest
/// request, and the suggestion shown at the cursor.
ai: ?*Ghost = null,
ai_gen: u64 = 0,
ai_asked: ?struct { buffer: *Buffer, pos: usize, version: u64 } = null,
ai_suggestion: ?AiSuggestion = null,
/// The model couldn't be reached: off until toggled again.
ai_unreachable: bool = false,
/// Claude Code: the connection, its panel's terminal, pending diffs.
claude: ?*Claude = null,
/// The editor window to come back to from a terminal window.
last_editor_window: ?*Windows.Window = null,
/// When Esc last went to a terminal (a second one soon after leaves it).
last_term_esc: Io.Timestamp = .zero,
/// Shells in windows (`SPC r w`); closing a window ends its shell.
shells: std.ArrayList(*Terminal) = .empty,
/// When open buffers were last checked for changes on disk.
last_disk_check: Io.Timestamp = .zero,
/// What `SPC a i` asks about: a file and its selected lines.
claude_ask: ?struct { path: []u8, lines: ?[2]usize } = null,
/// Tests never ask a model (they mustn't depend on one running).
ai_offline: bool = @import("builtin").is_test,
/// Word start a completion was last requested for, and whether its answer
/// is still on the way (so a key doesn't ask again for the same thing).
completion_asked: ?usize = null,
completion_pending: bool = false,

/// Repository root (found the first time a file opens), and whether we looked.
/// Every project seen (owned; buffers point into it).
projects: std.ArrayList(*Project) = .empty,
/// The project last worked in: the current one when the buffer has none.
last_project: ?*const Project = null,
/// Projects opened before, most recent first (`SPC p p`), loaded lazily.
known_projects: ?std.ArrayList([]u8) = null,
/// The folder the open picker lists (files, grep): its project root.
picker_root: []const u8 = ".",
/// Set to make the next picker list another project (`SPC p p`).
next_picker_root: ?[]const u8 = null,
/// A picker choice waiting for the "Open in..." menu (<Tab>) to say where.
pending_choice: ?Picker.Choice = null,
/// The picker the <Tab> action menu was opened from, and its query: an
/// action that keeps it open (close a buffer) brings it back.
action_origin: ?Picker.Kind = null,
action_query: std.ArrayList(u8) = .empty,
/// The picker was opened from visual mode (and how): menus give the
/// selection back to the row they run.
picker_visual: ?struct { line: bool } = null,
/// A folder chosen to work in (`c` in Files): the project root from then
/// on (owned).
work_dir: ?[]u8 = null,
/// A maximised window's saved sizes (`toggleZoom`).
zoom: ?Zoom = null,
/// Where the file picked next opens (a project opened into a split).
deferred_target: ?OpenTarget = null,
/// Set while the cursor is on a ghost line.
ghost: ?GhostCursor = null,
/// The git command running in the background, if any.
git_job: ?*GitJob = null,

/// Keys of the command being typed, for the status line (vim's showcmd).
showcmd: [16]KeyEvent = undefined,
showcmd_len: usize = 0,

message: Message = .{},
should_quit: bool = false,

pub fn noWake() void {}

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
    var ed: Editor = .{
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
    // Until a file says otherwise, the project is where we started.
    if (Project.detect(io, cwd)) |f| ed.last_project = project_ops.internProject(&ed, f.root, f.git);
    return ed;
}

pub fn deinit(ed: *Editor) void {
    if (ed.picker) |p| p.destroy();
    if (ed.pending_choice) |c| c.deinit(ed.gpa);
    if (ed.cmd_float) |w| {
        // Its buffer isn't in `buffers`.
        if (w != ed.window) w.buffer.deinit(ed.gpa) else ed.buffer.deinit(ed.gpa);
        ed.gpa.destroy(if (w != ed.window) w.buffer else ed.buffer);
        ed.gpa.destroy(w);
    }
    if (ed.shell) |t| t.destroy();
    debugging.deinit(ed);
    if (ed.cmd_from) |f| ed.gpa.free(f);
    if (ed.run) |t| t.destroy();
    if (ed.run_command) |cmd| ed.gpa.free(cmd);
    if (ed.run_root_owned) |r| ed.gpa.free(r);
    for (ed.run_errors.items) |e| e.deinit(ed.gpa);
    ed.run_errors.deinit(ed.gpa);
    quickfix_list.clearQuickfix(ed);
    ed.quickfix.deinit(ed.gpa);
    ed.quickfix_title.deinit(ed.gpa);
    if (ed.run_memory_path) |path| ed.gpa.free(path);
    for (ed.lsps.items) |l| l.deinit();
    ed.lsps.deinit(ed.gpa);
    ed.merged_diagnostics.deinit(ed.gpa);
    for (ed.zig_checks.items) |zc| zc.job.destroy();
    if (ed.sql_schema) |sc| sc.destroy(ed.gpa);
    if (ed.grid) |*g| g.deinit();
    if (ed.sql_results) |r| r.destroy(ed.gpa);
    ed.zig_checks.deinit(ed.gpa);
    for (ed.check_results.items) |r| freeDiagnosticList(ed.gpa, r.diags);
    ed.check_results.deinit(ed.gpa);
    var lc = ed.linter_checked.keyIterator();
    while (lc.next()) |key| ed.gpa.free(key.*);
    ed.linter_checked.deinit(ed.gpa);
    lsp_ops.clearLocations(ed);
    ed.locations.deinit(ed.gpa);
    lsp_ops.clearSymbols(ed);
    ed.symbols.deinit(ed.gpa);
    if (ed.hover) |h| ed.gpa.free(h);
    after_typing.closeCompletion(ed);
    signature_help.closeSignature(ed);
    snippet_ops.endSnippet(ed);
    ai_ghost.clearAiSuggestion(ed);
    if (ed.ai) |g| g.destroy();
    if (ed.claude) |c| c.destroy();
    for (ed.shells.items) |t| t.destroy();
    ed.shells.deinit(ed.gpa);
    if (ed.claude_ask) |a| ed.gpa.free(a.path);
    if (ed.browse_target) |p| ed.gpa.free(p);
    if (ed.browse_clip) |p| ed.gpa.free(p);
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
    for (ed.projects.items) |p| {
        ed.gpa.free(p.root);
        ed.gpa.destroy(p);
    }
    ed.projects.deinit(ed.gpa);
    if (ed.known_projects) |*k| {
        for (k.items) |r| ed.gpa.free(r);
        k.deinit(ed.gpa);
    }
    if (ed.search_prompt) |*sp| sp.input.deinit(ed.gpa);
    if (ed.replace) |r| r.destroy();
    ed.grow_stack.deinit(ed.gpa);
    ed.format_missing_told.deinit(ed.gpa);
    if (ed.work_dir) |w| ed.gpa.free(w);
    ed.action_query.deinit(ed.gpa);
    for (ed.query_undo.items) |u| ed.gpa.free(u.text);
    ed.query_undo.deinit(ed.gpa);
    blame.dropAllBlames(ed);
    ed.blames.deinit(ed.gpa);
    state_files.saveVisits(ed);
    ed.visits.deinit(ed.gpa);
    ed.toasts.deinit(ed.gpa);
    for (ed.history.items) |h| ed.gpa.free(h.text);
    ed.history.deinit(ed.gpa);
    ed.last_search.deinit(ed.gpa);
    ed.change_keys.deinit(ed.gpa);
    ed.cursors.deinit(ed.gpa);
    ed.multi_keys.deinit(ed.gpa);
    for (ed.jumps.items) |j| if (j.path) |p| ed.gpa.free(p);
    ed.jumps.deinit(ed.gpa);
    for (ed.marks.items) |m| if (m.path) |p| ed.gpa.free(p);
    ed.marks.deinit(ed.gpa);
    lsp_actions.clearCodeActions(ed);
    ed.code_actions.deinit(ed.gpa);
    lsp_actions.clearWorkspaceSymbols(ed);
    ed.workspace_symbols.deinit(ed.gpa);
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
    git_ops.updateGit(ed);
    if (ed.buffer.syntax) |*s| {
        const t = ed.text();
        s.update(t);
        // While a scroll glides, the lines in view are the ones around where
        // the text is drawn, some rows from `top`.
        const off = ed.view.drawOffset();
        const shift: isize = if (off > 0) -@as(isize, @intFromFloat(@ceil(off))) else @intFromFloat(@floor(-off));
        const first = folding.stepVisible(ed, @min(ed.view.top, t.lineCount() - 1), shift);
        // With closed folds the screen reaches past `top + rows` raw lines.
        const last_visible = folding.stepVisible(ed, first, @intCast(ed.view.rows + 2));
        const last = if (folding.foldAt(ed, last_visible)) |f| f.last else last_visible;
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
    ed.now = Io.Timestamp.now(ed.io, .awake);
    state_files.keepUndoHistories(ed);
    state_files.tickZigChecks(ed);
    file_ops.tickSaveChain(ed);
    sql_ops.tickSqlSchema(ed);
    sql_ops.tickSqlResults(ed);
    row_model.tickCodeLens(ed);
    if (ed.yank_flash) |f| if (f.strength(ed.now) <= 0) {
        ed.yank_flash = null;
    };
    notifications.pruneToasts(ed);
    notifications.tickIndentGuide(ed);
    resting.tickCursorRest(ed);
    blame.ensureBlame(ed);
    lsp_ops.tickLsp(ed);
    inlay.tickInlayHints(ed);
    git_ops.pollGitJob(ed);
    quickfix_list.pollTerminals(ed);
    debugging.tickSearch(ed);
    debugging.tick(ed);
    ai_ghost.pollAi(ed);
    claude_panel.tickClaude(ed);
    window_ops.pollShellWindows(ed);
    ed.highlightView();
    if (ed.picker) |p| {
        p.poll();
        p.updatePreview();
    }
}

/// Whether `cmd` needs a program that isn't installed; if so, says so.
fn toolMissing(ed: *Editor, cmd: *const commands.Command) bool {
    if (cmd.needs.len == 0 or sources.onPath(ed.io, cmd.needs)) return false;
    ed.setMessage(.err, "{s} isn't installed", .{cmd.needs});
    return true;
}

/// Runs a command as if its key was pressed with no count (command picker).
pub fn runCommand(ed: *Editor, cmd: *const commands.Command) !void {
    if (ed.toolMissing(cmd)) return;
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
    if (color_wheel.colorKey(ed, ev)) return;
    if (run_popup.popupKey(ed, ev)) return;
    if (sql_ops.gridKey(ed, ev)) return;
    if (run_popup.cmdFloatKey(ed, ev)) return;
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
/// `<cmd:name>` runs command `name` (tests: commands that have no key of
/// their own, being a row or an action in a picker).
pub fn feed(ed: *Editor, notation: []const u8) keys.ParseError!void {
    var i: usize = 0;
    while (i < notation.len) {
        if (std.mem.startsWith(u8, notation[i..], "<cmd:")) {
            const close = std.mem.indexOfScalarPos(u8, notation, i, '>') orelse return error.InvalidNotation;
            const cmd = commands.find(notation[i + 5 .. close]) orelse return error.InvalidNotation;
            ed.runCommand(cmd) catch {};
            // As a key would end: the undo step closes, the view follows.
            ed.afterKey();
            ed.scrollToCursor();
            i = close + 1;
            continue;
        }
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
pub fn queueNotation(ed: *Editor, notation: []const u8, count: usize) !void {
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
    git_ops.updateGit(ed);
    // Hover text disappears on the next key.
    if (ed.hover) |h| {
        ed.gpa.free(h);
        ed.hover = null;
    }
    if (ed.mode != .insert and ed.mode != .picker and ed.mode != .picker_normal and ed.mode != .search and ed.showcmd_len < ed.showcmd.len) {
        ed.showcmd[ed.showcmd_len] = ev;
        ed.showcmd_len += 1;
    }
    // To notice a deletion in insert mode (completion follows it).
    const buffer_before = ed.buffer;
    const len_before = ed.text().len();
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
    if (multi) multicursor.multiAfterKey(ed);
    ed.afterKey();
    row_model.clampToFolds(ed);
    // Typing text (insert mode, a prompt) isn't a pending command.
    if (ed.mode == .insert or ed.mode == .search) ed.showcmd_len = 0;
    if (ed.completion != null) completion_ops.refreshCompletion(ed) catch after_typing.closeCompletion(ed);
    if (ed.mode == .insert and ed.buffer == buffer_before and ed.text().len() < len_before) completion_ops.afterDeleted(ed);
    if (ed.mode != .insert) {
        ed.completion_asked = null;
        signature_help.closeSignature(ed);
        snippet_ops.endSnippet(ed);
    }
    ai_ghost.updateAi(ed);
    ed.scrollToCursor();
}

/// Nothing half-typed: no pending keys, count, register, operator or argument.
pub fn isIdle(ed: *const Editor) bool {
    return ed.mode != .insert and ed.mode != .operator and ed.mode != .search and ed.pending_len == 0 and ed.count == 0 and
        ed.register == null and !ed.awaiting_register and ed.awaiting_char == null;
}

/// Ends a command: commits the undo group and finishes dot-repeat capture.
pub fn afterKey(ed: *Editor) void {
    // A renamed tag's partner follows as you type, in the same undo step.
    tags.sync(ed);
    if (!ed.isIdle()) return;
    ed.command_seq +%= 1;
    const b = ed.buffer;
    b.history.commit(ed.gpa) catch {};
    b.modified = b.history.isModified();
    if (ed.capturing) {
        if (ed.capture_repeatable) {
            ed.last_change.clearRetainingCapacity();
            ed.last_change.appendSlice(ed.gpa, ed.change_keys.items) catch {};
            ed.last_change_count = ed.capture_count;
            ed.find_dot = false;
            ed.snipe_dot = false;
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

pub fn handleKeyInner(ed: *Editor, ev: KeyEvent) !void {
    // A message stays up until the next command starts.
    if (ed.isIdle() and ed.mode != .picker and ed.mode != .picker_normal) ed.clearMessage();

    // `"x`: the register for the next command.
    if (ed.awaiting_register) {
        ed.awaiting_register = false;
        if (ev.text()) |cp| if (Registers.isValidName(cp)) {
            ed.register = @intCast(cp);
            return;
        };
        return ed.resetCommand();
    }

    // A picker's actions: Ctrl keys in either mode; in normal mode its
    // letters (and a menu's row keys), then vim keys edit the query.
    if ((ed.mode == .picker or ed.mode == .picker_normal) and try picker_query.openInKey(ed, ev)) return;
    if ((ed.mode == .picker or ed.mode == .picker_normal) and try picker_query.pickerCtrlAction(ed, ev)) return;
    if (ed.mode == .picker_normal and try picker_query.pickerQueryKey(ed, ev)) return;

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
        if (cp == 'Q' and ed.mode == .normal and ed.macro_register != null) return code_motion.stopMacro(ed);
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
            // The command editor holds its own scratch buffer: leader menus
            // (buffers, windows, files...) would pull it out from under it.
            if (ed.cmd_float != null and seq[0].key == .codepoint and seq[0].key.codepoint == ' ') {
                ed.resetCommand();
                return ed.setMessage(.info, "close the command editor first (<Esc> in normal mode)", .{});
            }
            // Leader menus, undo, `.` and the like act once, not per cursor.
            if (cmd.jump and !ed.replaying and (ed.mode == .normal or ed.mode == .visual)) jumplist.pushJump(ed);
            if (cmd.once or (seq[0].key == .codepoint and seq[0].key.codepoint == ' ')) ed.multi_once = true;
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
                if (ed.mode == .visual) code_motion.exitVisual(ed);
            }
            if (cmd.repeat) ed.capture_repeatable = true;
            ed.find_shown = false;
            if (cmd.takes_char) {
                ed.awaiting_char = .{ .cmd = cmd, .count = @max(count, 1), .has_count = has_count, .register = register };
                return;
            }
            if (ed.toolMissing(cmd)) return;
            try cmd.run(.{
                .ed = ed,
                .count = @max(count, 1),
                .has_count = has_count,
                .register = register,
            });
            // A sticky command keeps its menu open: the prefix stays typed.
            if (cmd.sticky and seq.len > 1 and ed.mode == .normal) {
                ed.pending_len = seq.len - 1;
                ed.sticky_menu = true;
                // The typed-keys indicator shows the menu we're in.
                const n = @min(ed.pending_len, ed.showcmd.len);
                @memcpy(ed.showcmd[0..n], ed.pending[0..n]);
                ed.showcmd_len = n;
            } else ed.sticky_menu = false;
        },
        .none => {
            // A key the open (sticky) menu doesn't have leaves it and then
            // acts as usual.
            if (ed.sticky_menu and seq.len > 1) {
                ed.sticky_menu = false;
                ed.pending_len = 0;
                ed.count = 0;
                return ed.handleKeyInner(ev);
            }
            ed.pending_len = 0;
            ed.count = 0;
            // Unbound keys in insert and picker modes are text, including any
            // keys held back as a possible multi-key binding prefix.
            switch (ed.mode) {
                .normal, .visual => ed.register = null,
                .operator => ed.resetCommand(),
                .insert => for (seq) |k| if (k.text()) |cp| {
                    // `(` with the suggestions open takes the selected one first.
                    if (cp == '(') try completion_ops.commitCompletionName(ed);
                    try snippet_ops.snippetTypeOver(ed);
                    if (!try tags.typed(ed, cp) and !try pairs.typed(ed, cp)) try ed.insertCodepoint(cp);
                    if (cp == '}' or cp == ')' or cp == ']') try indenting.dedentCloser(ed);
                    after_typing.afterTyped(ed, cp);
                },
                // Unbound keys while moving through results do nothing.
                .picker_normal => {},
                .picker, .search => {
                    if (seq.len == 1) if (seq[0].text()) |cp| if (try prompts.takeSnipeLabel(ed, cp)) return;
                    const input = prompts.activeInput(ed) orelse return;
                    for (seq) |k| if (k.text()) |cp| try input.insert(ed.gpa, cp);
                    try prompts.inputChanged(ed);
                },
            }
        },
    }
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

/// `ga{motion}`: the range is known; the character to align on comes next.
pub fn awaitAlignChar(ed: *Editor, r: operators.Range) void {
    ed.align_range = r;
    ed.awaitChar("align_char", 1);
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
    ed.visual_origin = ed.view.cursor;
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

pub fn placeCursor(ed: *Editor, pos: usize) void {
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
    row_model.setCursorRow(ed, row_model.stepRows(ed, row_model.cursorRow(ed), delta));
}

// ---------------------------------------------------------------------------
// Scrolling

pub fn setViewSize(ed: *Editor, rows: usize, cols: usize) void {
    ed.view.rows = @max(rows, 1);
    ed.view.cols = @max(cols, 1);
    // A file just opened: where it was left (or where a jump goes) in the
    // middle of the window, not at its edge.
    if (ed.buffer.center_on_show) {
        ed.buffer.center_on_show = false;
        picker_ops.centerCursor(ed);
    }
    ed.scrollToCursor();
}

pub fn effectiveScrolloff(ed: *const Editor) usize {
    return @min(ed.options.scrolloff, (ed.view.rows -| 1) / 2);
}

/// Adjusts the viewport so the cursor is visible with `scrolloff` margin.
pub fn scrollToCursor(ed: *Editor) void {
    const v = &ed.view;
    const cur = row_model.cursorRow(ed);
    const so = ed.effectiveScrolloff();
    // Keep `top` on a row that exists (folds and hunks change).
    var top = row_model.topRow(ed);
    top.line = folding.visibleLine(ed, @min(top.line, ed.text().lineCount() -| 1));
    if (top.ghost) |k| {
        const h = row_model.ghostHunk(ed, top.line);
        if (h == null or k >= h.?.old_count) top.ghost = null;
    }
    if (top.ghost != null or !row_model.layered(ed)) {
        top.sub = 0;
    } else top.sub = @intCast(@min(top.sub, row_model.subRows(ed, top.line) - 1));
    row_model.setTop(ed, top);
    if (cur.before(top) or row_model.rowsFrom(ed, top, cur, so) < so) {
        row_model.setTop(ed, row_model.stepRows(ed, cur, -@as(isize, @intCast(so))));
    } else {
        // Keep `so` rows below the cursor, but only rows that exist: near
        // the end of the text (or when it all fits) there is nothing to
        // scroll for, as in vim.
        const last: Row = .{ .line = folding.visibleLine(ed, ed.text().lineCount() -| 1) };
        const below = @min(so, row_model.rowsFrom(ed, cur, last, so));
        if (row_model.rowsFrom(ed, top, cur, v.rows) + below >= v.rows) {
            row_model.setTop(ed, row_model.stepRows(ed, cur, -@as(isize, @intCast(v.rows -| (below + 1)))));
        }
    }

    // Wrapped lines fit the width: no sideways scrolling.
    if (inlay.wraps(ed) and ed.ghost == null) {
        v.left = 0;
        return;
    }
    const col = if (ed.ghost) |g| g.col else ed.cursorCol();
    if (col < v.left) v.left = col;
    if (col >= v.left + v.cols) v.left = col + 1 - v.cols;
}

/// Scrolls the view by `delta` lines, dragging the cursor along when it
/// would leave the screen (vim's <C-e>/<C-y> and mouse wheel behavior).
pub fn scrollLines(ed: *Editor, delta: isize) void {
    const v = &ed.view;
    const top = row_model.stepRows(ed, row_model.topRow(ed), delta);
    row_model.setTop(ed, top);

    const so = ed.effectiveScrolloff();
    const cur = row_model.cursorRow(ed);
    const at_start = row_model.prevRow(ed, top).eql(top);
    const lo = if (at_start) top else row_model.stepRows(ed, top, @intCast(so));
    const hi = row_model.stepRows(ed, top, @intCast(v.rows -| (so + 1)));
    if (cur.before(lo)) {
        row_model.setCursorRow(ed, lo);
    } else if (hi.before(cur) and !hi.before(lo)) row_model.setCursorRow(ed, hi);
}

// ---------------------------------------------------------------------------
// Editing primitives

/// Keeps `last_changed` up to date for an edit replacing `[start, end)`
/// with `inserted` bytes: within one command the ranges merge.
fn noteChange(ed: *Editor, start: usize, end: usize, inserted: usize) void {
    if (ed.replaying) return;
    const removed = end - start;
    if (ed.last_changed) |*lc| if (lc.buffer == ed.buffer and lc.group == ed.command_seq and !lc.linewise) {
        // Shift the old range like the text around it, then take in the edit.
        const shift = struct {
            fn at(p: usize, s: usize, e: usize, ins: usize) usize {
                if (p <= s) return p;
                if (p >= e) return p - (e - s) + ins;
                return s + ins;
            }
        }.at;
        lc.start = @min(shift(lc.start, start, end, inserted), start);
        lc.end = @max(shift(lc.end, start, end, inserted), start + inserted);
        return;
    };
    _ = removed;
    ed.last_changed = .{ .buffer = ed.buffer, .start = start, .end = start + inserted, .linewise = false, .group = ed.command_seq };
}

/// A yank is the last change too, for `gV`.
pub fn noteYank(ed: *Editor, start: usize, end: usize, linewise: bool) void {
    ed.last_changed = .{ .buffer = ed.buffer, .start = start, .end = end, .linewise = linewise, .group = ed.command_seq -% 1 };
}

/// `gV`: visual mode over the text last changed or yanked.
pub fn selectLastChange(ed: *Editor) void {
    const lc = ed.last_changed orelse return ed.setMessage(.info, "nothing changed yet", .{});
    if (lc.buffer != ed.buffer) return ed.setMessage(.info, "the last change was in another file", .{});
    const t = ed.text();
    const start = @min(lc.start, t.len());
    const end = @min(lc.end, t.len());
    ed.enterVisual(lc.linewise);
    ed.view.anchor = start;
    ed.view.cursor = if (end > start) motions.prevChar(t, end) else start;
    ed.view.want_col = null;
}

/// `SPC t s`: the scratch pad (one markdown file for every project) in a
/// window at the bottom, or that window closed (saved) if it is open.
pub fn toggleScratch(ed: *Editor) !void {
    const path = ed.scratchPath() orelse return ed.setMessage(.err, "nowhere to keep the scratch pad", .{});
    defer ed.gpa.free(path);
    for (ed.window_list.items) |w| {
        const b = window_ops.windowBuffer(ed, w);
        const bp = b.path orelse continue;
        const abs = ed.absolutePath(bp) catch continue;
        defer ed.gpa.free(abs);
        if (!std.mem.eql(u8, abs, path)) continue;
        if (b.modified) _ = b.save(ed.gpa, ed.io) catch {};
        window_ops.focusWindow(ed, w);
        if (ed.window_list.items.len > 1) window_ops.closeWindow(ed);
        return;
    }
    if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(ed.io, d) catch {};
    try window_ops.splitWindow(ed, .down);
    Windows.resize(ed.window, .vertical, -0.25);
    try ed.openFile(path);
}

/// Where the scratch pad is kept (`$XDG_DATA_HOME/zile/scratch.md`; in
/// tests, the state folder). Caller frees.
pub fn scratchPath(ed: *Editor) ?[]u8 {
    if (ed.state_dir) |d| return std.fs.path.join(ed.gpa, &.{ d, "scratch.md" }) catch null;
    if (@import("builtin").is_test) return null;
    return config.dir(ed.gpa, .data, "scratch.md");
}

/// Inserts at `pos`, recording it for undo. Leaves the cursor alone.
pub fn insertAt(ed: *Editor, pos: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    tags.beforeEdit(ed, pos, pos, bytes.len);
    ed.noteChange(pos, pos, bytes.len);
    try ed.buffer.history.recordInsert(ed.gpa, pos, bytes, ed.view.cursor);
    try ed.buffer.insert(ed.gpa, pos, bytes);
    ed.buffer.modified = true;
    multicursor.shiftCursors(ed, pos, pos, bytes.len);
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
    tags.beforeEdit(ed, start, end, 0);
    ed.noteChange(start, end, 0);
    const t = ed.text();
    try ed.buffer.history.recordDelete(ed.gpa, start, t.slice(start, end), ed.view.cursor);
    ed.buffer.delete(start, end);
    ed.buffer.modified = true;
    multicursor.shiftCursors(ed, start, end, 0);
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
    loaded.center_on_show = true;
    loaded.line_listener = .{ .ctx = ed, .changed = debugging.breakpointLinesChanged };
    loaded.project = project_ops.projectOf(ed, norm);
    project_ops.enterProject(ed, loaded.project);
    // Replace an untouched scratch buffer instead of keeping it around, like vim.
    const cur = ed.buffer;
    if (cur.path == null and !cur.modified and cur.text.len() == 0) {
        lsp_ops.lspCloseBuffer(ed, cur);
        cur.deinit(ed.gpa);
        state_files.restoreFileState(ed, &loaded);
        cur.* = loaded;
        ed.use_counter += 1;
        cur.last_used = ed.use_counter;
        git_ops.loadGitBase(ed, cur);
        ed.activate(cur);
        state_files.recordVisit(ed, cur);
        return;
    }
    errdefer loaded.deinit(ed.gpa);
    state_files.restoreFileState(ed, &loaded);
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = loaded;
    try ed.buffers.append(ed.gpa, b);
    git_ops.loadGitBase(ed, b);
    ed.switchTo(b);
}

/// `relativePath` for paths the user typed (relative or absolute).
pub fn relativePath(ed: *Editor, path: []const u8) Allocator.Error![]u8 {
    return ed.normalizePath(path);
}

/// An owned absolute path for a buffer path.
pub fn absolutePath(ed: *Editor, path: []const u8) Allocator.Error![]u8 {
    // Resolved: no "..", "." or trailing "/" (so "../x" isn't taken to be
    // inside the cwd's project).
    return std.fs.path.resolve(ed.gpa, &.{ ed.cwd, path });
}

/// Opens `path` and puts the cursor at (`line`, `col`), both 0-based.
pub fn jumpTo(ed: *Editor, path: []const u8, line: usize, col: usize) !void {
    jumplist.pushJump(ed);
    try ed.moveTo(path, line, col);
}

/// `jumpTo` without recording a jump.
pub fn moveTo(ed: *Editor, path: []const u8, line: usize, col: usize) !void {
    try ed.openFile(path);
    const t = ed.text();
    const l = @min(line, t.lineCount() - 1);
    row_model.revealLine(ed, l);
    const before = ed.view.top;
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
    // A line that wasn't in view: in the middle of it, not at its edge.
    if (!ed.buffer.center_on_show and (l < before or l >= before + ed.view.rows)) picker_ops.centerCursor(ed);
}

/// Paths inside the cwd are stored relative to it, without "./".
/// Paths outside it are absolute; "..", "." and trailing "/" are resolved.
pub fn normalizePath(ed: *Editor, path: []const u8) Allocator.Error![]u8 {
    const abs = try ed.absolutePath(path);
    if (abs.len > ed.cwd.len and std.mem.startsWith(u8, abs, ed.cwd) and abs[ed.cwd.len] == '/') {
        defer ed.gpa.free(abs);
        return ed.gpa.dupe(u8, abs[ed.cwd.len + 1 ..]);
    }
    return abs;
}

/// The file named on the command line: a folder opens the explorer there;
/// a file that can't be opened leaves an empty editor with a message
/// (instead of not starting at all).
pub fn openArg(ed: *Editor, path: []const u8) void {
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    const st = Io.Dir.cwd().statFile(ed.io, abs, .{}) catch null;
    if (st != null and st.?.kind == .directory) {
        if (Project.detect(ed.io, abs)) |f| project_ops.enterProject(ed, project_ops.internProject(ed, f.root, f.git));
        browser.setBrowseDir(ed, abs) catch return;
        ed.openPicker(.browse, "") catch {};
        return;
    }
    ed.openFile(abs) catch |err| ed.setMessage(.err, "could not open {s}: {s}", .{ path, @errorName(err) });
}

pub fn switchTo(ed: *Editor, b: *Buffer) void {
    if (b == ed.buffer) return;
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    state_files.leaveBuffer(ed, ed.buffer);
    ed.use_counter += 1;
    b.last_used = ed.use_counter;
    ed.activate(b);
    state_files.recordVisit(ed, b);
}

/// Shows `b` with its saved view, without saving the current one.
fn activate(ed: *Editor, b: *Buffer) void {
    ed.cursors.clearRetainingCapacity();
    project_ops.enterProject(ed, b.project);
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
        ed.setMessage(.err, "\"{s}\" has unsaved changes: SPC s to save it first", .{b.displayName()});
        return;
    }
    lsp_ops.lspCloseBuffer(ed, b);
    blame.dropBlame(ed, b);
    if (ed.exchange_mark) |m| if (m.buffer == b) {
        ed.exchange_mark = null;
    };
    if (ed.buffers.items.len == 1) {
        const fresh = try Buffer.initEmpty(ed.gpa);
        b.deinit(ed.gpa);
        b.* = fresh;
        for (ed.window_list.items) |w| w.view = .{ .rows = w.view.rows, .cols = w.view.cols };
        ed.activate(b);
        return;
    }
    _ = ed.buffers.orderedRemove(formatting.bufferIndex(ed, b));
    inlay.forgetJumps(ed, b);
    jumplist.forgetMarks(ed, b);
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
// Picker

pub fn openPicker(ed: *Editor, kind: Picker.Kind, query: []const u8) !void {
    // From visual mode (`SPC` on a selection): a menu row acts on it.
    ed.picker_visual = if (ed.mode == .visual) .{ .line = ed.visual_line } else null;
    picker_query.closePicker(ed);
    ed.picker_root = ed.next_picker_root orelse project_ops.projectRoot(ed);
    ed.next_picker_root = null;
    if (kind == .themes) ed.theme_before = ed.theme_index;
    ed.picker = try Picker.create(ed, kind, query);
    // The theme picker starts on the theme in use (moving previews).
    if (kind == .themes) ed.picker.?.want_id = @intCast(ed.theme_index);
    ed.mode = if (@import("picker/sources.zig").startsNormal(kind)) .picker_normal else .picker;
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
    ed.remember(kind, s);
}

pub fn clearMessage(ed: *Editor) void {
    ed.message.len = 0;
}

/// Keeps a message for the history (`SPC f n`); repeats aren't kept twice.
pub fn remember(ed: *Editor, kind: Message.Kind, s: []const u8) void {
    if (s.len == 0) return;
    if (ed.history.items.len > 0) {
        const last = ed.history.items[ed.history.items.len - 1];
        if (last.kind == kind and std.mem.eql(u8, last.text, s)) return;
    }
    const owned = ed.gpa.dupe(u8, s) catch return;
    if (ed.history.items.len >= max_history) ed.gpa.free(ed.history.orderedRemove(0).text);
    ed.history.append(ed.gpa, .{ .kind = kind, .text = owned }) catch ed.gpa.free(owned);
}
