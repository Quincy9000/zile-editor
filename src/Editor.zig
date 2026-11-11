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

const Editor = @This();

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
    /// Diagnostic messages after the end of lines.
    diagnostic_text: bool = true,
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

    fn dir(t: OpenTarget) ?Windows.Dir {
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

    fn deinit(s: SignatureHelp, gpa: Allocator) void {
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
    fn growing(g: IndentGuide, now: Io.Timestamp, top: usize, bottom: usize) bool {
        const up = g.origin -| @max(g.scope.first, top);
        const down = @min(g.scope.last, bottom) -| g.origin;
        return g.reach(now) < @as(f32, @floatFromInt(@max(up, down)));
    }

    /// The same block (it may have grown or shrunk at its end while typing).
    fn same(a: ?IndentGuide, b: ?IndentGuide) bool {
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

    fn set(t: *Toast, comptime fmt: []const u8, args: anytype) void {
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
const max_toasts = 6;

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
    if (Project.detect(io, cwd)) |f| ed.last_project = ed.internProject(f.root, f.git);
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
    if (ed.run) |t| t.destroy();
    if (ed.run_command) |cmd| ed.gpa.free(cmd);
    if (ed.run_root_owned) |r| ed.gpa.free(r);
    for (ed.run_errors.items) |e| e.deinit(ed.gpa);
    ed.run_errors.deinit(ed.gpa);
    ed.clearQuickfix();
    ed.quickfix.deinit(ed.gpa);
    ed.quickfix_title.deinit(ed.gpa);
    if (ed.run_memory_path) |path| ed.gpa.free(path);
    for (ed.lsps.items) |l| l.deinit();
    ed.lsps.deinit(ed.gpa);
    ed.merged_diagnostics.deinit(ed.gpa);
    for (ed.zig_checks.items) |zc| zc.job.destroy();
    if (ed.sql_schema) |sc| sc.destroy(ed.gpa);
    ed.zig_checks.deinit(ed.gpa);
    for (ed.check_results.items) |r| freeDiagnosticList(ed.gpa, r.diags);
    ed.check_results.deinit(ed.gpa);
    var lc = ed.linter_checked.keyIterator();
    while (lc.next()) |key| ed.gpa.free(key.*);
    ed.linter_checked.deinit(ed.gpa);
    ed.clearLocations();
    ed.locations.deinit(ed.gpa);
    ed.clearSymbols();
    ed.symbols.deinit(ed.gpa);
    if (ed.hover) |h| ed.gpa.free(h);
    ed.closeCompletion();
    ed.closeSignature();
    ed.endSnippet();
    ed.clearAiSuggestion();
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
    ed.action_query.deinit(ed.gpa);
    for (ed.query_undo.items) |u| ed.gpa.free(u.text);
    ed.query_undo.deinit(ed.gpa);
    ed.dropAllBlames();
    ed.blames.deinit(ed.gpa);
    ed.saveVisits();
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
    ed.clearCodeActions();
    ed.code_actions.deinit(ed.gpa);
    ed.clearWorkspaceSymbols();
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
    ed.updateGit();
    if (ed.buffer.syntax) |*s| {
        const t = ed.text();
        s.update(t);
        // While a scroll glides, the lines in view are the ones around where
        // the text is drawn, some rows from `top`.
        const off = ed.view.drawOffset();
        const shift: isize = if (off > 0) -@as(isize, @intFromFloat(@ceil(off))) else @intFromFloat(@floor(-off));
        const first = ed.stepVisible(@min(ed.view.top, t.lineCount() - 1), shift);
        // With closed folds the screen reaches past `top + rows` raw lines.
        const last_visible = ed.stepVisible(first, @intCast(ed.view.rows + 2));
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
    ed.now = Io.Timestamp.now(ed.io, .awake);
    ed.keepUndoHistories();
    ed.tickZigChecks();
    ed.tickSaveChain();
    ed.tickSqlSchema();
    ed.tickCodeLens();
    if (ed.yank_flash) |f| if (f.strength(ed.now) <= 0) {
        ed.yank_flash = null;
    };
    ed.pruneToasts();
    ed.tickIndentGuide();
    ed.ensureBlame();
    ed.tickLsp();
    ed.tickInlayHints();
    ed.pollGitJob();
    ed.pollTerminals();
    ed.pollAi();
    ed.tickClaude();
    ed.pollShellWindows();
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
    if (ed.colorKey(ev)) return;
    if (ed.popupKey(ev)) return;
    if (ed.cmdFloatKey(ev)) return;
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
    if (multi) ed.multiAfterKey();
    ed.afterKey();
    ed.clampToFolds();
    // Typing text (insert mode, a prompt) isn't a pending command.
    if (ed.mode == .insert or ed.mode == .search) ed.showcmd_len = 0;
    if (ed.completion != null) ed.refreshCompletion() catch ed.closeCompletion();
    if (ed.mode == .insert and ed.buffer == buffer_before and ed.text().len() < len_before) ed.afterDeleted();
    if (ed.mode != .insert) {
        ed.completion_asked = null;
        ed.closeSignature();
        ed.endSnippet();
    }
    ed.updateAi();
    ed.scrollToCursor();
}

/// Nothing half-typed: no pending keys, count, register, operator or argument.
fn isIdle(ed: *const Editor) bool {
    return ed.mode != .insert and ed.mode != .operator and ed.mode != .search and ed.pending_len == 0 and ed.count == 0 and
        ed.register == null and !ed.awaiting_register and ed.awaiting_char == null;
}

/// Ends a command: commits the undo group and finishes dot-repeat capture.
fn afterKey(ed: *Editor) void {
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

fn handleKeyInner(ed: *Editor, ev: KeyEvent) !void {
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
    if ((ed.mode == .picker or ed.mode == .picker_normal) and try ed.pickerCtrlAction(ev)) return;
    if (ed.mode == .picker_normal and try ed.pickerQueryKey(ev)) return;

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
            // The command editor holds its own scratch buffer: leader menus
            // (buffers, windows, files...) would pull it out from under it.
            if (ed.cmd_float != null and seq[0].key == .codepoint and seq[0].key.codepoint == ' ') {
                ed.resetCommand();
                return ed.setMessage(.info, "close the command editor first (<Esc> in normal mode)", .{});
            }
            // Leader menus, undo, `.` and the like act once, not per cursor.
            if (cmd.jump and !ed.replaying and (ed.mode == .normal or ed.mode == .visual)) ed.pushJump();
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
                if (ed.mode == .visual) ed.exitVisual();
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
                    if (cp == '(') try ed.commitCompletionName();
                    try ed.snippetTypeOver();
                    if (!try tags.typed(ed, cp) and !try pairs.typed(ed, cp)) try ed.insertCodepoint(cp);
                    if (cp == '}' or cp == ')' or cp == ']') try ed.dedentCloser();
                    ed.afterTyped(cp);
                },
                // Unbound keys while moving through results do nothing.
                .picker_normal => {},
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

/// A server that wouldn't start. Not installed: said when something needs it
/// (`gd`, `K`, rename...), not on opening a file. Anything else: said now.
fn serverStartFailed(ed: *Editor, i: usize, err: anyerror) void {
    ed.lsp_failed[i] = true;
    if (err == error.FileNotFound) {
        ed.lsp_missing[i] = true;
        return;
    }
    ed.notify(.err, "could not start {s}: {s}", .{ Lsp.servers[i].name, @errorName(err) });
}

fn tickLsp(ed: *Editor) void {
    // Start each language's server for each project, the first time one of
    // its files is open there.
    for (ed.buffers.items) |b| {
        const i = Lsp.serverFor(b) orelse continue;
        if (ed.lsp_failed[i] or ed.lspFor(b) != null) continue;
        const l = Lsp.start(ed, i, Lsp.bufferRoot(b, ed.cwd)) catch |err| {
            ed.serverStartFailed(i, err);
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
        if (running or ed.linterAbsent(i, root)) continue;
        const l = Lsp.start(ed, i, root) catch |err| {
            ed.serverStartFailed(i, err);
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
            ed.serverExited(i);
        }
    }
}

/// A server's output ended: it crashed or quit. It's started again (the
/// next tick, with its files reopened), a few times; the notification says
/// why, from the last line of its log.
const max_lsp_restarts = 3;

fn serverExited(ed: *Editor, i: usize) void {
    const name = Lsp.servers[i].name;
    var why_buf: [200]u8 = undefined;
    const why = ed.serverLogTail(i, &why_buf);
    const sep: []const u8 = if (why.len > 0) ": " else "";
    if (ed.lsp_restarts[i] < max_lsp_restarts) {
        ed.lsp_restarts[i] += 1;
        ed.notify(.err, "{s} exited{s}{s} (restarting)", .{ name, sep, why });
        return;
    }
    ed.lsp_failed[i] = true;
    const log = Lsp.logPath(ed.gpa, i);
    defer if (log) |p| ed.gpa.free(p);
    ed.notify(.err, "{s} exited again{s}{s}; not restarting it (its log: {s})", .{ name, sep, why, log orelse "none" });
}

/// The last non-blank line of server `i`'s log, cut to fit `buf`.
fn serverLogTail(ed: *Editor, i: usize, buf: []u8) []const u8 {
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
fn linterAbsent(ed: *Editor, index: usize, root: []const u8) bool {
    var key_buf: [Io.Dir.max_path_bytes + 8]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ index, root }) catch return true;
    if (ed.linter_checked.get(key)) |absent| return absent;
    const absent = for (Lsp.servers[index].markers) |m| {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, m }) catch continue;
        if (ed.fileExists(p)) break false;
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
    if (ed.lspFor(ed.buffer)) |l| return l;
    const name = Lsp.servers[i].name;
    if (ed.lsp_missing[i]) {
        ed.setMessage(.err, "{s} isn't installed", .{name});
    } else if (ed.lsp_failed[i]) ed.setMessage(.err, "{s} is not running", .{name}) else ed.setMessage(.info, "{s} is starting...", .{name});
    return null;
}

/// Everything the servers say about `b`, by line: its main server's and
/// its linters'. The slice is good until the next call.
pub fn diagnostics(ed: *const Editor, b: *const Buffer) []const Lsp.Diagnostic {
    const path = b.path orelse return &.{};
    var lists: [5][]const Lsp.Diagnostic = undefined;
    var n: usize = 0;
    for (ed.check_results.items) |r| if (r.buffer == b and r.diags.len > 0) {
        lists[n] = r.diags;
        n += 1;
    };
    for (ed.lsps.items) |l| if (l.wants(b) and n < lists.len) {
        const d = l.diagnosticsFor(path);
        if (d.len == 0) continue;
        lists[n] = d;
        n += 1;
    };
    if (n == 0) return &.{};
    if (n == 1) return lists[0];
    const self = @constCast(ed);
    self.merged_diagnostics.clearRetainingCapacity();
    for (lists[0..n]) |d| self.merged_diagnostics.appendSlice(ed.gpa, d) catch return lists[0];
    std.mem.sort(Lsp.Diagnostic, self.merged_diagnostics.items, {}, struct {
        fn lessThan(_: void, a: Lsp.Diagnostic, c: Lsp.Diagnostic) bool {
            return if (a.line != c.line) a.line < c.line else @intFromEnum(a.severity) < @intFromEnum(c.severity);
        }
    }.lessThan);
    return self.merged_diagnostics.items;
}

/// Tells every running server that `b` is going away.
fn lspCloseBuffer(ed: *Editor, b: *Buffer) void {
    for (ed.lsps.items) |l| l.closeBuffer(b);
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

/// `SPC f s`: the current file's symbols, from the language server when it
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

// Code actions (`SPC l a`) and workspace symbols (`SPC f w`): the server's
// answers, kept for their pickers.

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
    const l = ed.lspFor(ed.buffer) orelse return;
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
    const l = ed.languageServer() orelse return;
    ed.clearWorkspaceSymbols();
    try ed.openPicker(.workspace_symbols, "");
    try l.requestWorkspaceSymbols("");
}

/// The server answered: the open picker lists the new symbols.
pub fn workspaceSymbolsArrived(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind == .workspace_symbols) try p.refill();
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

/// A character of a name being completed in this buffer: in CSS and HTML
/// `-` is part of one (`background-color`, `--gap`, `aria-label`).
fn isNameChar(ed: *const Editor, b: u8) bool {
    if (isIdent(b)) return true;
    if (b != '-') return false;
    const lang = if (ed.buffer.syntax) |sx| sx.lang.name else return false;
    for ([_][]const u8{ "css", "scss", "less", "html" }) |l| if (std.mem.eql(u8, lang, l)) return true;
    return false;
}

/// Start of the identifier ending at the cursor.
fn wordStart(ed: *Editor) usize {
    const t = ed.text();
    const ls = t.lineStart(ed.cursorLine());
    var p = ed.view.cursor;
    while (p > ls and ed.isNameChar(t.byteAt(p - 1))) p -= 1;
    return p;
}

/// After typing in insert mode: asks for completions after one of the
/// server's trigger characters (`.`, `::`, `->`...) or two identifier chars.
fn afterTyped(ed: *Editor, cp: u21) void {
    if (ed.cursors.items.len > 0 or ed.replaying) return; // completion is single-cursor
    // Signature help: `(` opens it, `,` updates it, `)` closes it.
    if (cp == ')') ed.closeSignature();
    if (ed.isSql()) {
        // Our own list: the database's tables and columns.
        if (cp == '.') ed.closeCompletion();
        if (ed.completion != null) return;
        const start = ed.wordStart();
        if (cp == '.' or (cp < 0x80 and ed.isNameChar(@intCast(cp)) and ed.view.cursor > start)) ed.sqlCompletion(start);
        return;
    }
    const l = ed.lspFor(ed.buffer) orelse return;
    // A `,` asks again even if the popup was closed meanwhile (by a nested
    // call, say): the server answers with nothing outside a call.
    // After a `)` too: the call around the one just closed takes over.
    if (cp == ')' or l.isSignatureTrigger(cp, true)) l.requestSignature(ed) catch {};
    const trigger = l.isTrigger(cp);
    // A trigger starts a new list even if a popup is open.
    if (trigger) ed.closeCompletion();
    // A list we have is refiltered as you type (and comes back by itself
    // when a typo is fixed); only a cut-short one needs asking for again.
    if (ed.completion) |c| if (!c.incomplete) return;
    const start = ed.wordStart();
    const ask = trigger or (cp < 0x80 and ed.isNameChar(@intCast(cp)) and ed.view.cursor > start);
    if (!ask) return;
    ed.askCompletion(l, start);
}

/// The current file's folder (absolute), else the working folder. Caller
/// frees.
fn fileFolder(ed: *Editor) ![]u8 {
    const path = ed.buffer.path orelse return ed.gpa.dupe(u8, ed.cwd);
    const abs = try ed.absolutePath(path);
    defer ed.gpa.free(abs);
    return ed.gpa.dupe(u8, std.fs.path.dirname(abs) orelse ed.cwd);
}

fn isSql(ed: *const Editor) bool {
    const syn = ed.buffer.syntax orelse return false;
    return std.mem.eql(u8, syn.lang.name, "sql");
}

/// SQL completion, built here: keywords, the database's tables and columns
/// (after `name.` that table's columns), and the file's words.
fn sqlCompletion(ed: *Editor, start: usize) void {
    const t = ed.text();
    const tables: []const sql.Table = if (ed.sql_schema) |sc| (if (sc.done.load(.acquire)) sc.tables else &.{}) else &.{};
    const json = sql.completionJson(ed.gpa, tables, t.slice(0, t.len()), start) catch return;
    defer ed.gpa.free(json);
    var parsed = std.json.parseFromSlice(std.json.Value, ed.gpa, json, .{}) catch return;
    defer parsed.deinit();
    ed.showCompletion(ed.buffer, start, parsed.value) catch {};
}

/// The schema for SQL completion: loaded (in the background) when a SQL
/// file is first shown, from the database it would run on; again after a
/// statement that changes tables has run.
fn tickSqlSchema(ed: *Editor) void {
    if (ed.sql_reload and ed.run_reported) {
        ed.sql_reload = false;
        ed.sql_checked = null;
    }
    if (!ed.isSql() or ed.sql_checked == ed.buffer) return;
    // A load still running finishes first.
    if (ed.sql_schema) |sc| if (!sc.done.load(.acquire)) return;
    ed.sql_checked = ed.buffer;
    const folder = ed.fileFolder() catch return;
    defer ed.gpa.free(folder);
    const found = sql.findUrl(ed.gpa, ed.io, folder, ed.cwd) orelse return;
    defer ed.gpa.free(found.url);
    defer ed.gpa.free(found.from);
    if (ed.sql_schema) |sc| {
        if (std.mem.eql(u8, sc.url, found.url) and !sc.failed and ed.sql_fresh) return;
        sc.destroy(ed.gpa);
        ed.sql_schema = null;
    }
    ed.sql_schema = sql.Schema.load(ed.gpa, ed.io, found.url, ed.wake_fn) catch null;
    ed.sql_fresh = true;
}

/// Asks for completions for the word starting at `start`, unless the answer
/// to that same question is still on its way.
fn askCompletion(ed: *Editor, l: *Lsp, start: usize) void {
    if (ed.completion_pending and ed.completion_asked == start) return;
    ed.completion_asked = start;
    ed.completion_pending = true;
    l.requestCompletion(ed, start) catch {
        ed.completion_pending = false;
    };
}

/// After deleting in insert mode (<BS>, <C-w>): completion comes back for
/// what is left of the word, instead of staying gone until the word is
/// retyped from its start.
fn afterDeleted(ed: *Editor) void {
    if (ed.cursors.items.len > 0 or ed.replaying) return;
    if (ed.isSql()) {
        if (ed.completion != null) return;
        const start = ed.wordStart();
        const t = ed.text();
        const after_dot = ed.view.cursor > 0 and t.byteAt(ed.view.cursor - 1) == '.';
        if (ed.view.cursor > start or after_dot) ed.sqlCompletion(start);
        return;
    }
    const l = ed.lspFor(ed.buffer) orelse return;
    // A list is still held for this word: it was refiltered already.
    if (ed.completion) |c| {
        if (c.incomplete) ed.askCompletion(l, c.word_start);
        return;
    }
    const t = ed.text();
    const cur = ed.view.cursor;
    const start = ed.wordStart();
    const after_trigger = cur > t.lineStart(ed.cursorLine()) and l.isTrigger(t.byteAt(cur - 1));
    if (cur == start and !after_trigger) return; // nothing here to complete
    ed.askCompletion(l, start);
}

/// The completion popup, when it has something to show. (A list with no
/// match for a typo is kept, out of sight, until the text matches again.)
pub fn completionShown(ed: *Editor) ?*Completion {
    const c = &(ed.completion orelse return null);
    return if (c.shown.items.len > 0) c else null;
}

/// Manual trigger (<C-n> / <C-Space> in insert mode).
pub fn requestCompletion(ed: *Editor) !void {
    const l = ed.languageServer() orelse return;
    const start = ed.wordStart();
    ed.completion_asked = start;
    ed.completion_pending = true;
    try l.requestCompletion(ed, start);
}

/// A completion reply arrived: show it if the cursor is still on that word.
pub fn showCompletion(ed: *Editor, b: *Buffer, word_start: usize, result: std.json.Value) !void {
    ed.completion_pending = false;
    if (b != ed.buffer or ed.mode != .insert or ed.view.cursor < word_start) return;
    if (ed.text().lineOf(word_start) != ed.cursorLine()) return;
    ed.closeCompletion();
    ed.completion = try Completion.fromJson(ed.gpa, result, word_start);
    // The server's own idea of where the word starts wins over ours (zls
    // completes builtins from after the `@`, and filters without it).
    if (ed.completion.?.edit_col) |col| {
        const start = ed.text().lineStart(ed.cursorLine()) + col;
        if (start <= ed.view.cursor) ed.completion.?.word_start = start;
    }
    // Words of the file as well: the server may not have parsed it.
    if (ed.text().len() <= 2 << 20) {
        const t = ed.text();
        const src = t.slice(0, t.len());
        const ws = ed.completion.?.word_start;
        // Between tags: elements, and in JSX the file's components
        // (`view` -> `<View></View>`).
        const kind = tags.kindOf(ed);
        if (kind != .none and tags.childAt(ed, kind, src, ws)) {
            var unit_buf: [16]u8 = undefined;
            try ed.completion.?.addMarkup(src, ws, kind == .jsx, ed.indentUnit(&unit_buf));
        }
        try ed.completion.?.addWords(src, ws);
        // Our snippets for this kind of file.
        if (ed.buffer.syntax) |syn| {
            const lists = snippets.forFile(syn.lang.name, ed.buffer.path orelse "");
            const ls = t.lineStart(t.lineOf(ws));
            const line = t.slice(ls, t.lineEnd(t.lineOf(ws)));
            const indent = line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];
            var unit_buf: [16]u8 = undefined;
            try ed.completion.?.addSnippets(lists, indent, ed.indentUnit(&unit_buf));
        }
    }
    try ed.refreshCompletion();
}

/// A type is expected at `pos`: after `name:` (maybe with `*`, `?`, `!`,
/// `[]` or `const` in between), as in `fn f(a: *Actor)`.
fn typeExpected(ed: *Editor, pos: usize) bool {
    const t = ed.text();
    const ls = t.lineStart(t.lineOf(pos));
    var p = pos;
    while (p > ls) {
        const b = t.byteAt(p - 1);
        if (b == ' ' or b == '*' or b == '?' or b == '!' or b == '[' or b == ']') {
            p -= 1;
            continue;
        }
        if (b == 't' and p - ls >= 5 and std.mem.eql(u8, t.slice(p - 5, p), "const")) {
            p -= 5;
            continue;
        }
        return b == ':' and !(p - 1 > ls and t.byteAt(p - 2) == ':');
    }
    return false;
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
    for (typed) |b| if (!ed.isNameChar(b)) return ed.closeCompletion();
    try c.filter(ed.gpa, typed, ed.typeExpected(c.word_start));
    // No match for what is typed (a typo, say): the list is kept, hidden,
    // and returns as soon as the text matches again. An empty answer has
    // nothing to bring back.
    if (c.items.len == 0) ed.closeCompletion();
}

/// Replaces the typed word with the selected item.
/// Typing `(` while the suggestions are open takes the selected one, as
/// Enter would, but only its name: the `(` that follows is the call's own
/// (with its closing pair), so `drawtex(` becomes `drawText(|)`, not
/// `drawText(args)(`.
pub fn commitCompletionName(ed: *Editor) !void {
    const c = ed.completionShown() orelse return;
    const item = c.current() orelse return;
    const start = c.word_start;
    var snip: ?Snippet = null;
    defer if (snip) |s| s.deinit(ed.gpa);
    // What the suggestion inserts, up to where its arguments begin.
    var full: []const u8 = item.insert;
    if (item.snippet) {
        snip = try Snippet.parse(ed.gpa, item.insert);
        full = snip.?.text;
    }
    const name_end = std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    const name = try ed.gpa.dupe(u8, if (name_end > 0) full[0..name_end] else item.label);
    defer ed.gpa.free(name);
    ed.closeCompletion();
    try ed.deleteRange(start, ed.view.cursor);
    try ed.insertText(name);
}

pub fn acceptCompletion(ed: *Editor) !void {
    const c = &(ed.completion orelse return);
    const item = c.current() orelse return ed.closeCompletion();
    const insert = try ed.gpa.dupe(u8, item.insert);
    defer ed.gpa.free(insert);
    const is_snippet = item.snippet;
    const ours = item.user_snippet or item.markup;
    const start = c.word_start;
    // A function (by its kind, or text that ends in a call when the server
    // doesn't say): <Tab> after it can end the statement with `;`.
    const is_call = !ours and (item.call or std.mem.endsWith(u8, std.mem.trimEnd(u8, insert, "$0"), ")"));
    ed.closeCompletion();
    try ed.deleteRange(start, ed.view.cursor);
    if (!is_snippet) {
        try ed.insertText(insert);
        if (is_call) ed.callEnded();
        return;
    }
    // A snippet: insert its text, then fill in the placeholders.
    const snip = try Snippet.parse(ed.gpa, insert);
    defer snip.deinit(ed.gpa);
    try ed.insertText(snip.text);
    try ed.startSnippet(start, snip, is_call);
    if (ours) if (ed.snippet) |*sn| {
        sn.keep_defaults = true;
    };
}

/// Insert-mode <Tab> after an Emmet abbreviation in markup (`div`,
/// `ul>li*3`, `.card`): the markup, with tab stops in it. False when there
/// is none here.
pub fn expandEmmet(ed: *Editor) !bool {
    if (ed.cursors.items.len > 0) return false;
    const kind = tags.kindOf(ed);
    if (kind == .none) return false;
    const t = ed.text();
    const pos = ed.view.cursor;
    const ls = t.lineStart(t.lineOf(pos));
    const line = t.slice(ls, pos);
    const off = emmetStart(line);
    const abbr = line[off..];
    if (!emmet.looksLikeAbbreviation(abbr, kind == .jsx)) return false;
    const start = ls + off;
    if (!tags.markupAt(ed, kind, t.slice(0, t.len()), start)) return false;
    var unit_buf: [16]u8 = undefined;
    const indent = line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];
    const indent_copy = try ed.gpa.dupe(u8, indent);
    defer ed.gpa.free(indent_copy);
    const abbr_copy = try ed.gpa.dupe(u8, abbr);
    defer ed.gpa.free(abbr_copy);
    const src = (try emmet.expand(ed.gpa, abbr_copy, .{ .jsx = kind == .jsx, .unit = ed.indentUnit(&unit_buf), .indent = indent_copy })) orelse return false;
    defer ed.gpa.free(src);
    const snip = try Snippet.parse(ed.gpa, src);
    defer snip.deinit(ed.gpa);
    ed.closeCompletion();
    try ed.deleteRange(start, pos);
    try ed.insertText(snip.text);
    try ed.startSnippet(start, snip, false);
    return true;
}

/// Where the abbreviation before the end of `line` starts: back to a
/// space, or to the `>` of a tag written before it (`<View>div` -> `div`).
fn emmetStart(line: []const u8) usize {
    var i = line.len;
    var depth: usize = 0;
    while (i > 0) : (i -= 1) {
        const b = line[i - 1];
        if (b == ']' or b == '}' or b == ')') {
            depth += 1;
        } else if (b == '[' or b == '{' or b == '(') {
            if (depth == 0) break;
            depth -= 1;
        } else if (depth == 0 and (b == ' ' or b == '\t' or b == ';' or b == ',' or b == '=' or b == '&' or b == '|' or b == '?' or b == ':')) break;
    }
    const cand = line[i..];
    if (std.mem.lastIndexOfScalar(u8, cand, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, cand, lt, '>') orelse return line.len;
        return i + gt + 1;
    }
    return i;
}

/// A call was inserted with nothing to fill in (`foo()`): the cursor is
/// after it, and <Tab> can go on to the `;`.
fn callEnded(ed: *Editor) void {
    ed.endSnippet();
    const stops = ed.gpa.alloc([2]usize, 1) catch return;
    stops[0] = .{ ed.view.cursor, ed.view.cursor };
    ed.snippet = .{ .buffer = ed.buffer, .stops = stops, .has_final = true, .is_call = true };
    ed.snippetAtEnd();
}

// AI ghost completion: after typing in insert mode, a local model (Ollama)
// suggests what comes next, shown in gray at the cursor; <Tab> takes it.

/// Where Ollama is and which model to ask ($OLLAMA_HOST, $ZILE_AI_MODEL).
fn aiConfig() struct { host: []const u8, model: []const u8 } {
    const host: []const u8 = if (std.c.getenv("OLLAMA_HOST")) |h| std.mem.span(h) else "http://localhost:11434";
    const model: []const u8 = if (std.c.getenv("ZILE_AI_MODEL")) |m| std.mem.span(m) else "qwen2.5-coder:1.5b-base";
    return .{ .host = host, .model = model };
}

pub fn clearAiSuggestion(ed: *Editor) void {
    const s = ed.ai_suggestion orelse return;
    ed.gpa.free(s.text);
    ed.ai_suggestion = null;
}

/// The suggestion as it stands at the cursor, if it is still valid there.
pub fn aiSuggestionHere(ed: *Editor) ?[]const u8 {
    const s = ed.ai_suggestion orelse return null;
    if (s.buffer != ed.buffer or ed.mode != .insert) return null;
    const c = ed.view.cursor;
    if (c < s.pos or c - s.pos > s.text.len) return null;
    if (!std.mem.eql(u8, ed.text().slice(s.pos, c), s.text[0 .. c - s.pos])) return null;
    const rest = s.remaining(c);
    return if (rest.len > 0) rest else null;
}

/// After each key: keep a suggestion that is being typed out, otherwise
/// drop it and (at a line's end) ask for a new one.
fn updateAi(ed: *Editor) void {
    if (!ed.options.ai_complete or ed.ai_unreachable or ed.mode != .insert or
        ed.replaying or ed.cursors.items.len > 0 or ed.cmd_float != null)
    {
        ed.clearAiSuggestion();
        return;
    }
    if (ed.aiSuggestionHere() != null) return;
    ed.clearAiSuggestion();
    const b = ed.buffer;
    const c = ed.view.cursor;
    if (ed.ai_asked) |a| if (a.buffer == b and a.pos == c and a.version == b.edit_version) return;
    // Only at the end of a line (or before closing brackets/quotes/;):
    // mid-line guesses from a small model are mostly noise.
    const rest = ed.restOfLine();
    for (rest) |ch| if (std.mem.indexOfScalar(u8, ")]}\"';,", ch) == null) return;
    if (ed.ai_offline) return;
    const t = ed.text();
    if (ed.ai == null) {
        const cfg = aiConfig();
        ed.ai = Ghost.create(ed.gpa, ed.io, ed.wake_fn, cfg.host, cfg.model) catch return;
    }
    // A window around the cursor: from a line start ~6KB back, ~2KB ahead.
    var from = c -| 6000;
    if (from > 0) from = t.lineStart(t.lineOf(from));
    const to = @min(t.len(), c + 2000);
    const tail: []const u8 = if (to == t.len() and b.final_newline) "\n" else "";
    const suffix = std.mem.concat(ed.gpa, u8, &.{ t.slice(c, to), tail }) catch return;
    defer ed.gpa.free(suffix);
    ed.ai_gen += 1;
    ed.ai.?.submit(ed.ai_gen, t.slice(from, c), suffix) catch return;
    ed.ai_asked = .{ .buffer = b, .pos = c, .version = b.edit_version };
}

/// Picks up the model's reply, if it still fits where the cursor is.
fn pollAi(ed: *Editor) void {
    const g = ed.ai orelse return;
    const r = g.take() orelse return;
    defer if (r.text) |t| ed.gpa.free(t);
    if (r.failed) {
        ed.ai_unreachable = true;
        ed.clearAiSuggestion();
        ed.setMessage(.err, "AI completion is off: no answer from Ollama at {s} (SPC t a to try again)", .{g.url});
        return;
    }
    if (r.gen != ed.ai_gen or ed.mode != .insert) return;
    const a = ed.ai_asked orelse return;
    if (a.buffer != ed.buffer or a.pos != ed.view.cursor or a.version != ed.buffer.edit_version) return;
    const tidied = Ghost.tidy(r.text.?, ed.restOfLine(), 8);
    // Drop lines that only repeat what's already around the cursor.
    const t = ed.text();
    const line = ed.cursorLine();
    const ctx_from = t.lineStart(line -| 40);
    const ctx_to = t.lineEnd(@min(line + 40, t.lineCount() - 1));
    const prefix_on_line = t.slice(t.lineStart(line), ed.view.cursor);
    const suggestion = Ghost.dropRepeats(tidied, prefix_on_line, t.slice(ctx_from, ctx_to));
    if (suggestion.len == 0) return;
    ed.clearAiSuggestion();
    ed.ai_suggestion = .{ .buffer = ed.buffer, .pos = a.pos, .text = ed.gpa.dupe(u8, suggestion) catch return };
}

pub const AiPart = enum { all, line, char };

/// Takes the suggestion (<A-;>), its current line (<A-l>; at a line break,
/// the break and the next line), or one character (<A-Right>). What's left
/// stays offered. False when there is none.
pub fn acceptAiSuggestion(ed: *Editor, part: AiPart) !bool {
    const rest = ed.aiSuggestionHere() orelse return false;
    const n = switch (part) {
        .all => rest.len,
        .line => blk: {
            const start: usize = if (rest[0] == '\n') 1 else 0;
            break :blk start + (std.mem.indexOfScalar(u8, rest[start..], '\n') orelse rest.len - start);
        },
        .char => std.unicode.utf8ByteSequenceLength(rest[0]) catch 1,
    };
    const taken = try ed.gpa.dupe(u8, rest[0..@min(n, rest.len)]);
    defer ed.gpa.free(taken);
    // Typing it in keeps the rest of the suggestion on offer.
    try ed.insertText(taken);
    if (ed.aiSuggestionHere() == null) ed.clearAiSuggestion();
    return true;
}

// Snippets: function arguments as placeholders.

fn startSnippet(ed: *Editor, at: usize, snip: Snippet, is_call: bool) !void {
    ed.endSnippet();
    if (snip.stops.len == 0) {
        if (is_call) ed.callEnded();
        return;
    }
    // Without a $0 the final cursor is the snippet's end (by the LSP spec;
    // clangd's `printf(${1:...})` has none).
    const explicit_final = snip.stops[snip.stops.len - 1].index == 0;
    const n = snip.stops.len + @intFromBool(!explicit_final);
    const stops = try ed.gpa.alloc([2]usize, n);
    for (snip.stops, stops[0..snip.stops.len]) |st, *r| r.* = .{ at + st.start, at + st.end };
    if (!explicit_final) stops[n - 1] = .{ at + snip.text.len, at + snip.text.len };
    ed.snippet = .{ .buffer = ed.buffer, .stops = stops, .has_final = true, .is_call = is_call };
    ed.goSnippetStop(0);
}

pub fn endSnippet(ed: *Editor) void {
    const s = ed.snippet orelse return;
    ed.gpa.free(s.stops);
    ed.snippet = null;
}

/// Puts the cursor at stop `i`; the final cursor ($0) ends the session.
fn goSnippetStop(ed: *Editor, i: usize) void {
    const s = &(ed.snippet orelse return);
    const r = s.stops[i];
    const last = i == s.stops.len - 1;
    ed.view.cursor = @min(r[0], ed.text().len());
    ed.view.want_col = null;
    if (last and s.has_final) return ed.snippetAtEnd();
    s.current = i;
    s.at_end = false;
    s.fresh = r[1] > r[0];
    // The signature popup follows to this argument.
    if (ed.lspFor(ed.buffer)) |l| l.requestSignature(ed) catch {};
}

/// Leaving insert mode with a snippet half filled in: the placeholders still
/// holding their default text (the current one if untouched, and the ones
/// not reached yet) are removed together with the comma beside them, so
/// `f(a: A, b: B)` left alone becomes `f()` rather than code that doesn't
/// parse. Placeholders already visited stay as they are.
pub fn dropUnfilledPlaceholders(ed: *Editor) !void {
    if (ed.replaying) return;
    const s = &(ed.snippet orelse return);
    if (s.buffer != ed.buffer or s.at_end or s.keep_defaults) return;
    var first: ?usize = null;
    var i = s.stops.len;
    while (i > s.current) {
        i -= 1;
        if (s.has_final and i == s.stops.len - 1) continue; // the cursor's final place
        if (i == s.current and !s.fresh) continue; // typed into
        var start = s.stops[i][0];
        var end = s.stops[i][1];
        if (end <= start) continue;
        const t = ed.text();
        const line = t.lineOf(start);
        const ls = t.lineStart(line);
        const le = t.lineEnd(line);
        // The comma before it, else the one after it.
        if (start >= ls + 2 and t.byteAt(start - 2) == ',' and t.byteAt(start - 1) == ' ') {
            start -= 2;
        } else if (start >= ls + 1 and t.byteAt(start - 1) == ',') {
            start -= 1;
        } else if (end + 2 <= le and t.byteAt(end) == ',' and t.byteAt(end + 1) == ' ') {
            end += 2;
        } else if (end + 1 <= le and t.byteAt(end) == ',') end += 1;
        try ed.deleteRangeKeepCursor(start, end);
        first = start;
    }
    if (first) |f| {
        ed.view.cursor = @min(f, ed.text().len());
        ed.view.want_col = null;
    }
}

/// <Tab> / <S-Tab> in insert mode. False when there is no session.
pub fn snippetStep(ed: *Editor, forward: bool) bool {
    const s = &(ed.snippet orelse return false);
    if (s.buffer != ed.buffer) {
        ed.endSnippet();
        return false;
    }
    if (forward) {
        if (s.at_end) {
            ed.snippetSemicolon();
            return true;
        }
        if (s.current + 1 >= s.stops.len) {
            // Past the last placeholder (no $0): after it.
            ed.view.cursor = s.stops[s.current][1];
            ed.snippetAtEnd();
            return true;
        }
        ed.goSnippetStop(s.current + 1);
    } else if (s.at_end) {
        ed.goSnippetStop(s.current);
    } else if (s.current > 0) ed.goSnippetStop(s.current - 1);
    return true;
}

/// Languages whose statements end in `;` (the extra <Tab> after a call).
fn usesSemicolons(b: *const Buffer) bool {
    const s = b.syntax orelse return false;
    const name = s.lang.name;
    for ([_][]const u8{ "zig", "c", "rust", "javascript", "typescript", "tsx", "css" }) |l| if (std.mem.eql(u8, name, l)) return true;
    return false;
}

/// What follows the cursor on its line, trimmed.
fn restOfLine(ed: *Editor) []const u8 {
    const t = ed.text();
    return std.mem.trim(u8, t.slice(ed.view.cursor, t.lineEnd(ed.cursorLine())), " \t");
}

/// The cursor is after the call. If it ends the statement in a language
/// with semicolons, keep the session for one more <Tab> (to the `;`);
/// otherwise the snippet is done.
fn snippetAtEnd(ed: *Editor) void {
    const rest = ed.restOfLine();
    const can = ed.snippet.?.is_call and usesSemicolons(ed.buffer) and (rest.len == 0 or std.mem.eql(u8, rest, ";"));
    if (!can) return ed.endSnippet();
    const s = &ed.snippet.?;
    s.at_end = true;
    s.fresh = false;
}

/// The last <Tab>: to the end of the statement, adding the `;` if missing.
fn snippetSemicolon(ed: *Editor) void {
    ed.endSnippet();
    const rest = ed.restOfLine();
    // Something was typed after the call that isn't a statement end: stay.
    if (rest.len > 0 and !std.mem.eql(u8, rest, ";")) return;
    const t = ed.text();
    const line = ed.cursorLine();
    var end = t.lineEnd(line);
    while (end > t.lineStart(line) and (t.byteAt(end - 1) == ' ' or t.byteAt(end - 1) == '\t')) end -= 1;
    if (end == t.lineStart(line) or t.byteAt(end - 1) != ';') {
        ed.insertAt(end, ";") catch return;
        end += 1;
    }
    ed.view.cursor = end;
    ed.view.want_col = null;
}

/// The current placeholder, if it still holds its default and the cursor is
/// at its start (where typing replaces it).
fn freshPlaceholder(ed: *Editor) ?[2]usize {
    const s = ed.snippet orelse return null;
    if (!s.fresh or s.buffer != ed.buffer) return null;
    const r = s.stops[s.current];
    if (ed.view.cursor != r[0]) return null;
    return r;
}

/// Before typing: a fresh placeholder is replaced by what is typed.
fn snippetTypeOver(ed: *Editor) !void {
    const r = ed.freshPlaceholder() orelse return;
    ed.snippet.?.fresh = false;
    try ed.deleteRange(r[0], r[1]);
}

/// <BS> on a fresh placeholder removes it whole. True when it did.
pub fn snippetBackspace(ed: *Editor) !bool {
    if (ed.freshPlaceholder() == null) return false;
    try ed.snippetTypeOver();
    return true;
}

// Signature help.

pub fn closeSignature(ed: *Editor) void {
    const s = ed.signature orelse return;
    s.deinit(ed.gpa);
    ed.signature = null;
}

/// A `textDocument/signatureHelp` reply: the active signature and
/// parameter, or nothing (closes the popup).
pub fn showSignature(ed: *Editor, b: *Buffer, result: std.json.Value) !void {
    ed.closeSignature();
    if (b != ed.buffer or ed.mode != .insert) return;
    const sigs = Lsp.field(result, "signatures") orelse return;
    if (sigs != .array or sigs.array.items.len == 0) return;
    const active_sig: usize = if (Lsp.field(result, "activeSignature")) |v| (if (v == .integer) @intCast(@max(v.integer, 0)) else 0) else 0;
    const sig = sigs.array.items[@min(active_sig, sigs.array.items.len - 1)];
    const label = Lsp.str(Lsp.field(sig, "label")) orelse return;
    const active_param: ?usize = blk: {
        const v = Lsp.field(sig, "activeParameter") orelse Lsp.field(result, "activeParameter") orelse break :blk 0;
        break :blk if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
    };
    var help: SignatureHelp = .{ .label = try ed.gpa.dupe(u8, label), .doc = &.{} };
    errdefer help.deinit(ed.gpa);
    var doc_src: ?std.json.Value = Lsp.field(sig, "documentation");
    if (Lsp.field(sig, "parameters")) |params| if (params == .array and active_param != null and active_param.? < params.array.items.len) {
        const param = params.array.items[active_param.?];
        if (Lsp.field(param, "label")) |v| switch (v) {
            // Offsets into the label (UTF-16 by the spec; ASCII in practice).
            .array => |a| if (a.items.len == 2 and a.items[0] == .integer and a.items[1] == .integer) {
                help.param_start = @min(@as(usize, @intCast(@max(a.items[0].integer, 0))), label.len);
                help.param_end = @min(@as(usize, @intCast(@max(a.items[1].integer, 0))), label.len);
            },
            .string => |param_text| if (std.mem.indexOf(u8, label, param_text)) |at| {
                help.param_start = at;
                help.param_end = at + param_text.len;
            },
            else => {},
        };
        if (Lsp.field(param, "documentation")) |d| doc_src = d;
    };
    if (doc_src) |d| {
        const doc_text = Lsp.str(d) orelse Lsp.str(Lsp.field(d, "value")) orelse "";
        help.doc = try ed.gpa.dupe(u8, std.mem.trim(u8, std.mem.sliceTo(doc_text, '\n'), " \t"));
    }
    ed.signature = help;
}

// ---------------------------------------------------------------------------
// Git

/// Loads `b`'s HEAD version for diffing, if it is tracked in a repository.
fn loadGitBase(ed: *Editor, b: *Buffer) void {
    const path = b.path orelse return;
    const proj = b.project orelse return;
    if (!proj.git) return;
    const root = proj.root;
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
    if (ed.gitRoot() != null) return true;
    ed.setMessage(.info, "not in a git repository", .{});
    return false;
}

fn startGitJob(ed: *Editor, kind: GitJob.Kind, busy: []const u8, steps: []const []const []const u8) !void {
    if (!ed.inRepo()) return;
    if (ed.git_job != null) return ed.setMessage(.info, "git is still busy...", .{});
    ed.git_job = try GitJob.start(ed.gpa, ed.io, kind, ed.gitRoot().?, steps, ed.wake_fn);
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
        return ed.notify(.err, "git: {s}{s}", .{ job.message, hint });
    }
    switch (job.kind) {
        .commit => ed.notify(.info, "committed: {s}", .{job.message}),
        .push => ed.notify(.info, "pushed", .{}),
        .pull => ed.notify(.info, "pulled: {s}", .{job.message}),
        .switch_branch, .create_branch => ed.notify(.info, "{s}", .{job.message}),
        .set_remote => ed.notify(.info, "remote origin set", .{}),
        .init => {
            ed.notify(.info, "{s}", .{job.message});
            ed.adoptNewRepository(job.root);
        },
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
    fresh.project = b.project;
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

/// `SPC g i`: makes the current project (else the working folder) a git
/// repository.
pub fn gitInit(ed: *Editor) !void {
    if (ed.gitRoot()) |root| return ed.setMessage(.info, "already in a git repository ({s})", .{root});
    if (ed.git_job != null) return ed.setMessage(.info, "git is still busy...", .{});
    ed.git_job = try GitJob.start(ed.gpa, ed.io, .init, ed.projectRoot(), &.{&.{ "git", "init" }}, ed.wake_fn);
    ed.setMessage(.info, "git: initializing...", .{});
}

/// A repository was just made at `root`: the projects there (and the files
/// in them) are git projects from now on, so the gutter, ghost lines,
/// commits and the rest work without reopening anything.
fn adoptNewRepository(ed: *Editor, root: []const u8) void {
    for (ed.projects.items) |p| if (std.mem.eql(u8, p.root, root)) {
        p.git = true;
    };
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        b.project = ed.projectOf(path);
    }
    if (Project.detect(ed.io, root)) |f| ed.last_project = ed.internProject(f.root, f.git);
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
    if (Git.originUrl(ed.gpa, ed.io, ed.gitRoot().?)) |url| {
        defer ed.gpa.free(url);
        try ed.search_prompt.?.input.set(ed.gpa, url);
    }
}

fn finishGitRemote(ed: *Editor) !void {
    const url = try ed.takePromptText() orelse return;
    defer ed.gpa.free(url);
    const trimmed = std.mem.trim(u8, url, " ");
    if (trimmed.len == 0) return;
    const has_origin = if (Git.originUrl(ed.gpa, ed.io, ed.gitRoot().?)) |u| blk: {
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
    ed.dropAllBlames();
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
        // (Normal mode too: the query is edited there with vim keys.)
        .picker, .picker_normal => if (ed.picker) |p| {
            try p.queryChanged();
            // The server does this search: ask it again for the new text.
            if (p.kind == .workspace_symbols) if (ed.lspFor(ed.buffer)) |l| try l.requestWorkspaceSymbols(p.activeQuery());
        },
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
    ed.setMessage(.info, "renamed: {d} edit(s) in {d} file(s) (SPC s to save)", .{ edits.len, files });
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
    if (sp.kind == .select_in) {
        // Only shows the matches (the cursors come on <CR> / <Tab>).
        try ed.last_search.resize(ed.gpa, 0);
        try ed.last_search.appendSlice(ed.gpa, sp.input.items());
        ed.last_search_whole_word = false;
        ed.search_highlight = sp.input.items().len > 0;
        return;
    }
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
    ed.snipe_dot = sp.kind == .snipe and sp.return_mode != .operator;
    ed.find_dot = false;
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
        .run_command => |k| return ed.finishRunPrompt(k),
        .ask_claude => return ed.finishAskClaude(),
        .browse_new_folder, .browse_new_file, .browse_rename, .browse_move => |k| return ed.finishBrowsePrompt(k),
        .select_in => return ed.cursorsFromPrompt(),
        .replace => return ed.finishReplace(),
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
    // Cancelling one of the browser's prompts goes back to the browser.
    switch (sp.kind) {
        .browse_new_folder, .browse_new_file, .browse_rename, .browse_move => ed.reopenBrowser(null),
        .replace => ed.cancelReplace(),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Search and replace across the project

/// `<C-r>` in the grep picker: its query becomes the search (exact, smart
/// case), and a prompt asks for the replacement.
pub fn startReplace(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .grep) return ed.setMessage(.info, "<C-r> replaces from the grep picker (SPC /)", .{});
    const needle = try ed.gpa.dupe(u8, p.activeQuery());
    defer ed.gpa.free(needle);
    if (needle.len == 0) return ed.setMessage(.info, "type what to replace first", .{});
    if (!@import("picker/sources.zig").haveRg(ed.io)) return ed.setMessage(.err, "replacing needs ripgrep (rg)", .{});
    const root = ed.picker_root;
    const r = try Replace.start(ed.gpa, ed.io, needle, root, ed.wake_fn);
    ed.closePicker();
    if (ed.replace) |old| old.destroy();
    ed.replace = r;
    ed.replace_root = root;
    ed.startSearch(true, .replace);
}

/// `<Esc>`: back to the grep picker, with the search as its query.
fn cancelReplace(ed: *Editor) void {
    const r = ed.replace orelse return;
    ed.replace = null;
    defer r.destroy();
    ed.next_picker_root = ed.replace_root;
    ed.openPicker(.grep, r.needle) catch {};
}

/// `<CR>`: replaces every match not skipped. Each file is opened and changed
/// as one undo step; a match whose text changed since the search is left.
fn finishReplace(ed: *Editor) !void {
    const r = ed.replace orelse return ed.cancelSearch();
    if (!r.isDone()) return ed.setMessage(.info, "still searching...", .{});
    var sp = ed.search_prompt orelse return;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.replace = null;
    defer r.destroy();
    const replacement = sp.input.items();

    const home = ed.buffer;
    const home_cursor = sp.origin;
    var replaced: usize = 0;
    var files: usize = 0;
    var stale: usize = 0;
    const rows = r.matches.items;
    var i: usize = 0;
    while (i < rows.len) {
        const path = rows[i].path;
        var j = i;
        var wanted = false;
        while (j < rows.len and std.mem.eql(u8, rows[j].path, path)) : (j += 1) wanted = wanted or !rows[j].skip;
        defer i = j;
        if (!wanted) continue;
        const abs = try std.fs.path.join(ed.gpa, &.{ r.root, path });
        defer ed.gpa.free(abs);
        ed.openFile(abs) catch {
            for (rows[i..j]) |m| stale += if (m.skip) 0 else m.cols.len;
            continue;
        };
        const t = ed.text();
        var changed = false;
        // Bottom up, right to left: earlier positions stay valid.
        var k = j;
        while (k > i) {
            k -= 1;
            const m = rows[k];
            if (m.skip) continue;
            if (m.line >= t.lineCount()) {
                stale += m.cols.len;
                continue;
            }
            const ls = t.lineStart(m.line);
            var c = m.cols.len;
            while (c > 0) {
                c -= 1;
                const at = ls + m.cols[c];
                if (!r.matchesAt(t.slice(ls, t.lineEnd(m.line)), m.cols[c])) {
                    stale += 1;
                    continue;
                }
                try ed.deleteRangeKeepCursor(at, at + r.needle.len);
                try ed.insertAt(at, replacement);
                replaced += 1;
                changed = true;
            }
        }
        if (changed) {
            try ed.buffer.history.commit(ed.gpa);
            ed.buffer.modified = ed.buffer.history.isModified();
            files += 1;
        }
    }
    if (ed.bufferAlive(home)) ed.switchTo(home);
    ed.setCursor(@min(home_cursor, ed.text().len()));
    // With autosave, leaving each file wrote it.
    const after = if (ed.options.autosave) "saved; u in a file undoes it" else "SPC b a saves all; u in a file undoes it";
    if (stale > 0) {
        ed.setMessage(.info, "replaced {d} in {d} file(s) ({s}); {d} had changed since the search and were left alone", .{ replaced, files, after, stale });
    } else {
        ed.setMessage(.info, "replaced {d} in {d} file(s) ({s})", .{ replaced, files, after });
    }
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
    ed.snipe_dot = sp.kind == .snipe and sp.return_mode != .operator;
    ed.find_dot = false;
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
// Moving by the shape of the code (Alt keys; `syntax/objects.zig`)

/// What a selection was before `Alt-u` grew it (`normal`: a cursor, not a
/// selection, at `range.start`).
pub const GrowStep = struct { range: textobjects.Range, normal: bool };

/// The selection, or the cursor as a one-character range.
fn structureRange(ed: *Editor) textobjects.Range {
    if (ed.mode == .visual) return ed.visualRange();
    const t = ed.text();
    const c = @min(ed.view.cursor, t.len());
    return .{ .start = c, .end = @max(motions.nextChar(t, c), c + 1) };
}

fn structureSyntax(ed: *Editor) ?*Syntax {
    if (ed.buffer.syntax) |*s| return s;
    ed.setMessage(.info, "no syntax tree for this file", .{});
    return null;
}

/// Selects `r` charwise, entering visual mode if needed.
fn selectNode(ed: *Editor, r: textobjects.Range) void {
    if (ed.mode != .visual) ed.enterVisual(false);
    ed.visual_line = false;
    ed.selectRange(r);
    ed.revealLine(ed.text().lineOf(ed.view.cursor));
}

/// `Alt-u`: the selection grows to the next node up the syntax tree.
pub fn growSelection(ed: *Editor) !void {
    const s = ed.structureSyntax() orelse return;
    const sel = ed.structureRange();
    const r = syntax_objects.expand(s, ed.text(), sel) orelse return;
    // Keep the way back only while the selection is the one grown last.
    if (ed.grown) |g| {
        if (g.buffer != ed.buffer or g.version != ed.buffer.edit_version or ed.mode != .visual or g.range.start != sel.start or g.range.end != sel.end)
            ed.grow_stack.clearRetainingCapacity();
    } else ed.grow_stack.clearRetainingCapacity();
    try ed.grow_stack.append(ed.gpa, .{ .range = sel, .normal = ed.mode != .visual });
    ed.selectNode(r);
    ed.grown = .{ .buffer = ed.buffer, .version = ed.buffer.edit_version, .range = r };
}

/// `Alt-i`: back to what the selection was before the last `Alt-u`.
pub fn shrinkSelection(ed: *Editor) void {
    const g = ed.grown orelse return;
    const sel = ed.structureRange();
    if (ed.mode != .visual or g.buffer != ed.buffer or g.version != ed.buffer.edit_version or g.range.start != sel.start or g.range.end != sel.end) return;
    const step = ed.grow_stack.pop() orelse return;
    if (step.normal) {
        ed.grown = null;
        ed.grow_stack.clearRetainingCapacity();
        ed.exitVisual();
        ed.setCursor(step.range.start);
        return;
    }
    ed.selectNode(step.range);
    ed.grown = .{ .buffer = ed.buffer, .version = ed.buffer.edit_version, .range = step.range };
}

/// `Alt-n` / `Alt-p`: to the next / previous sibling node (an argument, a
/// statement, a field, a prop, a function): the cursor goes to its start, a
/// selection becomes it.
pub fn siblingNode(ed: *Editor, forward: bool) void {
    const s = ed.structureSyntax() orelse return;
    const visual = ed.mode == .visual;
    const r = syntax_objects.sibling(s, ed.text(), ed.structureRange(), !visual, forward) orelse return;
    if (visual) {
        ed.selectNode(r);
        ed.grown = null;
        return;
    }
    ed.revealLine(ed.text().lineOf(r.start));
    ed.setCursor(r.start);
}

/// `Alt-N` / `Alt-P`: the node at the cursor (or the selected one) trades
/// places with its next / previous sibling, and stays selected / under the
/// cursor, so pressing again carries it further. One undo step.
pub fn swapNode(ed: *Editor, forward: bool) !void {
    const s = ed.structureSyntax() orelse return;
    const visual = ed.mode == .visual;
    const t = ed.text();
    const pair = syntax_objects.swapPair(s, t, ed.structureRange(), !visual, forward) orelse return;
    const node = pair[0];
    const other = pair[1];
    const first = if (node.start < other.start) node else other;
    const second = if (node.start < other.start) other else node;
    if (first.end > second.start) return; // overlapping: not siblings
    const a = try ed.gpa.dupe(u8, t.slice(first.start, first.end));
    defer ed.gpa.free(a);
    const b = try ed.gpa.dupe(u8, t.slice(second.start, second.end));
    defer ed.gpa.free(b);
    // The later one first, so the earlier positions hold.
    try ed.deleteRangeKeepCursor(second.start, second.end);
    try ed.insertAt(second.start, a);
    try ed.deleteRangeKeepCursor(first.start, first.end);
    try ed.insertAt(first.start, b);
    try ed.buffer.history.commit(ed.gpa);
    // Where the node is now.
    const len = node.end - node.start;
    const at = if (node.start == first.start) second.start + b.len - a.len else first.start;
    const moved: textobjects.Range = .{ .start = at, .end = at + len };
    if (visual) {
        ed.selectNode(moved);
        ed.grown = null;
    } else {
        ed.revealLine(ed.text().lineOf(at));
        ed.setCursor(at);
    }
}

/// `Alt-f` / `Alt-F`: to the next / previous function.
pub fn functionJump(ed: *Editor, forward: bool) void {
    const s = ed.structureSyntax() orelse return;
    const pos = syntax_objects.functionStart(s, ed.text(), ed.view.cursor, forward) orelse
        return ed.setMessage(.info, "no {s} function", .{if (forward) "next" else "previous"});
    ed.revealLine(ed.text().lineOf(pos));
    ed.setCursor(pos);
}

/// `Alt-c`: the name under the cursor (or each name in the selection) in
/// the next case: snake_case, camelCase, PascalCase, SCREAMING_CASE,
/// kebab-case, and round again.
pub fn cycleCase(ed: *Editor) !void {
    const case = @import("core/case.zig");
    const t = ed.text();
    var r: textobjects.Range = undefined;
    if (ed.mode == .visual) {
        r = ed.visualRange();
        ed.exitVisual();
    } else {
        const c = @min(ed.view.cursor, t.len());
        const line = t.lineOf(c);
        const ls = t.lineStart(line);
        const le = t.lineEnd(line);
        if (c >= le or !case.isNameChar(t.byteAt(c))) return;
        var start = c;
        var end = c;
        while (start > ls and case.isNameChar(t.byteAt(start - 1))) start -= 1;
        while (end < le and case.isNameChar(t.byteAt(end))) end += 1;
        // A `-` only joins words (`a - b` isn't one name).
        while (start < end and t.byteAt(start) == '-') start += 1;
        while (end > start and t.byteAt(end - 1) == '-') end -= 1;
        r = .{ .start = start, .end = end };
    }
    if (r.end <= r.start) return;
    // Each name in the range, converted; the rest as it was.
    const src = try ed.gpa.dupe(u8, t.slice(r.start, r.end));
    defer ed.gpa.free(src);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ed.gpa);
    var i: usize = 0;
    while (i < src.len) {
        if (!case.isNameChar(src[i])) {
            try out.append(ed.gpa, src[i]);
            i += 1;
            continue;
        }
        var j = i;
        while (j < src.len and case.isNameChar(src[j])) j += 1;
        const next = try case.cycle(ed.gpa, src[i..j]);
        defer ed.gpa.free(next);
        try out.appendSlice(ed.gpa, next);
        i = j;
    }
    if (std.mem.eql(u8, out.items, src)) return;
    try ed.deleteRangeKeepCursor(r.start, r.end);
    try ed.insertAt(r.start, out.items);
    ed.setCursor(r.start);
}

/// Sticky context for the window: the scope headers the top line is inside
/// (outermost first), fewer when the text under them would hide the cursor.
pub fn contextLines(ed: *Editor, out: []usize) []usize {
    if (!ed.options.sticky_context or ed.ghost != null) return out[0..0];
    const s = if (ed.buffer.syntax) |*sx| sx else return out[0..0];
    const t = ed.text();
    const top = ed.topRow().line;
    var lines = syntax_objects.contextLines(s, t, top, out);
    // The context covers its own rows: look again from the line under it.
    if (lines.len > 0 and top + lines.len < t.lineCount()) {
        var again: [8]usize = undefined;
        const more = syntax_objects.contextLines(s, t, top + lines.len, again[0..out.len]);
        if (more.len >= lines.len) {
            @memcpy(out[0..more.len], more);
            lines = out[0..more.len];
        }
    }
    // Never over the cursor's row.
    const cur = ed.cursorLine();
    var n = lines.len;
    while (n > 0 and top + n > cur) n -= 1;
    return lines[0..n];
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

// Rows within a line: its code lens row, then its wrapped pieces.

/// Whether some line can take more than one row (then rows can't be
/// counted as lines).
pub fn layered(ed: *const Editor) bool {
    return ed.options.wrap or ed.hasLenses();
}

/// The rows (wrapped pieces) of `line`, written into `buf`: at least one.
/// A closed fold's line is one row.
pub fn segments(ed: *const Editor, line: usize, buf: *[max_segments]Seg) []Seg {
    const t = &ed.buffer.text;
    const cols = @max(ed.view.cols, 8);
    if (!ed.options.wrap or line >= t.lineCount() or ed.foldAt(line) != null) {
        buf[0] = .{ .start = 0, .end = std.math.maxInt(usize), .indent = 0 };
        return buf[0..1];
    }
    const bytes = t.lineSlice(line);
    const tab = ed.options.tab_width;
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = ed.lineHints(ed.buffer, line, &hint_buf);
    // Later rows start under the line's indentation (at most half the width).
    const lead = bytes[0 .. std.mem.indexOfNone(u8, bytes, " \t") orelse bytes.len];
    const indent = @min(motions.displayCol(bytes, lead.len, tab), cols / 2);
    var n: usize = 0;
    var row_start: usize = 0;
    var width = cols;
    var last_break: usize = 0; // visual column after the last space in this row
    var col: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const cp_end = @min(i + len, bytes.len);
        const next_col = if (bytes[i] == '\t') motions.nextTabStop(col, tab) else col + 1;
        const v0 = col + hintShift(hints, i);
        const v1 = next_col + hintShift(hints, i);
        if (v1 > row_start + width and v0 > row_start and n + 1 < max_segments) {
            const at = if (last_break > row_start) last_break else v0;
            buf[n] = .{ .start = row_start, .end = at, .indent = if (n == 0) 0 else indent };
            n += 1;
            row_start = at;
            width = cols - indent;
            last_break = row_start;
        }
        if (bytes[i] == ' ' or bytes[i] == '\t') last_break = v1;
        col = next_col;
        i = cp_end;
    }
    buf[n] = .{ .start = row_start, .end = std.math.maxInt(usize), .indent = if (n == 0) 0 else indent };
    return buf[0 .. n + 1];
}

/// The visual column (inlay hints counted) of byte `off` of `line`.
pub fn visualCol(ed: *const Editor, line: usize, off: usize) usize {
    const t = &ed.buffer.text;
    const bytes = t.lineSlice(line);
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = ed.lineHints(ed.buffer, line, &hint_buf);
    return motions.displayCol(bytes, @min(off, bytes.len), ed.options.tab_width) + hintShift(hints, off);
}

/// Which of `segs` visual column `vcol` is on.
pub fn segmentIndex(segs: []const Seg, vcol: usize) usize {
    var k: usize = 0;
    while (k + 1 < segs.len and vcol >= segs[k + 1].start) k += 1;
    return k;
}

/// A code lens title for `line` of `b`: joined to the line's others.
pub fn addLens(ed: *Editor, b: *Buffer, line: u32, title: []const u8) !void {
    const clean = std.mem.trim(u8, title, " ");
    if (clean.len == 0) return;
    var i: usize = 0;
    while (i < b.lenses.items.len and b.lenses.items[i].line < line) i += 1;
    if (i < b.lenses.items.len and b.lenses.items[i].line == line) {
        const lens = &b.lenses.items[i];
        const old = lens.text;
        // The first new title replaces the one kept from the last answer.
        lens.text = if (lens.stale) try ed.gpa.dupe(u8, clean) else try std.mem.concat(ed.gpa, u8, &.{ old, " | ", clean });
        lens.stale = false;
        ed.gpa.free(old);
        return;
    }
    const owned = try ed.gpa.dupe(u8, clean);
    errdefer ed.gpa.free(owned);
    try b.lenses.insert(ed.gpa, i, .{ .line = line, .text = owned });
}

/// Each frame: code lens for the buffers on screen, asked for once their
/// text has been still a moment (as inlay hints).
fn tickCodeLens(ed: *Editor) void {
    if (!ed.options.code_lens) return;
    for (ed.window_list.items) |w| {
        if (w.term != null) continue;
        const b = ed.windowBuffer(w);
        const l = ed.lspFor(b) orelse continue;
        if (!l.can_lens or b.lens_pending or b.lens_version == b.edit_version or b.path == null) continue;
        if (b.hint_changed.durationTo(ed.now).nanoseconds < hint_debounce_ms * std.time.ns_per_ms and b.hint_seen == b.edit_version) continue;
        l.requestCodeLens(b) catch {};
    }
}

pub fn hasLenses(ed: *const Editor) bool {
    return ed.options.code_lens and ed.buffer.lenses.items.len > 0;
}

/// The code lens text shown above `line`, if any.
pub fn lensText(ed: *const Editor, line: usize) ?[]const u8 {
    if (!ed.options.code_lens) return null;
    for (ed.buffer.lenses.items) |l| {
        if (l.line == line and !l.gone) return l.text;
        if (l.line > line) break;
    }
    return null;
}

pub fn lensRows(ed: *const Editor, line: usize) usize {
    return @intFromBool(ed.lensText(line) != null);
}

/// Rows `line` takes on screen.
pub fn subRows(ed: *const Editor, line: usize) usize {
    var buf: [max_segments]Seg = undefined;
    return ed.lensRows(line) + ed.segments(line, &buf).len;
}

pub fn nextRow(ed: *const Editor, r: Row) Row {
    const n = ed.buffer.text.lineCount();
    if (r.ghost) |k| {
        const h = ed.ghostHunk(r.line) orelse return .{ .line = @min(r.line, n - 1) };
        if (k + 1 < h.old_count) return .{ .line = r.line, .ghost = k + 1 };
        return if (r.line < n) .{ .line = r.line } else r;
    }
    if (ed.layered() and r.line < n and r.sub + 1 < ed.subRows(r.line)) return .{ .line = r.line, .sub = r.sub + 1 };
    const after = (if (ed.foldAt(r.line)) |f| f.last else r.line) + 1;
    if (ed.ghostHunk(after) != null) return .{ .line = after, .ghost = 0 };
    return if (after < n) .{ .line = after } else r;
}

pub fn prevRow(ed: *const Editor, r: Row) Row {
    if (r.ghost) |k| {
        if (k > 0) return .{ .line = r.line, .ghost = k - 1 };
        return if (r.line == 0) r else ed.lastRowOf(ed.visibleLine(r.line - 1));
    }
    if (r.sub > 0) return .{ .line = r.line, .sub = r.sub - 1 };
    if (ed.ghostHunk(r.line)) |h| return .{ .line = r.line, .ghost = h.old_count - 1 };
    return if (r.line == 0) r else ed.lastRowOf(ed.visibleLine(r.line - 1));
}

/// The bottom row of `line` (its last wrapped piece).
fn lastRowOf(ed: *const Editor, line: usize) Row {
    if (!ed.layered()) return .{ .line = line };
    return .{ .line = line, .sub = @intCast(ed.subRows(line) - 1) };
}

/// The row `delta` rows away from `r` (stops at the ends).
pub fn stepRows(ed: *const Editor, r: Row, delta: isize) Row {
    if (ed.buffer.folds.isEmpty() and !ed.hasGhosts() and r.ghost == null and !ed.layered()) {
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
    if (ed.buffer.folds.isEmpty() and !ed.hasGhosts() and a.ghost == null and b.ghost == null and !ed.layered()) {
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
    return .{ .line = ed.view.top, .ghost = ed.view.top_ghost, .sub = if (ed.view.top_ghost == null) ed.view.top_sub else 0 };
}

pub fn setTop(ed: *Editor, r: Row) void {
    ed.view.top = r.line;
    ed.view.top_ghost = r.ghost;
    ed.view.top_sub = r.sub;
}

pub fn cursorRow(ed: *const Editor) Row {
    if (ed.ghost) |g| return .{ .line = g.line, .ghost = g.k };
    const t = &ed.buffer.text;
    const line = ed.visibleLine(t.lineOf(ed.view.cursor));
    if (!ed.layered()) return .{ .line = line };
    var buf: [max_segments]Seg = undefined;
    const segs = ed.segments(line, &buf);
    const k = if (line == t.lineOf(ed.view.cursor)) segmentIndex(segs, ed.visualCol(line, ed.view.cursor - t.lineStart(line))) else 0;
    return .{ .line = line, .sub = @intCast(ed.lensRows(line) + k) };
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
        if (ed.layered() and ed.options.wrap) return ed.setCursorScreenRow(r);
        ed.gotoLine(r.line);
        ed.view.want_col = col;
    }
}

/// Onto a wrapped line's row `r` (a lens row counts as its first piece):
/// at the screen column the cursor was on, which sticks while moving up
/// and down (as `gj` / `gk`).
fn setCursorScreenRow(ed: *Editor, r: Row) void {
    const screen = ed.wantScreenCol();
    const t = ed.text();
    const line = @min(r.line, t.lineCount() - 1);
    var buf: [max_segments]Seg = undefined;
    const segs = ed.segments(line, &buf);
    const lens = ed.lensRows(line);
    const k = @min(@as(usize, r.sub) -| lens, segs.len - 1);
    const seg = segs[k];
    var vcol = seg.start + (screen -| seg.indent);
    // Not past this row's end (its last column, or the line's end).
    if (k + 1 < segs.len and vcol >= seg.end) vcol = seg.end -| 1;
    const bytes = t.lineSlice(line);
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = ed.lineHints(ed.buffer, line, &hint_buf);
    const text_col = hintVisualToText(hints, bytes, vcol, ed.options.tab_width);
    ed.setCursor(t.lineStart(line) + motions.byteAtCol(bytes, text_col, ed.options.tab_width));
    ed.wrap_want = .{ .cursor = ed.view.cursor, .screen = screen };
}

/// The screen column the cursor is on (within its row), or the one kept
/// from the last move up or down if the cursor hasn't moved since.
fn wantScreenCol(ed: *Editor) usize {
    if (ed.wrap_want) |w| if (w.cursor == ed.view.cursor) return w.screen;
    const t = ed.text();
    const line = t.lineOf(ed.view.cursor);
    var buf: [max_segments]Seg = undefined;
    const segs = ed.segments(line, &buf);
    const vcol = ed.visualCol(line, ed.view.cursor - t.lineStart(line));
    const seg = segs[segmentIndex(segs, vcol)];
    return vcol - seg.start + seg.indent;
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

/// A mouse button went down on a text cell (`clicks`: 1, 2 or 3 in a
/// row). One places the cursor (dragging from there selects), two select
/// the word, three the line; the selection goes to the clipboard on
/// release, as in kitty.
pub fn mousePress(ed: *Editor, row: usize, col: usize, clicks: u8) void {
    if (ed.mode == .insert) ed.setMode(.normal);
    if (ed.mode == .visual) ed.exitVisual();
    ed.clickCell(row, col);
    ed.mouse_drag = .{ .anchor = ed.view.cursor };
    // On a ghost line (old text from HEAD): whole old lines are selected
    // and copied, as `V` / `y` do on them.
    if (ed.ghost) |*g| {
        ed.mouse_drag.?.ghost = .{ .line = g.line, .k = g.k, .last = g.k };
        if (clicks >= 2) {
            ed.mode = .visual;
            ed.visual_line = true;
            g.anchor = g.k;
            ed.mouse_drag.?.selected = true;
        }
        return;
    }
    const t = ed.text();
    switch (clicks) {
        0, 1 => {},
        2 => if (textobjects.word(t, ed.view.cursor, .inner, false, 1)) |r| if (r.end > r.start) {
            ed.enterVisual(false);
            ed.selectRange(r);
            ed.mouse_drag.?.selected = true;
        },
        else => {
            ed.enterVisual(true);
            ed.mouse_drag.?.selected = true;
        },
    }
}

/// The pointer moved with the button down: the selection follows it.
pub fn mouseDrag(ed: *Editor, row: usize, col: usize) void {
    const d = &(ed.mouse_drag orelse return);
    if (d.ghost) |*start| {
        ed.clickCell(row, col);
        // Within the hunk it began in; off it, the selection stays where it
        // last was.
        const k = if (ed.ghost) |g| (if (g.line == start.line) g.k else start.last) else start.last;
        start.last = k;
        ed.ghost = .{ .line = start.line, .k = k, .col = 0, .anchor = start.k };
        ed.mode = .visual;
        ed.visual_line = true;
        d.selected = true;
        return;
    }
    if (ed.ghost != null) return;
    const anchor = if (ed.mode == .visual) ed.view.anchor else d.anchor;
    ed.clickCell(row, col);
    if (ed.mode != .visual) {
        if (ed.view.cursor == d.anchor) return;
        ed.enterVisual(false);
    }
    ed.view.anchor = anchor;
    d.selected = true;
}

/// The button came up: a selection made with the mouse is copied.
pub fn mouseRelease(ed: *Editor) void {
    const d = ed.mouse_drag orelse return;
    ed.mouse_drag = null;
    if (!d.selected or ed.mode != .visual) return;
    if (ed.ghost) |g| if (g.anchor) |a| {
        ed.yankGhostLines(g.line, a, g.k, '+') catch return;
        const n = @max(a, g.k) - @min(a, g.k) + 1;
        return ed.notify(.info, "copied {d} old line{s}", .{ n, if (n == 1) "" else "s" });
    };
    const r = ed.visualRange();
    const t = ed.text();
    const end = if (ed.visual_line) @min(r.end + 1, t.len()) else r.end;
    if (end <= r.start) return;
    ed.registers.store('+', .yank, t.slice(r.start, end), ed.visual_line) catch return;
    ed.yank_flash = .{ .buffer = ed.buffer, .start = r.start, .end = end, .linewise = ed.visual_line, .born = ed.now };
    const lines = t.lineOf(end -| 1) - t.lineOf(r.start) + 1;
    if (lines > 1) ed.notify(.info, "copied {d} lines", .{lines}) else ed.notify(.info, "copied {d} characters", .{end - r.start});
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
    // A cell on a line with inlay hints is further along the text than it
    // looks; one on a hint itself is the text right after it. On a wrapped
    // line's later row, the columns go on from the row before (a lens row
    // is the line's start).
    var hint_buf: [max_line_hints]LineHint = undefined;
    const hints = ed.lineHints(ed.buffer, r.line, &hint_buf);
    const bytes = t.lineSlice(r.line);
    var vcol = ed.view.left + col;
    if (ed.layered()) {
        var seg_buf: [max_segments]Seg = undefined;
        const segs = ed.segments(r.line, &seg_buf);
        const lens = ed.lensRows(r.line);
        if (r.sub < lens) {
            vcol = 0;
        } else {
            const k = @min(r.sub - lens, segs.len - 1);
            vcol = segs[k].start + (col -| segs[k].indent);
            if (k + 1 < segs.len and vcol >= segs[k].end) vcol = segs[k].end -| 1;
        }
    }
    const text_col = hintVisualToText(hints, bytes, vcol, ed.options.tab_width);
    const off = motions.byteAtCol(bytes, text_col, ed.options.tab_width);
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
    if (top.ghost != null or !ed.layered()) {
        top.sub = 0;
    } else top.sub = @intCast(@min(top.sub, ed.subRows(top.line) - 1));
    ed.setTop(top);
    if (cur.before(top) or ed.rowsFrom(top, cur, so) < so) {
        ed.setTop(ed.stepRows(cur, -@as(isize, @intCast(so))));
    } else {
        // Keep `so` rows below the cursor, but only rows that exist: near
        // the end of the text (or when it all fits) there is nothing to
        // scroll for, as in vim.
        const last: Row = .{ .line = ed.visibleLine(ed.text().lineCount() -| 1) };
        const below = @min(so, ed.rowsFrom(cur, last, so));
        if (ed.rowsFrom(top, cur, v.rows) + below >= v.rows) {
            ed.setTop(ed.stepRows(cur, -@as(isize, @intCast(v.rows -| (below + 1)))));
        }
    }

    // Wrapped lines fit the width: no sideways scrolling.
    if (ed.options.wrap and ed.ghost == null) {
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
        const b = ed.windowBuffer(w);
        const bp = b.path orelse continue;
        const abs = ed.absolutePath(bp) catch continue;
        defer ed.gpa.free(abs);
        if (!std.mem.eql(u8, abs, path)) continue;
        if (b.modified) _ = b.save(ed.gpa, ed.io) catch {};
        ed.focusWindow(w);
        if (ed.window_list.items.len > 1) ed.closeWindow();
        return;
    }
    if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(ed.io, d) catch {};
    try ed.splitWindow(.down);
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
    tags.beforeEdit(ed, start, end, 0);
    ed.noteChange(start, end, 0);
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
    loaded.project = ed.projectOf(norm);
    ed.enterProject(loaded.project);
    // Replace an untouched scratch buffer instead of keeping it around, like vim.
    const cur = ed.buffer;
    if (cur.path == null and !cur.modified and cur.text.len() == 0) {
        ed.lspCloseBuffer(cur);
        cur.deinit(ed.gpa);
        ed.restoreFileState(&loaded);
        cur.* = loaded;
        ed.use_counter += 1;
        cur.last_used = ed.use_counter;
        ed.loadGitBase(cur);
        ed.activate(cur);
        ed.recordVisit(cur);
        return;
    }
    errdefer loaded.deinit(ed.gpa);
    ed.restoreFileState(&loaded);
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
    // Resolved: no "..", "." or trailing "/" (so "../x" isn't taken to be
    // inside the cwd's project).
    return std.fs.path.resolve(ed.gpa, &.{ ed.cwd, path });
}

/// Opens `path` and puts the cursor at (`line`, `col`), both 0-based.
pub fn jumpTo(ed: *Editor, path: []const u8, line: usize, col: usize) !void {
    ed.pushJump();
    try ed.moveTo(path, line, col);
}

/// `jumpTo` without recording a jump.
pub fn moveTo(ed: *Editor, path: []const u8, line: usize, col: usize) !void {
    try ed.openFile(path);
    const t = ed.text();
    const l = @min(line, t.lineCount() - 1);
    ed.revealLine(l);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
}

/// Paths inside the cwd are stored relative to it, without "./".
/// Paths outside it are absolute; "..", "." and trailing "/" are resolved.
fn normalizePath(ed: *Editor, path: []const u8) Allocator.Error![]u8 {
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
        if (Project.detect(ed.io, abs)) |f| ed.enterProject(ed.internProject(f.root, f.git));
        ed.setBrowseDir(abs) catch return;
        ed.openPicker(.browse, "") catch {};
        return;
    }
    ed.openFile(abs) catch |err| ed.setMessage(.err, "could not open {s}: {s}", .{ path, @errorName(err) });
}

pub fn switchTo(ed: *Editor, b: *Buffer) void {
    if (b == ed.buffer) return;
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    ed.leaveBuffer(ed.buffer);
    ed.use_counter += 1;
    b.last_used = ed.use_counter;
    ed.activate(b);
    ed.recordVisit(b);
}

/// Shows `b` with its saved view, without saving the current one.
fn activate(ed: *Editor, b: *Buffer) void {
    ed.cursors.clearRetainingCapacity();
    ed.enterProject(b.project);
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
    ed.lspCloseBuffer(b);
    ed.dropBlame(b);
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
    _ = ed.buffers.orderedRemove(ed.bufferIndex(b));
    ed.forgetJumps(b);
    ed.forgetMarks(b);
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
    if (ed.multi_once or ed.mode == .picker or ed.mode == .picker_normal or ed.cursors.items.len == 0) return;
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
    for (ed.marks.items) |*m| if (m.buffer == ed.buffer) S.shift(&m.pos, start, end, inserted);
    // Placeholders grow with typing at their end, not their start.
    if (ed.snippet) |sn| if (sn.buffer == ed.buffer) for (sn.stops) |*r| {
        if (start == end and inserted > 0) {
            if (r[0] > start) r[0] += inserted;
            if (r[1] >= start) r[1] += inserted;
        } else {
            S.shift(&r[0], start, end, inserted);
            S.shift(&r[1], start, end, inserted);
        }
    };
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

/// `s` (visual: in the selection; normal: in the whole file): asks for text, then puts a cursor on every match of it
/// inside the selection, each match selected (`c` changes them all).
pub fn startSelectIn(ed: *Editor) void {
    if (ed.ghost != null or (ed.mode != .visual and ed.mode != .normal)) return;
    const t = ed.text();
    // From normal mode there is no selection: the whole file.
    var r: operators.Range = if (ed.mode == .visual) ed.visualRange() else .{ .start = 0, .end = t.len() };
    if (ed.visual_line) {
        r.start = t.lineStart(t.lineOf(r.start));
        r.end = t.lineEnd(t.lineOf(@max(r.start, r.end -| 1)));
    }
    ed.startSearch(true, .select_in);
    ed.search_prompt.?.within_start = r.start;
    ed.search_prompt.?.within_end = r.end;
}

/// <Tab> in the snipe (`s`) or search (`/`) prompt: a cursor on every match
/// (on screen for snipe, in the file for search), each match selected, so
/// `c` changes them all and <Esc> leaves plain cursors.
pub fn cursorsFromPrompt(ed: *Editor) !void {
    const sp = ed.search_prompt orelse return;
    // In the replace prompt, <Tab> skips a line instead.
    if (sp.kind == .replace) if (ed.replace) |r| return r.toggle();
    if (sp.kind != .search and sp.kind != .snipe and sp.kind != .select_in) return;
    const needle = try ed.gpa.dupe(u8, sp.input.items());
    defer ed.gpa.free(needle);
    if (needle.len == 0) return;
    const t = ed.text();
    var from: usize = 0;
    var to = t.len();
    if (sp.kind == .select_in) {
        from = sp.within_start;
        to = @min(sp.within_end, t.len());
    }
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
// Terminal popup (`SPC r t`) and running commands (`SPC r`).
//
// Both are terminals (a program on a PTY, emulated by libghostty-vt) shown
// in a popup over the editor. While the popup is open every key goes to the
// program, except <C-\> (hide) and, once a run has finished, q/<Esc>
// (close) and r (run again).

/// Starts `argv` in a terminal, in the current project's root.
/// Build files that mark the folder a command should run in.
const run_markers = Project.markers ++ [_][]const u8{ "makefile", "GNUmakefile" };

/// Where commands (the runner, shells) start: the folder of the code you
/// are in. From the current file's folder up to its project's root, the
/// nearest folder with a build file (build.zig, Makefile, Cargo.toml, ...),
/// else the project root. A file in no project: its own folder (not some
/// other project you were in earlier). No file: the project root. The
/// caller frees it.
pub fn commandFolder(ed: *Editor) ![]u8 {
    const b = ed.buffer;
    const path = b.path orelse return ed.gpa.dupe(u8, ed.projectRoot());
    const abs = try ed.absolutePath(path);
    defer ed.gpa.free(abs);
    const dir = std.fs.path.dirname(abs) orelse return ed.gpa.dupe(u8, ed.projectRoot());
    const root = (b.project orelse return ed.gpa.dupe(u8, dir)).root;
    const inside = dir.len >= root.len and std.mem.startsWith(u8, dir, root) and (dir.len == root.len or dir[root.len] == '/');
    if (!inside) return ed.gpa.dupe(u8, dir);
    var d: []const u8 = dir;
    while (true) {
        for (run_markers) |m| {
            const candidate = try std.fs.path.join(ed.gpa, &.{ d, m });
            defer ed.gpa.free(candidate);
            if (ed.fileExists(candidate)) return ed.gpa.dupe(u8, d);
        }
        if (d.len <= root.len) break;
        d = std.fs.path.dirname(d) orelse break;
    }
    return ed.gpa.dupe(u8, root);
}

fn spawnTerminal(ed: *Editor, argv: []const []const u8) !*Terminal {
    const folder = try ed.commandFolder();
    defer ed.gpa.free(folder);
    return ed.spawnTerminalIn(argv, folder);
}

fn spawnTerminalIn(ed: *Editor, argv: []const []const u8, cwd: []const u8) !*Terminal {
    const sz = ed.term_size;
    return Terminal.create(ed.gpa, ed.io, .{
        .argv = argv,
        .cwd = cwd,
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

/// `SPC r t` / <C-\>: shows or hides the shell (started on first use).
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

/// Esc in a terminal: the first goes to the program at once (Claude's
/// interrupt, vim); a second within a third of a second means "leave",
/// and isn't sent. True for that second Esc.
fn doubleEsc(ed: *Editor, t: *Terminal, ev: KeyEvent) bool {
    if (ev.key != .special or ev.key.special != .escape or ev.mods.any()) return false;
    const now = Io.Timestamp.now(ed.io, .awake);
    const since = ed.last_term_esc.durationTo(now).nanoseconds;
    if (ed.last_term_esc.nanoseconds != 0 and since < 350 * std.time.ns_per_ms) {
        ed.last_term_esc = .zero;
        return true;
    }
    ed.last_term_esc = now;
    _ = t;
    return false;
}

/// A key in a terminal window's normal mode; false lets the keymap have it.
fn termNormalKey(ed: *Editor, t: *Terminal, ev: KeyEvent) bool {
    const half: isize = @intCast(@max(1, t.rows / 2));
    switch (ev.key) {
        .codepoint => |cp| if (ev.mods.ctrl) switch (cp) {
            'd' => t.scroll(half),
            'u' => t.scroll(-half),
            else => {},
        } else switch (cp) {
            ' ' => return false,
            'i', 'a', 'I', 'A' => ed.window.term_normal = false,
            'j' => t.scroll(1),
            'k' => t.scroll(-1),
            else => {},
        },
        .special => |sp| switch (sp) {
            .enter => ed.window.term_normal = false,
            .down => t.scroll(1),
            .up => t.scroll(-1),
            else => {},
        },
    }
    return true;
}

fn isCtrlBackslash(ev: KeyEvent) bool {
    return ev.mods.ctrl and ev.key == .codepoint and ev.key.codepoint == '\\';
}

/// Keys while the popup is open (or <C-\> to open the shell). Returns
/// true when the key was used.
fn popupKey(ed: *Editor, ev: KeyEvent) bool {
    if (ed.popup == null) {
        // A terminal window (the Claude panel) has the keyboard.
        if (ed.window.term) |t| {
            // Normal mode: SPC and what follows go to the keymap; i/a type
            // again, j/k and Ctrl-d/u scroll, other keys do nothing.
            if (ed.window.term_normal) return ed.pending_len == 0 and termNormalKey(ed, t, ev);
            // Ctrl-\: back to the code, the panel staying open. Ctrl-C: close
            // the panel (it keeps running; SPC a a brings it back). Claude
            // interrupts with Esc; Ctrl-Shift-C sends it a real Ctrl-C.
            const ctrl_c = ev.mods.ctrl and !ev.mods.alt and ev.key == .codepoint and (ev.key.codepoint == 'c' or ev.key.codepoint == 'C');
            if (isCtrlBackslash(ev) or ed.doubleEsc(t, ev)) {
                ed.window.term_normal = true;
                ed.mode = .normal;
            } else if (ctrl_c and !ev.mods.shift and ed.isClaudeTerm(t)) {
                ed.closeWindow();
            } else if (ctrl_c and ed.isClaudeTerm(t)) {
                t.sendKey(.{ .key = .{ .codepoint = 'c' }, .mods = .{ .ctrl = true } });
            } else termKey(ed, t, ev);
            return true;
        }
        if (isCtrlBackslash(ev) and ed.mode == .normal) {
            // To the terminal window if there is one, else the shell popup.
            for (ed.window_list.items) |w| if (w.term != null) {
                ed.focusWindow(w);
                return true;
            };
            ed.toggleShell() catch |err| ed.setMessage(.err, "could not start the shell: {s}", .{@errorName(err)});
            return true;
        }
        return false;
    }
    const t = ed.popupTerminal() orelse {
        ed.popup = null;
        return false;
    };
    if (isCtrlBackslash(ev) or (t.isRunning() and ed.doubleEsc(t, ev))) {
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
            'y' => ed.yankRunOutput(t, false),
            'Y' => ed.yankRunOutput(t, true),
            'k' => t.scroll(-1),
            'j' => t.scroll(1),
            else => {},
        };
        return true;
    }
    t.sendKey(ev);
    return true;
}

/// Keys for a terminal: scrolling and pasting are ours, the rest its.
fn termKey(ed: *Editor, t: *Terminal, ev: KeyEvent) void {
    if (ev.mods.shift and ev.key == .special and (ev.key.special == .page_up or ev.key.special == .page_down)) {
        const page: isize = @intCast(@max(t.rows, 2) - 1);
        return t.scroll(if (ev.key.special == .page_up) -page else page);
    }
    if (ev.mods.ctrl and ev.mods.shift and ev.key == .codepoint and (ev.key.codepoint == 'v' or ev.key.codepoint == 'V')) {
        if (ed.registers.clipboard) |cb| if (cb.get(ed.gpa)) |clip| {
            defer ed.gpa.free(clip);
            t.paste(clip);
        };
        return;
    }
    t.sendKey(ev);
}

/// `SPC r c`: opens the command editor, a floating vim buffer for the
/// command (any number of lines). Insert mode first; in normal mode <CR>
/// runs it and <Esc> cancels.
pub fn openCommandEditor(ed: *Editor) !void {
    if (ed.cmd_float != null) return;
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    const w = try ed.gpa.create(Windows.Window);
    w.* = .{ .buffer = b, .view = .{ .rows = ed.view.rows, .cols = ed.view.cols }, .node = undefined };
    ed.cmd_float = w;
    ed.cmd_return = ed.window;
    ed.focusWindow(w);
    ed.setMode(.insert);
}

/// The command editor's text, as one shell script. Caller frees.
fn commandEditorText(ed: *Editor) ![]u8 {
    const t = ed.text();
    return ed.gpa.dupe(u8, std.mem.trim(u8, t.slice(0, t.len()), " \t\n"));
}

/// Closes the command editor, back to the window it was opened from.
pub fn closeCommandEditor(ed: *Editor) void {
    const w = ed.cmd_float orelse return;
    if (ed.mode != .normal) ed.setMode(.normal);
    ed.cursors.clearRetainingCapacity();
    const back = ed.cmd_return.?;
    ed.focusWindow(back);
    ed.forgetJumps(w.buffer);
    w.buffer.deinit(ed.gpa);
    ed.gpa.destroy(w.buffer);
    ed.gpa.destroy(w);
    ed.cmd_float = null;
    ed.cmd_return = null;
}

/// In the command editor's normal mode: <CR> runs, <Esc> cancels.
fn cmdFloatKey(ed: *Editor, ev: KeyEvent) bool {
    if (ed.cmd_float == null or ed.window != ed.cmd_float.? or ed.mode != .normal or !ed.isIdle()) return false;
    if (ed.cursors.items.len > 0) return false; // <Esc> first drops extra cursors
    if (ev.mods.any() or ev.key != .special) return false;
    switch (ev.key.special) {
        .escape => ed.closeCommandEditor(),
        .enter => {
            const cmd = ed.commandEditorText() catch return true;
            defer ed.gpa.free(cmd);
            ed.closeCommandEditor();
            if (cmd.len > 0) ed.startRun(cmd) catch |err| ed.setMessage(.err, "could not run: {s}", .{@errorName(err)});
        },
        else => return false,
    }
    return true;
}

/// `SPC r r`: the code runner's prompt, prefilled with the last command.
/// `SPC r r`: the runner, a picker of this project's commands, newest
/// first (Enter runs the last one again); typing a new one runs that.
/// `SPC r c`: the multi-line command editor.
pub fn runPrompt(ed: *Editor, runner: bool) !void {
    if (!runner) return ed.openCommandEditor();
    try ed.openPicker(.runner, "");
}

/// This project's runner commands, newest first. The caller frees each
/// and the slice.
pub fn runnerHistory(ed: *Editor) ![][]u8 {
    const path = ed.runMemoryPath() orelse return ed.gpa.alloc([]u8, 0);
    const key = try ed.runKey();
    defer ed.gpa.free(key);
    return RunMemory.history(ed.gpa, ed.io, path, key);
}

/// Runs `cmd` as the runner's command: it goes to the front of the history.
pub fn runFromRunner(ed: *Editor, command: []const u8) !void {
    const cmd = std.mem.trim(u8, command, " \t");
    if (cmd.len == 0) return;
    if (ed.runMemoryPath()) |path| {
        const key = try ed.runKey();
        defer ed.gpa.free(key);
        RunMemory.save(ed.gpa, ed.io, path, key, cmd);
    }
    try ed.startRun(cmd);
}

/// <Tab> in the runner: the selected command goes into the query line, to
/// add to or cut down (typing, <BS>, <C-w>) before Enter runs the result.
pub fn runnerEdit(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .runner) return;
    p.sync();
    // The "Run <typed>" row has nothing of its own to copy.
    const item = p.itemAt(p.selected) orelse return;
    try p.query.set(ed.gpa, item.text);
    ed.mode = .picker;
    try p.queryChanged();
}

/// `x` / `dd` in the runner: forgets the selected command.
pub fn pickerForgetCommand(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .runner) return;
    p.sync();
    const item = p.itemAt(p.selected) orelse return;
    const path = ed.runMemoryPath() orelse return;
    const key = try ed.runKey();
    defer ed.gpa.free(key);
    RunMemory.forget(ed.gpa, ed.io, path, key, item.text);
    try p.restart(null);
    ed.mode = .picker_normal;
}

/// `SPC ;`: a one-off shell command. The prompt starts empty and what runs
/// isn't remembered as the project's runner command (`SPC r r`).
pub fn shellPrompt(ed: *Editor) void {
    ed.startSearch(true, .run_command);
}

fn runMemoryPath(ed: *Editor) ?[]const u8 {
    if (ed.run_memory_path == null) ed.run_memory_path = RunMemory.defaultPath(ed.gpa);
    return ed.run_memory_path;
}

/// What the runner's history is kept under: the current file's project,
/// else (a file in no project) its folder, so a file elsewhere doesn't
/// borrow the commands of whatever project you were in before. No file: the
/// current project. The caller frees it.
fn runKey(ed: *Editor) ![]u8 {
    const b = ed.buffer;
    if (b.project) |p| return ed.gpa.dupe(u8, p.root);
    if (b.path) |path| {
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        return ed.gpa.dupe(u8, std.fs.path.dirname(abs) orelse abs);
    }
    return ed.gpa.dupe(u8, ed.projectRoot());
}

/// The remembered runner command for here. Caller frees.
fn loadRunnerCommand(ed: *Editor) ?[]u8 {
    const path = ed.runMemoryPath() orelse return null;
    const key = ed.runKey() catch return null;
    defer ed.gpa.free(key);
    return RunMemory.load(ed.gpa, ed.io, path, key);
}

fn finishRunPrompt(ed: *Editor, kind: PromptKind) !void {
    const raw = try ed.takePromptText() orelse return;
    defer ed.gpa.free(raw);
    const cmd = std.mem.trim(u8, raw, " \t");
    if (cmd.len == 0) return;
    _ = kind;
    try ed.startRun(cmd);
}

const libcSetenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });


/// `SPC r s` (`SPC r f` with `whole`): SQL against the project's database,
/// the results in the run popup: the statement at the cursor, the selected
/// lines in visual mode, or the whole file.
pub fn runSql(ed: *Editor, whole: bool) !void {
    const lang = if (ed.buffer.syntax) |syn| syn.lang.name else "";
    if (!std.mem.eql(u8, lang, "sql")) return ed.setMessage(.info, "not a SQL file", .{});
    const t = ed.text();
    const all = t.slice(0, t.len());
    const statement: []const u8 = if (ed.mode == .visual) blk: {
        const first = t.lineOf(@min(ed.view.anchor, ed.view.cursor));
        const last = t.lineOf(@max(ed.view.anchor, ed.view.cursor));
        ed.exitVisual();
        break :blk t.slice(t.lineStart(first), t.lineEnd(last));
    } else if (whole) all else sql.statementAt(all, ed.view.cursor);
    if (std.mem.trim(u8, statement, " \t\r\n;").len == 0) return ed.setMessage(.info, "no statement here", .{});
    const folder = try ed.fileFolder();
    defer ed.gpa.free(folder);
    const found = sql.findUrl(ed.gpa, ed.io, folder, ed.cwd) orelse
        return ed.setMessage(.err, "no database: set DATABASE_URL (environment, or a .env above the file)", .{});
    defer ed.gpa.free(found.url);
    defer ed.gpa.free(found.from);
    const shown = try sql.redact(ed.gpa, found.url);
    defer ed.gpa.free(shown);
    const client = sql.clientFor(found.url) orelse
        return ed.setMessage(.err, "can't run SQL on {s} (postgres:// or sqlite: URLs)", .{shown});
    // The database by the environment, so a password stays out of the
    // command line (and out of messages).
    const target = try ed.gpa.dupeSentinel(u8, client.target, 0);
    defer ed.gpa.free(target);
    _ = libcSetenv("ZILE_DB", target, 1);
    const cmd = try sql.command(ed.gpa, client.client, statement);
    defer ed.gpa.free(cmd);
    try ed.startRun(cmd);
    // Tables may change: completion reloads them once it has run.
    for ([_][]const u8{ "create", "alter", "drop", "rename" }) |w| {
        if (motions.indexOfFold(statement, 0, w) != null) {
            ed.sql_reload = true;
            ed.sql_fresh = false;
        }
    }
    ed.setMessage(.info, "{s} on {s} (from {s})", .{ @tagName(client.client), shown, found.from });
}

/// `SPC r .`: the runner's command again, without asking.
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
    const folder = try ed.commandFolder();
    errdefer ed.gpa.free(folder);
    const t = try ed.spawnTerminalIn(&.{ Pty.userShell(), "-c", cmd }, folder);
    if (ed.run) |old| old.destroy();
    if (ed.run_command) |old| ed.gpa.free(old);
    if (ed.run_root_owned) |old| ed.gpa.free(old);
    ed.run = t;
    ed.run_command = owned;
    // Paths in its output (errors) are relative to here.
    ed.run_root_owned = folder;
    ed.run_root = folder;
    ed.run_started = Io.Timestamp.now(ed.io, .awake);
    ed.run_reported = false;
    ed.popup = .run;
}

/// `y` / `Y` in a finished run: its errors (from the first `error:` line
/// on) or, with `all` or when there are none, the whole output, to the
/// clipboard.
fn yankRunOutput(ed: *Editor, t: *Terminal, all: bool) void {
    const out = t.copyOutput(ed.gpa) catch return;
    defer ed.gpa.free(out);
    var body: []const u8 = std.mem.trimEnd(u8, out, " \t\r\n");
    // Our own "exited" line at the end is not part of the output.
    if (std.mem.lastIndexOfScalar(u8, body, '\n')) |nl| {
        if (std.mem.indexOf(u8, body[nl..], "exited ") != null) body = std.mem.trimEnd(u8, body[0..nl], " \t\r\n");
    }
    var errors_only = false;
    // Zig/C/TS write `error:`, Rust `error[E0425]:`.
    const first_error: ?usize = blk: {
        const a = std.mem.indexOf(u8, body, "error:");
        const b = std.mem.indexOf(u8, body, "error[");
        if (a != null and b != null) break :blk @min(a.?, b.?);
        break :blk a orelse b;
    };
    if (!all) if (first_error) |at| {
        const line = if (std.mem.lastIndexOfScalar(u8, body[0..at], '\n')) |nl| nl + 1 else 0;
        body = body[line..];
        errors_only = true;
    };
    if (body.len == 0) return ed.setMessage(.info, "no output to yank", .{});
    ed.registers.store(null, .yank, body, false) catch return;
    ed.setMessage(.info, "yanked the run's {s} ({d} lines)", .{
        if (errors_only) "errors" else "output",
        std.mem.count(u8, body, "\n") + 1,
    });
}

/// Finds `path:line:col` errors in the finished run's output.
fn collectRunErrors(ed: *Editor, t: *Terminal) void {
    for (ed.run_errors.items) |e| e.deinit(ed.gpa);
    ed.run_errors.clearRetainingCapacity();
    const out = t.copyOutput(ed.gpa) catch return;
    defer ed.gpa.free(out);
    // Paths in the output are relative to where the command ran.
    const S = struct {
        fn exists(e: *Editor, path: []const u8) bool {
            if (std.fs.path.isAbsolute(path)) return e.fileExists(path);
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ e.run_root, path }) catch return false;
            return e.fileExists(full);
        }
    };
    run_errors_mod.parse(ed.gpa, out, ed, S.exists, &ed.run_errors) catch {};
    for (ed.run_errors.items) |*e| if (!std.fs.path.isAbsolute(e.path)) {
        const full = std.fs.path.join(ed.gpa, &.{ ed.run_root, e.path }) catch continue;
        ed.gpa.free(e.path);
        e.path = full;
    };
}

// Quickfix: one list of places, filled by runs and pickers, stepped
// through with ]q / [q, listed with SPC f q.

pub fn clearQuickfix(ed: *Editor) void {
    for (ed.quickfix.items) |q| q.deinit(ed.gpa);
    ed.quickfix.clearRetainingCapacity();
    ed.quickfix_title.clearRetainingCapacity();
    ed.quickfix_index = null;
    ed.quickfix_origin = .none;
}

/// Without a list of your own, the list is the project's errors and
/// warnings as the language servers report them now: the current file's
/// first (in line order), then the other files'.
fn refreshLiveQuickfix(ed: *Editor) void {
    if (ed.quickfix_origin == .run or ed.quickfix_origin == .picked) return;
    ed.newQuickfix("Errors") catch return;
    ed.quickfix_origin = .live;
    const current: []const u8 = ed.buffer.path orelse "";
    for ([_]bool{ true, false }) |own_file| {
        if (ed.live_errors_override) |items| {
            for (items) |q| if (std.mem.eql(u8, q.path, current) == own_file) {
                ed.addQuickfix(q.path, q.line, q.col, q.text) catch return;
            };
            continue;
        }
        for (ed.lsps.items) |l| for (l.diagnostics.keys(), l.diagnostics.values()) |path, list| {
            if (std.mem.eql(u8, path, current) != own_file) continue;
            for (list) |d| {
                if (d.severity != .err and d.severity != .warning) continue;
                ed.addQuickfix(path, d.line, d.col, std.mem.sliceTo(d.message, '\n')) catch return;
            }
        };
    }
}

/// `]q` / `[q` through live errors go by where the cursor is, not by a
/// remembered place in a list that changes as you fix things: the next
/// error below the cursor in this file, then on into the other files (and
/// around); the previous one above the cursor, else the last of all.
fn liveQuickfixTarget(ed: *Editor, forward: bool) usize {
    const items = ed.quickfix.items;
    const current: []const u8 = ed.buffer.path orelse "";
    const line = ed.cursorLine();
    if (forward) {
        for (items, 0..) |q, i| {
            if (!std.mem.eql(u8, q.path, current) or q.line > line) return i;
        }
        return 0;
    }
    var target: usize = items.len - 1;
    for (items, 0..) |q, i| {
        if (!std.mem.eql(u8, q.path, current) or q.line >= line) break;
        target = i;
    }
    return target;
}

/// `x in the quickfix picker`: drops a run's or picker's list, so the list is the
/// project's errors again.
pub fn resetQuickfix(ed: *Editor) void {
    ed.clearQuickfix();
    ed.setMessage(.info, "quickfix cleared: it lists the project's errors again", .{});
}

/// Starts a new list named `title` (add entries with `addQuickfix`).
pub fn newQuickfix(ed: *Editor, title: []const u8) !void {
    ed.clearQuickfix();
    ed.quickfix_origin = .picked;
    try ed.quickfix_title.appendSlice(ed.gpa, title);
}

/// Adds a place; `path` and `text` are copied.
pub fn addQuickfix(ed: *Editor, path: []const u8, line: usize, col: usize, message: []const u8) !void {
    const p = try ed.normalizePath(path);
    errdefer ed.gpa.free(p);
    const t = try ed.gpa.dupe(u8, std.mem.trim(u8, message, " \t"));
    errdefer ed.gpa.free(t);
    try ed.quickfix.append(ed.gpa, .{ .path = p, .line = line, .col = col, .text = t });
}

fn quickfixFromRunErrors(ed: *Editor) void {
    ed.newQuickfix(ed.run_command orelse "run") catch return;
    ed.quickfix_origin = .run;
    for (ed.run_errors.items) |e| ed.addQuickfix(e.path, e.line - 1, e.col - 1, e.message) catch return;
}

/// Goes to quickfix entry `i` (a jump, unless moving within the panel).
pub fn goQuickfix(ed: *Editor, i: usize) !void {
    if (i >= ed.quickfix.items.len) return;
    const q = ed.quickfix.items[i];
    ed.quickfix_index = i;
    try ed.jumpTo(q.path, q.line, q.col);
    ed.setMessage(.info, "({d}/{d}) {s}", .{ i + 1, ed.quickfix.items.len, q.text });
}

/// `]q` / `[q`: the next / previous entry (`count` of them).
pub fn stepQuickfix(ed: *Editor, forward: bool, count: usize) !void {
    ed.refreshLiveQuickfix();
    const n = ed.quickfix.items.len;
    if (n == 0) return ed.setMessage(.info, "no errors in the project (a run's errors, or Ctrl-q in a picker, also fill the quickfix list)", .{});
    if (ed.quickfix_origin == .live) {
        const first = ed.liveQuickfixTarget(forward);
        const extra = count - 1;
        return ed.goQuickfix(if (forward) @min(first + extra, n - 1) else first -| extra);
    }
    const i: usize = if (ed.quickfix_index) |cur| blk: {
        if (forward) {
            if (cur + 1 >= n) return ed.setMessage(.info, "last quickfix entry ({d}/{d})", .{ n, n });
            break :blk @min(cur + count, n - 1);
        }
        if (cur == 0) return ed.setMessage(.info, "first quickfix entry (1/{d})", .{n});
        break :blk cur -| count;
    } else if (forward) @min(count - 1, n - 1) else n - 1;
    try ed.goQuickfix(i);
}

/// `SPC f q`: the quickfix list as a picker (every entry with its file and
/// line number, previewed), in normal mode at the current entry. Nothing
/// moves until one is picked.
pub fn showQuickfix(ed: *Editor) !void {
    ed.refreshLiveQuickfix();
    if (ed.quickfix.items.len == 0) return ed.setMessage(.info, "no errors in the project (a run's errors, or Ctrl-q in a picker, also fill the quickfix list)", .{});
    // Live errors: start on the one at or after the cursor.
    const start = if (ed.quickfix_origin == .live) blk: {
        const next = ed.liveQuickfixTarget(true);
        const here = if (next > 0) next - 1 else 0;
        const q = ed.quickfix.items[here];
        const on_it = std.mem.eql(u8, q.path, ed.buffer.path orelse "") and q.line == ed.cursorLine();
        break :blk if (on_it) here else next;
    } else ed.quickfix_index orelse 0;
    ed.closePicker();
    ed.popup = null;
    try ed.openPicker(.quickfix, "");
    ed.picker.?.want_id = @intCast(start);
}

/// `<C-q>` in a picker of places: every current match becomes the list.
pub fn pickerToQuickfix(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (!sources.hasLocations(p.kind)) return ed.setMessage(.info, "these results aren't places", .{});
    p.sync();
    var title_buf: [128]u8 = undefined;
    const q = p.activeQuery();
    const title = if (q.len > 0) std.fmt.bufPrint(&title_buf, "{s}: {s}", .{ sources.title(p.kind), q }) catch sources.title(p.kind) else sources.title(p.kind);
    try ed.newQuickfix(title);
    var row: usize = 0;
    while (row < p.snap.len) : (row += 1) {
        const item = p.itemAt(row) orelse continue;
        const loc = (try sources.location(p.kind, ed, item.*)) orelse continue;
        defer ed.gpa.free(loc.path);
        try ed.addQuickfix(loc.path, loc.line, loc.col, item.text);
    }
    const n = ed.quickfix.items.len;
    ed.closePicker();
    if (n == 0) return ed.setMessage(.info, "no places to add", .{});
    try ed.showQuickfix();
}

/// `SPC r e` (or `e` in a finished run): the last run's errors in the
/// quickfix panel.
pub fn showRunErrors(ed: *Editor) !void {
    if (ed.run == null) return ed.setMessage(.info, "nothing has been run yet (SPC r r)", .{});
    if (ed.run_errors.items.len == 0) return ed.setMessage(.info, "no errors in the last run", .{});
    ed.quickfixFromRunErrors();
    try ed.showQuickfix();
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
        // A run without errors retires the last run's list: the quickfix
        // list is the project's live errors again.
        if (n > 0) ed.quickfixFromRunErrors() else if (ed.quickfix_origin == .run) ed.clearQuickfix();
        var buf: [160]u8 = undefined;
        const ok = t.exit_code == 0;
        var errs_buf: [48]u8 = undefined;
        const errs: []const u8 = if (n > 0) std.fmt.bufPrint(&errs_buf, "   e: {d} error{s}", .{ n, if (n == 1) "" else "s" }) catch "" else "";
        const line = std.fmt.bufPrint(&buf, "\r\n\x1b[1;{s}m{s} exited {d}\x1b[0;2m in {d:.2}s{s}   r: run again   y: yank errors   q: close\x1b[0m", .{
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
// Claude Code (`SPC a`): `claude` in a side panel, connected to the editor
// (ai/Claude.zig): proposed edits open here as diffs, the selection is
// shared, and selections can be sent as @mentions.

fn tickClaude(ed: *Editor) void {
    // Files changed by other programs (Claude, a build, git) reload when
    // they have no unsaved edits; checked at most once a second.
    const now = Io.Timestamp.now(ed.io, .awake);
    if (ed.last_disk_check.durationTo(now).nanoseconds > std.time.ns_per_s) {
        ed.last_disk_check = now;
        ed.checkDiskChanges();
    }
    const c = ed.claude orelse return;
    c.tick(ed);
    if (c.term) |t| if (!t.isRunning()) {
        // `claude` exited: its window closes.
        while (ed.windowShowing(t)) |w| {
            ed.focusWindow(w);
            ed.closeWindow();
        }
        t.destroy();
        c.term = null;
        ed.setMessage(.info, "Claude Code exited (SPC a a starts it again)", .{});
    };
}

/// Reloads buffers whose files changed on disk (when they have no unsaved
/// edits of their own).
pub fn checkDiskChanges(ed: *Editor) void {
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        const known = b.disk_mtime orelse continue;
        if (b.modified) continue;
        const st = Io.Dir.cwd().statFile(ed.io, path, .{}) catch continue;
        if (st.mtime.nanoseconds == known.nanoseconds) continue;
        ed.reloadBuffer(b) catch continue;
        ed.notify(.info, "reloaded {s} (changed on disk)", .{b.displayName()});
    }
}

/// `SPC a a`: shows Claude Code in a panel on the right (starting it, and
/// the connection, the first time), focuses it, or hides it if focused.
pub fn toggleClaude(ed: *Editor) !void {
    if (ed.claude == null) ed.claude = try Claude.start(ed);
    const c = ed.claude.?;
    if (c.term) |t| if (ed.windowShowing(t)) |w| {
        if (w == ed.window) {
            ed.closeWindow(); // hidden; it keeps running
        } else ed.focusWindow(w);
        return;
    };
    try ed.showClaude();
}

/// Makes sure the panel is open (and focused).
pub fn showClaude(ed: *Editor) !void {
    if (ed.claude == null) ed.claude = try Claude.start(ed);
    const c = ed.claude.?;
    if (c.term) |t| if (ed.windowShowing(t)) |w| return ed.focusWindow(w);
    if (c.term == null) {
        var env_buf: [64]u8 = undefined;
        const env = c.env(&env_buf);
        c.term = try Terminal.create(ed.gpa, ed.io, .{
            .argv = &.{ "/bin/sh", "-c", "exec claude" },
            .cwd = ed.projectRoot(),
            .cols = 80,
            .rows = 24,
            .fg = ed.term_fg,
            .bg = ed.term_bg,
            .env = &.{env},
            .wake = ed.wake_fn,
        });
    }
    ed.focusEditorWindow();
    try ed.splitWindow(.right);
    ed.window.term = c.term;
    ed.window.term_normal = false;
    // The panel takes about 40% of the width.
    Windows.resize(ed.window, .horizontal, -0.1);
}

/// Shows a proposed edit of `path` as a diff: a buffer holding the proposal
/// with the file as it is now as its base (removed lines show as ghost
/// lines, new ones are marked). The user can edit it before accepting.
pub fn openProposal(ed: *Editor, path: []const u8, contents: []const u8) !*Buffer {
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    const norm = try Git.normalize(ed.gpa, contents);
    defer ed.gpa.free(norm);
    try b.text.insert(ed.gpa, 0, norm);
    b.final_newline = contents.len == 0 or contents[contents.len - 1] == '\n';
    b.syntax = Syntax.forPath(path);
    b.project = ed.projectOf(path);
    const rel = try ed.normalizePath(path);
    defer ed.gpa.free(rel);
    b.label = try std.fmt.allocPrint(ed.gpa, "Claude: {s}", .{rel});
    // The base: the file as the editor has it (unsaved edits included), else on disk.
    const base: []u8 = if (ed.bufferForPath(path)) |open| try ed.gpa.dupe(u8, open.text.slice(0, open.text.len())) else blk: {
        const raw = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(64 << 20)) catch break :blk try ed.gpa.dupe(u8, "");
        defer ed.gpa.free(raw);
        break :blk try Git.normalize(ed.gpa, raw);
    };
    defer ed.gpa.free(base);
    b.git = .{ .base = try Text.init(ed.gpa, base) };
    try ed.buffers.append(ed.gpa, b);
    ed.focusEditorWindow();
    ed.switchTo(b);
    ed.updateGit();
    // Start at the first change.
    if (b.git.?.hunks.items.len > 0) {
        const line = @min(b.git.?.hunks.items[0].new_start, b.text.lineCount() - 1);
        ed.revealLine(line);
        ed.setCursor(motions.firstNonBlank(&b.text, line));
    }
    ed.setMessage(.info, "Claude proposes changes to {s}: SPC a y accept, SPC a n reject (edit it first if you like)", .{rel});
    return b;
}

/// Removes a proposal; windows showing it go back to the file.
pub fn closeProposal(ed: *Editor, b: *Buffer, path: []const u8) void {
    var still_open = false;
    for (ed.buffers.items) |o| still_open = still_open or o == b;
    if (!still_open) return;
    if (ed.buffer == b) ed.openFile(path) catch {};
    b.modified = false;
    ed.killBuffer(b) catch {};
}

/// The open buffer for `path` (absolute or relative), if any.
pub fn bufferForPath(ed: *Editor, path: []const u8) ?*Buffer {
    const norm = ed.normalizePath(path) catch return null;
    defer ed.gpa.free(norm);
    return ed.findBuffer(norm);
}

/// Claude's `openFile`: in an editor window, at `start_text` if given.
pub fn openFromClaude(ed: *Editor, path: []const u8, start_text: ?[]const u8) !void {
    ed.focusEditorWindow();
    try ed.openFile(path);
    const s0 = start_text orelse return;
    if (s0.len == 0) return;
    const t = ed.text();
    if (std.mem.indexOf(u8, t.slice(0, t.len()), s0)) |at| {
        ed.revealLine(t.lineOf(at));
        ed.setCursor(at);
    }
}

/// The current selection for Claude (`selection_changed`), as JSON; null
/// when no file is focused. Lines and characters are 0-based, the end
/// exclusive.
pub fn selectionJson(ed: *Editor, gpa: Allocator) ?[]u8 {
    if (ed.window.term != null) return null;
    const path = ed.buffer.path orelse return null;
    const abs = ed.absolutePath(path) catch return null;
    defer ed.gpa.free(abs);
    const t = ed.text();
    var start = ed.view.cursor;
    var end = ed.view.cursor;
    if (ed.mode == .visual) {
        const r = ed.visualRange();
        start = r.start;
        end = @min(r.end, t.len());
    }
    const pos = struct {
        fn of(x: *const Text, p: usize) struct { line: usize, character: usize } {
            const l = x.lineOf(p);
            return .{ .line = l, .character = p - x.lineStart(l) };
        }
    }.of;
    const url = std.fmt.allocPrint(gpa, "file://{s}", .{abs}) catch return null;
    defer gpa.free(url);
    return std.json.Stringify.valueAlloc(gpa, .{
        .text = t.slice(start, @min(end, start + (100 << 10))),
        .filePath = abs,
        .fileUrl = url,
        .selection = .{ .start = pos(t, start), .end = pos(t, end), .isEmpty = start == end },
    }, .{}) catch null;
}

/// Open files, for Claude's `getOpenEditors`.
pub fn openEditorsJson(ed: *Editor, gpa: Allocator) ![]u8 {
    const Tab = struct { uri: []const u8, isActive: bool, label: []const u8, isDirty: bool };
    var tabs: std.ArrayList(Tab) = .empty;
    defer {
        for (tabs.items) |tab| gpa.free(tab.uri);
        tabs.deinit(gpa);
    }
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        try tabs.append(gpa, .{ .uri = try std.fmt.allocPrint(gpa, "file://{s}", .{abs}), .isActive = b == ed.buffer, .label = std.fs.path.basename(path), .isDirty = b.modified });
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .tabs = tabs.items }, .{});
}

/// Language server diagnostics, for Claude's `getDiagnostics` (one file's,
/// by `file://` URI, or all).
pub fn diagnosticsJson(ed: *Editor, gpa: Allocator, uri: ?[]const u8) ![]u8 {
    const Pos = struct { line: u32, character: u32 };
    const D = struct { message: []const u8, severity: []const u8, range: struct { start: Pos, end: Pos }, source: []const u8 };
    const F = struct { uri: []u8, diagnostics: []D };
    var files: std.ArrayList(F) = .empty;
    defer {
        for (files.items) |f| {
            gpa.free(f.uri);
            gpa.free(f.diagnostics);
        }
        files.deinit(gpa);
    }
    const want: ?[]const u8 = if (uri) |u| (if (std.mem.startsWith(u8, u, "file://")) u[7..] else u) else null;
    for (ed.lsps.items) |l| {
        for (l.diagnostics.keys(), l.diagnostics.values()) |path, list| {
            const abs = try ed.absolutePath(path);
            defer ed.gpa.free(abs);
            if (want) |w| if (!std.mem.eql(u8, w, abs)) continue;
            const ds = try gpa.alloc(D, list.len);
            for (list, ds) |d, *o| o.* = .{
                .message = d.message,
                .severity = switch (d.severity) {
                    .err => "Error",
                    .warning => "Warning",
                    .info => "Information",
                    .hint => "Hint",
                },
                .range = .{ .start = .{ .line = d.line, .character = d.col }, .end = .{ .line = d.end_line, .character = d.end_col } },
                .source = Lsp.servers[l.index].name,
            };
            try files.append(gpa, .{ .uri = try std.fmt.allocPrint(gpa, "file://{s}", .{abs}), .diagnostics = ds });
        }
    }
    return std.json.Stringify.valueAlloc(gpa, files.items, .{});
}

/// `SPC a s`: mentions the selected lines (visual mode) or the file in
/// Claude's prompt, and shows the panel.
pub fn claudeMention(ed: *Editor) !void {
    const target = try ed.claudeTarget() orelse return;
    defer ed.gpa.free(target.path);
    try ed.showClaude();
    ed.claude.?.mention(target.path, target.lines);
}

const ClaudeTarget = struct { path: []u8, lines: ?[2]usize };

/// The file (absolute) and lines (the visual selection's) to send.
fn claudeTarget(ed: *Editor) !?ClaudeTarget {
    if (ed.window.term != null) return null;
    const path = ed.buffer.path orelse {
        ed.setMessage(.info, "save the file first: Claude refers to files by path", .{});
        return null;
    };
    const abs = try ed.absolutePath(path);
    var lines: ?[2]usize = null;
    if (ed.mode == .visual) {
        const t = ed.text();
        lines = .{ t.lineOf(@min(ed.view.anchor, ed.view.cursor)), t.lineOf(@max(ed.view.anchor, ed.view.cursor)) };
        ed.exitVisual();
    }
    return .{ .path = abs, .lines = lines };
}

/// `SPC a i`: asks for an instruction to send along with the selection.
pub fn claudeAskPrompt(ed: *Editor) !void {
    const target = try ed.claudeTarget() orelse return;
    if (ed.claude_ask) |a| ed.gpa.free(a.path);
    ed.claude_ask = .{ .path = target.path, .lines = target.lines };
    ed.startSearch(true, .ask_claude);
}

fn finishAskClaude(ed: *Editor) !void {
    const raw = try ed.takePromptText() orelse return;
    defer ed.gpa.free(raw);
    const ask = ed.claude_ask orelse return;
    ed.claude_ask = null;
    defer ed.gpa.free(ask.path);
    const instruction = std.mem.trim(u8, raw, " \t");
    try ed.showClaude();
    const c = ed.claude.?;
    c.mention(ask.path, ask.lines);
    // Typed into Claude's prompt, after the mention; <CR> in the panel sends it.
    if (instruction.len > 0) if (c.term) |t| t.paste(instruction);
}

/// `SPC a y` / `SPC a n`: accepts or rejects the proposal shown (or shows
/// the first one waiting, if another buffer is shown).
pub fn claudeResolve(ed: *Editor, accept: bool) void {
    const c = ed.claude orelse return ed.setMessage(.info, "no proposed changes", .{});
    if (c.diffFor(ed.buffer)) |i| return c.resolve(ed, i, accept);
    if (c.diffs.items.len == 0) return ed.setMessage(.info, "no proposed changes", .{});
    ed.focusEditorWindow();
    ed.switchTo(c.diffs.items[0].buffer);
    ed.setMessage(.info, "Claude's proposal for {s}: SPC a y accept, SPC a n reject", .{std.fs.path.basename(c.diffs.items[0].path)});
}

// ---------------------------------------------------------------------------
// Jumplist: where you were before each jump. `<C-o>` goes back, `<C-i>`
// forward, `SPC f j` lists them. One entry per line (the newest wins).

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

/// `` SPC ` ``: back to where the last jump left from, and again: here again
/// (vim's `''`, across files).
pub fn jumpToggle(ed: *Editor) !void {
    if (ed.jump_index + 1 >= ed.jumps.items.len) return ed.jumpOlder(1);
    try ed.jumpNewer(1);
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

// Marks: `m{letter}` sets one, `'{letter}` goes to its line, `` `{letter} ``
// to the exact place; `SPC f m` lists them.

/// The mark `name` as seen from the current buffer.
pub fn findMark(ed: *Editor, name: u21) ?*Mark {
    const n = std.math.cast(u8, name) orelse return null;
    const global = std.ascii.isUpper(n);
    for (ed.marks.items) |*m| {
        if (m.name == n and (global or m.buffer == ed.buffer)) return m;
    }
    return null;
}

pub fn setMark(ed: *Editor, name: u21) void {
    const n = std.math.cast(u8, name) orelse 0;
    if (!std.ascii.isAlphabetic(n)) return ed.setMessage(.info, "marks are letters: a-z in this file, A-Z across files", .{});
    const b = ed.buffer;
    const path = if (b.path) |p| ed.gpa.dupe(u8, p) catch null else null;
    if (ed.findMark(n)) |m| {
        if (m.path) |old| ed.gpa.free(old);
        m.* = .{ .name = n, .buffer = b, .path = path, .pos = ed.view.cursor };
    } else ed.marks.append(ed.gpa, .{ .name = n, .buffer = b, .path = path, .pos = ed.view.cursor }) catch {
        if (path) |p| ed.gpa.free(p);
        return;
    };
    ed.setMessage(.info, "mark {c} set", .{n});
}

/// Goes to a mark, reopening its file if its buffer was closed.
pub fn goMark(ed: *Editor, m: Mark, exact: bool) !void {
    if (m.buffer) |b| {
        ed.switchTo(b);
    } else if (m.path) |p| {
        const path = try ed.gpa.dupe(u8, p);
        defer ed.gpa.free(path);
        try ed.openFile(path);
        for (ed.marks.items) |*o| if (o.buffer == null and o.path != null and std.mem.eql(u8, o.path.?, path)) {
            o.buffer = ed.buffer;
        };
    } else return;
    const t = ed.text();
    const pos = @min(m.pos, t.len());
    ed.revealLine(t.lineOf(pos));
    ed.setCursor(if (exact) pos else motions.firstNonBlank(t, t.lineOf(pos)));
}

/// A closed buffer's own marks go; global ones keep their file.
fn forgetMarks(ed: *Editor, b: *Buffer) void {
    var i: usize = 0;
    while (i < ed.marks.items.len) {
        const m = &ed.marks.items[i];
        if (m.buffer == b) {
            if (std.ascii.isLower(m.name) or m.path == null) {
                if (m.path) |p| ed.gpa.free(p);
                _ = ed.marks.orderedRemove(i);
                continue;
            }
            m.buffer = null;
        }
        i += 1;
    }
}

// Indentation: the file's own style where it has one (`Buffer.indent_style`,
// detected when it is read), else the options.

pub fn usesTabs(ed: *const Editor) bool {
    if (ed.buffer.indent_style) |s| return s.tabs;
    // A Go file with no indentation yet: tabs, as gofmt writes them.
    if (ed.buffer.syntax) |syn| if (std.mem.eql(u8, syn.lang.name, "go")) return true;
    return !ed.options.expand_tab;
}

/// The columns one level of indentation takes.
pub fn indentWidth(ed: *const Editor) usize {
    if (ed.buffer.indent_style) |s| if (!s.tabs) return s.width;
    // The config's for the language.
    if (ed.buffer.syntax) |syn| if (config.settingsFor(syn.lang.name)) |cfg| if (cfg.indent) |n| return n;
    // A file with no indentation yet: the web and config languages indent
    // by two (as prettier writes them, and YAML is usually written).
    if (ed.buffer.syntax) |syn| for ([_][]const u8{ "javascript", "typescript", "tsx", "html", "css", "json", "yaml", "toml" }) |l| {
        if (std.mem.eql(u8, syn.lang.name, l)) return 2;
    };
    return ed.options.tab_width;
}

/// One level of indentation, as text.
pub fn indentUnit(ed: *const Editor, buf: *[16]u8) []const u8 {
    if (ed.usesTabs()) return "\t";
    const n = @min(ed.indentWidth(), buf.len);
    @memset(buf[0..n], ' ');
    return buf[0..n];
}

/// The indentation for a new line made by breaking `line` at `at`: the
/// line's own, one level deeper after something that opens a block (`{`,
/// `(`, `[`; `:` in Python).
pub fn newlineIndent(ed: *Editor, line: usize, at: usize, buf: []u8) []const u8 {
    const t = ed.text();
    // A blank line has no indentation of its own to go by: the code around it does.
    if (ed.isBlankLine(t, line)) return ed.contextIndent(line, buf);
    const ls = t.lineStart(line);
    const base = t.slice(ls, @min(motions.firstNonBlank(t, line), @max(at, ls)));
    const before = std.mem.trimEnd(u8, t.slice(ls, @max(at, ls)), " \t");
    const python = if (ed.buffer.path) |p| std.mem.endsWith(u8, p, ".py") else false;
    const opens = before.len > 0 and switch (before[before.len - 1]) {
        '{', '(', '[' => true,
        ':' => python,
        else => false,
    };
    var unit_buf: [16]u8 = undefined;
    const unit: []const u8 = if (opens) ed.indentUnit(&unit_buf) else "";
    if (base.len + unit.len > buf.len) return "";
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..unit.len], unit);
    return buf[0 .. base.len + unit.len];
}

pub fn isBlankLine(_: *const Editor, t: *const Text, line: usize) bool {
    return std.mem.indexOfNone(u8, t.lineSlice(line), " \t") == null;
}

/// The indentation a new line made on blank line `line` should have: where
/// the code around it is. That of the nearest line above that has text (a
/// level deeper when it opens a block); with none above, the nearest below.
pub fn contextIndent(ed: *Editor, line: usize, buf: []u8) []const u8 {
    const t = ed.text();
    var l = line;
    while (l > 0) {
        l -= 1;
        if (!ed.isBlankLine(t, l)) return ed.newlineIndent(l, t.lineEnd(l), buf);
    }
    l = line + 1;
    while (l < t.lineCount()) : (l += 1) {
        if (ed.isBlankLine(t, l)) continue;
        const own = t.slice(t.lineStart(l), motions.firstNonBlank(t, l));
        const n = @min(own.len, buf.len);
        @memcpy(buf[0..n], own[0..n]);
        return buf[0..n];
    }
    return buf[0..0];
}

/// A closing bracket typed as the first thing on its line lines up with the
/// line that opened it.
pub fn dedentCloser(ed: *Editor) !void {
    const t = ed.text();
    const pos = ed.view.cursor;
    if (pos == 0) return;
    const line = t.lineOf(pos - 1);
    const ls = t.lineStart(line);
    if (std.mem.indexOfNone(u8, t.slice(ls, pos - 1), " \t") != null) return; // not first on the line
    const open = motions.matchBracket(t, pos - 1) orelse return;
    const open_line = t.lineOf(open);
    if (open_line >= line) return;
    var buf: [256]u8 = undefined;
    const want = t.slice(t.lineStart(open_line), motions.firstNonBlank(t, open_line));
    if (want.len > buf.len or std.mem.eql(u8, want, t.slice(ls, pos - 1))) return;
    @memcpy(buf[0..want.len], want);
    try ed.deleteRangeKeepCursor(ls, pos - 1);
    try ed.insertAt(ls, buf[0..want.len]);
    ed.view.cursor = ls + want.len + 1;
    ed.view.want_col = null;
}

// ---------------------------------------------------------------------------
// Inlay hints: the language server's type and parameter labels (`: u32`
// after a name, `fmt:` before an argument), drawn inside the code. They are
// asked for the lines in view (a screenful either side), again when the text
// has been still for a moment or the view moves out of what was asked, and
// kept in place through edits in between (`Buffer.insert` / `delete`).

/// One hint on a line: its label goes before the text at byte `off`.
pub const LineHint = struct {
    off: usize,
    text: []const u8,

    pub fn cells(h: LineHint) usize {
        return std.unicode.utf8CountCodepoints(h.text) catch h.text.len;
    }
};

pub const max_line_hints = 32;

/// How long the text must stay unchanged before hints are asked for again.
const hint_debounce_ms = 250;

/// The hints to draw on `line` of `b`, in order. None while the option is
/// off, and none on the line being typed on in insert mode (they would
/// jump about under the cursor; they come back with Esc).
pub fn lineHints(ed: *const Editor, b: *const Buffer, line: usize, out: []LineHint) []LineHint {
    if (!ed.options.inlay_hints or b.hints.items.len == 0) return out[0..0];
    if (ed.mode == .insert and b == ed.buffer and line == ed.cursorLineConst()) return out[0..0];
    const t = &b.text;
    if (line >= t.lineCount()) return out[0..0];
    const ls = t.lineStart(line);
    const le = t.lineEnd(line);
    // First hint at or after the line's start.
    var lo: usize = 0;
    var hi: usize = b.hints.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (b.hints.items[mid].pos < ls) lo = mid + 1 else hi = mid;
    }
    var n: usize = 0;
    while (lo < b.hints.items.len and b.hints.items[lo].pos <= le and n < out.len) : (lo += 1) {
        const h = b.hints.items[lo];
        out[n] = .{ .off = h.pos - ls, .text = h.text };
        n += 1;
    }
    return out[0..n];
}

fn cursorLineConst(ed: *const Editor) usize {
    return ed.buffer.text.lineOf(ed.view.cursor);
}

/// Columns the hints push the text at byte `off` to the right (hints
/// before it, and one at `off` itself, which is drawn in front of it).
pub fn hintShift(hints: []const LineHint, off: usize) usize {
    var n: usize = 0;
    for (hints) |h| if (h.off <= off) {
        n += h.cells();
    };
    return n;
}

/// Like `hintShift`, without a hint at `off` itself: where a range ends,
/// the hint in front of the next character isn't part of it.
pub fn hintShiftBefore(hints: []const LineHint, off: usize) usize {
    var n: usize = 0;
    for (hints) |h| if (h.off < off) {
        n += h.cells();
    };
    return n;
}

/// The text column for a column of the screen: the other way round from
/// `hintShift`. A column on a hint is the text right after it.
pub fn hintVisualToText(hints: []const LineHint, bytes: []const u8, visual: usize, tab_width: usize) usize {
    var shift: usize = 0;
    for (hints) |h| {
        const start = motions.displayCol(bytes, @min(h.off, bytes.len), tab_width) + shift;
        const width = h.cells();
        if (visual < start) break;
        if (visual < start + width) return start - shift;
        shift += width;
    }
    return visual - shift;
}

/// An inlay-hint answer for lines `first..last` of `b` (as at `version`):
/// takes the hints in `new` (the texts go to the buffer) in place of the
/// ones it had for those lines.
pub fn takeInlayHints(ed: *Editor, b: *Buffer, new: *std.ArrayList(Buffer.Hint), first: usize, last: usize, version: u64) !void {
    b.hint_pending = false;
    // The text moved on while the server worked: its answer is for text that
    // is gone. The next tick asks again.
    if (b.edit_version != version) return;
    const t = &b.text;
    const lo = t.lineStart(@min(first, t.lineCount() - 1));
    const hi = t.lineEnd(@min(last, t.lineCount() - 1));
    var kept: std.ArrayList(Buffer.Hint) = .empty;
    errdefer kept.deinit(ed.gpa);
    for (b.hints.items) |h| {
        if (h.pos >= lo and h.pos <= hi) ed.gpa.free(h.text) else try kept.append(ed.gpa, h);
    }
    for (new.items) |h| try kept.append(ed.gpa, h);
    new.clearRetainingCapacity(); // now the buffer's
    std.mem.sort(Buffer.Hint, kept.items, {}, struct {
        fn before(_: void, a: Buffer.Hint, c: Buffer.Hint) bool {
            return a.pos < c.pos;
        }
    }.before);
    b.hints.deinit(ed.gpa);
    b.hints = kept;
    b.hint_version = version;
    b.hint_range = .{ first, last };
    ed.wake_fn();
}

/// The lines of `b` to have hints for while a window shows it from `top`:
/// the screen and a screenful either side.
fn hintWindow(b: *const Buffer, top: usize, rows: usize) [2]usize {
    return .{ top -| rows, @min(top + 2 * rows, b.text.lineCount() - 1) };
}

/// Whether `b`'s hints are for what is on screen (from `top`, `rows` tall).
fn hintsCover(b: *const Buffer, top: usize, rows: usize) bool {
    const r = b.hint_range;
    return r[0] <= top and top + rows <= r[1] + 1 or (r[1] + 1 >= b.text.lineCount() and r[0] <= top);
}

/// Each frame: asks the language server for the hints of whatever a window
/// shows that has none, or stale ones.
fn tickInlayHints(ed: *Editor) void {
    if (!ed.options.inlay_hints) return;
    for (ed.window_list.items) |w| {
        if (w.term != null) continue;
        const b = ed.windowBuffer(w);
        const l = ed.lspFor(b) orelse continue;
        if (!l.can_inlay or b.hint_pending or b.path == null) continue;
        // The text changing resets the wait.
        if (b.hint_seen != b.edit_version) {
            b.hint_seen = b.edit_version;
            b.hint_changed = ed.now;
        }
        const v = ed.windowView(w);
        const stale = b.hint_version != b.edit_version;
        const covered = hintsCover(b, v.top, v.rows);
        if (!stale and covered) continue;
        // After edits: once the text has been still for a moment. Scrolling
        // to lines never asked for: at once.
        if (stale and b.hint_changed.durationTo(ed.now).nanoseconds < hint_debounce_ms * std.time.ns_per_ms) continue;
        const range = hintWindow(b, v.top, v.rows);
        l.requestInlayHints(ed, b, range[0], range[1]) catch {};
    }
}

/// Some window's hints are waiting out the debounce (a frame must come).
fn inlayHintsDue(ed: *const Editor) bool {
    if (!ed.options.inlay_hints) return false;
    for (ed.window_list.items) |w| {
        if (w.term != null) continue;
        const b = if (w == ed.window) ed.buffer else w.buffer;
        const l = ed.lspFor(b) orelse continue;
        if (!l.can_inlay or b.hint_pending or b.path == null) continue;
        if (b.hint_version != b.edit_version) return true;
    }
    return false;
}

/// Writes a todo tag as a comment (`SPC l t`, insert-mode `<C-t>`): a blank
/// line becomes the comment, a line of code gets it at its end. Then insert
/// mode, after the tag.
pub fn writeTodoTag(ed: *Editor, tag: []const u8) !void {
    const t = ed.text();
    const line = ed.cursorLine();
    const st = textops.commentStyle(ed, line);
    var buf: [64]u8 = undefined;
    const blank = motions.firstNonBlank(t, line) == t.lineEnd(line);
    const written = try std.fmt.bufPrint(&buf, "{s}{s} {s}: ", .{ if (blank) "" else " ", st.open, tag });
    ed.setMode(.insert);
    const at = t.lineEnd(line);
    try ed.insertAt(at, written);
    // A block comment closes after where you type.
    if (st.close.len > 0) {
        var cbuf: [16]u8 = undefined;
        try ed.insertAt(at + written.len, std.fmt.bufPrint(&cbuf, " {s}", .{st.close}) catch st.close);
    }
    ed.setCursor(at + written.len);
}

/// Opens `text` as a new buffer named `label` (a manual page, say): not a
/// file, and not counted as modified.
pub fn openTextBuffer(ed: *Editor, label: []const u8, contents: []const u8) !void {
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try b.text.insert(ed.gpa, 0, std.mem.trimEnd(u8, contents, "\n"));
    b.label = try ed.gpa.dupe(u8, label);
    try ed.buffers.append(ed.gpa, b);
    ed.focusEditorWindow();
    ed.switchTo(b);
}

/// `SPC f y`: pastes register `name` after the cursor.
pub fn pasteRegister(ed: *Editor, name: u8) !void {
    const v = ed.registers.get(name) orelse return ed.setMessage(.info, "register {c} is empty", .{name});
    const copy = try ed.gpa.dupe(u8, v.text);
    defer ed.gpa.free(copy);
    try operators.paste(ed, .{ .text = copy, .linewise = v.linewise }, 1, false, true);
}

/// `SPC f u`: takes the buffer to any state in its undo tree.
pub fn undoTo(ed: *Editor, node: u32) !void {
    ed.cursors.clearRetainingCapacity();
    const b = ed.buffer;
    try b.history.commit(ed.gpa);
    const cursor = try b.history.goTo(ed.gpa, node, b) orelse return;
    b.modified = b.history.isModified();
    ed.setCursor(cursor);
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
// Projects: the git repo (or build-file folder) a file is in. Pickers, the
// runner, the shell, git and language servers work in the current window's
// project, not wherever the editor was started.

/// The project for `root`, shared by every buffer in it.
pub fn internProject(ed: *Editor, root: []const u8, git: bool) ?*const Project {
    for (ed.projects.items) |p| if (std.mem.eql(u8, p.root, root)) return p;
    const p = ed.gpa.create(Project) catch return null;
    p.* = .{ .root = ed.gpa.dupe(u8, root) catch {
        ed.gpa.destroy(p);
        return null;
    }, .git = git };
    ed.projects.append(ed.gpa, p) catch {
        ed.gpa.free(p.root);
        ed.gpa.destroy(p);
        return null;
    };
    return p;
}

/// The project a buffer path (relative to the cwd, or absolute) belongs to.
fn projectOf(ed: *Editor, path: []const u8) ?*const Project {
    const abs = ed.absolutePath(path) catch return null;
    defer ed.gpa.free(abs);
    const f = Project.detect(ed.io, std.fs.path.dirname(abs) orelse return null) orelse return null;
    return ed.internProject(f.root, f.git);
}

/// The current project: the focused buffer's, else the last one used.
pub fn project(ed: *const Editor) ?*const Project {
    return ed.buffer.project orelse ed.last_project;
}

/// Where project-wide things happen: the current project, else the cwd.
pub fn projectRoot(ed: *const Editor) []const u8 {
    return if (ed.project()) |p| p.root else ed.cwd;
}

/// The current project's repository root, if it is one.
pub fn gitRoot(ed: *const Editor) ?[]const u8 {
    const p = ed.project() orelse return null;
    return if (p.git) p.root else null;
}

/// A path from a picker (relative to the folder it listed) as a buffer path.
/// Caller frees.
pub fn pickerPath(ed: *Editor, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return ed.normalizePath(path);
    const abs = try std.fs.path.join(ed.gpa, &.{ ed.picker_root, path });
    defer ed.gpa.free(abs);
    return ed.normalizePath(abs);
}

/// A buffer's project becomes the one we're in (and is remembered for
/// `SPC p p`).
fn enterProject(ed: *Editor, p: ?*const Project) void {
    const proj = p orelse return;
    if (ed.last_project == proj) return;
    ed.last_project = proj;
    ed.rememberProject(proj.root);
}

fn knownProjectsPath(ed: *Editor) ?[]u8 {
    return RunMemory.statePath(ed.gpa, "projects");
}

/// Projects opened before, most recent first.
pub fn knownProjects(ed: *Editor) []const []u8 {
    if (ed.known_projects == null) {
        ed.known_projects = .empty;
        if (@import("builtin").is_test) return ed.known_projects.?.items;
        const path = ed.knownProjectsPath() orelse return &.{};
        defer ed.gpa.free(path);
        const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(1 << 20)) catch return &.{};
        defer ed.gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| if (line.len > 0) {
            const owned = ed.gpa.dupe(u8, line) catch break;
            ed.known_projects.?.append(ed.gpa, owned) catch ed.gpa.free(owned);
        };
    }
    return ed.known_projects.?.items;
}

const max_known_projects = 50;

fn rememberProject(ed: *Editor, root: []const u8) void {
    _ = ed.knownProjects();
    const list = &ed.known_projects.?;
    for (list.items, 0..) |r, i| if (std.mem.eql(u8, r, root)) {
        if (i == 0) return;
        const owned = list.orderedRemove(i);
        list.insert(ed.gpa, 0, owned) catch ed.gpa.free(owned);
        return ed.saveKnownProjects();
    };
    const owned = ed.gpa.dupe(u8, root) catch return;
    list.insert(ed.gpa, 0, owned) catch return ed.gpa.free(owned);
    while (list.items.len > max_known_projects) ed.gpa.free(list.pop().?);
    ed.saveKnownProjects();
}

fn saveKnownProjects(ed: *Editor) void {
    if (@import("builtin").is_test) return;
    const path = ed.knownProjectsPath() orelse return;
    defer ed.gpa.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ed.gpa);
    for (ed.known_projects.?.items) |r| out.print(ed.gpa, "{s}\n", .{r}) catch return;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(ed.io, dir) catch return;
    Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// `SPC p p` picked a project: find a file in it.
pub fn switchProject(ed: *Editor, root: []const u8) !void {
    const f = Project.detect(ed.io, root) orelse Project.Found{ .root = root, .git = false };
    const p = ed.internProject(f.root, f.git) orelse return;
    // Leaving a project keeps its session; coming back to one with nothing
    // open restores it.
    const same = ed.project() == p;
    if (!same) ed.saveSession(false);
    ed.enterProject(p);
    if (!same and ed.deferred_target == null and !ed.hasBuffersIn(p) and ed.restoreSession(p.root)) return;
    try ed.exploreProject(p.root);
}

/// The Files picker (the explorer) at project `root`.
pub fn exploreProject(ed: *Editor, root: []const u8) !void {
    const r = try ed.gpa.dupe(u8, root);
    defer ed.gpa.free(r);
    ed.next_picker_root = ed.internProject(r, (Project.detect(ed.io, r) orelse Project.Found{ .root = r, .git = false }).git).?.root;
    try ed.setBrowseDir(r);
    try ed.openPicker(.browse, "");
}

/// Forgets project `root` from the list of ones opened before.
pub fn forgetProject(ed: *Editor, root: []const u8) void {
    _ = ed.knownProjects();
    const list = &ed.known_projects.?;
    for (list.items, 0..) |r, i| if (std.mem.eql(u8, r, root)) {
        ed.gpa.free(list.orderedRemove(i));
        ed.saveKnownProjects();
        return;
    };
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
    if (ed.window.term == null) ed.last_editor_window = ed.window;
    ed.window.view = ed.view;
    ed.window.buffer = ed.buffer;
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    if (w.buffer != ed.buffer) ed.leaveBuffer(ed.buffer);
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
    ed.enterProject(ed.buffer.project);
    ed.use_counter += 1;
    ed.buffer.last_used = ed.use_counter;
    w.used = ed.use_counter;
    ed.placeCursor(@min(ed.view.cursor, ed.text().len()));
    ed.scrollToCursor();
}

/// Swaps what windows `a` and `b` show (buffer and place, or terminal);
/// focus stays where it is.
pub fn swapWindows(ed: *Editor, a: *Windows.Window, b: *Windows.Window) void {
    if (a == b) return;
    // The focused window's live state back into it first.
    ed.window.view = ed.view;
    ed.window.buffer = ed.buffer;
    std.mem.swap(*Buffer, &a.buffer, &b.buffer);
    std.mem.swap(View, &a.view, &b.view);
    std.mem.swap(?*Terminal, &a.term, &b.term);
    std.mem.swap(bool, &a.term_normal, &b.term_normal);
    ed.loadWindow(ed.window);
}

/// The sizes before a window was maximised (`z` in the windows picker):
/// the splits on its way to the root and their ratios. Dropped when windows
/// are split or closed (the tree changed under it).
pub const Zoom = struct { n: usize = 0, splits: [16]*Windows.Split = undefined, ratios: [16]f32 = undefined };

/// `z` in the windows picker: window `w` takes nearly all the room, the
/// others a sliver; again: the sizes they had.
pub fn toggleZoom(ed: *Editor, w: *Windows.Window) void {
    if (ed.zoom) |z| {
        for (z.splits[0..z.n], z.ratios[0..z.n]) |sp, r| sp.ratio = r;
        ed.zoom = null;
        return ed.setMessage(.info, "window sizes back", .{});
    }
    var z: Zoom = .{};
    var node = w.node;
    while (node.parent) |parent| : (node = parent) {
        if (z.n == z.splits.len) break;
        const sp = &parent.kind.split;
        z.splits[z.n] = sp;
        z.ratios[z.n] = sp.ratio;
        z.n += 1;
        sp.ratio = if (sp.first == node) 0.92 else 0.08;
    }
    if (z.n == 0) return ed.setMessage(.info, "only one window", .{});
    ed.zoom = z;
    ed.setMessage(.info, "maximised (z again: back)", .{});
}

/// `SPC w s` + direction: a new window on that side, showing this buffer.
pub fn splitWindow(ed: *Editor, dir: Windows.Dir) !void {
    ed.zoom = null; // the tree changes: the saved sizes no longer fit
    const nw = try ed.windows.split(ed.window, dir, ed.view, ed.buffer);
    ed.refreshWindowList();
    ed.focusWindow(nw);
}

/// `SPC w d`: closes the focused window (not the last one).
/// Windows of your own (not the Claude panel; a shell shown in a window
/// still counts: the window has its file underneath).
pub fn codeWindowCount(ed: *const Editor) usize {
    var n: usize = 0;
    for (ed.window_list.items) |w| n += @intFromBool(if (w.term) |t| std.mem.indexOfScalar(*Terminal, ed.shells.items, t) != null else true);
    return n;
}

pub fn closeWindow(ed: *Editor) void {
    const closing = ed.window;
    const shell = closing.term;
    // Never leave only a terminal panel on screen.
    if (closing.term == null and ed.codeWindowCount() <= 1 and ed.window_list.items.len > 1)
        return ed.setMessage(.info, "this is the last code window (SPC a a hides Claude)", .{});
    // The only window, showing a shell: the shell ends, the file shows.
    if (shell != null and ed.window_list.items.len == 1 and !ed.isClaudeTerm(shell.?)) {
        closing.term = null;
        if (std.mem.indexOfScalar(*Terminal, ed.shells.items, shell.?)) |i| _ = ed.shells.orderedRemove(i);
        shell.?.destroy();
        return ed.setMessage(.info, "terminal closed", .{});
    }
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    ed.zoom = null;
    const target = ed.windows.close(closing) orelse
        return ed.setMessage(.info, "this is the last window (SPC q closes the buffer, then quits)", .{});
    ed.refreshWindowList();
    ed.loadWindow(target);
    // A shell window's shell ends with it (the Claude panel just hides).
    if (shell) |t| for (ed.shells.items, 0..) |o, i| if (o == t) {
        _ = ed.shells.orderedRemove(i);
        t.destroy();
        break;
    };
}

pub fn isClaudeTerm(ed: *const Editor, t: *const Terminal) bool {
    const c = ed.claude orelse return false;
    return c.term == t;
}

/// `SPC r w`: the current window becomes your shell (the file stays
/// underneath). A shell hidden earlier comes back; else a new one starts in
/// the project root.
pub fn openTermWindow(ed: *Editor) !void {
    ed.focusEditorWindow();
    const t = for (ed.shells.items) |o| {
        if (ed.windowShowing(o) == null) break o;
    } else blk: {
        const fresh = try ed.spawnTerminal(&.{Pty.userShell()});
        errdefer fresh.destroy();
        try ed.shells.append(ed.gpa, fresh);
        break :blk fresh;
    };
    ed.window.term = t;
    ed.window.term_normal = false;
}

/// Shells that exited: their windows show their files again.
fn pollShellWindows(ed: *Editor) void {
    var i = ed.shells.items.len;
    while (i > 0) {
        i -= 1;
        const t = ed.shells.items[i];
        if (t.isRunning()) continue;
        _ = ed.shells.orderedRemove(i);
        for (ed.window_list.items) |w| if (w.term == t) {
            w.term = null;
        };
        t.destroy();
    }
}

/// `SPC w o`: closes every other window.
pub fn onlyWindow(ed: *Editor) !void {
    ed.zoom = null;
    try ed.windows.only(ed.window);
    ed.refreshWindowList();
}

/// Back to an editor window (from a terminal window).
pub fn focusEditorWindow(ed: *Editor) void {
    if (ed.window.term == null) return;
    if (ed.last_editor_window) |w| for (ed.window_list.items) |o| if (o == w) return ed.focusWindow(w);
    for (ed.window_list.items) |o| if (o.term == null) return ed.focusWindow(o);
}

/// The window showing terminal `t`, if any.
pub fn windowShowing(ed: *Editor, t: *const Terminal) ?*Windows.Window {
    for (ed.window_list.items) |w| if (w.term == t) return w;
    return null;
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
        return ed.setMessage(.info, "this buffer has no file yet: SPC b w saves it as one", .{});
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
    b.project = ed.projectOf(path);
    ed.loadGitBase(b);
    if (b == ed.buffer) ed.updateGit();
}

/// `SPC b x`: asks (in a Yes/No picker) before deleting the current file.
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
    if (b.path == null) return ed.filePrompt(.save_as);
    if (ed.options.trim_on_save) _ = try textops.trimTrailing(ed);
    // JavaScript / TypeScript: eslint's fixes and organized imports first.
    const lang = if (b.syntax) |sx| sx.lang.name else "";
    if (ed.save_chain == null and (std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "typescript") or std.mem.eql(u8, lang, "tsx"))) {
        ed.save_chain = .{ .buffer = b, .step = .start, .started = ed.now };
        return ed.saveChainNext();
    }
    ed.finishSave(b);
}

/// The last part of saving: formatted (format on save), then written.
fn finishSave(ed: *Editor, b: *Buffer) void {
    // `.env` files are shell-ish, not scripts: shfmt would rewrite them.
    const env = if (b.path) |p| @import("syntax/languages.zig").isEnvFile(p) else false;
    if (ed.options.format_on_save and b.syntax != null and b == ed.buffer and !env) {
        ed.formatBuffer(null, true) catch ed.saveBufferNow(b);
        return;
    }
    ed.saveBufferNow(b);
}

/// The save of a JS/TS file, a step at a time: eslint's "fix all", then
/// "organize imports", then format and write. Each server's answer (or 2
/// seconds without one) moves it on; a server not running is skipped.
pub fn saveChainNext(ed: *Editor) void {
    const chain = &(ed.save_chain orelse return);
    const b = chain.buffer;
    if (!ed.bufferAlive(b)) {
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
            .organize => if (ed.lspFor(b)) |l| {
                if (l.requestSourceAction(ed, b, "source.organizeImports")) |_| return else |_| {}
            },
            .done => {
                ed.save_chain = null;
                ed.finishSave(b);
                return;
            },
        }
    }
}

/// A step waiting too long on its server: on without it.
fn tickSaveChain(ed: *Editor) void {
    const chain = ed.save_chain orelse return;
    const ms = @divTrunc(chain.started.durationTo(ed.now).nanoseconds, std.time.ns_per_ms);
    if (ms > 2000) ed.saveChainNext();
}

/// Writes `b` as it is.
pub fn saveBufferNow(ed: *Editor, b: *Buffer) void {
    const n = b.save(ed.gpa, ed.io) catch |err|
        return ed.setMessage(.err, "could not save \"{s}\": {s}", .{ b.displayName(), @errorName(err) });
    ed.setMessage(.info, "\"{s}\" {d}L, {d}B written", .{ b.displayName(), b.text.lineCount(), n });
    if (ed.lspFor(b)) |l| l.didSave(b);
}

// ---------------------------------------------------------------------------
// Formatting (`SPC l f`, and on save): the language server's, else the
// language's formatter run directly.

/// Formats the current buffer (lines `range`, inclusive, if the server can
/// format ranges), then saves it if `then_save`.
pub fn formatBuffer(ed: *Editor, range: ?[2]usize, then_save: bool) !void {
    const b = ed.buffer;
    const lang = if (b.syntax) |sx| sx.lang.name else "";
    if (!format.preferred(lang)) if (ed.lspFor(b)) |l| if (l.can_format) {
        l.requestFormat(ed, range, then_save) catch |err| {
            ed.setMessage(.err, "could not format: {s}", .{@errorName(err)});
            if (then_save) ed.saveBufferNow(b);
            return;
        };
        if (!then_save) ed.setMessage(.info, "formatting...", .{});
        return;
    };
    try ed.formatExternal(then_save);
}

fn formatExternal(ed: *Editor, then_save: bool) !void {
    const b = ed.buffer;
    defer if (then_save) ed.saveBufferNow(b);
    const lang = if (b.syntax) |sx| sx.lang.name else "";
    const t = ed.text();
    // The buffer as the file would be written (final newline included).
    const src = try std.mem.concat(ed.gpa, u8, &.{ t.slice(0, t.len()), if (b.final_newline and t.len() > 0) "\n" else "" });
    defer ed.gpa.free(src);
    const abs = if (b.path) |p| try ed.absolutePath(p) else null;
    defer if (abs) |a| ed.gpa.free(a);
    switch (try format.run(ed.gpa, ed.io, lang, src, ed.projectRoot(), abs)) {
        .none => if (!then_save) {
            if (format.name(lang)) |n| ed.setMessage(.err, "{s} isn't installed", .{n}) else ed.setMessage(.info, "no formatter for this file", .{});
        } else if (format.name(lang)) |n| {
            // On save: said once, then saving just goes on unformatted.
            if (!ed.format_missing_told.contains(n)) {
                ed.format_missing_told.put(ed.gpa, n, {}) catch {};
                ed.notify(.err, "{s} isn't installed: saved without formatting", .{n});
            }
        },
        .failed => |m| {
            defer ed.gpa.free(m);
            ed.setMessage(.err, "{s}: {s}", .{ format.name(lang).?, m });
        },
        .ok => |out| {
            defer ed.gpa.free(out);
            const body = if (b.final_newline and out.len > 0 and out[out.len - 1] == '\n') out[0 .. out.len - 1] else out;
            try ed.replaceTextKeepingCursor(body);
        },
    }
}

/// Replaces the buffer's text with `new`, changing only the lines that
/// differ (one undo step), the cursor staying on its line and column.
fn replaceTextKeepingCursor(ed: *Editor, new: []const u8) !void {
    const t = ed.text();
    if (std.mem.eql(u8, t.slice(0, t.len()), new)) return;
    const new_text = try Text.init(ed.gpa, new);
    var nt = new_text;
    defer nt.deinit(ed.gpa);
    const lines = struct {
        fn of(gpa: Allocator, x: *const Text) ![][]const u8 {
            const n = if (x.len() == 0) 0 else x.lineCount();
            const out = try gpa.alloc([]const u8, n);
            for (out, 0..) |*l, i| l.* = x.lineSlice(i);
            return out;
        }
    }.of;
    const old_lines = try lines(ed.gpa, t);
    defer ed.gpa.free(old_lines);
    const new_lines = try lines(ed.gpa, &nt);
    defer ed.gpa.free(new_lines);
    var hunks: std.ArrayList(diff.Hunk) = .empty;
    defer hunks.deinit(ed.gpa);
    try diff.diffLines(ed.gpa, old_lines, new_lines, &hunks);
    const line = ed.cursorLine();
    const col = ed.view.cursor - t.lineStart(line);
    // Last hunk first, so earlier line numbers stay valid.
    var i = hunks.items.len;
    while (i > 0) {
        i -= 1;
        const h = hunks.items[i];
        var repl: std.ArrayList(u8) = .empty;
        defer repl.deinit(ed.gpa);
        for (0..h.new_count) |k| {
            if (k > 0) try repl.append(ed.gpa, '\n');
            try repl.appendSlice(ed.gpa, new_lines[h.new_start + k]);
        }
        const total = t.lineCount();
        if (h.old_count == 0) {
            // Inserted lines: before line old_start (or after the last).
            if (h.old_start < total and t.len() > 0) {
                try repl.append(ed.gpa, '\n');
                try ed.insertAt(t.lineStart(h.old_start), repl.items);
            } else {
                if (t.len() > 0) try repl.insert(ed.gpa, 0, '\n');
                try ed.insertAt(t.len(), repl.items);
            }
        } else {
            var start = t.lineStart(h.old_start);
            var end = t.lineEnd(h.old_start + h.old_count - 1);
            if (h.new_count == 0) {
                // Removed lines, with one of their line breaks.
                if (end < t.len()) end += 1 else if (start > 0) start -= 1;
            }
            try ed.deleteRangeKeepCursor(start, end);
            try ed.insertAt(start, repl.items);
        }
    }
    try ed.buffer.history.commit(ed.gpa);
    const l = @min(line, t.lineCount() - 1);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
}

/// The server's formatting edits for `b` arrived: apply them (one undo
/// step, cursor kept on its line), then save if asked.
pub fn applyFormatEdits(ed: *Editor, b: *Buffer, edits: []const Lsp.TextEdit, then_save: bool) !void {
    defer if (then_save) ed.saveBufferNow(b);
    if (edits.len == 0) {
        if (!then_save) ed.setMessage(.info, "already formatted", .{});
        return;
    }
    if (b != ed.buffer) return; // switched away meanwhile: leave it
    const t = ed.text();
    const line = ed.cursorLine();
    const col = ed.view.cursor - t.lineStart(line);
    const sorted = try ed.gpa.dupe(Lsp.TextEdit, edits);
    defer ed.gpa.free(sorted);
    std.mem.sort(Lsp.TextEdit, sorted, {}, struct {
        fn later(_: void, a: Lsp.TextEdit, c: Lsp.TextEdit) bool {
            return if (a.start_line != c.start_line) a.start_line > c.start_line else a.start_col > c.start_col;
        }
    }.later);
    for (sorted) |e| {
        const start = ed.offsetOf(e.start_line, e.start_col);
        const end = ed.offsetOf(e.end_line, e.end_col);
        try ed.deleteRangeKeepCursor(start, @max(start, end));
        try ed.insertAt(start, e.text);
    }
    try ed.buffer.history.commit(ed.gpa);
    ed.buffer.modified = ed.buffer.history.isModified();
    const l = @min(line, t.lineCount() - 1);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
    if (!then_save) ed.setMessage(.info, "formatted", .{});
}

fn fileExists(ed: *Editor, path: []const u8) bool {
    Io.Dir.cwd().access(ed.io, path, .{}) catch return false;
    return true;
}

fn findBuffer(ed: *Editor, path: []const u8) ?*Buffer {
    for (ed.buffers.items) |b| if (b.path) |p| if (std.mem.eql(u8, p, path)) return b;
    return null;
}

/// `SPC b e`: a new empty scratch buffer.
pub fn newBuffer(ed: *Editor) !void {
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try ed.buffers.append(ed.gpa, b);
    ed.switchTo(b);
}

/// `SPC b b`: back to the previous buffer (the most recently used other one).
pub fn lastBuffer(ed: *Editor) !void {
    const order = try ed.buffersByRecency(ed.gpa);
    defer ed.gpa.free(order);
    if (order.len < 2) return ed.setMessage(.info, "no other buffer", .{});
    ed.switchTo(order[0]);
}

/// `SPC b o`: kills every other buffer without unsaved changes.
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

/// `SPC b a`: saves every modified buffer that has a file.
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
    // The command editor's buffer isn't one of the list.
    if (ed.cmd_float != null) return ed.setMessage(.info, "close the command editor first (<Esc> in normal mode)", .{});
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
    // From visual mode (`SPC` on a selection): a menu row acts on it.
    ed.picker_visual = if (ed.mode == .visual) .{ .line = ed.visual_line } else null;
    ed.closePicker();
    ed.picker_root = ed.next_picker_root orelse ed.projectRoot();
    ed.next_picker_root = null;
    if (kind == .themes) ed.theme_before = ed.theme_index;
    ed.picker = try Picker.create(ed, kind, query);
    // The theme picker starts on the theme in use (moving previews).
    if (kind == .themes) ed.picker.?.want_id = @intCast(ed.theme_index);
    ed.mode = if (@import("picker/sources.zig").startsNormal(kind)) .picker_normal else .picker;
}

// Vim keys on the picker's query (its normal mode, after <Esc>): motions
// `h l w b e W B E 0 ^ $`, `x X D C s S`, operators `d c y` with those and
// `iw aw` (`dd cc yy`: all of it), `p P`, `u`, and `i a I A` to type. In
// the pickers that use some of these keys for their rows (the explorer,
// buffers, runner, quickfix), those keep doing that.

fn pickerQueryKey(ed: *Editor, ev: KeyEvent) !bool {
    const p = ed.picker orelse return false;
    if (ed.pending_len != 0) return false;
    const pending = ed.query_op != null;
    if (ev.mods.blocksText() or ev.key != .codepoint) {
        // <Esc> cancels a waiting operator (else it closes the picker).
        if (pending and ev.key == .special and ev.key.special == .escape) {
            ed.query_op = null;
            ed.query_obj = null;
            return true;
        }
        return false;
    }
    const cp = ev.key.codepoint;
    const q = &p.query;
    const len = q.items().len;

    if (ed.query_op) |op| {
        if (ed.query_obj) |obj| {
            ed.query_op = null;
            ed.query_obj = null;
            if (cp != 'w' and cp != 'W') return true;
            const r = q.wordObject(q.cursor, obj == 'a', cp == 'W');
            try ed.queryApply(op, r[0], r[1]);
            return true;
        }
        if (cp == 'i' or cp == 'a') {
            ed.query_obj = @intCast(cp);
            return true;
        }
        ed.query_op = null;
        if (cp == op) {
            try ed.queryApply(op, 0, len);
            return true;
        }
        const r = queryMotionRange(q, cp, op) orelse return true;
        try ed.queryApply(op, r[0], r[1]);
        return true;
    }

    // A menu row's key runs that row; a picker action's letter runs it.
    if (std.math.cast(u8, cp)) |b| {
        if (std.mem.indexOfScalar(u8, sources.rowKeys(p.kind), b)) |id| {
            try ed.pickerRunRow(p, @intCast(id));
            return true;
        }
        for (sources.itemActions(p.kind)) |*a| if (a.key == b) {
            try ed.runPickerAction(p, a);
            return true;
        };
    }
    const own = switch (p.kind) {
        .browse, .buffers, .runner, .quickfix => true,
        else => false,
    };
    if (own and std.mem.indexOfScalar(u8, "hlxdpyonrm", std.math.cast(u8, cp) orelse 0) != null) return false;
    const last = q.lastChar();
    switch (cp) {
        'h' => q.cursor = q.prev(q.cursor),
        'l' => q.cursor = @min(q.next(q.cursor), last),
        'w', 'W' => q.cursor = @min(q.wordForward(q.cursor, cp == 'W'), last),
        'b', 'B' => q.cursor = q.wordBackward(q.cursor, cp == 'B'),
        'e', 'E' => q.cursor = q.wordEnd(q.cursor, cp == 'E'),
        '0', '^' => q.cursor = 0,
        '$' => q.cursor = last,
        'x' => try ed.queryApply('d', q.cursor, q.next(q.cursor)),
        'X' => try ed.queryApply('d', q.prev(q.cursor), q.cursor),
        'D' => try ed.queryApply('d', q.cursor, len),
        'C' => try ed.queryApply('c', q.cursor, len),
        's' => try ed.queryApply('c', q.cursor, q.next(q.cursor)),
        'S' => try ed.queryApply('c', 0, len),
        'd', 'c', 'y' => ed.query_op = @intCast(cp),
        'p', 'P' => {
            const v = ed.registers.get(null) orelse return true;
            const yanked = std.mem.trimEnd(u8, std.mem.sliceTo(v.text, '\n'), "\r");
            if (yanked.len == 0) return true;
            try ed.querySnapshot();
            q.cursor = if (cp == 'p' and len > 0) q.next(q.cursor) else q.cursor;
            try q.insertSlice(ed.gpa, yanked);
            q.cursor = q.prev(q.cursor);
            try ed.inputChanged();
        },
        'u' => {
            const u = ed.query_undo.pop() orelse return true;
            defer ed.gpa.free(u.text);
            try q.set(ed.gpa, u.text);
            q.cursor = @min(u.cursor, q.lastChar());
            try ed.inputChanged();
        },
        'i' => ed.mode = .picker,
        'a' => {
            q.cursor = q.next(q.cursor);
            ed.mode = .picker;
        },
        'I' => {
            q.cursor = 0;
            ed.mode = .picker;
        },
        'A' => {
            q.cursor = len;
            ed.mode = .picker;
        },
        else => return false,
    }
    return true;
}

/// The bytes `op` + motion `cp` covers, from the query's cursor.
fn queryMotionRange(q: *const LineInput, cp: u21, op: u8) ?[2]usize {
    const c = q.cursor;
    const len = q.items().len;
    return switch (cp) {
        // `cw` on a word changes to its end, like vim.
        'w', 'W' => if (op == 'c' and c < len and q.items()[c] != ' ') .{ c, q.next(q.wordEnd(c, cp == 'W')) } else .{ c, q.wordForward(c, cp == 'W') },
        'b', 'B' => .{ q.wordBackward(c, cp == 'B'), c },
        'e', 'E' => .{ c, q.next(q.wordEnd(c, cp == 'E')) },
        'h' => .{ q.prev(c), c },
        'l', ' ' => .{ c, q.next(c) },
        '0', '^' => .{ 0, c },
        '$' => .{ c, len },
        else => null,
    };
}

/// `C-t`: the picker's next scope (Files: project, open, recent, disk...),
/// with the same query and mode. A scope that can't open now (no run yet)
/// is passed over.
pub fn pickerNextScope(ed: *Editor) !void {
    const p = ed.picker orelse return;
    const group = sources.scopeGroup(p.kind) orelse return;
    var at: usize = 0;
    for (group, 0..) |sc, i| if (sc.kind == p.kind) {
        at = i;
    };
    const query = try ed.gpa.dupe(u8, p.activeQuery());
    defer ed.gpa.free(query);
    const mode = ed.mode;
    for (1..group.len) |step| {
        const next = group[(at + step) % group.len];
        ed.closePicker();
        const cmd = commands.find(next.command) orelse continue;
        ed.runCommand(cmd) catch {};
        const np = ed.picker orelse continue;
        if (np.kind != next.kind) continue;
        try np.query.set(ed.gpa, query);
        ed.mode = mode;
        try ed.inputChanged();
        return;
    }
}

/// Ctrl + an action's letter, typing or not.
fn pickerCtrlAction(ed: *Editor, ev: KeyEvent) !bool {
    const p = ed.picker orelse return false;
    if (!ev.mods.ctrl or ev.mods.alt or ev.key != .codepoint or ed.pending_len != 0) return false;
    const b = std.math.cast(u8, ev.key.codepoint) orelse return false;
    for (sources.itemActions(p.kind)) |*a| if (a.ctrl == b) {
        try ed.runPickerAction(p, a);
        return true;
    };
    return false;
}

/// Runs `a` on the picker's selected row (a copy: the picker may close).
fn runPickerAction(ed: *Editor, p: *Picker, a: *const sources.Action) !void {
    p.sync();
    const live = p.itemAt(p.selected);
    if (live == null and !a.any) return;
    var row_text: ?[]u8 = null;
    var row_detail: ?[]u8 = null;
    defer if (row_text) |x| ed.gpa.free(x);
    defer if (row_detail) |x| ed.gpa.free(x);
    var item: ?Picker.ItemsStore.Item = null;
    if (live) |it| {
        row_text = try ed.gpa.dupe(u8, it.text);
        row_detail = try ed.gpa.dupe(u8, it.detail);
        item = .{ .text = row_text.?, .detail = row_detail.?, .id = it.id };
    }
    if (a.stay) {
        try a.run(ed, item);
        if (ed.picker == p) try p.refill();
        return;
    }
    ed.closePicker();
    try a.run(ed, item);
}

/// A menu row's key: that row, as if picked.
fn pickerRunRow(ed: *Editor, p: *Picker, id: u32) !void {
    p.sync();
    for (p.snap.slice(), 0..) |r, row| {
        if (p.shown.items.get(r.index).id != id) continue;
        p.selected = row;
        return ed.acceptPicker();
    }
}

/// Remembers the query for `u` (the last 50 changes).
fn querySnapshot(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (ed.query_undo.items.len >= 50) ed.gpa.free(ed.query_undo.orderedRemove(0).text);
    try ed.query_undo.append(ed.gpa, .{ .text = try ed.gpa.dupe(u8, p.query.items()), .cursor = p.query.cursor });
}

/// `d` / `c` / `y` on query bytes `[start, end)`.
fn queryApply(ed: *Editor, op: u8, start: usize, end: usize) !void {
    const p = ed.picker orelse return;
    const q = &p.query;
    if (op == 'y') {
        try ed.registers.store(null, .yank, q.items()[start..@min(end, q.items().len)], false);
        q.cursor = start;
        return;
    }
    if (start >= end and op == 'd') return;
    try ed.querySnapshot();
    q.delete(start, end);
    q.cursor = start;
    if (op == 'c') {
        ed.mode = .picker;
    } else q.cursor = @min(q.cursor, q.lastChar());
    try ed.inputChanged();
}

/// A menu row from a picker opened in visual mode: the selection is back
/// for it (the view kept its anchor and cursor meanwhile).
pub fn restorePickerVisual(ed: *Editor) void {
    const v = ed.picker_visual orelse return;
    ed.picker_visual = null;
    ed.mode = .visual;
    ed.visual_line = v.line;
}

/// Whether boolean option `name` is on (null: there is no such option).
pub fn optionState(ed: *const Editor, name: []const u8) ?bool {
    const info = @typeInfo(Options).@"struct";
    inline for (info.field_names, info.field_types) |field_name, T| {
        if (T == bool and std.mem.eql(u8, field_name, name)) return @field(ed.options, field_name);
    }
    return null;
}

pub fn closePicker(ed: *Editor) void {
    const p = ed.picker orelse return;
    // Closing without picking cancels a split waiting for a file.
    ed.deferred_target = null;
    // `SPC '` resumes a picker you searched in, not a menu on the way to it.
    if (sources.rowKeys(p.base).len == 0 and p.base != .open_in) {
        ed.resume_kind = p.base;
        ed.resume_query.clearRetainingCapacity();
        ed.resume_query.appendSlice(ed.gpa, p.query.items()) catch {};
    }
    // Moving through the themes previews them; only Enter keeps one.
    if (p.base == .themes) ed.theme_index = ed.theme_before;
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
    // Files from elsewhere (typed search): `~/...` and absolute paths.
    if (std.mem.startsWith(u8, name, "~/")) if (std.c.getenv("HOME")) |h| return std.fs.path.join(ed.gpa, &.{ std.mem.span(h), name[2..] });
    if (std.fs.path.isAbsolute(name)) return ed.gpa.dupe(u8, name);
    return std.fs.path.join(ed.gpa, &.{ ed.browse_dir.items, name });
}

pub fn setBrowseDir(ed: *Editor, dir: []const u8) !void {
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

// File operations in the browser's list (normal mode): `o` new folder,
// `n` new file, `r` rename, `m` move, `x` / `dd` delete, `yy` copy and `p`
// paste into the folder shown.

pub const BrowseOp = enum { new_folder, new_file, rename, move, delete, copy, paste };

fn setBrowseSlot(ed: *Editor, slot: *?[]u8, path: []const u8) !void {
    const owned = try ed.gpa.dupe(u8, path);
    if (slot.*) |old| ed.gpa.free(old);
    slot.* = owned;
}

/// Reopens the browser on its folder, on the entry `select` if given.
fn reopenBrowser(ed: *Editor, select: ?[]const u8) void {
    ed.openPicker(.browse, "") catch return;
    ed.mode = .picker_normal;
    if (select) |s| ed.picker.?.want_select = ed.gpa.dupe(u8, s) catch null;
}

pub fn browseOp(ed: *Editor, op: BrowseOp) !void {
    const p = ed.picker orelse return;
    if (p.kind != .browse) return;
    p.sync();
    switch (op) {
        .new_folder, .new_file => {
            ed.closePicker();
            ed.startSearch(true, if (op == .new_folder) .browse_new_folder else .browse_new_file);
            return;
        },
        .paste => return ed.browsePaste(),
        else => {},
    }
    // The rest act on the selected entry.
    const item = p.itemAt(p.selected) orelse return ed.setMessage(.info, "nothing selected", .{});
    const is_dir = std.mem.endsWith(u8, item.text, "/");
    const name = try ed.gpa.dupe(u8, std.mem.trimEnd(u8, item.text, "/"));
    defer ed.gpa.free(name);
    const abs = try ed.browsePath(name);
    defer ed.gpa.free(abs);
    switch (op) {
        .copy => {
            if (is_dir) return ed.setMessage(.info, "copying a whole folder isn't supported (m moves one)", .{});
            try ed.setBrowseSlot(&ed.browse_clip, abs);
            ed.setMessage(.info, "copied \"{s}\": p pastes it into the folder shown", .{name});
        },
        .rename, .move => {
            try ed.setBrowseSlot(&ed.browse_target, abs);
            ed.closePicker();
            ed.startSearch(true, if (op == .rename) .browse_rename else .browse_move);
            try ed.search_prompt.?.input.set(ed.gpa, if (op == .rename) name else abs);
        },
        .delete => {
            try ed.setBrowseSlot(&ed.browse_target, abs);
            ed.closePicker();
            try ed.openPicker(.confirm_remove, "");
        },
        else => unreachable,
    }
}

fn browsePaste(ed: *Editor) !void {
    const src = ed.browse_clip orelse return ed.setMessage(.info, "nothing copied (yy on a file copies it)", .{});
    const base = std.fs.path.basename(src);
    var dest = try ed.browsePath(base);
    defer ed.gpa.free(dest);
    if (ed.fileExists(dest)) {
        // Next to the original: "name copy.ext".
        const ext = std.fs.path.extension(base);
        const named = try std.fmt.allocPrint(ed.gpa, "{s} copy{s}", .{ base[0 .. base.len - ext.len], ext });
        defer ed.gpa.free(named);
        ed.gpa.free(dest);
        dest = try ed.browsePath(named);
        if (ed.fileExists(dest)) return ed.setMessage(.err, "\"{s}\" already exists here", .{named});
    }
    Io.Dir.copyFile(Io.Dir.cwd(), src, Io.Dir.cwd(), dest, ed.io, .{}) catch |err|
        return ed.setMessage(.err, "could not copy: {s}", .{@errorName(err)});
    const shown = try ed.gpa.dupe(u8, std.fs.path.basename(dest));
    defer ed.gpa.free(shown);
    if (ed.picker) |p| {
        try p.restart(shown);
        ed.mode = .picker_normal;
    }
    ed.setMessage(.info, "pasted \"{s}\"", .{shown});
}

fn finishBrowsePrompt(ed: *Editor, kind: PromptKind) !void {
    const raw = try ed.takePromptText() orelse return;
    defer ed.gpa.free(raw);
    const typed = std.mem.trim(u8, raw, " ");
    if (typed.len == 0) {
        ed.setMessage(.info, "cancelled: no name", .{});
        return ed.reopenBrowser(null);
    }
    const cwd = Io.Dir.cwd();
    // Relative names are inside the folder shown.
    const dest = try std.fs.path.resolve(ed.gpa, &.{ ed.browse_dir.items, typed });
    defer ed.gpa.free(dest);
    switch (kind) {
        .browse_new_folder => {
            cwd.createDirPath(ed.io, dest) catch |err| {
                ed.setMessage(.err, "could not make the folder: {s}", .{@errorName(err)});
                return ed.reopenBrowser(null);
            };
            ed.setMessage(.info, "made folder \"{s}\"", .{typed});
        },
        .browse_new_file => {
            if (ed.fileExists(dest)) {
                ed.setMessage(.err, "\"{s}\" already exists", .{typed});
                return ed.reopenBrowser(null);
            }
            if (std.fs.path.dirname(dest)) |dir| cwd.createDirPath(ed.io, dir) catch {};
            cwd.writeFile(ed.io, .{ .sub_path = dest, .data = "" }) catch |err| {
                ed.setMessage(.err, "could not make the file: {s}", .{@errorName(err)});
                return ed.reopenBrowser(null);
            };
            // A new file is for writing in: open it.
            return ed.openFile(dest);
        },
        .browse_rename, .browse_move => {
            const old = ed.browse_target orelse return;
            if (std.mem.eql(u8, old, dest)) return ed.reopenBrowser(null);
            if (ed.fileExists(dest)) {
                ed.setMessage(.err, "\"{s}\" already exists", .{typed});
                return ed.reopenBrowser(null);
            }
            if (std.fs.path.dirname(dest)) |dir| cwd.createDirPath(ed.io, dir) catch {};
            Io.Dir.rename(cwd, old, cwd, dest, ed.io) catch |err| {
                ed.setMessage(.err, "could not move it: {s}", .{@errorName(err)});
                return ed.reopenBrowser(null);
            };
            try ed.retargetBuffers(old, dest);
            ed.setMessage(.info, "\"{s}\" is now \"{s}\"", .{ std.fs.path.basename(old), typed });
        },
        else => unreachable,
    }
    // Show the result where it now is.
    if (std.fs.path.dirname(dest)) |dir| ed.setBrowseDir(dir) catch {};
    var sel_buf: [Io.Dir.max_name_bytes + 1]u8 = undefined;
    const base = std.fs.path.basename(dest);
    const st = cwd.statFile(ed.io, dest, .{}) catch null;
    const is_dir = st != null and st.?.kind == .directory;
    const sel = if (is_dir) std.fmt.bufPrint(&sel_buf, "{s}/", .{base}) catch base else base;
    ed.reopenBrowser(sel);
}

/// Open buffers of a file (or of files in a folder) that moved from `old`
/// to `new` follow it.
fn retargetBuffers(ed: *Editor, old: []const u8, new: []const u8) !void {
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        const inside = abs.len > old.len and std.mem.startsWith(u8, abs, old) and abs[old.len] == '/';
        if (!std.mem.eql(u8, abs, old) and !inside) continue;
        const moved = try std.mem.concat(ed.gpa, u8, &.{ new, abs[old.len..] });
        defer ed.gpa.free(moved);
        const norm = try ed.normalizePath(moved);
        defer ed.gpa.free(norm);
        try ed.setBufferPath(b, norm);
    }
}

/// The delete confirmation answered: removes `browse_target` (a folder with
/// everything in it) and closes unmodified buffers of what is gone.
pub fn browseRemove(ed: *Editor, confirmed: bool) !void {
    const target = ed.browse_target orelse return;
    defer ed.reopenBrowser(null);
    if (!confirmed) return ed.setMessage(.info, "kept \"{s}\"", .{std.fs.path.basename(target)});
    const cwd = Io.Dir.cwd();
    const st = cwd.statFile(ed.io, target, .{}) catch null;
    const is_dir = st != null and st.?.kind == .directory;
    (if (is_dir) cwd.deleteTree(ed.io, target) else cwd.deleteFile(ed.io, target)) catch |err|
        return ed.setMessage(.err, "could not delete: {s}", .{@errorName(err)});
    var i = ed.buffers.items.len;
    while (i > 0) {
        i -= 1;
        if (i >= ed.buffers.items.len) continue;
        const b = ed.buffers.items[i];
        const path = b.path orelse continue;
        if (b.modified) continue;
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        const inside = abs.len > target.len and std.mem.startsWith(u8, abs, target) and abs[target.len] == '/';
        if (std.mem.eql(u8, abs, target) or inside) try ed.killBuffer(b);
    }
    ed.setMessage(.info, "deleted \"{s}\"", .{std.fs.path.basename(target)});
}

/// `x` / `dd` in the buffer picker: closes the selected buffer, staying in
/// the list.
pub fn pickerKillBuffer(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .buffers) return;
    p.sync();
    const item = p.itemAt(p.selected) orelse return;
    if (item.id >= ed.buffers.items.len) return;
    const b = ed.buffers.items[item.id];
    if (b.modified) return ed.setMessage(.err, "\"{s}\" has unsaved changes: save it first", .{b.displayName()});
    try ed.killBuffer(b);
    try p.restart(null);
    ed.mode = .picker_normal;
}

/// Accepts the selected row: closes the picker, then acts on the choice
/// (which may open another picker).
pub fn acceptPicker(ed: *Editor) !void {
    return ed.acceptPickerAs(.here);
}

/// Accepts the selection, opening it in `target` (<C-v>: a split to the
/// right, <C-s>: below).
pub fn acceptPickerAs(ed: *Editor, target: OpenTarget) !void {
    const p = ed.picker orelse return;
    const choice = try p.choice();
    defer choice.deinit(ed.gpa);
    // The toggles: flip the row, list them again with the new states.
    if (sources.staysOpen(p.kind)) {
        switch (choice) {
            .item => |c| try sources.accept(c.kind, ed, c.item),
            else => {},
        }
        if (ed.picker == p) try p.refill();
        return;
    }
    const deferred = ed.deferred_target;
    ed.deferred_target = null;
    ed.closePicker();
    try ed.runChoice(choice, if (target == .here) deferred orelse .here else target);
}

/// Sources whose choices open something somewhere (files, places).
pub fn opensPlaces(kind: Picker.Kind) bool {
    return switch (kind) {
        .files, .buffers, .lines, .grep, .locations, .diagnostics, .symbols, .git_changes, .browse, .jumps, .run_errors, .projects, .recent, .frecent, .todos, .quickfix, .files_anywhere, .workspace_symbols, .marks => true,
        else => false,
    };
}

/// <Tab> in a picker: asks where to open the selection.
pub fn pickerOpenMenu(ed: *Editor) !void {
    const p = ed.picker orelse return;
    const has_actions = sources.itemActions(p.kind).len > 0;
    if (!opensPlaces(p.kind) and !has_actions) return;
    const choice = try p.choice();
    if (choice == .none and !has_actions) return;
    if (ed.pending_choice) |old| old.deinit(ed.gpa);
    ed.pending_choice = choice;
    ed.action_origin = p.kind;
    ed.action_query.clearRetainingCapacity();
    try ed.action_query.appendSlice(ed.gpa, p.query.items());
    ed.closePicker();
    try ed.openPicker(.open_in, "");
}

/// The <Tab> menu ran action `i` of the picker it came from, on the row
/// waiting in `pending_choice`; one that keeps that picker open brings it
/// back.
pub fn runPendingAction(ed: *Editor, i: usize) !void {
    const origin = ed.action_origin orelse return;
    const list = sources.itemActions(origin);
    if (i >= list.len) return;
    const a = &list[i];
    const choice = ed.pending_choice orelse Picker.Choice.none;
    ed.pending_choice = null;
    defer choice.deinit(ed.gpa);
    const item: ?Picker.ItemsStore.Item = switch (choice) {
        .item => |c| c.item,
        else => null,
    };
    if (item == null and !a.any) return;
    if (a.stay) {
        // Its rows are needed (a buffer's index): reopen it, then act.
        const query = try ed.gpa.dupe(u8, ed.action_query.items);
        defer ed.gpa.free(query);
        try a.run(ed, item);
        try ed.openPicker(origin, query);
        if (ed.picker) |np| np.selected = 0;
        if (!sources.startsNormal(origin)) ed.mode = .picker_normal;
        return;
    }
    try a.run(ed, item);
}

/// The "Open in..." menu picked `target` for the waiting choice.
pub fn openPendingIn(ed: *Editor, target: OpenTarget) !void {
    const choice = ed.pending_choice orelse return;
    ed.pending_choice = null;
    defer choice.deinit(ed.gpa);
    try ed.runChoice(choice, target);
}

fn runChoice(ed: *Editor, choice: Picker.Choice, target_in: OpenTarget) anyerror!void {
    const kind: ?Picker.Kind = switch (choice) {
        .none => null,
        .item => |c| c.kind,
        .create => |c| c.kind,
    };
    var target = target_in;
    if (kind) |k| {
        if (!opensPlaces(k)) target = .here;
        // A project opens into a split once a file is picked in it.
        if (k == .projects and target != .here) {
            ed.deferred_target = target;
            target = .here;
        }
        // Entering a folder in the explorer isn't opening anything yet.
        if (k == .browse and choice == .item and std.mem.endsWith(u8, choice.item.item.text, "/")) {
            if (target != .here) ed.deferred_target = target;
            target = .here;
        }
    }
    // Pickers that take you somewhere are jumps.
    if (kind) |k| switch (k) {
        .files, .buffers, .lines, .grep, .locations, .diagnostics, .symbols, .git_changes, .recent, .frecent, .todos => ed.pushJump(),
        else => {},
    };
    if (target.dir()) |d| try ed.splitWindow(d);
    switch (choice) {
        .none => {},
        .item => |c| try @import("picker/sources.zig").accept(c.kind, ed, c.item),
        .create => |c| try @import("picker/sources.zig").create(c.kind, ed, c.query),
    }
    // A picker that took you to a line shows it in the middle of the window,
    // with its surroundings (pickers that open a file leave its view as it was).
    if (choice == .item) switch (choice.item.kind) {
        .lines, .grep, .todos, .locations, .diagnostics, .symbols, .workspace_symbols, .jumps, .marks, .quickfix, .run_errors => ed.centerCursor(),
        else => {},
    };
}

/// Scrolls so the cursor's row is in the middle of the window (`zz`).
pub fn centerCursor(ed: *Editor) void {
    ed.setTop(ed.stepRows(ed.cursorRow(), -@as(isize, @intCast(ed.view.rows / 2))));
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
fn remember(ed: *Editor, kind: Message.Kind, s: []const u8) void {
    if (s.len == 0) return;
    if (ed.history.items.len > 0) {
        const last = ed.history.items[ed.history.items.len - 1];
        if (last.kind == kind and std.mem.eql(u8, last.text, s)) return;
    }
    const owned = ed.gpa.dupe(u8, s) catch return;
    if (ed.history.items.len >= max_history) ed.gpa.free(ed.history.orderedRemove(0).text);
    ed.history.append(ed.gpa, .{ .kind = kind, .text = owned }) catch ed.gpa.free(owned);
}

// ---------------------------------------------------------------------------
// Notifications (mini.notify): toasts at the top right for things that
// happen on their own, fading after a few seconds.

fn timeAfter(ed: *Editor, ms: i64) Io.Timestamp {
    const now = Io.Timestamp.now(ed.io, .awake);
    return .{ .nanoseconds = now.nanoseconds + @as(i96, ms) * std.time.ns_per_ms };
}

fn pushToast(ed: *Editor, t: Toast) void {
    if (ed.toasts.items.len >= max_toasts) _ = ed.toasts.orderedRemove(0);
    ed.toasts.append(ed.gpa, t) catch return;
    ed.wake_fn();
}

pub fn notify(ed: *Editor, kind: Message.Kind, comptime fmt: []const u8, args: anytype) void {
    var t: Toast = .{ .kind = kind, .expires = ed.timeAfter(Toast.lifetime_ms) };
    t.set(fmt, args);
    ed.remember(kind, t.text());
    ed.pushToast(t);
}

/// A notification for work in progress, updated in place: the same `key`
/// changes its text; `busy` false ends it (it lingers a moment, then goes).
pub fn progress(ed: *Editor, key: u64, busy: bool, comptime fmt: []const u8, args: anytype) void {
    for (ed.toasts.items) |*t| if (t.key == key and key != 0) {
        t.set(fmt, args);
        t.busy = busy;
        t.expires = ed.timeAfter(1500);
        return ed.wake_fn();
    };
    if (!busy) return;
    var t: Toast = .{ .key = key, .busy = true };
    t.set(fmt, args);
    ed.pushToast(t);
}

fn pruneToasts(ed: *Editor) void {
    var i: usize = 0;
    while (i < ed.toasts.items.len) {
        const t = ed.toasts.items[i];
        if (!t.busy and t.expires.nanoseconds <= ed.now.nanoseconds) {
            _ = ed.toasts.orderedRemove(i);
        } else i += 1;
    }
}

/// Something on screen is moving (a gliding scroll, a fading toast): the UI
/// should keep drawing frames instead of sleeping until the next key.
pub fn wantsFrames(ed: *const Editor) bool {
    if (ed.view.scroll_offset != 0 or ed.view.scroll_frac != 0) return true;
    for (ed.window_list.items) |w| if (w != ed.window and (w.view.scroll_offset != 0 or w.view.scroll_frac != 0)) return true;
    for (ed.toasts.items) |t| if (!t.busy) return true;
    if (ed.yank_flash != null) return true;
    // Hints waiting out their debounce: a frame has to come to ask for them.
    if (ed.inlayHintsDue()) return true;
    // A guide is waiting out its delay, or growing: frames have to come.
    if (ed.indent_candidate != null) return true;
    if (ed.indent_guide) |g| if (g.growing(ed.now, ed.view.top, ed.view.top + ed.view.rows)) return true;
    return false;
}

/// Decides which indent scope guide is drawn this frame: the cursor's scope
/// once it has been the same for a moment. Moving on to another block hides
/// the guide at once; the new one appears when the cursor settles.
fn tickIndentGuide(ed: *Editor) void {
    const want: ?IndentGuide = blk: {
        if (!ed.options.indent_scope or ed.ghost != null or ed.window.term != null) break :blk null;
        const s = indents.scope(ed.text(), ed.cursorLine(), ed.options.tab_width, true) orelse break :blk null;
        break :blk .{ .buffer = ed.buffer, .scope = s };
    };
    if (IndentGuide.same(want, ed.indent_guide)) {
        if (ed.indent_guide) |*g| g.scope = want.?.scope; // its end may have moved
        ed.indent_candidate = null;
        return;
    }
    ed.indent_guide = null;
    if (want == null) {
        ed.indent_candidate = null;
    } else if (!IndentGuide.same(want, ed.indent_candidate)) {
        ed.indent_candidate = want;
        ed.indent_since = ed.now;
    } else if (ed.indent_since.durationTo(ed.now).nanoseconds >= indent_guide_delay_ms * std.time.ns_per_ms) {
        ed.indent_guide = want;
        ed.indent_guide.?.origin = std.math.clamp(ed.cursorLine(), want.?.scope.first, want.?.scope.last);
        ed.indent_guide.?.born = ed.now;
        ed.indent_candidate = null;
    }
}

// ---------------------------------------------------------------------------
// Smooth scrolling (mini.animate): when a view's top moves, the text is
// drawn offset by the distance and glides into place over a few frames.
// Purely visual: `top` and the cursor are where they are at once.

/// Advances every window's glide by `dt` seconds. Called once per frame by
/// the windowed UI (never in a terminal or in tests).
pub fn animate(ed: *Editor, dt: f32) void {
    const step = @min(dt, 1.0 / 30.0);
    for (ed.window_list.items) |w| ed.animateView(ed.windowView(w), ed.windowBuffer(w), w == ed.window, step);
    if (ed.cmd_float) |f| {
        ed.windowView(f).scroll_offset = 0;
        ed.windowView(f).scroll_frac = 0;
    }
}

/// The mouse wheel: scrolls the focused window by `delta` rows, fractions
/// included. Whole lines move `top` (and glide like any scroll); the rest is
/// shown as a partial line, so a touchpad or smooth wheel moves the text
/// continuously instead of a line at a time.
pub fn scrollSmooth(ed: *Editor, delta: f32) void {
    if (delta == 0) return;
    const v = &ed.view;
    if (!ed.options.smooth_scroll) {
        // Whole lines only; fractions add up out of sight.
        if ((delta > 0) != (ed.wheel_rest > 0)) ed.wheel_rest = 0;
        ed.wheel_rest += delta;
        const whole = @trunc(ed.wheel_rest);
        ed.wheel_rest -= whole;
        if (whole != 0) ed.scrollLines(@intFromFloat(whole));
        return;
    }
    v.scroll_idle = 0;
    const top = ed.topRow();
    const at_edge = if (delta < 0) ed.prevRow(top).eql(top) else ed.nextRow(top).eql(top);
    // Turning back, or nowhere left to go: the partial line becomes part of
    // the glide (the text doesn't jump) and eases back into place.
    if (at_edge or (delta > 0) != (v.scroll_frac > 0)) {
        v.scroll_offset -= v.scroll_frac;
        v.scroll_frac = 0;
        if (at_edge) return;
    }
    const frac = v.scroll_frac + delta;
    const whole = @trunc(frac);
    if (whole != 0) ed.scrollLines(@intFromFloat(whole));
    // The text must not move at the moment of input: what the target gained
    // is added to the glide's distance (`animate` adds the whole lines when
    // it sees `top` moved; the partial line is added here).
    v.scroll_offset += (frac - whole) - v.scroll_frac;
    v.scroll_frac = frac - whole;
}

/// The glide's time constant in seconds: about a fifth of a second to settle.
const scroll_glide = 0.06;

/// How long the wheel rests before a partial line settles.
const wheel_settle = 0.12;

fn animateView(ed: *Editor, v: *View, b: *const Buffer, focused: bool, dt: f32) void {
    // A scroll can run this many screens ahead of the drawn text before the
    // text jumps to keep up.
    const max_rows = v.rows * 4;
    const cap: f32 = @floatFromInt(max_rows);
    // The wheel has come to rest between two lines: settle on the nearer.
    v.scroll_idle += dt;
    if (v.scroll_frac != 0 and v.scroll_idle > wheel_settle and v.seen_buffer == b) {
        if (focused and @abs(v.scroll_frac) >= 0.5) ed.scrollLines(if (v.scroll_frac > 0) 1 else -1);
        v.scroll_offset -= v.scroll_frac;
        v.scroll_frac = 0;
    }
    if (!ed.options.smooth_scroll or v.seen_buffer != b) {
        v.scroll_offset = 0;
        v.scroll_frac = 0;
    } else if (v.top != v.seen_top) {
        const old: Row = .{ .line = v.seen_top };
        const new: Row = .{ .line = v.top };
        // Folds and ghost lines count as the rows they take (for the
        // focused window, whose buffer is the current one).
        const rows: f32 = if (focused)
            @floatFromInt(if (old.before(new)) ed.rowsFrom(old, new, max_rows) else ed.rowsFrom(new, old, max_rows))
        else
            @min(@as(f32, @floatFromInt(if (v.top > v.seen_top) v.top - v.seen_top else v.seen_top - v.top)), cap);
        v.scroll_offset = std.math.clamp(v.scroll_offset + (if (old.before(new)) rows else -rows), -cap, cap);
    }
    v.seen_top = v.top;
    v.seen_buffer = b;
    // Every frame closes the same share of what is left, also while more
    // scrolling keeps arriving (a held key, a turning wheel): the text
    // then moves at an even speed a little behind, instead of in steps.
    if (v.scroll_offset != 0) {
        v.scroll_offset *= @exp(-dt / scroll_glide);
        if (@abs(v.scroll_offset) < 0.02) v.scroll_offset = 0;
    }
}

// ---------------------------------------------------------------------------
// State files, visits, sessions, themes

/// `$XDG_STATE_HOME/zile/<name>` (or under `state_dir`). Caller frees. Null
/// when there is nowhere to keep state (and always in tests without a
/// `state_dir`, so they never touch the real one).
pub fn statePath(ed: *Editor, name: []const u8) ?[]u8 {
    if (ed.state_dir) |d| return std.fs.path.join(ed.gpa, &.{ d, name }) catch null;
    if (@import("builtin").is_test) return null;
    return RunMemory.statePath(ed.gpa, name);
}

pub fn unixNow(ed: *Editor) i64 {
    return Io.Timestamp.now(ed.io, .real).toSeconds();
}

/// The visit history, read from disk the first time.
pub fn loadedVisits(ed: *Editor) *Visits {
    if (!ed.visits.loaded) {
        ed.visits.loaded = true;
        if (ed.statePath("visits")) |p| {
            defer ed.gpa.free(p);
            ed.visits.load(ed.gpa, ed.io, p);
        }
    }
    return &ed.visits;
}

fn freeDiagnosticList(gpa: Allocator, list: []Lsp.Diagnostic) void {
    for (list) |d| gpa.free(d.message);
    gpa.free(list);
}

/// Standalone Zig files (no build.zig): compile-checked when opened and
/// saved; finished checks become the file's diagnostics.
fn tickZigChecks(ed: *Editor) void {
    var i: usize = 0;
    while (i < ed.zig_checks.items.len) {
        const zc = ed.zig_checks.items[i];
        if (!zc.job.done.load(.acquire)) {
            i += 1;
            continue;
        }
        _ = ed.zig_checks.swapRemove(i);
        defer zc.job.destroy();
        if (!ed.bufferAlive(zc.buffer)) continue;
        const diags = zc.job.diagnostics.toOwnedSlice(ed.gpa) catch continue;
        for (ed.check_results.items) |*r| if (r.buffer == zc.buffer) {
            freeDiagnosticList(ed.gpa, r.diags);
            r.diags = diags;
            r.libc = zc.job.needed_libc;
            break;
        } else ed.check_results.append(ed.gpa, .{ .buffer = zc.buffer, .diags = diags, .libc = zc.job.needed_libc }) catch freeDiagnosticList(ed.gpa, diags);
    }
    // Results of closed buffers go.
    var k: usize = 0;
    while (k < ed.check_results.items.len) {
        if (ed.bufferAlive(ed.check_results.items[k].buffer)) {
            k += 1;
        } else freeDiagnosticList(ed.gpa, ed.check_results.swapRemove(k).diags);
    }
    for (ed.buffers.items) |b| {
        if (b.checked == b.saves) continue;
        const path = b.path orelse continue;
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        const running = for (ed.zig_checks.items) |zc| {
            if (zc.buffer == b) break true;
        } else false;
        if (running) continue; // the next tick after it, for the newer save
        b.checked = b.saves;
        const abs = ed.absolutePath(path) catch continue;
        defer ed.gpa.free(abs);
        if (!ZigCheck.wanted(ed.io, abs)) continue;
        const libc = for (ed.check_results.items) |r| {
            if (r.buffer == b) break r.libc;
        } else false;
        // The file as it is on disk is what the compiler reads.
        const job = ZigCheck.start(ed.gpa, ed.io, abs, b.text.slice(0, b.text.len()), libc, ed.wake_fn) catch continue;
        ed.zig_checks.append(ed.gpa, .{ .buffer = b, .job = job }) catch job.destroy();
    }
}

/// Leaving `b` (for another buffer or window): it is saved if modified
/// (autosave) and its cursor position remembered.
fn leaveBuffer(ed: *Editor, b: *Buffer) void {
    ed.rememberPosition(b);
    ed.autosave(b);
}

/// zile lost focus: every modified file is saved.
pub fn focusLost(ed: *Editor) void {
    for (ed.buffers.items) |b| ed.autosave(b);
}

fn autosave(ed: *Editor, b: *Buffer) void {
    if (!ed.options.autosave or !b.modified or b.path == null or ed.replaying) return;
    // Claude's proposals are reviewed, not saved behind your back.
    if (ed.claude) |c| if (c.diffFor(b) != null) return;
    if (!ed.bufferAlive(b)) return;
    _ = b.save(ed.gpa, ed.io) catch return;
    if (ed.lspFor(b)) |l| l.didSave(b);
}

pub fn bufferAlive(ed: *const Editor, b: *const Buffer) bool {
    return std.mem.indexOfScalar(*Buffer, ed.buffers.items, @constCast(b)) != null;
}

/// Notes where `b`'s cursor is (the reopen position).
fn rememberPosition(ed: *Editor, b: *Buffer) void {
    const path = b.path orelse return;
    const cursor = if (b == ed.buffer) ed.view.cursor else b.saved.cursor;
    const t = &b.text;
    const pos = @min(cursor, t.len());
    const line = t.lineOf(pos);
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    ed.loadedVisits().setPosition(abs, line, pos - t.lineStart(line));
}

/// A file just loaded: the cursor where it was left, and its undo history
/// from the last session (if the file is still as it was then).
fn restoreFileState(ed: *Editor, b: *Buffer) void {
    const path = b.path orelse return;
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    if (ed.loadedVisits().get(abs)) |e| {
        const t = &b.text;
        const line = @min(@as(usize, e.line), t.lineCount() - 1);
        const cursor = t.lineStart(line) + @min(@as(usize, e.col), t.lineLen(line));
        b.saved = .{ .cursor = cursor, .top = line -| 10 };
    }
    const undo_path = ed.undoPath(abs) orelse return;
    defer ed.gpa.free(undo_path);
    const data = Io.Dir.cwd().readFileAlloc(ed.io, undo_path, ed.gpa, .limited(64 << 20)) catch return;
    defer ed.gpa.free(data);
    const hash = std.hash.Wyhash.hash(0, b.text.slice(0, b.text.len()));
    const h = (History.deserialize(ed.gpa, data, hash) catch return) orelse return;
    b.history.deinit(ed.gpa);
    b.history = h;
}

/// `$XDG_STATE_HOME/zile/undo/<hash of the path>`. Caller frees.
fn undoPath(ed: *Editor, abs: []const u8) ?[]u8 {
    var name: [32]u8 = undefined;
    const n = std.fmt.bufPrint(&name, "undo/{x:0>16}", .{std.hash.Wyhash.hash(0, abs)}) catch return null;
    return ed.statePath(n);
}

/// Each frame: the undo history of every file saved since is written
/// out, so it survives closing the file.
fn keepUndoHistories(ed: *Editor) void {
    for (ed.buffers.items) |b| {
        if (b.saves == b.undo_kept) continue;
        const path = b.path orelse continue;
        const data = (b.history.serialize(ed.gpa, std.hash.Wyhash.hash(0, b.text.slice(0, b.text.len()))) catch continue) orelse continue;
        defer ed.gpa.free(data);
        b.undo_kept = b.saves;
        if (data.len > 32 << 20) continue;
        const abs = ed.absolutePath(path) catch continue;
        defer ed.gpa.free(abs);
        const undo_path = ed.undoPath(abs) orelse continue;
        defer ed.gpa.free(undo_path);
        if (std.fs.path.dirname(undo_path)) |d| Io.Dir.cwd().createDirPath(ed.io, d) catch continue;
        Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = undo_path, .data = data }) catch {};
    }
}

fn recordVisit(ed: *Editor, b: *const Buffer) void {
    const path = b.path orelse return;
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    const v = ed.loadedVisits();
    v.record(ed.gpa, abs, ed.unixNow()) catch return;
    if (v.unsaved >= 8) ed.saveVisits();
}

/// Where each open file's cursor is, for next time (on the way out, while
/// the buffers are still there).
pub fn rememberPositions(ed: *Editor) void {
    for (ed.buffers.items) |b| ed.rememberPosition(b);
}

pub fn saveVisits(ed: *Editor) void {
    if (ed.visits.unsaved == 0) return;
    const p = ed.statePath("visits") orelse return;
    defer ed.gpa.free(p);
    ed.visits.save(ed.gpa, ed.io, p, ed.unixNow());
}

/// Saves the current project's session (`SPC p s`, and on the way out).
pub fn saveSession(ed: *Editor, report: bool) void {
    const n = Session.save(ed) catch |err| {
        if (report) ed.setMessage(.err, "could not save the session: {s}", .{@errorName(err)});
        return;
    };
    if (!report) return;
    if (n == 0) ed.setMessage(.info, "no files of this project are open: nothing to save", .{}) else ed.setMessage(.info, "session saved: {d} file(s)", .{n});
}

/// Restores `root`'s session. False when it has none.
pub fn restoreSession(ed: *Editor, root: []const u8) bool {
    const n = Session.restore(ed, root) catch 0;
    if (n == 0) return false;
    ed.setMessage(.info, "session restored: {d} file(s)", .{n});
    return true;
}

fn hasBuffersIn(ed: *const Editor, p: *const Project) bool {
    for (ed.buffers.items) |b| if (b.project == p) return true;
    return false;
}

/// Picks colour scheme `i` and remembers it for the next start.
pub fn setTheme(ed: *Editor, i: usize) void {
    if (i >= ed.theme_names.len) return;
    ed.theme_index = i;
    ed.theme_before = i;
    const p = ed.statePath("theme") orelse return;
    defer ed.gpa.free(p);
    if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(ed.io, dir) catch return;
    Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = p, .data = ed.theme_names[i] }) catch {};
}

/// The colour scheme chosen last time, if it still exists.
pub fn loadTheme(ed: *Editor) void {
    const p = ed.statePath("theme") orelse return;
    defer ed.gpa.free(p);
    const data = Io.Dir.cwd().readFileAlloc(ed.io, p, ed.gpa, .limited(256)) catch return;
    defer ed.gpa.free(data);
    const name = std.mem.trim(u8, data, " \n");
    for (ed.theme_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
        ed.theme_index = i;
        ed.theme_before = i;
    };
}

/// The start screen (mini.starter): recent files and first steps.
pub fn openStarter(ed: *Editor) !void {
    try ed.openPicker(.start, "");
}

// ---------------------------------------------------------------------------
// The colour wheel (`SPC l c`): see ColorPicker.zig.

/// Opens the wheel on the colour literal at the cursor, else the next one on
/// the line, else the last one before it.
pub fn openColorPicker(ed: *Editor) void {
    const t = ed.text();
    const line = ed.cursorLine();
    const ls = t.lineStart(line);
    const col = ed.view.cursor - ls;
    const bytes = t.lineSlice(line);
    var buf: [64]hipatterns.Match = undefined;
    var found: ?hipatterns.Match = null;
    for (hipatterns.scan(bytes, &buf)) |m| {
        if (m.kind == .todo) continue;
        found = m;
        if (m.end > col) break; // at or after the cursor
    }
    const m = found orelse return ed.setMessage(.info, "no colour on this line (#rrggbb, #rgb, #rrggbbaa or 0xRRGGBB)", .{});
    const parsed = ColorPicker.parse(bytes[m.start..m.end]) orelse return;
    ed.color_picker = .init(ed.buffer, ls + m.start, ls + m.end, parsed);
    ed.setCursor(ls + m.start);
    ed.clearMessage();
}

/// Keys while the wheel is open. False when it isn't (or just went away
/// because the text under it changed).
fn colorKey(ed: *Editor, ev: KeyEvent) bool {
    const p = &(ed.color_picker orelse return false);
    if (p.buffer != ed.buffer or p.version != ed.buffer.edit_version) {
        ed.color_picker = null;
        return false;
    }
    const action: ColorPicker.Action = switch (ev.key) {
        .special => |s| switch (s) {
            .escape => .cancel,
            .enter => .apply,
            else => .none,
        },
        .codepoint => |cp| if (ev.mods.ctrl or ev.mods.alt) .none else p.key(cp),
    };
    var buf: [16]u8 = undefined;
    switch (action) {
        .none => {},
        .cancel => ed.color_picker = null,
        .yank => {
            const literal = p.write(&buf);
            ed.registers.store(null, .yank, literal, false) catch {};
            ed.setMessage(.info, "copied {s}", .{literal});
        },
        .apply => {
            const literal = p.write(&buf);
            const start = p.start;
            const end = p.end;
            ed.color_picker = null;
            if (!std.mem.eql(u8, literal, ed.text().slice(start, end))) {
                ed.deleteRange(start, end) catch return true;
                ed.insertAt(start, literal) catch return true;
            }
            ed.setCursor(start);
            ed.afterKey(); // one undo step
            ed.setMessage(.info, "colour: {s}", .{literal});
        },
    }
    ed.wake_fn();
    return true;
}

// ---------------------------------------------------------------------------
// Bracketed jumps (mini.bracketed): `]d` `[d` diagnostics, `]x` `[x`
// conflict markers, `]c` `[c` comment blocks.

fn goLine(ed: *Editor, line: usize, col: usize) void {
    const t = ed.text();
    const l = @min(line, t.lineCount() - 1);
    ed.ghost = null;
    ed.revealLine(l);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
}

pub fn jumpDiagnostic(ed: *Editor, forward: bool) void {
    const diags = ed.diagnostics(ed.buffer);
    if (diags.len == 0) return ed.setMessage(.info, "no diagnostics in this file", .{});
    const line = ed.cursorLine();
    const col = ed.view.cursor - ed.text().lineStart(line);
    var target: ?*const Lsp.Diagnostic = null;
    for (diags) |*d| {
        const after = d.line > line or (d.line == line and d.col > col);
        const before = d.line < line or (d.line == line and d.col < col);
        if (forward and after) {
            target = d;
            break;
        }
        if (!forward and before) target = d;
    }
    // Past the last one: around to the other end.
    const d = target orelse if (forward) &diags[0] else &diags[diags.len - 1];
    ed.goLine(d.line, d.col);
    ed.setMessage(if (d.severity == .err) .err else .info, "{s}", .{std.mem.sliceTo(d.message, '\n')});
}

fn isConflictMarker(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "<<<<<<< ") or std.mem.startsWith(u8, line, ">>>>>>> ") or
        std.mem.startsWith(u8, line, "||||||| ") or std.mem.eql(u8, line, "=======");
}

pub fn jumpConflict(ed: *Editor, forward: bool) void {
    const t = ed.text();
    var line = ed.cursorLine();
    while (true) {
        if (forward) {
            line += 1;
            if (line >= t.lineCount()) break;
        } else {
            if (line == 0) break;
            line -= 1;
        }
        if (isConflictMarker(t.lineSlice(line))) return ed.goLine(line, 0);
    }
    ed.setMessage(.info, "no more conflict markers", .{});
}

pub fn jumpComment(ed: *Editor, forward: bool) void {
    const t = ed.text();
    const line = comment.nextBlock(t, ed.cursorLine(), textops.commentStyle(ed, ed.cursorLine()), forward) orelse
        return ed.setMessage(.info, "no more comments", .{});
    ed.goLine(line, motions.firstNonBlank(t, line) - t.lineStart(line));
}

// ---------------------------------------------------------------------------
// Git blame (mini.git): who last changed a line. Blame is of HEAD, and
// buffer lines map onto HEAD lines through the diff, so edits don't
// invalidate it.

pub fn blameFor(ed: *const Editor, b: *const Buffer) ?*Blame {
    for (ed.blames.items) |e| if (e.buffer == b) return e.blame;
    return null;
}

/// Starts blaming the current buffer when inline blame is on (each frame;
/// a no-op once started).
fn ensureBlame(ed: *Editor) void {
    if (!ed.options.git_blame) return;
    const b = ed.buffer;
    if (b.git == null or ed.blameFor(b) != null) return;
    const rel = ed.repoPath(b) orelse return;
    defer ed.gpa.free(rel.path);
    const blame = Blame.start(ed.gpa, ed.io, rel.root, rel.path, ed.wake_fn) catch return;
    ed.blames.append(ed.gpa, .{ .buffer = b, .blame = blame }) catch blame.destroy();
}

/// `b`'s repository and its path inside it (`path` is owned by the caller).
fn repoPath(ed: *Editor, b: *const Buffer) ?struct { root: []const u8, path: []u8 } {
    const proj = b.project orelse return null;
    if (!proj.git) return null;
    const abs = ed.absolutePath(b.path orelse return null) catch return null;
    defer ed.gpa.free(abs);
    if (!(abs.len > proj.root.len + 1 and std.mem.startsWith(u8, abs, proj.root))) return null;
    return .{ .root = proj.root, .path = ed.gpa.dupe(u8, abs[proj.root.len + 1 ..]) catch return null };
}

fn dropBlame(ed: *Editor, b: *const Buffer) void {
    for (ed.blames.items, 0..) |e, i| if (e.buffer == b) {
        e.blame.destroy();
        _ = ed.blames.orderedRemove(i);
        return;
    };
}

fn dropAllBlames(ed: *Editor) void {
    for (ed.blames.items) |e| e.blame.destroy();
    ed.blames.clearRetainingCapacity();
}

/// The HEAD line that buffer line `line` still is, or null if the line was
/// added or changed since.
pub fn headLineOf(ed: *const Editor, line: usize) ?usize {
    const g = ed.buffer.git orelse return null;
    var delta: isize = 0;
    for (g.hunks.items) |h| {
        if (line < h.new_start) break;
        if (line < h.new_start + h.new_count) return null;
        delta += @as(isize, @intCast(h.old_count)) - @as(isize, @intCast(h.new_count));
    }
    return @intCast(@as(isize, @intCast(line)) + delta);
}

pub const BlameLine = union(enum) {
    /// Still being computed, or not a tracked file.
    unknown,
    uncommitted,
    commit: *const Blame.Commit,
};

/// Who last changed the current buffer's line `line`.
pub fn blameLine(ed: *const Editor, line: usize) BlameLine {
    const blame = ed.blameFor(ed.buffer) orelse return .unknown;
    if (!blame.done.load(.acquire)) return .unknown;
    const head = ed.headLineOf(line) orelse return .uncommitted;
    return if (blame.at(head)) |c| .{ .commit = c } else .unknown;
}

/// `SPC g l`: the commit that last changed the cursor's line, in a popup.
pub fn showLineCommit(ed: *Editor) !void {
    const gpa = ed.gpa;
    const rel = ed.repoPath(ed.buffer) orelse return ed.setMessage(.info, "not a file in a git repository", .{});
    defer gpa.free(rel.path);
    const head = ed.headLineOf(ed.cursorLine()) orelse return ed.setMessage(.info, "this line isn't committed yet", .{});
    var range_buf: [48]u8 = undefined;
    const range = try std.fmt.bufPrint(&range_buf, "{d},{d}", .{ head + 1, head + 1 });
    const blamed = std.process.run(gpa, ed.io, .{
        .argv = &.{ "git", "blame", "--porcelain", "-L", range, "HEAD", "--", rel.path },
        .cwd = .{ .path = rel.root },
    }) catch |err| return ed.setMessage(.err, "git blame: {s}", .{@errorName(err)});
    defer gpa.free(blamed.stdout);
    defer gpa.free(blamed.stderr);
    if (!blamed.term.success() or blamed.stdout.len < 40) return ed.setMessage(.err, "git blame: {s}", .{std.mem.sliceTo(blamed.stderr, '\n')});
    const shown = std.process.run(gpa, ed.io, .{
        .argv = &.{ "git", "show", "--stat", "--date=relative", "--format=%h  %an, %ad%n%n%B", blamed.stdout[0..40] },
        .cwd = .{ .path = rel.root },
    }) catch |err| return ed.setMessage(.err, "git show: {s}", .{@errorName(err)});
    defer gpa.free(shown.stdout);
    defer gpa.free(shown.stderr);
    try ed.showHover(std.mem.trim(u8, shown.stdout, " \n"));
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

/// A test editor whose buffer is a (never written) file named `path`, so it
/// gets that language's syntax tree and settings.
fn testEditorAs(path: []const u8, content: []const u8) !Editor {
    var ed = try testEditor(content);
    errdefer ed.deinit();
    ed.buffer.path = try ed.gpa.dupe(u8, path);
    ed.buffer.syntax = Syntax.forPath(path);
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

test "leader menus: quit refuses unsaved changes, SPC Q Q forces" {
    var ed = try testEditor("x");
    defer ed.deinit();
    try ed.feed("ia<Esc><Space>Q");
    try testing.expectEqual(.leader_quit, ed.picker.?.kind); // the quit menu
    try ed.feed("<Esc><Space>q"); // smart close, last buffer: quit, but it's unsaved
    try testing.expect(!ed.should_quit);
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("<Space>QQ");
    try testing.expect(ed.should_quit);
}

test "SPC q: closes the window, then buffers, then the editor" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile("zile-test-a.txt");
    try ed.openFile("zile-test-b.txt");
    try ed.feed("<cmd:split_right>");
    try ed.feed("<Space>q"); // two windows: the focused one goes
    try testing.expectEqual(1, ed.window_list.items.len);
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.feed("<Space>q"); // one window, two buffers: the buffer goes
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expect(!ed.should_quit);
    try ed.feed("<Space>q"); // last of everything: quit
    try testing.expect(ed.should_quit);
}

test "files: SPC SPC lists the project's folder; typing finds files below it; src/ goes in" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    settlePicker(&ed);
    const p = ed.picker.?;
    // Nothing typed: just the folder's own entries (folders first).
    try testing.expect(std.mem.endsWith(u8, p.itemAt(0).?.text, "/"));
    const entries = p.rowCount();
    try testing.expect(entries < 100);
    for (0..entries) |i| try testing.expect(std.mem.indexOfScalar(u8, std.mem.trimEnd(u8, p.itemAt(i).?.text, "/"), '/') == null);
    // Typing: a file deep inside comes up.
    try ed.feed("pairs.zig");
    settlePicker(&ed);
    try testing.expectEqualStrings("src/pairs.zig", ed.picker.?.itemAt(0).?.text);
    // src/ goes into that folder; its entries again.
    try ed.feed("<C-u>src/");
    settlePicker(&ed);
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/src"));
    try ed.feed("Editor.z");
    settlePicker(&ed);
    try testing.expectEqualStrings("Editor.zig", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/Editor.zig"));
}

test "leader menu: rows keep their keys; a selection survives the menus" {
    var ed = try testEditor("hello world");
    defer ed.deinit();
    try ed.feed("<Space>");
    try testing.expectEqual(.leader, ed.picker.?.kind);
    try testing.expectEqual(Mode.picker_normal, ed.mode);
    try ed.feed("t"); // SPC t: the toggles
    try testing.expectEqual(.toggles, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // Visual, through two menus (SPC f f): the selection is the query.
    try ed.feed("0viw<Space>ff");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expectEqualStrings("hello", ed.picker.?.query.items());
    try ed.feed("<Esc><Esc>");
    // i filters the leader menu (its / is grep).
    try ed.feed("<Space>iwindo");
    settlePicker(&ed);
    try testing.expectEqualStrings("Windows", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
}

test "escape leaves the leader menu" {
    var ed = try testEditor("abc");
    defer ed.deinit();
    try ed.feed("<Space>f<Esc>");
    try testing.expectEqual(0, ed.pending_len);
    try testing.expectEqual(null, ed.picker);
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
    try ed.feed("<Space>fc");
    try testing.expectEqual(.picker, ed.mode);
    try ed.feed("quitwo<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(ed.should_quit);
}

test "prefix switches sources; Esc closes and resume restores" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed(">savefi");
    try testing.expectEqual(.commands, ed.picker.?.kind);
    try testing.expectEqualStrings("savefi", ed.picker.?.activeQuery());
    ed.picker.?.sync();
    try testing.expectEqualStrings("save_file", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
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

    try ed.feed("<Space>b<CR>"); // top entry is the previous buffer
    try testing.expectEqualStrings("edit-test-missing-a.txt", ed.buffer.path.?);

    try ed.feed("<cmd:kill_buffer>");
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
    // On the last pasted line.
    try expectCursor(&ed, 5, 0);
    try ed.feed("ggddP");
    try expectText(&ed, "e f g\nl2\nl3\nl4\nl2\nl3");
    try ed.feed("3dd");
    try expectText(&ed, "l4\nl2\nl3");
}

test "pastes in a row stack in order: the cursor ends on the last pasted line" {
    var ed = try testEditor("a\nb\nend");
    defer ed.deinit();
    try ed.feed("2yyjpp");
    try expectText(&ed, "a\nb\na\nb\na\nb\nend");
    try expectCursor(&ed, 5, 0);
    try ed.feed("u");
    try expectText(&ed, "a\nb\na\nb\nend");
    // P with a count: on the first pasted line (so another P goes above).
    try ed.feed("G2P");
    try expectText(&ed, "a\nb\na\nb\na\nb\na\nb\nend");
    try expectCursor(&ed, 4, 0);
}

test "P in a row stacks in order too: the cursor ends on the first pasted line" {
    var ed = try testEditor("a\nb\nend");
    defer ed.deinit();
    try ed.feed("2yyGPP");
    try expectText(&ed, "a\nb\na\nb\na\nb\nend");
    try expectCursor(&ed, 2, 0);
    // Characters: `P` `P` gives abab, not aabb.
    var ed2 = try testEditor("abX");
    defer ed2.deinit();
    try ed2.feed("y2l$PP");
    try expectText(&ed2, "abababX");
    try expectCursor(&ed2, 0, 2);
}

test "yanking leaves the cursor where it is" {
    var ed = try testEditor("one\n    foo(bar, baz)\nthree\n\nfour");
    defer ed.deinit();
    try ed.feed("j$h"); // on the last `z`
    try ed.feed("yil");
    try expectCursor(&ed, 1, 15);
    try ed.feed("yib");
    try expectCursor(&ed, 1, 15);
    try ed.feed("yip");
    try expectCursor(&ed, 1, 15);
    try ed.feed("yb");
    try expectCursor(&ed, 1, 15);
    // Visual: back to where `v` was pressed, even from the other end.
    try ed.feed("Vjy");
    try expectCursor(&ed, 1, 15);
    try ed.feed("vipy");
    try expectCursor(&ed, 1, 15);
    try testing.expectEqualStrings("one\n    foo(bar, baz)\nthree\n", ed.registers.get(null).?.text);
}

test "replace across the project: from the grep picker, skipping a line and a file" {
    if (!@import("picker/sources.zig").haveRg(testing.io)) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "const foo = 1;\nfn f() void {\n    _ = foo + foo;\n}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "// foo\nconst Foo = 2;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.zig", .data = "foo\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    ed.next_picker_root = dir;
    try ed.openPicker(.grep, "foo");
    try ed.feed("<C-r>");
    try testing.expectEqual(PromptKind.replace, ed.search_prompt.?.kind);
    const r = ed.replace.?;
    r.wait();
    // Lowercase: any case (smart case), so `Foo` too. Lines: a 1, a 3, b 1, b 2, c 1.
    try testing.expectEqual(5, r.matches.items.len);
    try testing.expectEqual(6, r.counts().matches);
    try ed.feed("bar");
    // Skip `const Foo` (b.zig's second line), then all of c.zig.
    try ed.feed("<Down><Down><Down><Tab><S-Tab>");
    try testing.expectEqual(4, r.counts().matches);
    try ed.feed("<CR>");
    try testing.expectEqual(null, ed.replace);
    try testing.expectEqual(Mode.normal, ed.mode);

    const a_path = try std.fs.path.join(gpa, &.{ dir, "a.zig" });
    defer gpa.free(a_path);
    const b_path = try std.fs.path.join(gpa, &.{ dir, "b.zig" });
    defer gpa.free(b_path);
    const c_path = try std.fs.path.join(gpa, &.{ dir, "c.zig" });
    defer gpa.free(c_path);
    const a = ed.bufferForPath(a_path).?;
    try testing.expectEqualStrings("const bar = 1;\nfn f() void {\n    _ = bar + bar;\n}", a.text.slice(0, a.text.len()));
    // Written (autosave, on leaving each file); c.zig untouched.
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "a.zig", gpa, .limited(1024));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("const bar = 1;\nfn f() void {\n    _ = bar + bar;\n}\n", on_disk);
    const c_disk = try tmp.dir.readFileAlloc(testing.io, "c.zig", gpa, .limited(1024));
    defer gpa.free(c_disk);
    try testing.expectEqualStrings("foo\n", c_disk);
    const b = ed.bufferForPath(b_path).?;
    try testing.expectEqualStrings("// bar\nconst Foo = 2;", b.text.slice(0, b.text.len()));
    try testing.expect(ed.bufferForPath(c_path) == null);
    // One undo step per file.
    ed.switchTo(a);
    try ed.feed("u");
    try testing.expectEqualStrings("const foo = 1;\nfn f() void {\n    _ = foo + foo;\n}", a.text.slice(0, a.text.len()));
}

test "replace: Esc goes back to the grep picker with the search" {
    if (!@import("picker/sources.zig").haveRg(testing.io)) return error.SkipZigTest;
    var ed = try testEditor("");
    defer ed.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    ed.next_picker_root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try ed.openPicker(.grep, "needle");
    try ed.feed("<C-r>");
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.replace);
    try testing.expectEqual(null, ed.search_prompt);
    try testing.expectEqualStrings("needle", ed.picker.?.query.items());
}

test "a language server that exits is restarted a few times, then left" {
    var ed = try testEditor("");
    defer ed.deinit();
    for (0..max_lsp_restarts) |n| {
        ed.serverExited(0);
        try testing.expect(!ed.lsp_failed[0]);
        try testing.expectEqual(n + 1, ed.lsp_restarts[0]);
        try testing.expect(std.mem.endsWith(u8, ed.toasts.items[ed.toasts.items.len - 1].text(), "(restarting)"));
    }
    ed.serverExited(0);
    try testing.expect(ed.lsp_failed[0]);
    try testing.expect(std.mem.indexOf(u8, ed.toasts.items[ed.toasts.items.len - 1].text(), "not restarting") != null);
}

test "gp / gP paste a yanked line inline, inside brackets" {
    var ed = try testEditor("    a + b\nfoo();\nbar();");
    defer ed.deinit();
    try ed.feed("yyjf(gp");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar();");
    // On the last pasted character, like p.
    try expectCursor(&ed, 1, 8);
    try ed.feed("jf)gP");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar(a + b);");
    // p still puts the line below.
    try ed.feed("p");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar(a + b);\n    a + b");
    // Charwise text goes in unchanged.
    try ed.feed("ggyiwG$gp");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar(a + b);\n    a + ba");
}

test "statement object: vis/dis/yas take the header line and its block" {
    var ed = try testEditor("fn a() void {\n    if (x) {\n        y();\n    }\n}\n");
    defer ed.deinit();
    try ed.feed("jvis");
    try testing.expectEqual(.visual, ed.mode);
    const r = ed.visualRange();
    try testing.expectEqualStrings("    if (x) {\n        y();\n    }", ed.text().slice(r.start, r.end));
    try testing.expect(r.linewise);
    try ed.feed("<Esc>dis");
    try expectText(&ed, "fn a() void {\n}\n");
    try ed.feed("u");
    try ed.feed("ggjjdas"); // from inside the block
    try expectText(&ed, "fn a() void {\n}\n");
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
    try ed.feed("..");
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

test "v again switches to line mode over all the selected lines" {
    var ed = try testEditor("hello world\nsecond line\nthird");
    defer ed.deinit();
    try ed.feed("wvvd");
    try expectText(&ed, "second line\nthird");
    try ed.feed("vjvd"); // moved: still line mode, both lines
    try expectText(&ed, "");
}

test "autopairs: an opener right before its own closer adds no pair" {
    var ed = try testEditor("}");
    defer ed.deinit();
    try ed.feed("i{<Esc>");
    try expectText(&ed, "{}");
    try ed.feed("A[<Esc>");
    try expectText(&ed, "{}[]"); // another kind still pairs
    try ed.feed("0a{<Esc>");
    try expectText(&ed, "{{}}[]"); // an opener before: it nests
}

test "multicursor: qf in a selection puts cursors on the matches inside it" {
    var ed = try testEditor("a1 a2\nxx a3 a4\na5");
    defer ed.deinit();
    try ed.feed("Vjsa<CR>");
    try testing.expectEqual(3, ed.cursors.items.len); // four matches, not the fifth
    try ed.feed("cZ<Esc>");
    try expectText(&ed, "Z1 Z2\nxx Z3 Z4\na5");
}

test "f searches the line from its start; ; walks on; after an operator it starts at the cursor" {
    var ed = try testEditor("a.b.c.d\nxx");
    defer ed.deinit();
    try ed.feed("$f.");
    try testing.expectEqual(1, ed.view.cursor); // from the left, though the cursor was at the end
    try ed.feed(".");
    try testing.expectEqual(3, ed.view.cursor);
    try ed.feed("0lldf.");
    try expectText(&ed, "a.c.d\nxx"); // from the cursor
}

test ". repeats the last find, or the last change if that came after" {
    var ed = try testEditor("a.b.c.d");
    defer ed.deinit();
    try ed.feed("f..");
    try testing.expectEqual(3, ed.view.cursor); // f. then . : the second dot
    try ed.feed("x"); // a change: . repeats it now
    try expectText(&ed, "a.bc.d");
    try ed.feed(".");
    try expectText(&ed, "a.b.d");
}

test ". and , continue a snipe too" {
    var ed = try testEditor("foo bar baz\nqux bar");
    defer ed.deinit();
    try ed.feed("tbar<CR>");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed(".");
    try testing.expectEqual(16, ed.view.cursor); // the next "bar"
    try ed.feed(",");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed("x.");
    try expectText(&ed, "foo r baz\nqux bar"); // a change: . repeats it
}

test "yanking flashes the range; a delete does not" {
    var ed = try testEditor("one two\nthree");
    defer ed.deinit();
    try ed.feed("yiw");
    try testing.expectEqual(0, ed.yank_flash.?.start);
    try testing.expectEqual(3, ed.yank_flash.?.end);
    ed.yank_flash = null;
    try ed.feed("dw");
    try testing.expect(ed.yank_flash == null);
    try ed.feed("yy");
    try testing.expect(ed.yank_flash.?.linewise);
}

test "comments: <!-- --> in HTML, /* */ in CSS, {/* */} among JSX children" {
    {
        var ed = try testEditorAs("x.html", "<div>\n  <p>hi</p>\n</div>");
        defer ed.deinit();
        try ed.feed("jgcc");
        try expectText(&ed, "<div>\n  <!-- <p>hi</p> -->\n</div>");
        try ed.feed("gcc");
        try expectText(&ed, "<div>\n  <p>hi</p>\n</div>");
    }
    {
        var ed = try testEditorAs("x.css", "a {\n  color: red;\n}");
        defer ed.deinit();
        try ed.feed("jgcc");
        try expectText(&ed, "a {\n  /* color: red; */\n}");
    }
    {
        const src = "const A = () => (\n  <div>\n    <p>hi</p>\n  </div>\n);\nconst b = 1;";
        var ed = try testEditorAs("x.tsx", src);
        defer ed.deinit();
        try ed.feed("jjgcc"); // a child of the <div>
        try expectText(&ed, "const A = () => (\n  <div>\n    {/* <p>hi</p> */}\n  </div>\n);\nconst b = 1;");
        try ed.feed("gcc");
        try expectText(&ed, src);
        try ed.feed("Ggcc"); // plain code
        try expectText(&ed, "const A = () => (\n  <div>\n    <p>hi</p>\n  </div>\n);\n// const b = 1;");
    }
}

test "tags: > closes, </ closes the open one, Enter splits, void and self-closing stay" {
    {
        var ed = try testEditorAs("x.html", "");
        defer ed.deinit();
        try ed.feed("i<lt>div class=\"a>b\">");
        try expectText(&ed, "<div class=\"a>b\"></div>");
        try ed.feed("<CR>");
        try expectText(&ed, "<div class=\"a>b\">\n  \n</div>");
        try ed.feed("<lt>br><Esc>");
        try expectText(&ed, "<div class=\"a>b\">\n  <br>\n</div>"); // void: no </br>
        try ed.feed("o<lt>p><Esc>");
        try expectText(&ed, "<div class=\"a>b\">\n  <br>\n  <p></p>\n</div>");
    }
    {
        var ed = try testEditorAs("x.html", "<ul>\n  <li>one");
        defer ed.deinit();
        try ed.feed("Go<lt>/"); // the <li> is the innermost open one
        try expectText(&ed, "<ul>\n  <li>one\n  </li>");
        try ed.feed("<CR><lt>/");
        try expectText(&ed, "<ul>\n  <li>one\n  </li>\n</ul>"); // at the <ul>'s indentation
    }
    {
        var ed = try testEditorAs("x.tsx", "const a: Array<string = [];\nconst A = () => ");
        defer ed.deinit();
        try ed.feed("GA<lt>View onPress={() => go()}><Esc>");
        try expectText(&ed, "const a: Array<string = [];\nconst A = () => <View onPress={() => go()}></View>");
        try ed.feed("ggf<lt>ea><Esc>"); // a generic: left alone
        try expectText(&ed, "const a: Array<string> = [];\nconst A = () => <View onPress={() => go()}></View>");
    }
    {
        var ed = try testEditorAs("x.tsx", "const f = ");
        defer ed.deinit();
        try ed.feed("A<lt>><Esc>"); // a fragment
        try expectText(&ed, "const f = <></>");
    }
    {
        var ed = try testEditorAs("x.tsx", "const x = <Foo />;");
        defer ed.deinit();
        try ed.feed("$i<lt>b><Esc>"); // after another element: a tag
        try expectText(&ed, "const x = <Foo /><b></b>;");
        try ed.feed("o<lt>Bar /><Esc>"); // self-closing: nothing added
        try expectText(&ed, "const x = <Foo /><b></b>;\n<Bar />");
    }
}

test "tags: editing a tag's name edits its partner, as one undo step" {
    {
        var ed = try testEditorAs("x.html", "<div>\n  <p>hi</p>\n</div>");
        defer ed.deinit();
        try ed.feed("lciwsection<Esc>");
        try expectText(&ed, "<section>\n  <p>hi</p>\n</section>");
        try ed.feed("u");
        try expectText(&ed, "<div>\n  <p>hi</p>\n</div>");
        try ed.feed("G$iaa<Esc>"); // the closing tag works too: </divaa>
        try expectText(&ed, "<divaa>\n  <p>hi</p>\n</divaa>");
        try ed.feed("jkkfpx"); // and in normal mode: x on the <p>
        try expectText(&ed, "<divaa>\n  <>hi</>\n</divaa>");
        try ed.feed("iem<Esc>"); // a name typed into the empty tag: both again
        try expectText(&ed, "<divaa>\n  <em>hi</em>\n</divaa>");
    }
    {
        var ed = try testEditorAs("x.tsx", "const A = () => (\n  <View style={s}>\n    <Text>hi</Text>\n  </View>\n);");
        defer ed.deinit();
        try ed.feed("jfVcwScrollView<Esc>");
        try expectText(&ed, "const A = () => (\n  <ScrollView style={s}>\n    <Text>hi</Text>\n  </ScrollView>\n);");
    }
}

test "tags: a nameless JSX tag (<>, or a name deleted) gets the name on both sides" {
    {
        // A fragment: typing a name into `<>` names `</>` too.
        var ed = try testEditorAs("x.tsx", "const a = <>hi</>;");
        defer ed.deinit();
        try ed.feed("f<lt>aView<Esc>");
        try expectText(&ed, "const a = <View>hi</View>;");
        try ed.feed("u");
        try expectText(&ed, "const a = <>hi</>;");
        // From the closing side too.
        try ed.feed("$F/aText<Esc>");
        try expectText(&ed, "const a = <Text>hi</Text>;");
    }
    {
        // A name deleted, then a new one typed later.
        var ed = try testEditorAs("x.tsx", "const a = <h1>hi</h1>;");
        defer ed.deinit();
        try ed.feed("fhdiw");
        try expectText(&ed, "const a = <>hi</>;");
        try ed.feed("0f<lt>ah2<Esc>");
        try expectText(&ed, "const a = <h2>hi</h2>;");
    }
}

test "emmet: Tab expands an abbreviation in markup, with tab stops" {
    {
        var ed = try testEditorAs("x.html", "<body>\n  \n</body>");
        defer ed.deinit();
        try ed.feed("jAul>li.item$*2<Tab>");
        try expectText(&ed, "<body>\n  <ul>\n    <li class=\"item1\"></li>\n    <li class=\"item2\"></li>\n  </ul>\n</body>");
        try ed.feed("one<Tab>two<Esc>"); // tab stops: the first <li>, then the second
        try expectText(&ed, "<body>\n  <ul>\n    <li class=\"item1\">one</li>\n    <li class=\"item2\">two</li>\n  </ul>\n</body>");
        try ed.feed("ohello<Tab><Esc>"); // prose: a tab, not <hello>
        try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "<hello>") == null);
    }
    {
        var ed = try testEditorAs("x.tsx", "const A = () => (\n  <View>\n    \n  </View>\n);");
        defer ed.deinit();
        try ed.feed("jjAText.title<Tab>Hi<Esc>");
        try expectText(&ed, "const A = () => (\n  <View>\n    <Text className=\"title\">Hi</Text>\n  </View>\n);");
    }
    {
        var ed = try testEditorAs("x.ts", "const x = ");
        defer ed.deinit();
        try ed.feed("Adiv<Tab><Esc>"); // TypeScript without JSX: no markup
        try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "<div>") == null);
    }
}

test "completion between JSX tags offers elements and the file's components" {
    const gpa = testing.allocator;
    var ed = try testEditorAs("x.tsx", "import { View } from \"rn\";\nconst A = () => (\n  <View>\n    \n  </View>\n);");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa, "{\"items\":[]}", .{});
    defer reply.deinit();
    try ed.feed("3jAvie");
    try ed.showCompletion(ed.buffer, ed.view.cursor - 3, reply.value);
    const c = ed.completionShown().?;
    try testing.expectEqualStrings("View", c.current().?.label);
    try ed.feed("<CR>");
    try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "    <View></View>\n") != null);
}

test "completion in CSS: a - keeps the list (background-color, --gap)" {
    const gpa = testing.allocator;
    var ed = try testEditorAs("x.css", "a {\n  \n}");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"background"},{"label":"background-color"},{"label":"border"}]}
    , .{});
    defer reply.deinit();
    try ed.feed("jAba");
    try ed.showCompletion(ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("ckground-");
    const c = ed.completionShown() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("background-color", c.current().?.label);
    try ed.feed("<CR>");
    try testing.expectEqualStrings("  background-color", ed.text().lineSlice(1));
}

test "snippets: the exact trigger first, indented like its line" {
    const gpa = testing.allocator;
    const reply = try std.json.parseFromSlice(std.json.Value, gpa, "{\"items\":[{\"label\":\"useState\"},{\"label\":\"user\"}]}", .{});
    defer reply.deinit();
    {
        var ed = try testEditorAs("x.tsx", "function A() {\n  \n}");
        defer ed.deinit();
        try ed.feed("jAus");
        try ed.showCompletion(ed.buffer, ed.view.cursor - 2, reply.value);
        try testing.expectEqualStrings("us", ed.completionShown().?.current().?.label);
        try ed.feed("<CR>count<Tab>Count<Tab>0<Esc>");
        try expectText(&ed, "function A() {\n  const [count, setCount] = useState(0);\n}");
    }
    {
        var ed = try testEditorAs("x.ts", "function A() {\n  \n}");
        defer ed.deinit();
        try ed.feed("jAtc");
        try ed.showCompletion(ed.buffer, ed.view.cursor - 2, reply.value);
        try testing.expectEqualStrings("tc", ed.completionShown().?.current().?.label);
        try ed.feed("<CR><Esc>");
        try expectText(&ed, "function A() {\n  try {\n    \n  } catch (err) {\n    \n  }\n}");
    }
    {
        var ed = try testEditorAs("x.ts", "");
        defer ed.deinit();
        try ed.feed("ius"); // React Native snippets are for .jsx / .tsx only
        try ed.showCompletion(ed.buffer, 0, reply.value);
        const c = ed.completionShown().?;
        for (c.shown.items) |i| try testing.expect(!std.mem.eql(u8, c.items[i].label, "us"));
    }
}

test "U redoes; <C-;> ends the line with ;, the cursor staying" {
    var ed = try testEditor("foo(1)");
    defer ed.deinit();
    try ed.feed("xu");
    try expectText(&ed, "foo(1)");
    try ed.feed("U");
    try expectText(&ed, "oo(1)");
    try ed.feed("$i<C-;>");
    try expectText(&ed, "oo(1);");
    try testing.expectEqual(4, ed.view.cursor); // still before the `)`
    try ed.feed("<C-;><Esc>"); // already ends in `;`
    try expectText(&ed, "oo(1);");
}

test "gV selects the last change, or the last yank" {
    var ed = try testEditor("one two three\nfour");
    defer ed.deinit();
    try ed.feed("wcwTWO<Esc>gV");
    try testing.expectEqual(Mode.visual, ed.mode);
    try ed.feed("y");
    try testing.expectEqualStrings("TWO", ed.registers.get(null).?.text);
    try ed.feed("jyygV"); // a linewise yank: the line, linewise
    try testing.expect(ed.visual_line);
    try testing.expectEqual(1, ed.cursorLine());
}

test "scratch pad: SPC t s opens it below, again closes it (saved)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.state_dir = dir;
    try ed.feed("<cmd:toggle_scratch>");
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "scratch.md"));
    try ed.feed("inote<Esc><cmd:toggle_scratch>");
    try testing.expectEqual(1, ed.window_list.items.len);
    try expectText(&ed, "code");
    const saved = try tmp.dir.readFileAlloc(testing.io, "scratch.md", testing.allocator, .limited(1024));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("note\n", saved);
}

test "autosave on leaving a file; the cursor and undo come back next time" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const a = try std.fs.path.join(gpa, &.{ dir, "a.txt" });
    defer gpa.free(a);
    const b = try std.fs.path.join(gpa, &.{ dir, "b.txt" });
    defer gpa.free(b);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "other\n" });
    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = dir;
        try ed.openFile(a);
        try ed.feed("jjAx<Esc>");
        try ed.openFile(b); // leaving a.txt saves it
        ed.tick(); // ...and keeps its undo history
        const saved = try tmp.dir.readFileAlloc(testing.io, "a.txt", gpa, .limited(1024));
        defer gpa.free(saved);
        try testing.expectEqualStrings("one\ntwo\nthreex\n", saved);
        ed.rememberPositions();
        ed.saveVisits();
    }
    var ed = try testEditor("");
    defer ed.deinit();
    ed.state_dir = dir;
    try ed.openFile(a);
    try testing.expectEqual(2, ed.cursorLine()); // where it was left
    try ed.feed("u"); // the edit from last time undoes
    try expectText(&ed, "one\ntwo\nthree");
}

test "mouse: drag selects and copies on release; double-click a word, triple a line" {
    var ed = try testEditor("hello world\nsecond line");
    defer ed.deinit();
    ed.setViewSize(10, 40);
    const Fake = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        fn get(_: Allocator) ?[]u8 {
            return null;
        }
        fn set(_: Allocator, data: []const u8) void {
            len = @min(data.len, buf.len);
            @memcpy(buf[0..len], data[0..len]);
        }
        fn copied() []const u8 {
            return buf[0..len];
        }
    };
    ed.registers.clipboard = .{ .get = Fake.get, .set = Fake.set };
    ed.mousePress(0, 0, 1);
    ed.mouseDrag(0, 4);
    try testing.expectEqual(Mode.visual, ed.mode);
    ed.mouseRelease();
    try testing.expectEqualStrings("hello", Fake.copied());
    try testing.expectEqual(Mode.visual, ed.mode); // still selected, as in nvim
    ed.mousePress(0, 7, 2);
    ed.mouseRelease();
    try testing.expectEqualStrings("world", Fake.copied());
    ed.mousePress(1, 2, 3);
    ed.mouseRelease();
    try testing.expectEqualStrings("second line", std.mem.trimEnd(u8, Fake.copied(), "\n"));
    ed.mousePress(0, 3, 1); // a plain click: no selection, nothing copied
    ed.mouseRelease();
    try testing.expectEqual(Mode.normal, ed.mode);
    try testing.expectEqual(3, ed.view.cursor);
}

test "saving a TypeScript file with no servers running still saves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "a.ts" });
    defer testing.allocator.free(path);
    var ed = try testEditor("");
    defer ed.deinit();
    ed.options.format_on_save = false;
    try ed.openFile(path);
    try ed.feed("iconst x = 1;<Esc><Space>s");
    try testing.expect(ed.save_chain == null);
    const saved = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .limited(64));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("const x = 1;\n", saved);
}

test "SQL completion: tables and columns from the database, after an alias its columns" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const db = try std.fs.path.join(gpa, &.{ dir, "app.db" });
    defer gpa.free(db);
    const made = std.process.run(gpa, testing.io, .{ .argv = &.{ "sqlite3", db, "create table users(id integer, email text); create table orders(id integer, total real);" } }) catch return error.SkipZigTest;
    gpa.free(made.stdout);
    gpa.free(made.stderr);
    const env = try std.fmt.allocPrint(gpa, "DATABASE_URL=sqlite:{s}\n", .{db});
    defer gpa.free(env);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = env });
    const path = try std.fs.path.join(gpa, &.{ dir, "q.sql" });
    defer gpa.free(path);
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(path);
    ed.tick();
    ed.sql_schema.?.wait();
    try testing.expectEqual(2, ed.sql_schema.?.tables.len);
    try ed.feed("iselect  from users u;<Esc>0f a"); // between `select` and `from`
    try ed.feed("u.");
    const c = ed.completionShown().?;
    try testing.expectEqual(2, c.shown.items.len); // users' columns only
    try ed.feed("em");
    try testing.expectEqualStrings("email", ed.completionShown().?.current().?.label);
    try ed.feed("<Esc>o");
    try ed.feed("ord");
    try testing.expectEqualStrings("orders", ed.completionShown().?.current().?.label);
}

test "wrap: long lines break at words, keep their indent; j/k go by screen row" {
    var ed = try testEditor("  alpha beta gamma delta epsilon\nshort");
    defer ed.deinit();
    ed.setViewSize(10, 16);
    var buf: [max_segments]Seg = undefined;
    const segs = ed.segments(0, &buf);
    try testing.expectEqual(3, segs.len);
    try testing.expectEqual(13, segs[1].start); // after "  alpha beta "
    try testing.expectEqual(2, segs[1].indent); // under the indentation
    try testing.expectEqual(3, ed.subRows(0));
    try testing.expectEqual(1, ed.subRows(1));
    try ed.feed("j"); // a screen row down: still line 0
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(1, ed.cursorRow().sub);
    try ed.feed("jj");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("k");
    try testing.expectEqual(2, ed.cursorRow().sub);
    try ed.feed("gg2j"); // a count: whole lines
    try testing.expectEqual(1, ed.cursorLine());
    // A click on a later row lands in that piece.
    ed.clickCell(1, 4);
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(15, ed.view.cursor); // col 13 + (4 - indent 2)
    ed.options.wrap = false;
    try testing.expectEqual(1, ed.segments(0, &buf).len);
}

test "code lens: a row above its line that the cursor steps over" {
    var ed = try testEditor("a\nfn f() {}\nb");
    defer ed.deinit();
    try ed.addLens(ed.buffer, 1, "2 references");
    try ed.addLens(ed.buffer, 1, "1 implementation");
    try testing.expectEqualStrings("2 references | 1 implementation", ed.lensText(1).?);
    try testing.expectEqual(2, ed.subRows(1)); // the lens row and the line
    try ed.feed("j");
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expectEqual(1, ed.cursorRow().sub); // on the text, not the lens
    try ed.feed("k");
    try testing.expectEqual(0, ed.cursorLine());
    try ed.feed("jj");
    try testing.expectEqual(2, ed.cursorLine());
    ed.clickCell(1, 0); // the lens row: its line
    try testing.expectEqual(1, ed.cursorLine());
    ed.options.code_lens = false;
    try testing.expectEqual(1, ed.subRows(1));
}

test "code lens: lenses move with the lines, and a refresh doesn't blank them" {
    var ed = try testEditor("a\nfn f() {}\nb\nfn g() {}");
    defer ed.deinit();
    try ed.addLens(ed.buffer, 1, "2 references");
    try ed.addLens(ed.buffer, 3, "1 reference");
    // New lines above: both move down.
    try ed.feed("Onew<Esc>");
    try testing.expectEqual(null, ed.lensText(1));
    try testing.expectEqualStrings("2 references", ed.lensText(2).?);
    try testing.expectEqualStrings("1 reference", ed.lensText(4).?);
    // A line opened at the end of a lens's line doesn't move it.
    try ed.feed("jjA<CR>x<Esc>");
    try testing.expectEqualStrings("2 references", ed.lensText(2).?);
    try testing.expectEqualStrings("1 reference", ed.lensText(5).?);
    // Deleting lines: the lens of a deleted line goes, the next moves up.
    try ed.feed("ggjdd");
    try testing.expectEqual(null, ed.lensText(1));
    try testing.expectEqualStrings("1 reference", ed.lensText(4).?);
    // A refresh: the kept title shows until the resolved one replaces it.
    ed.buffer.lenses.items[ed.buffer.lenses.items.len - 1].stale = true;
    try testing.expectEqualStrings("1 reference", ed.lensText(4).?);
    try ed.addLens(ed.buffer, 4, "2 references");
    try testing.expectEqualStrings("2 references", ed.lensText(4).?);
    try ed.addLens(ed.buffer, 4, "1 implementation");
    try testing.expectEqualStrings("2 references | 1 implementation", ed.lensText(4).?);
}

test "structure keys: grow (Alt-u) / shrink (Alt-i), siblings, carrying a node, functions, case" {
    var ed = try testEditorAs("a.zig", "fn add(first: u8, second: u8) u8 {\n    return call(first, second, 3);\n}\n\nfn two() void {}");
    defer ed.deinit();
    const t = ed.text();
    // Alt-u from the cursor on `first` (the argument): the name, then the call.
    try ed.feed("jff<A-u>");
    var r = ed.visualRange();
    try testing.expectEqualStrings("first", t.slice(r.start, r.end));
    try ed.feed("<A-u>");
    r = ed.visualRange();
    try testing.expectEqualStrings("call(first, second, 3)", t.slice(r.start, r.end));
    // Alt-i goes back, and from the first step to the cursor.
    try ed.feed("<A-i>");
    r = ed.visualRange();
    try testing.expectEqualStrings("first", t.slice(r.start, r.end));
    try ed.feed("<A-i>");
    try testing.expectEqual(Mode.normal, ed.mode);
    // Alt-n: the next argument.
    try ed.feed("<A-n>");
    try testing.expectEqual(t.lineStart(1) + 23, ed.view.cursor); // on `second`
    // Alt-P carries `second` left past `first`; again does nothing at the edge.
    try ed.feed("<A-P>");
    try testing.expectEqualStrings("    return call(second, first, 3);", t.lineSlice(1));
    try testing.expectEqual(t.lineStart(1) + 16, ed.view.cursor);
    try ed.feed("u");
    try testing.expectEqualStrings("    return call(first, second, 3);", t.lineSlice(1));
    // Selected, it stays selected as it travels.
    try ed.feed("0ff<A-u><A-N><A-N>");
    try testing.expectEqualStrings("    return call(second, 3, first);", t.lineSlice(1));
    r = ed.visualRange();
    try testing.expectEqualStrings("first", t.slice(r.start, r.end));
    try ed.feed("<Esc>");
    // Functions.
    try ed.feed("gg<A-f>");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("<A-F>");
    try testing.expectEqual(0, ed.cursorLine());
    // Case: add -> Add -> ADD -> add (kebab and snake are the same for one word).
    try ed.feed("w<A-c>");
    try testing.expectEqualStrings("fn Add(", t.lineSlice(0)[0..7]);
    try ed.feed("<A-c>");
    try testing.expectEqualStrings("fn ADD(", t.lineSlice(0)[0..7]);
    try ed.feed("<A-c>");
    try testing.expectEqualStrings("fn add(", t.lineSlice(0)[0..7]);
}

test "sticky context: the headers of the scopes the top line is in" {
    var ed = try testEditorAs("a.zig", "fn f() void {\n    if (x) {\n        a();\n        b();\n        c();\n        d();\n    }\n}");
    defer ed.deinit();
    var buf: [3]usize = undefined;
    // At the top of the file, nothing.
    try testing.expectEqual(0, ed.contextLines(&buf).len);
    ed.view.top = 3;
    ed.view.cursor = ed.text().lineStart(5);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, ed.contextLines(&buf));
    // Not over the cursor: with it on the top line, none.
    ed.view.cursor = ed.text().lineStart(3);
    try testing.expectEqual(0, ed.contextLines(&buf).len);
    ed.options.sticky_context = false;
    ed.view.cursor = ed.text().lineStart(5);
    try testing.expectEqual(0, ed.contextLines(&buf).len);
}

test "picker: vim keys edit the query in normal mode" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openPicker(.commands, "");
    try ed.feed("open file here");
    const q = &ed.picker.?.query;
    try ed.feed("<Esc>");
    try testing.expectEqual(Mode.picker_normal, ed.mode);
    try testing.expectEqual(13, q.cursor); // on the last `e`, like vim
    try ed.feed("bdw");
    try testing.expectEqualStrings("open file ", q.items());
    try ed.feed("0wciwthe<Esc>");
    try testing.expectEqualStrings("open the ", q.items());
    try ed.feed("u");
    try testing.expectEqualStrings("open file ", q.items());
    try ed.feed("0x");
    try testing.expectEqualStrings("pen file ", q.items());
    try ed.feed("Io<Esc>");
    try testing.expectEqualStrings("open file ", q.items());
    try ed.feed("$D");
    try testing.expectEqualStrings("open file", q.items());
    try ed.feed("0yiw$p");
    try testing.expectEqualStrings("open fileopen", q.items());
    try ed.feed("S");
    try testing.expectEqual(Mode.picker, ed.mode);
    try testing.expectEqualStrings("", q.items());
    // Typing goes where the cursor is.
    try ed.feed("ac<Left>b");
    try testing.expectEqualStrings("abc", q.items());
    // j / k still move through the results; Esc closes.
    try ed.feed("<Esc>j<Esc>");
    try testing.expect(ed.picker == null);
}

test "pickers as menus: buffers' actions, the Tab menu, toggles, row keys" {
    var ed = try testEditor("main");
    defer ed.deinit();
    // Buffers: n makes one, x closes it, the list stays open and shows it.
    try ed.feed("<Space>b<Esc>n");
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<C-x>"); // while typing: Ctrl-x closes the selected one
    settlePicker(&ed);
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expect(ed.picker != null);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    // Tab: the action menu for the row; "new" from it.
    try ed.feed("<Tab>");
    try testing.expectEqual(.open_in, ed.picker.?.kind);
    settlePicker(&ed);
    try ed.feed("inew<CR>");
    try testing.expectEqual(2, ed.buffers.items.len);
    try ed.feed("<Esc>");
    // Toggles: Enter flips one and the list stays, with the new state.
    const wrap = ed.options.wrap;
    try ed.feed("<Space>tline wrap");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expectEqual(!wrap, ed.options.wrap);
    try testing.expect(ed.picker != null);
    settlePicker(&ed);
    try testing.expectEqualStrings(if (wrap) "off" else "on", ed.picker.?.itemAt(0).?.detail);
    try ed.feed("<Esc><Esc>");
    try testing.expectEqual(null, ed.picker);
    // A menu: a row's key runs it (W: trim trailing whitespace).
    try ed.text().insert(ed.gpa, 0, "x   ");
    try ed.feed("<Space>l");
    settlePicker(&ed);
    try ed.feed("W");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "x   ") == null);
}

test "go: a new file indents with tabs" {
    var ed = try testEditorAs("main.go", "func main() {");
    defer ed.deinit();
    try testing.expect(ed.usesTabs());
    try ed.feed("A<CR>x<Esc>");
    try testing.expectEqualStrings("\tx", ed.text().lineSlice(1));
}

test "missing tools: quiet until an action needs them, then said plainly" {
    var ed = try testEditorAs("main.go", "package main");
    defer ed.deinit();
    const i = Lsp.serverFor(ed.buffer).?;
    const toasts = ed.toasts.items.len;
    ed.serverStartFailed(i, error.FileNotFound);
    try testing.expectEqual(toasts, ed.toasts.items.len); // nothing on opening
    try testing.expect(ed.languageServer() == null); // gd, K, rename...
    try testing.expect(std.mem.endsWith(u8, ed.message.text(), "isn't installed"));
    // A command needing a program that isn't there.
    const cmd: commands.Command = .{ .name = "x", .doc = "x", .run = struct {
        fn run(_: commands.Context) anyerror!void {
            return error.ShouldNotRun;
        }
    }.run, .needs = "zile-no-such-program" };
    try ed.runCommand(&cmd);
    try testing.expectEqualStrings("zile-no-such-program isn't installed", ed.message.text());
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

test "mini.move: <A-j>/<A-k>/<A-h>/<A-l>" {
    var ed = try testEditor("one\ntwo\nthree");
    defer ed.deinit();
    try ed.feed("<A-j>");
    try expectText(&ed, "two\none\nthree");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<A-j><A-j>"); // second is a no-op at the end
    try expectText(&ed, "two\nthree\none");
    try ed.feed("<A-k>");
    try expectText(&ed, "two\none\nthree");
    try ed.feed("<A-l>");
    try expectText(&ed, "two\n    one\nthree");
    try ed.feed("<A-h>");
    try expectText(&ed, "two\none\nthree");
    // Charwise selection moves along the line; linewise selection moves lines.
    try ed.feed("ggvl<A-l>");
    try expectText(&ed, "otw\none\nthree");
    try ed.feed("<A-h><Esc>Vj<A-j>");
    try expectText(&ed, "three\ntwo\none");
    try ed.feed("<Esc>u");
    try expectText(&ed, "two\none\nthree");
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
    try ed.feed("<cmd:search_buffer>thr<CR>");
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
    try ed.feed("tba");
    try testing.expectEqual(.search, ed.mode); // three matches: keep typing
    try ed.feed("z");
    try testing.expectEqual(.normal, ed.mode); // only "baz" left: jumped
    try testing.expectEqual(8, ed.view.cursor);

    try ed.feed("ggtbar<CR>");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed("n");
    try testing.expectEqual(16, ed.view.cursor);

    try ed.feed("ggtq<Esc>"); // only one 'q': jumps on the first key
    try testing.expectEqual(12, ed.view.cursor);
    try ed.feed("gg");
    try ed.feed("tw<Esc>"); // no 'w' anywhere: Esc puts the cursor back
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

test "SPC Q s saves every modified buffer, then quits; SPC q checks all buffers" {
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
    try ed.feed("ibeta<Esc>[b"); // back to a.txt, which is saved? no: both modified
    try ed.feed("<Space>q");
    try testing.expect(!ed.should_quit); // a.txt is unsaved: not closed
    try ed.feed("<Space>Qs");
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

test "SPC l l without a language server: tree-sitter outline picker" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-symbols.zig");
    try ed.insertAt(0, "const A = struct {\n    fn one() void {}\n};\nfn two() void {}");
    try ed.buffer.history.commit(ed.gpa);
    try ed.feed("<Space>ll");
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
    try ed.feed("gg<cmd:git_next_hunk><cmd:git_restore_hunk>");
    try expectText(&ed, "a\nold b\nc\nd");
    try ed.feed("<cmd:git_next_hunk><cmd:git_restore_hunk>");
    try expectText(&ed, "a\nold b\nc\ngone\nd");
    try ed.feed("u");
    try expectText(&ed, "a\nold b\nc\nd");

    try ed.feed("<cmd:toggle_ghost_lines>"); // ghost lines off: j skips them
    try ed.feed("ggjj");
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(2, ed.cursorLine());
}

test "ghost lines: the mouse selects and copies them" {
    var ed = try ghostEditor("x\nold1\nold2\nold3\ny", "x\ny");
    defer ed.deinit();
    const Fake = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        fn get(_: Allocator) ?[]u8 {
            return null;
        }
        fn set(_: Allocator, data: []const u8) void {
            len = @min(data.len, buf.len);
            @memcpy(buf[0..len], data[0..len]);
        }
        fn copied() []const u8 {
            return buf[0..len];
        }
    };
    ed.registers.clipboard = .{ .get = Fake.get, .set = Fake.set };
    // Rows: x, [old1], [old2], [old3], y. Drag from old1 to old3.
    ed.mousePress(1, 0, 1);
    try testing.expect(ed.ghost != null);
    ed.mouseDrag(3, 2);
    try testing.expectEqual(Mode.visual, ed.mode);
    ed.mouseDrag(4, 0); // past the hunk: stays on its last old line
    ed.mouseRelease();
    try testing.expectEqualStrings("old1\nold2\nold3\n", Fake.copied());
    // A double click: that one line.
    try ed.feed("<Esc>");
    ed.mousePress(2, 1, 2);
    ed.mouseRelease();
    try testing.expectEqualStrings("old2\n", Fake.copied());
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
    try ed.feed("th"); // the only 'h' on screen is in the ghost line: jumps
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
    const file = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{dir});
    defer gpa.free(file);
    try ed.openFile(file);
    try ed.feed("ihello<Esc>");

    try ed.feed("<cmd:git_commit>first commit<CR>");
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

    // A scratch buffer: SPC s asks for a name, then saves there.
    try ed.feed("ihello<Esc><Space>s");
    try testing.expectEqual(PromptKind.save_as, ed.search_prompt.?.kind);
    try ed.search_prompt.?.input.set(gpa, a);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, a, ed.buffer.path.?));
    try testing.expect(!ed.buffer.modified);
    const saved = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(1024));
    defer gpa.free(saved);
    try testing.expectEqualStrings("hello\n", saved);

    // Rename into a new folder: the file moves and the language follows.
    try ed.feed("<cmd:rename_file>");
    try testing.expect(std.mem.endsWith(u8, a, ed.search_prompt.?.input.items())); // prefilled
    try ed.search_prompt.?.input.set(gpa, b);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, b, ed.buffer.path.?));
    try testing.expect(ed.buffer.syntax != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "a.txt", .{}));
    try tmp.dir.access(io, "sub/b.zig", .{});

    // Copy: writes a copy (unsaved edits included) and opens it; the
    // original keeps its unsaved state (with autosave off: else leaving it
    // saves it).
    ed.options.autosave = false;
    try ed.feed("A!<Esc><cmd:copy_file>");
    try ed.search_prompt.?.input.set(gpa, c);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, c, ed.buffer.path.?));
    try testing.expectEqualStrings("hello!", ed.text().slice(0, ed.text().len()));
    try testing.expect(ed.buffers.items[0].modified);

    // Refuses to overwrite an existing file.
    try ed.feed("<cmd:save_file_as>");
    try ed.search_prompt.?.input.set(gpa, b);
    try ed.feed("<CR>");
    try testing.expectEqual(.err, ed.message.kind);
    try testing.expect(std.mem.endsWith(u8, c, ed.buffer.path.?));

    // Delete: "No" keeps it, "Yes" removes it and closes the buffer.
    try ed.feed("<cmd:delete_file><CR>");
    try tmp.dir.access(io, "c.zig", .{});
    try ed.feed("<cmd:delete_file>j<CR>"); // the confirmation starts in normal mode: j to "Yes"
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "c.zig", .{}));
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expect(std.mem.endsWith(u8, b, ed.buffer.path.?));

    // New file: prefilled with the current folder; created on first save.
    try ed.feed("<cmd:new_file>");
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
    try ed.feed("<Esc><Esc><Space>.<CR>ma<CR>");
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
    try ed.feed("<cmd:toggle_auto_pairs>Go(<Esc>"); // toggled off
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
    try ed.feed("<cmd:split_right>"); // split right: focus moves to the new window
    try testing.expectEqual(2, ed.window_list.items.len);
    const right = ed.window;
    try ed.feed("G");
    try ed.feed("<cmd:window_left>");
    try testing.expect(ed.window != right);
    try testing.expectEqual(0, ed.cursorLine()); // each window has its own cursor
    // Typing above shifts the other window's cursor with the text.
    try ed.feed("Onew<Esc>");
    try testing.expectEqual(3, right.view.cursor - ed.text().lineStart(3) + 3);
    try ed.feed("<cmd:window_right>");
    try testing.expectEqual(right, ed.window);
    try testing.expectEqual(3, ed.cursorLine()); // still on "three"
    try ed.feed("<cmd:window_next>"); // wraps to the first window
    try testing.expect(ed.window != right);
    try ed.feed("<cmd:split_down><cmd:window_close><cmd:window_close>");
    try testing.expectEqual(1, ed.window_list.items.len);
    try ed.feed("<cmd:window_close>"); // the last window stays
    try testing.expectEqual(1, ed.window_list.items.len);
}

test "windows: killing a buffer shown in another window" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile("zile-test-a.txt");
    try ed.feed("<cmd:split_right>");
    try ed.openFile("zile-test-b.txt");
    const b = ed.buffer;
    try ed.feed("<cmd:window_left>");
    try ed.feed("<cmd:last_buffer>"); // flip to the other buffer: b, here too
    try testing.expectEqual(b, ed.buffer);
    try ed.feed("<cmd:kill_buffer>");
    // Both windows moved off the killed buffer.
    for (ed.window_list.items) |w| try testing.expect(ed.windowBuffer(w) != b);
}

test "buffers: new, last, kill others" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-a.txt");
    const a = ed.buffer;
    try ed.feed("<cmd:new_buffer>");
    try testing.expect(ed.buffer != a);
    try ed.feed("<cmd:last_buffer>");
    try testing.expectEqual(a, ed.buffer);
    try ed.feed("<cmd:new_buffer><cmd:new_buffer><cmd:kill_other_buffers>");
    try testing.expectEqual(1, ed.buffers.items.len);
}

test "SPC ,: back to the last jump, and again: back here" {
    var ed = try testEditor("a\nb\nc\nd\ne");
    defer ed.deinit();
    try ed.feed("jG"); // a jump from line 2 to the end
    try ed.feed("<Space>,");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<Space>,");
    try testing.expectEqual(4, ed.cursorLine());
    try ed.feed("<Space>,");
    try testing.expectEqual(1, ed.cursorLine());
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
    try ed.feed("<Space>fj");
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
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });

    try ed.feed("<cmd:run_command>echo hi; exit 4<Esc><CR>");
    try testing.expectEqual(.run, ed.popup.?);
    waitForRun(&ed);
    try testing.expectEqual(4, ed.run.?.exit_code);
    try testing.expectEqual(.err, ed.message.kind);
    const out = try ed.run.?.screenText(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "hi\n"));
    try testing.expect(std.mem.indexOf(u8, out, "exited 4") != null);
    try ed.feed("y"); // no errors in it: the whole output, without our status line
    try testing.expectEqualStrings("hi", std.mem.trimEnd(u8, ed.registers.get(null).?.text, "\n"));
    try ed.feed("q");
    try testing.expectEqual(null, ed.popup);

    // The runner: a picker of the commands run here. Empty the first time;
    // typing one runs it; then it is first in the list.
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(.runner, ed.picker.?.kind);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try ed.feed("echo runner<CR>");
    waitForRun(&ed);
    try testing.expectEqual(0, ed.run.?.exit_code);
    try ed.feed("q<cmd:run_runner>echo second<CR>");
    waitForRun(&ed);
    try ed.feed("q<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("echo second", ed.picker.?.itemAt(0).?.text); // newest first
    try testing.expectEqualStrings("echo runner", ed.picker.?.itemAt(1).?.text);
    // Typing filters the history; the typed text itself stays the first row.
    try ed.feed("run");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.createRow().?);
    try testing.expectEqualStrings("echo runner", ed.picker.?.itemAt(1).?.text);
    try ed.feed("<C-n><CR>"); // down to the old command: run that
    try testing.expectEqualStrings("echo runner", ed.run_command.?);
    waitForRun(&ed);
    // It is the newest now; x forgets one.
    try ed.feed("q<cmd:run_runner><Esc>");
    settlePicker(&ed);
    try testing.expectEqualStrings("echo runner", ed.picker.?.itemAt(0).?.text);
    try ed.feed("jx");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    try ed.feed("<CR>"); // Enter on the list: the last command again
    try testing.expectEqualStrings("echo runner", ed.run_command.?);
    waitForRun(&ed);
    try ed.feed("r"); // `r` in a finished run: once more
    waitForRun(&ed);
    try testing.expectEqual(0, ed.run.?.exit_code);
    try ed.feed("q<cmd:run_output>"); // the output comes back
    try testing.expectEqual(.run, ed.popup.?);
}

test "terminal popup: keys go to the shell, Ctrl-\\ hides it and keeps it running" {
    var ed = try testEditor("text");
    defer ed.deinit();
    try ed.feed("<cmd:terminal_toggle>");
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

/// Lets the picker catch up (results, then a frame for the preview).
fn settlePicker(ed: *Editor) void {
    if (ed.picker) |p| p.sync();
    ed.tick();
}

test "run errors: a failing run fills the quickfix picker; j/k preview, Enter goes" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    try ed.feed("<cmd:run_command>printf 'src/main.zig:4:7: error: boom\\nsrc/Editor.zig:2:1: error: two\\nnot/a/file.zig:1:1: error: x\\n'; exit 1<Esc><CR>");
    waitForRun(&ed);
    try testing.expectEqual(2, ed.run_errors.items.len); // only real files count
    try testing.expectEqual(2, ed.quickfix.items.len); // and they're the quickfix list
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("e"); // from the finished run's popup
    try testing.expectEqual(.quickfix, ed.picker.?.kind);
    try testing.expectEqual(.picker_normal, ed.mode); // quickfix starts in normal mode
    try testing.expectEqual(null, ed.popup);
    settlePicker(&ed);
    // A picker like any other: each row has its file and line number, the
    // preview shows the place, and the editor stays put until Enter.
    try testing.expectEqualStrings("src/main.zig:4", ed.picker.?.itemAt(0).?.detail);
    try testing.expectEqualStrings("src/Editor.zig:2", ed.picker.?.itemAt(1).?.detail);
    try testing.expectEqual(3, ed.picker.?.preview.focus_line);
    try testing.expectEqual(null, ed.buffer.path);
    try ed.feed("j");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.picker.?.preview.focus_line);
    try testing.expectEqual(null, ed.buffer.path);
    try ed.feed("k");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    try testing.expectEqual(3, ed.cursorLine());
    try testing.expectEqual(6, ed.view.cursor - ed.text().lineStart(3));
    try ed.feed("j"); // a normal j again
    try testing.expectEqual(4, ed.cursorLine());
    // ]q / [q without the picker.
    try ed.feed("]q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/Editor.zig"));
    try ed.feed("[q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    // SPC f q reopens at the current entry; i types to filter; q closes.
    try ed.feed("<cmd:quickfix_list>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.selected);
    try ed.feed("itwo");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    try ed.feed("<Esc>q");
    try testing.expectEqual(null, ed.picker);
}

test "pickers: Esc moves from typing to normal mode, j/k move, q closes" {
    var ed = try testEditor("alpha\nbeta\ngamma");
    defer ed.deinit();
    try ed.feed("<cmd:search_buffer>");
    try testing.expectEqual(.picker, ed.mode); // buffer lines start typing
    try ed.feed("a<Esc>");
    try testing.expectEqual(.picker_normal, ed.mode);
    settlePicker(&ed);
    try ed.feed("jjk"); // moving, not typing
    try testing.expectEqualStrings("a", ed.picker.?.query.items());
    try testing.expectEqual(1, ed.picker.?.selected);
    try ed.feed("Gi"); // back to typing
    try testing.expectEqual(.picker, ed.mode);
    try ed.feed("<Esc><Esc>");
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(.normal, ed.mode);
}

test "quickfix: Ctrl-q sends a picker's results" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    try ed.feed("<cmd:search_buffer>surround");
    ed.picker.?.sync();
    const n = ed.picker.?.snap.len;
    try testing.expect(n > 1);
    try ed.feed("<C-q>");
    try testing.expectEqual(.quickfix, ed.picker.?.kind);
    try testing.expectEqual(n, ed.quickfix.items.len);
    try ed.feed("q");
    try testing.expectEqual(null, ed.picker);
}

test "command editor: multi-line with vim editing; Enter runs, Esc cancels" {
    var ed = try testEditor("main text");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    const main_buffer = ed.buffer;

    try ed.feed("<cmd:run_command>");
    try testing.expect(ed.cmd_float != null);
    try testing.expectEqual(.insert, ed.mode);
    try ed.feed("echo one<CR>echo two<Esc>");
    try ed.feed("ggA; echo three<Esc>"); // plain vim editing
    try expectText(&ed, "echo one; echo three\necho two");
    try ed.feed("<Space>w"); // leader keys wait until it closes
    try testing.expect(ed.cmd_float != null);
    try ed.feed("<CR>"); // normal mode: run it
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expectEqual(main_buffer, ed.buffer);
    try expectText(&ed, "main text");
    waitForRun(&ed);
    const out = try ed.run.?.screenText(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "one\nthree\ntwo\n"));

    try ed.feed("q<cmd:run_command>echo nope<Esc><Esc>"); // Esc in normal mode cancels
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expectEqualStrings("echo one; echo three\necho two", ed.run_command.?);
}

test "projects: each window's pickers, git and runner use its file's project" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "alpha/.git");
    try tmp.dir.createDirPath(io, "alpha/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha/src/a.txt", .data = "a\n" });
    try tmp.dir.createDirPath(io, "beta/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "beta/b.txt", .data = "b\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fmt.allocPrint(gpa, "{s}/alpha/src/a.txt", .{base});
    defer gpa.free(a);
    const b = try std.fmt.allocPrint(gpa, "{s}/beta/b.txt", .{base});
    defer gpa.free(b);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ base, "run-commands" });
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);

    try ed.openFile(a);
    try testing.expectEqualStrings("alpha", ed.project().?.name());
    try testing.expect(std.mem.endsWith(u8, ed.gitRoot().?, "/alpha"));
    // The file picker lists alpha, relative to its root, and opens from there.
    try ed.feed("<Space><Space>");
    try testing.expect(std.mem.endsWith(u8, ed.picker_root, "/alpha"));
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/alpha"));
    ed.picker.?.sync();
    try testing.expectEqualStrings("src/", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");

    // The runner remembers per project.
    try ed.feed("<cmd:run_runner>echo alpha<CR>");
    waitForRun(&ed);
    try ed.feed("q");

    try ed.feed("<cmd:split_right>");
    try ed.openFile(b);
    try testing.expectEqualStrings("beta", ed.project().?.name());
    try ed.feed("<Space><Space>");
    try testing.expect(std.mem.endsWith(u8, ed.picker_root, "/beta"));
    try ed.feed("<Esc><Esc><cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try ed.feed("<Esc><Esc><cmd:window_left><cmd:run_runner>"); // back in alpha's window
    settlePicker(&ed);
    try testing.expectEqualStrings("echo alpha", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
}

test "open in: Ctrl-v / Ctrl-s / Tab menu split; a project into a split" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/xx.txt", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/yy.txt", .data = "y\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const x = try std.fmt.allocPrint(gpa, "{s}/proj/xx.txt", .{base});
    defer gpa.free(x);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.openFile(x);
    const x_buffer = ed.buffer;

    try ed.feed("<Space><Space>yy");
    ed.picker.?.sync();
    try ed.feed("<C-v>"); // split right
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "yy.txt"));
    try testing.expectEqual(x_buffer, ed.window_list.items[0].buffer); // the old window keeps xx

    try ed.feed("<Space><Space>xx");
    ed.picker.?.sync();
    try ed.feed("<Tab>");
    try testing.expectEqual(.open_in, ed.picker.?.kind);
    ed.picker.?.sync();
    try ed.feed("<Down><Down><CR>"); // "Split below"
    try testing.expectEqual(3, ed.window_list.items.len);
    try testing.expectEqual(x_buffer, ed.buffer);

    // A project into a split: the split waits for the file.
    try ed.feed("<Space>p");
    ed.picker.?.sync();
    try ed.feed("<C-v>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expectEqual(3, ed.window_list.items.len);
    try ed.feed("<Esc><Esc>"); // changed our mind: no split
    try testing.expectEqual(3, ed.window_list.items.len);
    try ed.feed("<Space>pp");
    ed.picker.?.sync();
    try ed.feed("<C-s>yy");
    ed.picker.?.sync();
    try ed.feed("<CR>");
    try testing.expectEqual(4, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "yy.txt"));
}

test "paths: trailing slashes and .. resolve; a folder argument opens the explorer" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    const inside = try ed.normalizePath("./src/../src/main.zig/");
    defer gpa.free(inside);
    try testing.expectEqualStrings("src/main.zig", inside);
    const outside = try ed.normalizePath("../elsewhere/x.zig");
    defer gpa.free(outside);
    try testing.expect(std.fs.path.isAbsolute(outside));
    try testing.expect(std.mem.indexOf(u8, outside, "..") == null);

    ed.openArg("src/main.zig/");
    try testing.expectEqualStrings("src/main.zig", ed.buffer.path.?);
    ed.openArg("src");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/src"));
}

test "picker normal mode: j reaches the create row" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("<Space><Space>render<Esc>");
    settlePicker(&ed);
    const rows = ed.picker.?.rowCount();
    try ed.feed("j");
    try testing.expectEqual(@min(1, rows - 1), ed.picker.?.selected);
    try ed.feed("<Esc>");
}

test "snippet completion: placeholders, typing over, Tab / Shift-Tab, Backspace" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doThing","insertText":"doThing(${1:path}, ${2:opts})$0","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("<Tab>"); // accept
    try expectText(&ed, "doThing(path, opts)");
    try testing.expectEqual(8, ed.view.cursor); // on "path", which typing replaces
    try ed.feed("src");
    try expectText(&ed, "doThing(src, opts)");
    try ed.feed("<Tab>"); // on to "opts"
    try testing.expectEqual(13, ed.view.cursor);
    try ed.feed("<S-Tab><Tab>"); // back and forth keeps what was typed
    try expectText(&ed, "doThing(src, opts)");
    try ed.feed("<BS>"); // a fresh placeholder goes whole
    try expectText(&ed, "doThing(src, )");
    try ed.feed("o<Tab>"); // the last Tab lands on $0, after the call
    try expectText(&ed, "doThing(src, o)");
    try testing.expectEqual(15, ed.view.cursor);
    try testing.expectEqual(null, ed.snippet);
    try ed.feed("<Esc>");
}

test "signature help: the active parameter, closed by )" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ifoo(a, ");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"signatures":[{"label":"fn foo(a: u8, b: []const u8) void","documentation":"Does foo.\nMore.",
        \\ "parameters":[{"label":[7,12]},{"label":"b: []const u8","documentation":{"kind":"markdown","value":"The bytes."}}],
        \\ "activeParameter":1}]}
    , .{});
    defer reply.deinit();
    try ed.showSignature(ed.buffer, reply.value);
    const sig = ed.signature.?;
    try testing.expectEqualStrings("b: []const u8", sig.label[sig.param_start..sig.param_end]);
    try testing.expectEqualStrings("The bytes.", sig.doc);
    try ed.feed("b)");
    try testing.expectEqual(null, ed.signature);
    try ed.feed("<Esc>");
}

test "zoom keys request a size change" {
    var ed = try testEditor("abc");
    defer ed.deinit();
    try ed.feed("<cmd:zoom_in>");
    try testing.expectEqual(1, ed.zoom_request);
    try ed.feed("<cmd:zoom_out><cmd:zoom_out>");
    try testing.expectEqual(-1, ed.zoom_request);
    try ed.feed("<cmd:zoom_reset>");
    try testing.expect(ed.zoom_reset);
    try expectText(&ed, "abc");
    try testing.expectEqual(.normal, ed.mode);
}

test "snippet: one more Tab after the call goes to the end, adding the ;" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-snippet.zig"); // a Zig buffer (not on disk)
    try ed.feed("iconst x = do");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doThing","insertText":"doThing(${1:a})$0","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();
    try ed.showCompletion(ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("<Tab>1<Tab>"); // accept, fill a, past the call
    try expectText(&ed, "const x = doThing(1)");
    try testing.expect(ed.snippet != null); // one more stop: the ;
    try ed.feed("<Tab>");
    try expectText(&ed, "const x = doThing(1);");
    try testing.expectEqual(ed.text().len(), ed.view.cursor);
    try testing.expectEqual(null, ed.snippet);
    try ed.feed("<Tab>"); // a plain tab again
    try testing.expect(std.mem.endsWith(u8, ed.text().slice(0, ed.text().len()), ";   "));

    // The ; already there: the Tab moves past it.
    try ed.feed("<Esc>oconst y = do;<Left>");
    try ed.showCompletion(ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("<Tab>2<Tab><Tab>");
    try expectText(&ed, "const x = doThing(1);   \nconst y = doThing(2);");
    try testing.expectEqual(ed.text().len(), ed.view.cursor);

    // Inside another call: no ; stop, the snippet just ends.
    try ed.feed("<Esc>oouter(do, 3);<Esc>0fda");
    try ed.feed("<Right>");
    try ed.showCompletion(ed.buffer, ed.view.cursor - 2, reply.value);
    try ed.feed("<Tab>4<Tab>");
    try expectText(&ed, "const x = doThing(1);   \nconst y = doThing(2);\nouter(doThing(4), 3);");
    try testing.expectEqual(null, ed.snippet);
}

test "formatting: SPC l f, one undo step, format on save, SPC t f" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data = "const  x=1;\nfn f() void {\nreturn;\n}\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.allocPrint(gpa, "{s}/m.zig", .{buf[0..try tmp.dir.realPath(io, &buf)]});
    defer gpa.free(path);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(path);
    try ed.feed("jj"); // on "return;"
    try ed.feed("<cmd:format_buffer>");
    if (ed.message.kind == .err) return error.SkipZigTest; // no zig fmt here
    try expectText(&ed, "const x = 1;\nfn f() void {\n    return;\n}");
    try testing.expectEqual(2, ed.cursorLine()); // still on "return;"
    try ed.feed("u"); // one undo step
    try expectText(&ed, "const  x=1;\nfn f() void {\nreturn;\n}");

    // Saving formats first.
    try ed.feed("<Space>s");
    const saved = try tmp.dir.readFileAlloc(io, "m.zig", gpa, .limited(1024));
    defer gpa.free(saved);
    try testing.expectEqualStrings("const x = 1;\nfn f() void {\n    return;\n}\n", saved);

    // Off: saved as typed.
    try ed.feed("<cmd:toggle_format_on_save>ggiconst  y=2;<CR><Esc><Space>s");
    const raw = try tmp.dir.readFileAlloc(io, "m.zig", gpa, .limited(1024));
    defer gpa.free(raw);
    try testing.expect(std.mem.startsWith(u8, raw, "const  y=2;\n"));
}

test "snippet without $0 (clangd's printf): Tab after the last argument leaves the call, then the ;" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-snippet.c");
    try ed.feed("ipr");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"printf","insertText":"printf(${1:const char *, ...})","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("<Tab>\"hi\"<Tab>");
    try expectText(&ed, "printf(\"hi\")");
    try testing.expectEqual(ed.text().len(), ed.view.cursor); // after the )
    try ed.feed("<Tab>");
    try expectText(&ed, "printf(\"hi\");");
    try testing.expectEqual(null, ed.snippet);
}

test "any function completion ends with ; on Tab: no arguments, plain text; not for keywords" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("zile-test-calls.zig");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[
        \\ {"label":"reset","kind":3,"insertText":"reset()","insertTextFormat":2},
        \\ {"label":"flush","kind":2,"insertText":"flush()"},
        \\ {"label":"iffy","kind":14,"insertText":"if (${1:cond}) {$0}","insertTextFormat":2}
        \\]}
    , .{});
    defer reply.deinit();

    try ed.feed("ires");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("<Tab><Tab>"); // a snippet with nothing to fill in
    try expectText(&ed, "reset();");

    try ed.feed("<CR>flu");
    try ed.showCompletion(ed.buffer, ed.view.cursor - 3, reply.value);
    try ed.feed("<Tab><Tab>"); // plain text
    try expectText(&ed, "reset();\nflush();");

    try ed.feed("<CR>iff");
    try ed.showCompletion(ed.buffer, ed.view.cursor - 3, reply.value);
    try ed.feed("<Tab>x<Tab>"); // a keyword snippet: no ;
    try expectText(&ed, "reset();\nflush();\nif (x) {}");
    try testing.expectEqual(null, ed.snippet);
}

test "AI suggestion: typing it out keeps it, Tab takes the rest, other keys drop it" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ireturn ");
    ed.ai_suggestion = .{ .buffer = ed.buffer, .pos = ed.view.cursor, .text = try testing.allocator.dupe(u8, "a + b;\n}") };
    try ed.feed("a "); // matches: still offered, minus what was typed
    try testing.expectEqualStrings("+ b;\n}", ed.aiSuggestionHere().?);
    try ed.feed("<A-Right>"); // one character
    try testing.expectEqualStrings(" b;\n}", ed.aiSuggestionHere().?);
    try ed.feed("<A-l>"); // the rest of this line
    try expectText(&ed, "return a + b;");
    try testing.expectEqualStrings("\n}", ed.aiSuggestionHere().?);
    try ed.feed("<A-;>"); // all of what's left
    try expectText(&ed, "return a + b;\n}");
    try testing.expectEqual(null, ed.ai_suggestion);
    try ed.feed("<Tab>"); // Tab is just a tab
    try expectText(&ed, "return a + b;\n}   ");

    try ed.feed("<CR>");
    ed.ai_suggestion = .{ .buffer = ed.buffer, .pos = ed.view.cursor, .text = try testing.allocator.dupe(u8, "xyz") };
    try ed.feed("q"); // doesn't match: gone
    try testing.expectEqual(null, ed.aiSuggestionHere());
    try ed.feed("<Esc>");
}

/// A minimal Claude Code CLI for tests: a WebSocket client speaking JSON-RPC.
const FakeCli = struct {
    fd: c_int,
    buf: std.ArrayList(u8) = .empty,

    const socketFn = @extern(*const fn (c_uint, c_uint, c_uint) callconv(.c) c_int, .{ .name = "socket" });
    const SockaddrIn = extern struct { family: u16 = 2, port: u16, addr: u32, zero: [8]u8 = @splat(0) };

    fn connect(port: u16, token: []const u8) !FakeCli {
        const fd = socketFn(2, 1, 0);
        var addr: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)) != 0) return error.Connect;
        var req: [512]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: mcp\r\nX-Claude-Code-Ide-Authorization: {s}\r\n\r\n", .{token});
        _ = std.c.write(fd, r.ptr, r.len);
        var resp: [512]u8 = undefined;
        const n = std.c.read(fd, &resp, resp.len);
        if (n <= 0 or !std.mem.startsWith(u8, resp[0..@intCast(n)], "HTTP/1.1 101")) return error.Handshake;
        return .{ .fd = fd };
    }

    fn deinit(f: *FakeCli) void {
        _ = std.c.close(f.fd);
        f.buf.deinit(testing.allocator);
    }

    fn send(f: *FakeCli, msg: []const u8) void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(testing.allocator);
        frame.append(testing.allocator, 0x81) catch return;
        if (msg.len < 126) {
            frame.append(testing.allocator, 0x80 | @as(u8, @intCast(msg.len))) catch return;
        } else {
            frame.appendSlice(testing.allocator, &.{ 0x80 | 126, @intCast(msg.len >> 8), @intCast(msg.len & 0xff) }) catch return;
        }
        frame.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 }) catch return; // a zero mask
        frame.appendSlice(testing.allocator, msg) catch return;
        _ = std.c.write(f.fd, frame.items.ptr, frame.items.len);
    }

    /// The next message containing `needle`, running the editor's frames
    /// until it arrives (caller frees).
    fn expect(f: *FakeCli, ed: *Editor, needle: []const u8) ![]u8 {
        for (0..400) |_| {
            ed.tick();
            while (f.nextFrame()) |msg| {
                if (std.mem.indexOf(u8, msg, needle) != null) return msg;
                testing.allocator.free(msg);
            }
            var fds = [_]std.c.pollfd{.{ .fd = f.fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 10) > 0) {
                var chunk: [64 * 1024]u8 = undefined;
                const n = std.c.read(f.fd, &chunk, chunk.len);
                if (n > 0) try f.buf.appendSlice(testing.allocator, chunk[0..@intCast(n)]);
            }
        }
        return error.Timeout;
    }

    fn nextFrame(f: *FakeCli) ?[]u8 {
        const b = f.buf.items;
        if (b.len < 2) return null;
        var len: usize = b[1] & 0x7f;
        var at: usize = 2;
        if (len == 126) {
            if (b.len < 4) return null;
            len = std.mem.readInt(u16, b[2..4], .big);
            at = 4;
        } else if (len == 127) {
            if (b.len < 10) return null;
            len = @intCast(std.mem.readInt(u64, b[2..10], .big));
            at = 10;
        }
        if (b.len < at + len) return null;
        const msg = testing.allocator.dupe(u8, b[at .. at + len]) catch return null;
        f.buf.replaceRangeAssumeCapacity(0, at + len, &.{});
        return msg;
    }
};

test "claude: lock file, handshake, selection, mentions, openDiff accepted" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/a.zig", .data = "const a = 1;\nconst b = 2;\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const cfg = try std.fmt.allocPrintSentinel(gpa, "{s}/cfg", .{base}, 0);
    defer gpa.free(cfg);
    const setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });
    _ = setenv("CLAUDE_CONFIG_DIR", cfg.ptr, 1);
    const file = try std.fmt.allocPrint(gpa, "{s}/proj/a.zig", .{base});
    defer gpa.free(file);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(file);
    ed.claude = try Claude.start(&ed);
    const c = ed.claude.?;

    // The lock file announces us.
    const lock = try std.fmt.allocPrint(gpa, "{s}/ide/{d}.lock", .{ cfg, c.port() });
    defer gpa.free(lock);
    const lock_text = try Io.Dir.cwd().readFileAlloc(io, lock, gpa, .limited(4096));
    defer gpa.free(lock_text);
    try testing.expect(std.mem.indexOf(u8, lock_text, "\"transport\":\"ws\"") != null);
    try testing.expect(std.mem.indexOf(u8, lock_text, &c.token) != null);

    // A wrong token is turned away; the right one gets in.
    try testing.expectError(error.Handshake, FakeCli.connect(c.port(), "wrong-token-wrong-token-wrong-to"));
    var cli = try FakeCli.connect(c.port(), &c.token);
    defer cli.deinit();
    cli.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"claude-code\",\"version\":\"test\"}}}");
    const hello = try cli.expect(&ed, "\"id\":1");
    defer gpa.free(hello);
    try testing.expect(std.mem.indexOf(u8, hello, "\"protocolVersion\":\"2025-06-18\"") != null);
    try testing.expect(std.mem.indexOf(u8, hello, "\"logging\":{}") != null);

    // The cursor's place in the file is shared.
    const sel = try cli.expect(&ed, "selection_changed");
    defer gpa.free(sel);
    try testing.expect(std.mem.indexOf(u8, sel, "a.zig") != null);

    // Tools are listed.
    cli.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const tools = try cli.expect(&ed, "\"id\":2");
    defer gpa.free(tools);
    try testing.expect(std.mem.indexOf(u8, tools, "openDiff") != null);

    // A mention of lines 1-2 (0-based 0..1).
    c.mention(file, .{ 0, 1 });
    const men = try cli.expect(&ed, "at_mentioned");
    defer gpa.free(men);
    try testing.expect(std.mem.indexOf(u8, men, "\"lineStart\":0,\"lineEnd\":1") != null);

    // A proposed edit opens as a diff; SPC a y accepts it.
    const call = try std.fmt.allocPrint(gpa,
        \\{{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{{"name":"openDiff","arguments":{{"old_file_path":"{s}","new_file_path":"{s}","new_file_contents":"const a = 10;\nconst b = 2;\n","tab_name":"t1"}}}}}}
    , .{ file, file });
    defer gpa.free(call);
    cli.send(call);
    for (0..200) |_| {
        ed.tick();
        if (c.diffs.items.len > 0) break;
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expectEqual(1, c.diffs.items.len);
    try testing.expect(std.mem.startsWith(u8, ed.buffer.displayName(), "Claude: "));
    try testing.expectEqual(1, ed.buffer.git.?.hunks.items.len); // line 1 changed
    try ed.feed("<Space>ay");
    const saved = try cli.expect(&ed, "\"id\":3");
    defer gpa.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "FILE_SAVED") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "const a = 10;") != null);
    try testing.expectEqual(0, c.diffs.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "a.zig")); // back on the file

    // A rejected one answers DIFF_REJECTED.
    const call2 = try std.mem.replaceOwned(u8, gpa, call, "\"id\":3", "\"id\":4");
    defer gpa.free(call2);
    cli.send(call2);
    for (0..200) |_| {
        ed.tick();
        if (c.diffs.items.len > 0) break;
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try ed.feed("<Space>an");
    const rejected = try cli.expect(&ed, "\"id\":4");
    defer gpa.free(rejected);
    try testing.expect(std.mem.indexOf(u8, rejected, "DIFF_REJECTED") != null);
}

test "terminal window: Esc Esc is normal mode, SPC commands work, i types again" {
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    const t = try Terminal.create(ed.gpa, ed.io, .{ .argv = &.{ "/bin/sh", "-c", "trap 'echo got-int' INT; echo ready; while :; do sleep 0.05; done" }, .cwd = "/", .cols = 40, .rows = 5, .wake = noWake });
    defer t.destroy();
    const code_window = ed.window;
    try ed.splitWindow(.right);
    ed.window.term = t;
    const term_window = ed.window;
    for (0..200) |_| {
        const out = try t.screenText(testing.allocator);
        defer testing.allocator.free(out);
        if (std.mem.indexOf(u8, out, "ready") != null) break;
        io_sleep(10);
    }
    try ed.feed("<C-S-c>"); // to the program
    try testing.expectEqual(term_window, ed.window);
    try ed.feed("<Esc><Esc>"); // normal mode: keys go to the editor
    try testing.expect(term_window.term_normal);
    try ed.feed("x"); // does nothing
    try expectText(&ed, "code");
    try ed.feed("<cmd:window_left>"); // SPC commands work from here
    try testing.expectEqual(code_window, ed.window);
    try testing.expectEqual(2, ed.window_list.items.len);
    try ed.feed("<C-\\>"); // and to the terminal again
    try testing.expectEqual(term_window, ed.window);
    try ed.feed("i"); // typing into the program again
    try testing.expect(!term_window.term_normal);
    var got = false;
    for (0..200) |_| {
        const out = try t.screenText(testing.allocator);
        defer testing.allocator.free(out);
        if (std.mem.indexOf(u8, out, "got-int") != null) {
            got = true;
            break;
        }
        io_sleep(10);
    }
    try testing.expect(got);
    try ed.feed("<C-c>"); // not the Claude panel: Ctrl-C is the program's
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expectEqual(term_window, ed.window);
}

fn io_sleep(ms: i64) void {
    testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

test "SPC q with the Claude panel: the last code window hides the panel first" {
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    const t = try Terminal.create(ed.gpa, ed.io, .{ .argv = &.{ "/bin/sh", "-c", "sleep 5" }, .cwd = "/", .cols = 40, .rows = 5, .wake = noWake });
    defer t.destroy();
    const code_window = ed.window;
    try ed.splitWindow(.right);
    ed.window.term = t;
    ed.focusWindow(code_window);

    try ed.feed("<cmd:window_close>"); // the last code window stays
    try testing.expectEqual(2, ed.window_list.items.len);
    try ed.feed("<Space>q"); // hides the panel, not the code
    try testing.expectEqual(1, ed.window_list.items.len);
    try testing.expectEqual(code_window, ed.window);
    try testing.expect(!ed.should_quit);
    try ed.feed("<Space>q"); // then on to buffers / quitting
    try testing.expect(ed.should_quit);
}

test "SPC w: the windows picker flips, moves, makes, resizes, swaps, maximises" {
    var ed = try testEditor("one\ntwo");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try ed.feed("<Space>w");
    try testing.expectEqual(.windows, ed.picker.?.kind);
    settlePicker(&ed);
    // One window, then the rows that make new ones.
    try testing.expectEqual(4, ed.picker.?.rowCount());
    try testing.expectEqualStrings("+ New window right...", ed.picker.?.itemAt(1).?.text);
    try ed.feed("v"); // split right: two windows, in the new (right) one
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(2, ed.window_list.items.len);
    const right = ed.window;
    try ed.openFile("src/format.zig"); // a file of its own
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    // SPC w Enter: the other window (the one you're in is listed last).
    try ed.feed("<Space>w");
    settlePicker(&ed);
    try testing.expectEqualStrings("here", ed.picker.?.itemAt(1).?.detail);
    try ed.feed("<CR>");
    const left = ed.window;
    try testing.expect(left != right);
    // SPC w w: back and forth between the last two.
    try ed.feed("<Space>ww");
    try testing.expectEqual(right, ed.window);
    try ed.feed("<Space>ww");
    try testing.expectEqual(left, ed.window);
    // h / l: the window that way from here.
    try ed.feed("<Space>wl");
    try testing.expectEqual(right, ed.window);
    try ed.feed("<Space>wh");
    try testing.expectEqual(left, ed.window);
    // > widens the selected one (the other, the right) and the list stays.
    const before = right.rect.w;
    try ed.feed("<Space>w>>");
    try testing.expect(ed.picker != null);
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try testing.expect(right.rect.w > before);
    // z: maximised; again: back.
    try ed.feed("z");
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try testing.expect(right.rect.w > 80);
    try ed.feed("z");
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    try testing.expect(right.rect.w < 80);
    // X: the right window's buffer and this one's trade places.
    const mine = ed.buffer;
    try ed.feed("X<Esc>");
    try testing.expect(ed.buffer != mine);
    try testing.expectEqual(mine, right.buffer);
    // "+ New window right...": the Files picker, and the file opens beside.
    try ed.feed("<Space>w");
    settlePicker(&ed);
    ed.picker.?.selected = 2; // past the two windows
    try ed.feed("<CR>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed("build.zig");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expectEqual(3, ed.window_list.items.len);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "build.zig"));
}

test "SPC b Enter flips to the previous buffer" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    try ed.openFile("src/format.zig");
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "pairs.zig"));
    try ed.feed("<Space>b");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "format.zig"));
}

test "mini.comment: gcc, gc{motion}, visual gc, the gc object" {
    var ed = try testEditor("one\n  two\n\n  three");
    defer ed.deinit();
    try ed.feed("gcc");
    try expectText(&ed, "# one\n  two\n\n  three");
    try ed.feed("gcc");
    try expectText(&ed, "one\n  two\n\n  three");
    // The prefix goes at the block's smallest indentation; blank lines stay.
    try ed.feed("jgcG");
    try expectText(&ed, "one\n  # two\n\n  # three");
    try ed.feed("dgc"); // the comment block at the cursor (one line)
    try expectText(&ed, "one\n\n  # three");
    try ed.feed("GVgc");
    try expectText(&ed, "one\n\n  three");
    try ed.feed("ggVGgc");
    try expectText(&ed, "# one\n\n#   three");
    try ed.feed("gcgc"); // uncomments only the block under the cursor
    try expectText(&ed, "one\n\n#   three");
}

test "mini.operators: gr replaces, gx exchanges, gs sorts, gm duplicates" {
    var ed = try testEditor("foo bar\nc, a, b\nz\ny");
    defer ed.deinit();
    try ed.feed("yiwwgriw");
    try expectText(&ed, "foo foo\nc, a, b\nz\ny");
    try testing.expectEqualStrings("foo", ed.registers.get(null).?.text); // kept
    try ed.feed("u0gxiwwgxiw");
    try expectText(&ed, "bar foo\nc, a, b\nz\ny");
    try ed.feed("j0gs$");
    try expectText(&ed, "bar foo\na, b, c\nz\ny");
    try ed.feed("jgsj");
    try expectText(&ed, "bar foo\na, b, c\ny\nz");
    try ed.feed("gmm");
    try expectText(&ed, "bar foo\na, b, c\ny\ny\nz");
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("grr");
    try expectText(&ed, "bar foo\na, b, c\ny\nfoo\nz");
    try ed.feed("gmiw");
    try expectText(&ed, "bar foo\na, b, c\ny\nfoofoo\nz");
    // A mark is dropped by <Esc>; `dr` is not `dd`.
    try ed.feed("gxiw<Esc>ggdr");
    try testing.expect(ed.exchange_mark == null);
    try expectText(&ed, "bar foo\na, b, c\ny\nfoofoo\nz");
}

test "mini.align: ga{motion}{char}; mini.splitjoin: gS" {
    var ed = try testEditor("a = 1\nbbb = 2\ncc += 3");
    defer ed.deinit();
    try ed.feed("gaip=");
    try expectText(&ed, "a   = 1\nbbb = 2\ncc  += 3");
    try ed.feed("u");
    try expectText(&ed, "a = 1\nbbb = 2\ncc += 3");

    var ed2 = try testEditor("x: 1,\nlonger: 2,");
    defer ed2.deinit();
    try ed2.feed("Vjga:");
    try expectText(&ed2, "x:      1,\nlonger: 2,");

    var ed3 = try testEditor("  f(a, g(b, c), d);");
    defer ed3.deinit();
    try ed3.feed("gS");
    try expectText(&ed3, "  f(\n      a,\n      g(b, c),\n      d\n  );");
    try ed3.feed("gS");
    try expectText(&ed3, "  f(a, g(b, c), d);");
}

test "mini.ai: next / previous objects, the indent scope, g[ and g]" {
    var ed = try testEditor("f(a) + g(b) + h(c)");
    defer ed.deinit();
    try ed.feed("fgdin(");
    try expectText(&ed, "f(a) + g() + h(c)");
    try ed.feed("diN(");
    try expectText(&ed, "f() + g() + h(c)");
    try ed.feed("$g[(");
    try expectCursor(&ed, 0, 13);
    try ed.feed("0can\"x<Esc>"); // no quotes anywhere: nothing happens, no insert mode
    try testing.expectEqual(Mode.normal, ed.mode);

    var ed2 = try testEditor("if x:\n    a\n\n    b\nend\n  \"s\" 'q' \"t\"");
    defer ed2.deinit();
    try ed2.feed("j]i");
    try testing.expectEqual(4, ed2.cursorLine());
    try ed2.feed("k[i");
    try testing.expectEqual(0, ed2.cursorLine());
    try ed2.feed("jdii");
    try expectText(&ed2, "if x:\nend\n  \"s\" 'q' \"t\"");
    try ed2.feed("Gfqcinqz<Esc>"); // from inside 'q': the next quoted string
    try expectText(&ed2, "if x:\nend\n  \"s\" 'q' \"z\"");
}

test "mini.jump: f and t reach across lines; ; repeats" {
    var ed = try testEditor("abc\ndef x\nyy x");
    defer ed.deinit();
    try ed.feed("fx");
    try expectCursor(&ed, 1, 4);
    try testing.expect(ed.find_shown);
    try ed.feed(".");
    try expectCursor(&ed, 2, 3);
    try ed.feed("Fa");
    try expectCursor(&ed, 0, 0);
    try ed.feed("l");
    try testing.expect(!ed.find_shown);
    try ed.feed("dtx");
    try expectText(&ed, "ax\nyy x");
}

test "mini.bracketed: conflict markers and comment blocks; trailing whitespace" {
    var ed = try testEditor("x  \n<<<<<<< HEAD\na\t\n=======\nb\n>>>>>>> other\n# note\ny");
    defer ed.deinit();
    try ed.feed("]x");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("]x]x");
    try testing.expectEqual(5, ed.cursorLine());
    try ed.feed("[x");
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("]c");
    try testing.expectEqual(6, ed.cursorLine());
    try ed.feed("<cmd:trim_trailing_whitespace>");
    try expectText(&ed, "x\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n# note\ny");
    try ed.feed("u");
    try testing.expect(std.mem.startsWith(u8, ed.text().slice(0, 3), "x  "));
}

test "notifications: toasts expire, progress updates in place, history keeps both" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.notify(.info, "pushed", .{});
    ed.progress(7, true, "zls: indexing {d}%", .{10});
    ed.progress(7, true, "zls: indexing {d}%", .{80});
    try testing.expectEqual(2, ed.toasts.items.len);
    try testing.expectEqualStrings("zls: indexing 80%", ed.toasts.items[1].text());
    try testing.expect(ed.wantsFrames());
    // Long after: the plain toast is gone, the busy one stays until done.
    ed.now = ed.timeAfter(60_000);
    ed.pruneToasts();
    try testing.expectEqual(1, ed.toasts.items.len);
    ed.progress(7, false, "zls: done", .{});
    ed.now = ed.timeAfter(60_000);
    ed.pruneToasts();
    try testing.expectEqual(0, ed.toasts.items.len);
    ed.setMessage(.err, "oops", .{});
    try ed.feed("<Space>fn");
    settlePicker(&ed);
    try testing.expectEqualStrings("oops", ed.picker.?.itemAt(0).?.text);
    try testing.expectEqualStrings("pushed", ed.picker.?.itemAt(1).?.text);
    try ed.feed("q");
}

test "themes: moving previews, Esc goes back, Enter keeps" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.theme_names = &.{ "one", "two", "three" };
    try ed.feed("<cmd:pick_theme>");
    settlePicker(&ed);
    try ed.feed("j");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.theme_index);
    try ed.feed("<Esc>");
    try testing.expectEqual(0, ed.theme_index);
    try ed.feed("<cmd:pick_theme>");
    settlePicker(&ed);
    try ed.feed("jj<CR>");
    try testing.expectEqual(2, ed.theme_index);
}

test "smooth scrolling: the offset follows a scroll and glides to zero" {
    var buf: [400]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i % 2 == 0) 'x' else '\n';
    var ed = try testEditor(&buf);
    defer ed.deinit();
    ed.setViewSize(10, 40);
    ed.animate(0.016); // sees the buffer
    try ed.feed("<C-d>");
    ed.animate(0.016);
    const first = ed.view.scroll_offset;
    try testing.expect(first > 3 and first < 5); // already moving
    try testing.expect(ed.wantsFrames());
    // More scrolling while it glides adds on; every frame still moves.
    try ed.feed("<C-e>");
    ed.animate(0.016);
    const second = ed.view.scroll_offset;
    try testing.expect(second < first + 1 and second > first * 0.7);
    ed.animate(0.016);
    try testing.expect(ed.view.scroll_offset < second);
    for (0..80) |_| ed.animate(0.016);
    try testing.expectEqual(0, ed.view.scroll_offset);
    // Another buffer in the window is not a scroll.
    try ed.feed("<cmd:new_buffer>");
    ed.animate(0.016);
    try testing.expectEqual(0, ed.view.scroll_offset);
}

test "visits, recent files and sessions survive a restart" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/a.txt", .data = "a1\na2\na3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/b.txt", .data = "b1\nb2\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const state = try std.fs.path.join(gpa, &.{ base, "state" });
    defer gpa.free(state);
    const a = try std.fmt.allocPrint(gpa, "{s}/proj/a.txt", .{base});
    defer gpa.free(a);
    const b = try std.fmt.allocPrint(gpa, "{s}/proj/b.txt", .{base});
    defer gpa.free(b);
    const root = try std.fmt.allocPrint(gpa, "{s}/proj", .{base});
    defer gpa.free(root);

    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = state;
        ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
        try ed.openFile(b);
        try ed.openFile(a);
        try ed.feed("jj"); // a.txt: line 3
        try ed.feed("<cmd:split_right>");
        try ed.openFile(b);
        try ed.feed("j");
        try testing.expect(!Session.exists(&ed, root));
        try ed.feed("<Space>p<Esc>s"); // the projects picker: s saves the session
        try testing.expect(Session.exists(&ed, root));
        try ed.feed("<Esc>");
        // deinit saves the visits.
    }
    {
        var ed = try testEditor("");
        defer ed.deinit();
        ed.state_dir = state;
        ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
        // b.txt was opened most.
        try ed.feed("<cmd:recent_files>");
        settlePicker(&ed);
        try testing.expect(std.mem.endsWith(u8, ed.picker.?.itemAt(0).?.text, "b.txt"));
        try testing.expectEqual(2, ed.picker.?.rowCount());
        try ed.feed("<Esc><Esc>");

        try testing.expect(ed.restoreSession(root));
        try testing.expectEqual(2, ed.window_list.items.len);
        try testing.expectEqual(2, ed.buffers.items.len);
        // Focus is back in the right-hand window, on b.txt line 2.
        try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "b.txt"));
        try testing.expectEqual(1, ed.cursorLine());
        try ed.feed("<cmd:window_left>");
        try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "a.txt"));
        try testing.expectEqual(2, ed.cursorLine());
    }
}

test "Ctrl-/ toggles comments in normal, visual and insert mode, cursor on its text" {
    var ed = try testEditor("one\n  two\nthree");
    defer ed.deinit();
    try ed.feed("jw<C-/>"); // on "two"
    try expectText(&ed, "one\n  # two\nthree");
    try expectCursor(&ed, 1, 4);
    try ed.feed("ix<C-/>y<Esc>");
    try expectText(&ed, "one\n  xytwo\nthree");
    try ed.feed("ggVj<C-/>");
    try expectText(&ed, "# one\n#   xytwo\nthree");
    try testing.expectEqual(Mode.normal, ed.mode);
    try ed.feed("gg2<C-/>");
    try expectText(&ed, "one\n  xytwo\nthree");
    try ed.feed("jj<C-_>");
    try expectText(&ed, "one\n  xytwo\n# three");
}

test "wheel: fractions of a line show at once, settle on a whole line, stop at the ends" {
    var buf: [400]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i % 2 == 0) 'x' else '\n';
    var ed = try testEditor(&buf);
    defer ed.deinit();
    ed.setViewSize(10, 40);
    ed.animate(0.016);
    // At the top, scrolling up does nothing.
    ed.scrollSmooth(-0.4);
    try testing.expectEqual(0, ed.view.drawOffset());
    // Small steps add up; the text doesn't jump at the moment of input.
    for (0..7) |_| {
        const before = ed.view.drawOffset() - @as(f32, @floatFromInt(ed.view.top));
        ed.scrollSmooth(0.4);
        ed.animate(0); // sees `top` move, no time passes
        const after = ed.view.drawOffset() - @as(f32, @floatFromInt(ed.view.top));
        try testing.expectApproxEqAbs(before, after, 0.001);
    }
    try testing.expectEqual(2, ed.view.top); // 2.8 rows so far
    try testing.expectApproxEqAbs(0.8, ed.view.scroll_frac, 0.001);
    // The wheel rests: the nearer line (one more), then everything settles.
    for (0..120) |_| ed.animate(0.016);
    try testing.expectEqual(3, ed.view.top);
    try testing.expectEqual(0, ed.view.drawOffset());
    try testing.expect(!ed.wantsFrames());
}

test "QQ quits without asking, even with unsaved changes; Qq still records" {
    var ed = try testEditor("one");
    defer ed.deinit();
    try ed.feed("Qqxx");
    try testing.expectEqual('q', ed.macro_register.?);
    try ed.feed("Q");
    try testing.expect(!ed.should_quit);
    try ed.feed("QQ");
    try testing.expect(ed.should_quit);
}

test "ghost lines: o and O open a line in the text next to them" {
    // Rows: a, [gone 1], [gone 2], "  b", c
    var ed = try ghostEditor("a\ngone 1\ngone 2\n  b\nc", "a\n  b\nc");
    defer ed.deinit();
    try ed.feed("jj");
    try testing.expectEqualStrings("gone 2", ed.ghostText(ed.ghost.?.line, ed.ghost.?.k));
    try ed.feed("ox<Esc>"); // before the line below them, with its indent
    try expectText(&ed, "a\n  x\n  b\nc");
    try testing.expectEqual(null, ed.ghost);
    try ed.feed("u");
    try expectText(&ed, "a\n  b\nc");
    try ed.feed("ggj");
    try testing.expect(ed.ghost != null);
    try ed.feed("Oy<Esc>"); // after the line above them, with its indent
    try expectText(&ed, "a\ny\n  b\nc");
    // Other edits are still refused there.
    try ed.feed("u");
    try ed.feed("ggjdd");
    try expectText(&ed, "a\n  b\nc");
}

test "quickfix: without a run it is the project's live errors; a run's list takes over until cleared" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    var live = [_]QuickfixItem{
        .{ .path = @constCast("src/main.zig"), .line = 4, .col = 0, .text = @constCast("elsewhere") },
        .{ .path = @constCast("src/pairs.zig"), .line = 10, .col = 2, .text = @constCast("first here") },
        .{ .path = @constCast("src/pairs.zig"), .line = 30, .col = 0, .text = @constCast("second here") },
    };
    ed.live_errors_override = &live;
    // ]q: by the cursor, this file first, then the others.
    try ed.feed("]q");
    try testing.expectEqual(10, ed.cursorLine());
    try ed.feed("]q");
    try testing.expectEqual(30, ed.cursorLine());
    try ed.feed("[q");
    try testing.expectEqual(10, ed.cursorLine());
    try ed.feed("]q]q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    try testing.expectEqual(4, ed.cursorLine());
    // The list is live: a fixed error is gone the next time.
    ed.live_errors_override = live[1..];
    try ed.feed("<cmd:quickfix_list>");
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    try testing.expectEqualStrings("src/pairs.zig:11", ed.picker.?.itemAt(0).?.detail);
    try ed.feed("q");
    // A list of your own stays, whatever the errors are, until x in the quickfix picker.
    try ed.newQuickfix("mine");
    try ed.addQuickfix("src/main.zig", 1, 0, "picked");
    try ed.feed("]q");
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expectEqual(1, ed.quickfix.items.len);
    try ed.feed("<cmd:quickfix_list>x]q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/pairs.zig"));
    try testing.expectEqual(10, ed.cursorLine());
}

test "colour wheel: SPC l c edits the colour at the cursor; Enter writes, Esc leaves it, one undo" {
    var ed = try testEditor("a = #ff0000; b = 0x0000FF;");
    defer ed.deinit();
    try ed.feed("<cmd:pick_color>");
    try testing.expect(ed.color_picker != null);
    try testing.expectEqual(4, ed.view.cursor); // on the literal
    try ed.feed("60l<CR>"); // red, 120 degrees round: green
    try expectText(&ed, "a = #00ff00; b = 0x0000FF;");
    try testing.expectEqual(null, ed.color_picker);
    try ed.feed("u");
    try expectText(&ed, "a = #ff0000; b = 0x0000FF;");
    // From past the first literal: the next one, written back in its form.
    try ed.feed("$<cmd:pick_color>");
    try ed.feed("50j<Esc>"); // changed, then cancelled
    try expectText(&ed, "a = #ff0000; b = 0x0000FF;");
    try ed.feed("fb<cmd:pick_color>25Jy<CR>");
    try expectText(&ed, "a = #ff0000; b = 0x000080;");
    try testing.expectEqualStrings("0x000080", ed.registers.get(null).?.text);
    // Keys don't leak to the editor while it is open.
    try ed.feed("<cmd:pick_color>dd");
    try expectText(&ed, "a = #ff0000; b = 0x000080;");
    try ed.feed("q");
    try ed.feed("ggOno colours here<Esc><cmd:pick_color>");
    try testing.expectEqual(null, ed.color_picker);
}

test "SPC ; runs a one-off shell command: empty prompt, survives being cleared, leaves the runner alone" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    try ed.feed("<Space>;");
    try testing.expectEqual(PromptKind.run_command, ed.search_prompt.?.kind);
    try testing.expectEqualStrings("", ed.search_prompt.?.input.items());
    // Typing, deleting it all, and one more <BS>: still open.
    try ed.feed("ab<BS><BS><BS><BS>");
    try testing.expect(ed.search_prompt != null);
    try ed.feed("echo once<CR>");
    waitForRun(&ed);
    try testing.expectEqualStrings("echo once", ed.run_command.?);
    try ed.feed("q");
    // Not one of the runner's commands: its list is still empty.
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try ed.feed("<Esc><Esc>");
    // The search prompt still closes on <BS> when empty.
    try ed.feed("/<BS>");
    try testing.expectEqual(null, ed.search_prompt);
}

test "file browser: new folder and file, rename, move, copy and paste, delete" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    try tmp.dir.createDirPath(io, "sub");
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const exists = struct {
        fn at(d: Io.Dir, name: []const u8) bool {
            d.access(testing.io, name, .{}) catch return false;
            return true;
        }
    }.at;

    var ed = try testEditor("");
    defer ed.deinit();
    const a = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{base});
    defer gpa.free(a);
    try ed.openFile(a);
    try ed.feed("<Space>.<Esc>"); // the browser, in normal mode
    settlePicker(&ed);
    try testing.expectEqual(.browse, ed.picker.?.kind);

    try ed.feed("onewdir<CR>"); // o: a folder; back in the browser, on it
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "newdir"));
    try testing.expectEqualStrings("newdir/", ed.picker.?.itemAt(ed.picker.?.selected).?.text);

    try ed.feed("ggjj"); // newdir/, sub/, a.txt
    settlePicker(&ed);
    try testing.expectEqualStrings("a.txt", ed.picker.?.itemAt(ed.picker.?.selected).?.text);
    try ed.feed("yyp"); // copy, paste beside itself
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "a copy.txt"));

    try ed.feed("r<C-u>b.txt<CR>"); // rename the copy (selected after the paste)
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "b.txt"));
    try testing.expect(!exists(tmp.dir, "a copy.txt"));

    // Move the open file into sub/: its buffer follows.
    try ed.feed("gg");
    settlePicker(&ed);
    while (!std.mem.eql(u8, ed.picker.?.itemAt(ed.picker.?.selected).?.text, "a.txt")) {
        try ed.feed("j");
        settlePicker(&ed);
    }
    try ed.feed("m<C-u>sub/a.txt<CR>");
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "sub/a.txt"));
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "sub/a.txt"));
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/sub"));

    // Delete asks; No keeps, Yes removes and closes its buffer.
    try ed.feed("x");
    try testing.expectEqual(.confirm_remove, ed.picker.?.kind);
    settlePicker(&ed);
    try ed.feed("<CR>"); // "No" is first
    settlePicker(&ed);
    try testing.expect(exists(tmp.dir, "sub/a.txt"));
    try ed.feed("ddj<CR>");
    settlePicker(&ed);
    try testing.expect(!exists(tmp.dir, "sub/a.txt"));
    try testing.expectEqual(null, ed.buffer.path);
    // Esc in a prompt goes back to the browser.
    try ed.feed("nxyz<Esc>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed("q");
}

test "buffer picker: x closes the selected buffer in place; pickers take a visual selection" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    try ed.openFile("src/format.zig");
    try ed.feed("<Space>b<Esc>");
    settlePicker(&ed);
    try testing.expectEqualStrings("src/pairs.zig", ed.picker.?.itemAt(0).?.text);
    try ed.feed("x");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.buffers.items.len);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    try testing.expectEqual(.picker_normal, ed.mode);
    try ed.feed("q");
    // Visual SPC SPC / SPC /: the selection is the query.
    try ed.feed("<cmd:new_buffer>ihello @import<Esc>0viw<Space><Space>");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expectEqualStrings("hello", ed.picker.?.query.items());
    try ed.feed("<Esc><Esc>wviW<Space>/");
    try testing.expectEqual(.grep, ed.picker.?.kind); // not the symbols picker
    try testing.expectEqualStrings(" @import", ed.picker.?.query.items());
    try ed.feed("<Esc><Esc>");
}

test "marks: m sets, ' and ` go (also as motions), SPC f m lists; global marks cross files" {
    var ed = try testEditor("one\n  two\nthree\nfour");
    defer ed.deinit();
    try ed.feed("jwma"); // on "two"
    try ed.feed("G'a");
    try expectCursor(&ed, 1, 2);
    try ed.feed("gg`a");
    try expectCursor(&ed, 1, 2);
    try ed.feed("ggOzero<Esc>"); // marks move with the text
    try ed.feed("G'a");
    try testing.expectEqual(2, ed.cursorLine());
    try ed.feed("Gd'a"); // linewise, as a motion
    try expectText(&ed, "zero\none");
    try ed.feed("'z");
    try testing.expectEqual(.info, ed.message.kind);

    try ed.feed("mB"); // a global mark, here in the scratch buffer
    try ed.openFile("src/pairs.zig");
    try ed.feed("5jmc");
    try ed.feed("<cmd:pick_mark>");
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount()); // B and this file's c
    try ed.feed("q'B");
    try testing.expectEqual(null, ed.buffer.path); // back in the scratch buffer
}

test "pickers: registers paste, undo history travels the tree, help finds keys" {
    var ed = try testEditor("alpha beta");
    defer ed.deinit();
    try ed.feed("\"ayiww\"byiw");
    try ed.feed("<Space>fy");
    settlePicker(&ed);
    const p = ed.picker.?;
    var found: ?usize = null;
    for (0..p.rowCount()) |row| if (std.mem.eql(u8, p.itemAt(row).?.detail, "\"a")) {
        found = row;
    };
    for (0..found.?) |_| try ed.feed("j");
    try ed.feed("<CR>");
    try expectText(&ed, "alpha balphaeta");

    // Undo history: two more states, then back to an earlier one and forward
    // to a branch that plain redo could no longer reach.
    try ed.feed("u");
    try expectText(&ed, "alpha beta");
    try ed.feed("x"); // "alpha eta": a second branch from the same state
    try ed.feed("<Space>fu");
    settlePicker(&ed);
    try testing.expectEqual(3, ed.picker.?.rowCount()); // opened, the paste, the x
    try ed.feed("j<CR>"); // the paste's state
    try expectText(&ed, "alpha balphaeta");
    try ed.feed("<Space>fuG<CR>"); // the file as opened
    try expectText(&ed, "alpha beta");

    try ed.feed("<cmd:help_keys>comment / un");
    settlePicker(&ed);
    const h = ed.picker.?;
    try testing.expect(h.rowCount() > 0);
    try testing.expect(std.mem.indexOf(u8, h.itemAt(0).?.text, "Comment / uncomment") != null);
    try ed.feed("<Esc><Esc>");
}

test "pickers: the list of pickers opens one; code actions and project symbols list the server's answers" {
    var ed = try testEditor("");
    defer ed.deinit();
    // SPC f: the menu; / filters it by name, Enter opens the row.
    try ed.feed("<Space>f/undo");
    settlePicker(&ed);
    try testing.expectEqualStrings("Undo history", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<CR>");
    try testing.expectEqual(.undo, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // C-t: the same picker in its next scope, the query kept.
    try ed.feed("<Space><Space>main");
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try ed.feed("<C-t>");
    try testing.expectEqual(.buffers, ed.picker.?.kind);
    try testing.expectEqualStrings("main", ed.picker.?.query.items());
    try testing.expectEqual(Mode.picker, ed.mode);
    try ed.feed("<C-t>");
    try testing.expectEqual(.recent, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    // Search: project, then this file.
    try ed.feed("<Space>/x<C-t>");
    try testing.expectEqual(.lines, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");

    try ed.showCodeActions(); // none: a message, no picker
    try testing.expectEqual(null, ed.picker);
    try ed.addCodeAction("Remove unused variable", "quickfix", try testing.allocator.dupe(u8, "{}"));
    try ed.showCodeActions();
    settlePicker(&ed);
    try testing.expectEqualStrings("Remove unused variable", ed.picker.?.itemAt(0).?.text);
    try ed.feed("q");

    try ed.openPicker(.workspace_symbols, "");
    try ed.addWorkspaceSymbol("handleKey", "fn", "src/Editor.zig", 10, 4);
    try ed.workspaceSymbolsArrived(); // the server answered: the list fills in
    settlePicker(&ed);
    try testing.expectEqualStrings("handleKey", ed.picker.?.itemAt(0).?.text);
    try testing.expectEqualStrings("fn  src/Editor.zig:11", ed.picker.?.itemAt(0).?.detail);
    try ed.feed("<Esc><CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/Editor.zig"));
    try testing.expectEqual(10, ed.cursorLine());
}

test "todo tags: SPC l t writes a comment tag and leaves you typing; Ctrl-t from insert mode" {
    var ed = try testEditor("x = 1\n    ");
    defer ed.deinit();
    try ed.feed("<cmd:todo_tag>");
    settlePicker(&ed);
    try ed.feed("j<CR>"); // FIXME
    try testing.expectEqual(Mode.insert, ed.mode);
    try ed.feed("later<Esc>");
    try expectText(&ed, "x = 1 # FIXME: later\n    ");
    try ed.feed("jA<C-t>");
    settlePicker(&ed);
    try ed.feed("<CR>now<Esc>"); // TODO, on the blank line, keeping its indent
    try expectText(&ed, "x = 1 # FIXME: later\n    # TODO: now");
    try ed.feed("u");
    try expectText(&ed, "x = 1 # FIXME: later\n    ");
}

test "completion: arrow keys and Ctrl-n / Ctrl-p move through the suggestions" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doOne"},{"label":"doTwo"},{"label":"doThree"}]}
    , .{});
    defer reply.deinit();
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try testing.expectEqual(0, ed.completion.?.selected);
    try ed.feed("<Down>");
    try testing.expectEqual(1, ed.completion.?.selected);
    try ed.feed("<Down>");
    try testing.expectEqual(2, ed.completion.?.selected);
    try ed.feed("<Up>");
    try testing.expectEqual(1, ed.completion.?.selected);
    try ed.feed("<C-n><C-p><C-p>");
    try testing.expectEqual(0, ed.completion.?.selected);
    try ed.feed("<Down><CR>");
    try expectText(&ed, "doTwo");
}

test "completion: zls builtins after @ (the server's range starts after the @)" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ix = @");
    // As zls answers: filterText without the @, the edit from after it.
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[
        \\ {"label":"@as","filterText":"as","insertTextFormat":2,"textEdit":{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":5}},"newText":"as(${1:T}, ${2:x})"}},
        \\ {"label":"@import","filterText":"import","insertTextFormat":2,"textEdit":{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":5}},"newText":"import(${1:path})"}}
        \\]}
    , .{});
    defer reply.deinit();
    try ed.showCompletion(ed.buffer, 4, reply.value); // our guess: the word starts at the @
    try testing.expectEqual(2, ed.completion.?.shown.items.len);
    try ed.feed("im");
    try testing.expectEqual(1, ed.completion.?.shown.items.len);
    try ed.feed("<Tab>");
    try expectText(&ed, "x = @import(path)");
}

test "completion: a typo hides the list, fixing it brings the list back" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doOne"},{"label":"doTwo"}]}
    , .{});
    defer reply.deinit();
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try testing.expectEqual(2, ed.completionShown().?.shown.items.len);
    try ed.feed("x"); // "dox": nothing matches
    try testing.expectEqual(null, ed.completionShown());
    try testing.expect(ed.completion != null); // kept, out of sight
    try ed.feed("<CR>"); // keys act as if no popup were there...
    try expectText(&ed, "dox\n");
    try testing.expectEqual(null, ed.completion); // ...and leaving the word drops it
    try ed.feed("<BS>");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try testing.expectEqual(null, ed.completionShown());
    try ed.feed("<BS>T"); // fix the typo and go on: "doT"
    try testing.expectEqual(1, ed.completionShown().?.shown.items.len);
    try ed.feed("<BS><BS><BS>"); // back to nothing typed: every item
    try testing.expectEqual(2, ed.completionShown().?.shown.items.len);
    try ed.feed("d<Down><Tab>");
    try expectText(&ed, "doTwo");
}

test "completion: letter case never rules a suggestion out" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("iAR");
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"arrayList"},{"label":"ArrayList"},{"label":"other"}]}
    , .{});
    defer reply.deinit();
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try testing.expectEqual(2, ed.completionShown().?.shown.items.len);
    try ed.feed("<BS><BS><BS>arr");
    try testing.expectEqual(2, ed.completionShown().?.shown.items.len);
}

test "r replaces the character under the cursor (with a count, and repeatable)" {
    var ed = try testEditor("abcdef");
    defer ed.deinit();
    try ed.feed("rx");
    try expectText(&ed, "xbcdef");
    try ed.feed("l3ry");
    try expectText(&ed, "xyyyef");
    try ed.feed("0."); // the count goes with the repeat
    try expectText(&ed, "yyyyef");
    try ed.feed("$3rz"); // not enough characters left: nothing happens, as in vim
    try expectText(&ed, "yyyyef");
    try testing.expectEqual(Mode.normal, ed.mode);
}

test "new lines: a level deeper after an opening bracket; a closing bracket lines up with its opener" {
    var ed = try testEditor("fn f() {\n    if (x) {\n    }\n}");
    defer ed.deinit();
    try ed.feed("oa;<Esc>"); // below a line that opens a block
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n    }\n}");
    try ed.feed("jA<CR>b;<Esc>"); // Enter after `{`
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n    }\n}");
    try ed.feed("jOc;<Esc>"); // above the line that closes it
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n        c;\n    }\n}");
    try ed.feed("od;<Esc>"); // an ordinary line: the same indentation
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n        c;\n        d;\n    }\n}");
    // Typing the closer on a fresh line pulls it back to its opener's level.
    try ed.feed("<cmd:toggle_auto_pairs>"); // (auto pairs off: type it by hand)
    try ed.feed("Gowhile (y) {<CR>e;<CR>}<Esc>");
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n        c;\n        d;\n    }\n}\nwhile (y) {\n    e;\n}");
}

test "indentation follows the file: two spaces, or tabs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "two.c", .data = "int f() {\n  if (x) {\n    y();\n  }\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tabs.c", .data = "int f() {\n\tif (x) {\n\t\ty();\n\t}\n}\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const two = try std.fmt.allocPrint(gpa, "{s}/two.c", .{base});
    defer gpa.free(two);
    const tabs = try std.fmt.allocPrint(gpa, "{s}/tabs.c", .{base});
    defer gpa.free(tabs);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.options.format_on_save = false;
    try ed.openFile(two);
    try testing.expectEqual(2, ed.indentWidth());
    try ed.feed("joz();<Esc>"); // after `if (x) {`: four spaces, not eight
    try testing.expectEqualStrings("    z();", ed.text().lineSlice(2));
    try ed.feed(">>");
    try testing.expectEqualStrings("      z();", ed.text().lineSlice(2));
    try ed.feed("I<Tab><Esc>"); // a tab key is one level too
    try testing.expectEqualStrings("        z();", ed.text().lineSlice(2));

    try ed.openFile(tabs);
    try testing.expect(ed.usesTabs());
    try ed.feed("joz();<Esc>");
    try testing.expectEqualStrings("\t\tz();", ed.text().lineSlice(2));
    try ed.feed("<lt><lt>");
    try testing.expectEqualStrings("\tz();", ed.text().lineSlice(2));
}

test "pickers that jump to a line centre it" {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    for (0..200) |i| try lines.print(testing.allocator, "line {d}\n", .{i});
    var ed = try testEditor(lines.items);
    defer ed.deinit();
    ed.setViewSize(20, 40);
    try ed.feed("<cmd:search_buffer>line 150<CR>");
    try testing.expectEqual(150, ed.cursorLine());
    try testing.expectEqual(140, ed.view.top); // ten rows above it
    try ed.feed("ggmaG<cmd:pick_mark><CR>"); // a mark near the top: as centred as the start allows
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(0, ed.view.top);
}

test "indent guide: appears once the cursor settles in a scope, hides at once on leaving it" {
    var ed = try testEditor("fn a() {\n    x;\n    y;\n}\nfn b() {\n    z;\n}");
    defer ed.deinit();
    try ed.feed("j");
    ed.tick();
    try testing.expectEqual(null, ed.indent_guide); // not yet
    try testing.expect(ed.wantsFrames()); // but a frame is due
    ed.now = ed.timeAfter(indent_guide_delay_ms + 20);
    ed.tickIndentGuide();
    try testing.expectEqual(1, ed.indent_guide.?.scope.first);
    // It grows out from the cursor's line, a row every step.
    try testing.expectEqual(1, ed.indent_guide.?.origin);
    try testing.expectEqual(0, ed.indent_guide.?.reach(ed.now));
    try testing.expect(ed.wantsFrames()); // still growing
    ed.now.nanoseconds += 10 * indent_guide_step_ms * std.time.ns_per_ms;
    try testing.expectEqual(10, ed.indent_guide.?.reach(ed.now));
    try testing.expect(!ed.wantsFrames()); // done: the block is two rows
    // Within the block it stays; typing a line in it keeps it.
    try ed.feed("j");
    ed.tickIndentGuide();
    try testing.expectEqual(1, ed.indent_guide.?.scope.first);
    try ed.feed("ow;<Esc>");
    ed.tickIndentGuide();
    try testing.expectEqual(3, ed.indent_guide.?.scope.last);
    // On into the next block: gone straight away, back after the delay.
    try ed.feed("3j");
    ed.tickIndentGuide();
    try testing.expectEqual(null, ed.indent_guide);
    ed.now = ed.timeAfter(10 * indent_guide_delay_ms); // well past the wait
    ed.tickIndentGuide();
    try testing.expectEqual(6, ed.indent_guide.?.scope.first);
}

test "file browser: typing a name ending in / makes a folder and goes into it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const a = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{base});
    defer gpa.free(a);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(a);
    try ed.feed("<Space>.");
    settlePicker(&ed);
    try ed.feed("newdir/"); // nothing matches, so the / is part of the name
    try testing.expectEqualStrings("newdir/", ed.picker.?.query.items());
    settlePicker(&ed);
    try ed.feed("<CR>");
    tmp.dir.access(io, "newdir", .{}) catch return error.FolderNotMade;
    try testing.expectEqual(.browse, ed.picker.?.kind);
    try testing.expect(std.mem.endsWith(u8, ed.browse_dir.items, "/newdir"));
    // Nested, and a plain name is still a file.
    try ed.feed("x/y/");
    settlePicker(&ed);
    try ed.feed("<CR>");
    tmp.dir.access(io, "newdir/x/y", .{}) catch return error.FolderNotMade;
    try ed.feed("note.txt");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "x/y/note.txt"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "newdir/x/y/note.txt", .{})); // not on disk until saved
}

test "git init: SPC g i makes the project a repository, and the open file becomes a git file" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Not under the checkout the tests run in (that is a repository already,
    // and a project's git root is the outermost one found).
    const dir = try std.fmt.allocPrint(gpa, "/tmp/zile-test-gitinit-{d}", .{Io.Timestamp.now(io, .real).nanoseconds});
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const file = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{dir});
    defer gpa.free(file);
    const build = try std.fmt.allocPrint(gpa, "{s}/build.zig", .{dir});
    defer gpa.free(build);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "one\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = build, .data = "" });

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(file);
    try testing.expectEqual(null, ed.gitRoot()); // a build.zig project, no repository yet
    try ed.feed("<cmd:git_init>");
    while (ed.git_job) |job| {
        if (job.done.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    ed.tick();
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{dir});
    defer gpa.free(dot_git);
    Io.Dir.cwd().access(io, dot_git, .{}) catch return error.NoRepository;
    try testing.expectEqualStrings(dir, ed.gitRoot().?);
    try testing.expect(ed.buffer.project.?.git);
    // Again: it says so instead of starting over.
    try ed.feed("<cmd:git_init>");
    try testing.expectEqual(null, ed.git_job);
    try testing.expect(std.mem.startsWith(u8, ed.message.text(), "already in a git repository"));
}

test "commands run in the folder of the code you are in" {
    const gpa = testing.allocator;
    const io = testing.io;
    const base = try std.fmt.allocPrint(gpa, "/tmp/zile-test-runfolder-{d}", .{Io.Timestamp.now(io, .real).nanoseconds});
    defer gpa.free(base);
    const cwd = Io.Dir.cwd();
    defer cwd.deleteTree(io, base) catch {};
    for ([_][]const u8{ "repo/.git", "repo/app/src", "repo/docs", "loose" }) |sub| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, sub });
        defer gpa.free(p);
        try cwd.createDirPath(io, p);
    }
    const files = [_][2][]const u8{
        .{ "repo/app/Makefile", "" },     .{ "repo/app/src/main.c", "int x;\n" },
        .{ "repo/docs/notes.txt", "n\n" }, .{ "loose/x.txt", "x\n" },
    };
    for (files) |f| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, f[0] });
        defer gpa.free(p);
        try cwd.writeFile(io, .{ .sub_path = p, .data = f[1] });
    }
    const at = struct {
        fn path(g: std.mem.Allocator, b: []const u8, rel: []const u8) ![]u8 {
            return std.fmt.allocPrint(g, "{s}/{s}", .{ b, rel });
        }
    }.path;

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try gpa.dupe(u8, "/nonexistent/run-commands");
    // Inside the app: its Makefile's folder, not the repository's root.
    const main_c = try at(gpa, base, "repo/app/src/main.c");
    defer gpa.free(main_c);
    try ed.openFile(main_c);
    const folder = try ed.commandFolder();
    defer gpa.free(folder);
    const want_app = try at(gpa, base, "repo/app");
    defer gpa.free(want_app);
    try testing.expectEqualStrings(want_app, folder);
    // No build file on the way up: the project root.
    const notes = try at(gpa, base, "repo/docs/notes.txt");
    defer gpa.free(notes);
    try ed.openFile(notes);
    const root = try ed.commandFolder();
    defer gpa.free(root);
    const want_root = try at(gpa, base, "repo");
    defer gpa.free(want_root);
    try testing.expectEqualStrings(want_root, root);
    // A file in no project: its own folder, whatever project came before it.
    const loose = try at(gpa, base, "loose/x.txt");
    defer gpa.free(loose);
    try ed.openFile(loose);
    const own = try ed.commandFolder();
    defer gpa.free(own);
    const want_loose = try at(gpa, base, "loose");
    defer gpa.free(want_loose);
    try testing.expectEqualStrings(want_loose, own);
    // Its runner history is its own too, not the project's from before.
    const memory = try at(gpa, base, "run-commands");
    defer gpa.free(memory);
    gpa.free(ed.run_memory_path.?);
    ed.run_memory_path = try gpa.dupe(u8, memory);
    try ed.openFile(main_c);
    try ed.feed("<cmd:run_runner>make app<CR>");
    waitForRun(&ed);
    try ed.feed("q");
    try ed.openFile(loose);
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try ed.feed("<Esc><Esc>");
    try ed.openFile(main_c);
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("make app", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
    try ed.openFile(loose);
    // And that is where the command really runs.
    try ed.feed("<Space>;pwd<CR>");
    waitForRun(&ed);
    const out = try ed.run.?.screenText(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.startsWith(u8, out, want_loose));
    try testing.expectEqualStrings(want_loose, ed.run_root);
    try ed.feed("q");
}

test "runner: e / Ctrl-e pulls a previous command into the query to append to or cut down" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });
    try ed.feed("<cmd:run_runner>echo hello<CR>");
    waitForRun(&ed);
    try ed.feed("q<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("echo hello", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc>e"); // from the list: into the query, typing again
    try testing.expectEqual(Mode.picker, ed.mode);
    try testing.expectEqualStrings("echo hello", ed.picker.?.query.items());
    try ed.feed(" world<CR>"); // appended
    waitForRun(&ed);
    try testing.expectEqualStrings("echo hello world", ed.run_command.?);
    // Newest first now; Tab, cut the " world" off again, and Enter runs
    // what is left, which is the older command.
    try ed.feed("q<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("echo hello world", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<C-e><BS><BS><BS><BS><BS><BS><CR>"); // six: " world"
    waitForRun(&ed);
    try testing.expectEqualStrings("echo hello", ed.run_command.?);
    // Cut down to something new: it runs as typed, not as the entry it resembles.
    try ed.feed("q<cmd:run_runner><C-e><BS><BS>xy<CR>");
    waitForRun(&ed);
    try testing.expectEqualStrings("echo helxy", ed.run_command.?);
}

test "snippet: Esc removes the arguments that were never filled in, with their commas" {
    const gpa = testing.allocator;
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"doThing","insertText":"doThing(${1:path: Path}, ${2:opts: Opts}, ${3:last})$0","insertTextFormat":2}]}
    , .{});
    defer reply.deinit();

    // Nothing filled in: the whole argument list goes.
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ido");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("<Tab>");
    try expectText(&ed, "doThing(path: Path, opts: Opts, last)");
    try ed.feed("<Esc>");
    try expectText(&ed, "doThing()");
    try testing.expectEqual(Mode.normal, ed.mode);
    try testing.expectEqual(null, ed.snippet);
    try testing.expectEqual(7, ed.view.cursor); // on the (
    try ed.feed("u"); // one undo step for the whole insert
    try expectText(&ed, "");

    // The first one typed over: the rest go, and the comma after it.
    try ed.feed("ido");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("<Tab>src<Esc>");
    try expectText(&ed, "doThing(src)");

    // Tabbed on to the second without typing: it goes (the first was left
    // as it came); the third was never reached.
    try ed.feed("S"); // start over on the line
    try ed.feed("do");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("<Tab><Tab><Esc>");
    try expectText(&ed, "doThing(path: Path)");
}

test "inlay hints: parsed from zls's answer, kept in place through edits, mapped to columns" {
    const gpa = testing.allocator;
    var ed = try testEditor("const x = add(1, 2);\nconst s = \"zile\";");
    defer ed.deinit();
    ed.options.inlay_hints = true;
    // As zls answers (labels, padding, byte columns).
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\[{"position":{"line":0,"character":7},"label":": u32","kind":1,"paddingLeft":false,"paddingRight":false},
        \\ {"position":{"line":0,"character":14},"label":"a:","kind":2,"paddingLeft":false,"paddingRight":true},
        \\ {"position":{"line":0,"character":17},"label":[{"value":"b"},{"value":":"}],"kind":2,"paddingRight":true},
        \\ {"position":{"line":1,"character":7},"label":": *const [4:0]u8","kind":1},
        \\ {"position":{"line":9,"character":0},"label":"off the end"},
        \\ {"position":{"line":0,"character":2},"label":""}]
    , .{});
    defer reply.deinit();
    var parsed: std.ArrayList(Buffer.Hint) = .empty;
    defer {
        for (parsed.items) |h| gpa.free(h.text);
        parsed.deinit(gpa);
    }
    try Lsp.parseInlayHints(gpa, ed.text(), reply.value, &parsed);
    try testing.expectEqual(4, parsed.items.len); // the empty label and the missing line are skipped
    try testing.expectEqualStrings("b: ", parsed.items[2].text); // parts joined, padding added

    try ed.takeInlayHints(ed.buffer, &parsed, 0, 1, ed.buffer.edit_version);
    try testing.expectEqual(0, parsed.items.len); // the buffer has them now
    var buf: [max_line_hints]LineHint = undefined;
    const first = ed.lineHints(ed.buffer, 0, &buf);
    try testing.expectEqual(3, first.len);
    try testing.expectEqual(7, first[0].off);
    // `x` ends at 7: the hint is in front of the byte at 7 (the space).
    try testing.expectEqual(0, hintShift(first, 6));
    try testing.expectEqual(5, hintShift(first, 7)); // ": u32"
    try testing.expectEqual(5 + 3, hintShift(first, 14)); // + "a: "
    try testing.expectEqual(5, hintShiftBefore(first, 14)); // a range ending at 14 stops before it
    // And back: the screen column of a character after the hints.
    const bytes = ed.text().lineSlice(0);
    try testing.expectEqual(14, hintVisualToText(first, bytes, 14 + 5 + 3, 4)); // the `1`
    try testing.expectEqual(7, hintVisualToText(first, bytes, 8, 4)); // on the first hint: the text after it

    // Typing before a hint moves it on; deleting around it keeps it in the line.
    try ed.feed("ggi// <Esc>");
    const moved = ed.lineHints(ed.buffer, 0, &buf);
    try testing.expectEqual(10, moved[0].off);
    try ed.feed("0dw");
    try testing.expectEqual(7, ed.lineHints(ed.buffer, 0, &buf)[0].off);
    // Not on the line being typed on in insert mode.
    try ed.feed("A");
    try testing.expectEqual(0, ed.lineHints(ed.buffer, 0, &buf).len);
    try testing.expectEqual(1, ed.lineHints(ed.buffer, 1, &buf).len);
    try ed.feed("<Esc>");
    try testing.expectEqual(3, ed.lineHints(ed.buffer, 0, &buf).len);

    // A new answer for the lines replaces the old; one for stale text is dropped.
    var again: std.ArrayList(Buffer.Hint) = .empty;
    defer again.deinit(gpa);
    try again.append(gpa, .{ .pos = 0, .text = try gpa.dupe(u8, "new ") });
    const stale_version = ed.buffer.edit_version -% 1;
    try ed.takeInlayHints(ed.buffer, &again, 0, 1, stale_version);
    try testing.expectEqual(3, ed.lineHints(ed.buffer, 0, &buf).len); // dropped
    gpa.free(again.items[0].text);
    again.clearRetainingCapacity();
    try again.append(gpa, .{ .pos = 0, .text = try gpa.dupe(u8, "new ") });
    try ed.takeInlayHints(ed.buffer, &again, 0, 1, ed.buffer.edit_version);
    try testing.expectEqual(1, ed.lineHints(ed.buffer, 0, &buf).len);
    try testing.expectEqual(0, ed.lineHints(ed.buffer, 1, &buf).len);
    // Off: nothing.
    ed.options.inlay_hints = false;
    try testing.expectEqual(0, ed.lineHints(ed.buffer, 0, &buf).len);
}

test "inlay hints: a click lands on the character it looks like it is on" {
    const gpa = testing.allocator;
    var ed = try testEditor("const x = 1;");
    defer ed.deinit();
    var new: std.ArrayList(Buffer.Hint) = .empty;
    defer new.deinit(gpa);
    try new.append(gpa, .{ .pos = 7, .text = try gpa.dupe(u8, ": u8") });
    try ed.takeInlayHints(ed.buffer, &new, 0, 0, ed.buffer.edit_version);
    ed.clickCell(0, 6); // the `x`
    try testing.expectEqual(6, ed.view.cursor);
    ed.clickCell(0, 12); // after the hint: " = " begins at screen column 11
    try testing.expectEqual(8, ed.view.cursor); // the `=` is at 8, screen column 12
    ed.clickCell(0, 8); // on the hint: the text right after it
    try testing.expectEqual(7, ed.view.cursor);
}

test "autopairs: Tab steps over a closing quote and bracket instead of inserting a tab" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ifoo(\"hi");
    try expectText(&ed, "foo(\"hi\")");
    try ed.feed("<Tab>"); // out of the quote
    try testing.expectEqual(8, ed.view.cursor);
    try ed.feed("<Tab>"); // out of the call
    try testing.expectEqual(9, ed.view.cursor);
    try ed.feed("<Tab>x"); // nothing to step over: a tab as usual
    try expectText(&ed, "foo(\"hi\")   x"); // to the next tab stop
    // An empty pair, and nested ones.
    try ed.feed("<Esc>Sg([\"\"]");
    try expectText(&ed, "g([\"\"])");
    try ed.feed("<Esc>0f\"a<Tab><Tab><Tab>"); // inside the quotes: out of "", ], )
    try testing.expectEqual(7, ed.view.cursor);
    // A quote that opens a string isn't stepped over; nor is a closer at the
    // start of a line (that is indentation).
    try ed.feed("<Esc>S0 = \"abc\"<Esc>0f\"i<Tab>");
    try expectText(&ed, "0 =     \"abc\"");
    try ed.feed("<Esc>S}<Esc>0i<Tab>");
    try expectText(&ed, "    }");
    // Off with autopairs.
    try ed.feed("<Esc><cmd:toggle_auto_pairs>Sf(1)<Esc>i<Tab>"); // (S keeps the line's indentation)
    try expectText(&ed, "    f(1 )");
}

test "f, t, F, T ignore letter case; ; and , repeat" {
    var ed = try testEditor("xAbca\nDa");
    defer ed.deinit();
    try ed.feed("fa");
    try expectCursor(&ed, 0, 1); // the capital A
    try ed.feed(".");
    try expectCursor(&ed, 0, 4);
    try ed.feed("FA"); // a capital finds lower case too
    try expectCursor(&ed, 0, 1);
    try ed.feed("0dtA"); // till still works after an operator
    try expectText(&ed, "Abca\nDa");
    try ed.feed("u");
    try ed.feed("fd"); // on to the next line: "Da"
    try expectCursor(&ed, 1, 0);
    try ed.feed("$dFa"); // back across the line to the previous a; F is exclusive: "a\nD" goes
    try expectText(&ed, "xAbca");
}

test "completion: ( takes the selected suggestion's name, then opens the call" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"drawText","insertText":"drawText(${1:text}, ${2:x})$0","insertTextFormat":2},{"label":"other"}]}
    , .{});
    defer reply.deinit();
    try ed.feed("idrawtex");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try testing.expectEqual(1, ed.completionShown().?.shown.items.len);
    try ed.feed("(");
    try expectText(&ed, "drawText()");
    try testing.expectEqual(9, ed.view.cursor); // inside the parentheses
    try testing.expectEqual(null, ed.completion);
    // A plain item works the same; nothing to take when nothing matches.
    try ed.feed("<Esc>Soth");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("(");
    try expectText(&ed, "other()");
    try ed.feed("<Esc>Szzz");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    try ed.feed("(");
    try expectText(&ed, "zzz()");
}

test "o, O and Enter on a blank line indent like the code around it" {
    var ed = try testEditor("fn f() {\n    if (x) {\n\n        y;\n    }\n}");
    defer ed.deinit();
    try ed.feed("ggjjoz<Esc>"); // below the blank line: the block's level, not column 0
    try expectText(&ed, "fn f() {\n    if (x) {\n\n        z\n        y;\n    }\n}");
    try ed.feed("ggjjOw<Esc>"); // above it
    try expectText(&ed, "fn f() {\n    if (x) {\n        w\n\n        z\n        y;\n    }\n}");
    try ed.feed("ggjjjA<CR>v<Esc>"); // Enter on the blank line
    try expectText(&ed, "fn f() {\n    if (x) {\n        w\n\n        v\n        z\n        y;\n    }\n}");
    // After a finished block, the level of the line closing it.
    try ed.feed("Go<Esc>o}<Esc>");
    // Nothing above: the code below it.
    var top = try testEditor("\n\n    a;");
    defer top.deinit();
    try top.feed("ggox<Esc>");
    try expectText(&top, "\n    x\n\n    a;");
}

test "completion: the exact name first, then shorter names, whatever order the server sent" {
    const gpa = testing.allocator;
    var ed = try testEditor("");
    defer ed.deinit();
    const reply = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"DrawTexture"},{"label":"DrawTextureV"},{"label":"DrawTextEx"},{"label":"DrawText"},{"label":"DrawTextCodepoint"}]}
    , .{});
    defer reply.deinit();
    try ed.feed("idrawtext");
    try ed.showCompletion(ed.buffer, 0, reply.value);
    const c = ed.completionShown().?;
    try testing.expectEqualStrings("DrawText", c.items[c.shown.items[0]].label);
    // Not yet the whole name: the shortest of the equal matches leads.
    try ed.feed("<BS>");
    const d = ed.completionShown().?;
    try testing.expectEqualStrings("DrawText", d.items[d.shown.items[0]].label);
    try testing.expectEqualStrings("DrawTextEx", d.items[d.shown.items[1]].label);
    try testing.expectEqualStrings("DrawTexture", d.items[d.shown.items[2]].label);
    try ed.feed("<CR>"); // Enter takes the first one
    try expectText(&ed, "DrawText");
}

