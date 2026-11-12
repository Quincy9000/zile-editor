//! Picker sources. Each source is a struct with a fixed set of declarations,
//! dispatched at comptime by `Kind`:
//!
//!   title:   []const u8           prompt label
//!   start_mode: StartMode          typing (.insert) or moving (.normal) first
//!   prefix:  ?u8                  typing this first switches any picker here
//!   fill:    fn (*Editor, *Items)  static items, filled on the main thread
//!   produce: Engine.Producer      dynamic items, produced on the worker thread
//!   accept:  fn (*Editor, Item)    act on the chosen item (main thread)
//!   create:  fn (*Editor, query)   optional "Create <query>" row
//!   preview: fn (*Editor, *const Item, *Preview)
//!   location: fn (*Editor, Item)   optional: the place an item stands for
//!
//! Adding a source = adding a `Kind` tag and a struct below.

const std = @import("std");
const debugging = @import("../debugging.zig");
const Io = std.Io;
const Editor = @import("../Editor.zig");
const Engine = @import("Engine.zig");
const Items = @import("Items.zig");
const Item = Items.Item;
const commands = @import("../commands.zig");
const keys = @import("../input/keys.zig");
const Syntax = @import("../syntax/Syntax.zig");
const languages = @import("../syntax/languages.zig");
const motions = @import("../core/motions.zig");
const Git = @import("../git/Git.zig");
const hipatterns = @import("../core/hipatterns.zig");
const keymap = @import("../input/keymap.zig");

pub const Kind = enum { files, buffers, commands, lines, grep, locations, diagnostics, symbols, git_actions, git_branches, git_changes, confirm_delete, browse, jumps, run_errors, projects, open_in, quickfix, recent, todos, themes, messages, start, confirm_remove, runner, registers, marks, undo, help, pickers, files_anywhere, folders_anywhere, code_actions, workspace_symbols, todo_tags, man, frecent, windows, toggles, code_menu, leader, leader_projects, leader_claude, leader_quit, files_global, debug };

fn Impl(comptime kind: Kind) type {
    return switch (kind) {
        .files => Files,
        .buffers => Buffers,
        .commands => Commands,
        .lines => Lines,
        .grep => Grep,
        .locations => Locations,
        .diagnostics => Diagnostics,
        .symbols => Symbols,
        .git_actions => GitActions,
        .git_branches => GitBranches,
        .git_changes => GitChanges,
        .confirm_delete => ConfirmDelete,
        .browse => Browse,
        .jumps => Jumps,
        .run_errors => RunErrors,
        .projects => Projects,
        .open_in => OpenIn,
        .quickfix => Quickfix,
        .recent => Recent,
        .todos => Todos,
        .themes => Themes,
        .messages => Messages,
        .start => Start,
        .confirm_remove => ConfirmRemove,
        .runner => Runner,
        .registers => RegisterList,
        .marks => Marks,
        .undo => UndoHistory,
        .help => Help,
        .pickers => Pickers,
        .files_anywhere => Anywhere(false),
        .folders_anywhere => Anywhere(true),
        .code_actions => CodeActions,
        .workspace_symbols => WorkspaceSymbols,
        .todo_tags => TodoTags,
        .man => ManPages,
        .frecent => Frecent,
        .windows => WindowList,
        .toggles => Toggles,
        .code_menu => CodeMenu,
        .leader => Leader,
        .leader_projects => ProjectsMenu,
        .leader_claude => ClaudeMenu,
        .leader_quit => QuitMenu,
        .files_global => GlobalFiles,
        .debug => Debug,
    };
}

pub const Preview = struct {
    text: std.ArrayList(u8) = .empty,
    /// Line to scroll to (0-based).
    focus_line: usize = 0,
    /// Show line numbers (file contents, not prose).
    numbered: bool = false,
    /// Syntax style per byte of `text` (empty when not highlighted).
    styles: std.ArrayList(Syntax.Style) = .empty,

    pub fn clear(p: *Preview) void {
        p.text.clearRetainingCapacity();
        p.styles.clearRetainingCapacity();
        p.focus_line = 0;
        p.numbered = false;
    }

    /// Shows file contents: numbered and, for known languages, highlighted.
    fn setCode(p: *Preview, gpa: std.mem.Allocator, text: []const u8, path: ?[]const u8) !void {
        try p.text.appendSlice(gpa, text);
        p.numbered = true;
        // Big previews would take a noticeable moment to parse.
        if (text.len > max_highlight) return;
        const lang = languages.forPath(path orelse return) orelse return;
        try Syntax.highlightText(gpa, lang, p.text.items, &p.styles);
    }

    const max_highlight = 256 * 1024;
};

pub fn title(kind: Kind) []const u8 {
    return switch (kind) {
        inline else => |k| Impl(k).title,
    };
}

/// The Debug picker's title, with the program's state.
pub fn debugTitle(ed: *Editor) []const u8 {
    return Debug.liveTitle(ed);
}

pub fn prefix(kind: Kind) ?u8 {
    return switch (kind) {
        inline else => |k| Impl(k).prefix,
    };
}

/// Sources whose items depend on the query get a fresh engine per query.
pub fn queryDriven(kind: Kind, io: Io) bool {
    return switch (kind) {
        .grep => haveRg(io),
        // The whole disk is searched per query, never listed.
        .files_anywhere, .folders_anywhere => true,
        // So is your home, under the explorer's own rows.
        .files_global => true,
        else => false,
    };
}

pub fn canCreate(kind: Kind) bool {
    return switch (kind) {
        inline else => |k| @hasDecl(Impl(k), "create"),
    };
}

/// Sources where the typed text is what Enter takes unless you move to a
/// row (the runner: a new command, not the old one it happens to match).
pub fn createFirst(kind: Kind) bool {
    return switch (kind) {
        inline else => |k| @hasDecl(Impl(k), "create_first"),
    };
}

/// What the "create" row says before the typed text.
pub fn createLabel(kind: Kind) []const u8 {
    return switch (kind) {
        inline else => |k| if (@hasDecl(Impl(k), "create_label")) Impl(k).create_label else "+ Create ",
    };
}

/// The source a query's first byte switches to, if any.
pub fn byPrefix(c: u8) ?Kind {
    inline for (comptime std.meta.tags(Kind)) |k| {
        if (Impl(k).prefix) |p| if (p == c) return k;
    }
    return null;
}

/// Static sources fill `e.items` now; dynamic ones return their producer.
pub fn setup(kind: Kind, ed: *Editor, e: *Engine) !?Engine.Producer {
    switch (kind) {
        inline else => |k| {
            const S = Impl(k);
            if (@hasDecl(S, "fill")) try S.fill(ed, &e.items);
            // The explorer: the folder's entries when nothing is typed; the
            // files below it (visited ones first, then the rest) as you type.
            if (@hasDecl(S, "fillTyped")) {
                e.empty_limit = e.items.count();
                try S.fillTyped(ed, e);
            }
            return if (@hasDecl(S, "produce")) S.produce else null;
        },
    }
}

pub fn accept(kind: Kind, ed: *Editor, item: Item) !void {
    switch (kind) {
        inline else => |k| try Impl(k).accept(ed, item),
    }
}

pub fn create(kind: Kind, ed: *Editor, query: []const u8) !void {
    switch (kind) {
        inline else => |k| if (@hasDecl(Impl(k), "create")) try Impl(k).create(ed, query),
    }
}

/// The mode a picker opens in: `.insert` (typing the query) for ones you
/// search, `.normal` (moving with j/k) for short lists you step through.
/// Every source must choose.
pub const StartMode = enum { insert, normal };

pub fn startsNormal(kind: Kind) bool {
    return switch (kind) {
        inline else => |k| blk: {
            if (!@hasDecl(Impl(k), "start_mode")) @compileError("picker source " ++ @tagName(k) ++ " must declare start_mode");
            break :blk Impl(k).start_mode == .normal;
        },
    };
}

// ---------------------------------------------------------------------------
// Actions: what a picker does with a row besides Enter. Every picker shows
// its own at the bottom: letters after <Esc>, Ctrl keys while typing, and
// all of them (with the "open in a split" ones) in the <Tab> menu.

pub const Action = struct {
    /// Shown in the bar and the <Tab> menu ("close", "rename...").
    label: []const u8,
    /// Its letter in the picker's normal mode (0: none).
    key: u8 = 0,
    /// Ctrl + this letter, typing or not (0: none).
    ctrl: u8 = 0,
    /// Runs with the picker open, which then lists its rows again (closing a
    /// buffer, flipping a setting); else the picker closes first (a prompt,
    /// a split).
    stay: bool = false,
    /// Needs no row (a new buffer, save all).
    any: bool = false,
    /// With `stay`: the rows don't change, so they aren't listed again.
    keep_rows: bool = false,
    run: *const fn (ed: *Editor, item: ?Item) anyerror!void,
};

/// Ctrl-Enter: a second way to accept (the runner: under the debugger).
pub const AltAccept = struct {
    label: []const u8,
    /// Gets the selected row's text, or the query on the typed row.
    run: *const fn (ed: *Editor, text: []const u8) anyerror!void,
};

pub fn altAccept(kind: Kind) ?AltAccept {
    return switch (kind) {
        inline else => |k| if (@hasDecl(Impl(k), "alt_accept")) Impl(k).alt_accept else null,
    };
}

pub fn itemActions(kind: Kind) []const Action {
    return switch (kind) {
        inline else => |k| if (@hasDecl(Impl(k), "item_actions")) &Impl(k).item_actions else &.{},
    };
}

/// Menus: each row's key runs it (shown beside it); `row_keys[id]`.
pub fn rowKeys(kind: Kind) []const u8 {
    return switch (kind) {
        inline else => |k| if (@hasDecl(Impl(k), "row_keys")) Impl(k).row_keys else "",
    };
}

/// Enter does the row's thing and the picker stays (the toggles).
pub fn staysOpen(kind: Kind) bool {
    return switch (kind) {
        inline else => |k| @hasDecl(Impl(k), "stays_open"),
    };
}

// ---------------------------------------------------------------------------
// Scopes: pickers that are one picker over different ranges. `C-t` steps
// through a group, keeping what you typed.

const Scope = struct { kind: Kind, name: []const u8, command: []const u8 };

const scope_groups = [_][]const Scope{
    &.{
        .{ .kind = .browse, .name = "folder", .command = "find_file" },
        .{ .kind = .buffers, .name = "buffers", .command = "switch_buffer" },
        .{ .kind = .recent, .name = "recent everywhere", .command = "recent_files" },
        .{ .kind = .files_anywhere, .name = "whole disk", .command = "find_file_anywhere" },
    },
    &.{
        .{ .kind = .grep, .name = "project", .command = "search_project" },
        .{ .kind = .lines, .name = "this file", .command = "search_buffer" },
        .{ .kind = .todos, .name = "todos", .command = "search_todos" },
    },
    &.{
        .{ .kind = .symbols, .name = "this file", .command = "goto_symbol" },
        .{ .kind = .workspace_symbols, .name = "project", .command = "workspace_symbols" },
    },
    &.{
        .{ .kind = .diagnostics, .name = "errors", .command = "list_diagnostics" },
        .{ .kind = .run_errors, .name = "last run", .command = "run_errors" },
        .{ .kind = .quickfix, .name = "saved list", .command = "quickfix_list" },
    },
    &.{
        .{ .kind = .jumps, .name = "jumps", .command = "jump_list" },
        .{ .kind = .marks, .name = "marks", .command = "pick_mark" },
    },
    &.{
        .{ .kind = .commands, .name = "commands", .command = "command_picker" },
        .{ .kind = .help, .name = "keys", .command = "help_keys" },
    },
};

/// The scopes `kind` is one of, if any.
pub fn scopeGroup(kind: Kind) ?[]const Scope {
    for (scope_groups) |g| for (g) |sc| if (sc.kind == kind) return g;
    return null;
}

/// An action that runs command `name` (on whatever is current).
fn command(comptime name: []const u8) *const fn (*Editor, ?Item) anyerror!void {
    return &struct {
        fn run(ed: *Editor, _: ?Item) anyerror!void {
            const c = commands.find(name) orelse return;
            ed.restorePickerVisual();
            try ed.runCommand(c);
        }
    }.run;
}

/// A menu row: its key, what it says, the command it runs.
const MenuEntry = struct { key: u8, label: []const u8, command: []const u8 };

/// A menu as a picker: every row is a command; its key (shown beside it)
/// runs it at once, or type to filter and Enter.
fn Menu(comptime menu_title: []const u8, comptime entries: []const MenuEntry) type {
    return struct {
        pub const title = menu_title;
        pub const prefix: ?u8 = null;
        pub const start_mode: StartMode = .normal;
        pub const menu_entries = entries;
        pub const row_keys: []const u8 = blk: {
            var k: [entries.len]u8 = undefined;
            for (entries, 0..) |e, i| k[i] = e.key;
            const r = k;
            break :blk &r;
        };

        pub fn fill(_: *Editor, items: *Items) !void {
            inline for (entries, 0..) |e, i| try items.append(.{ .text = e.label, .detail = if (e.key == ' ') "SPC" else &[_]u8{e.key}, .id = i });
        }

        pub fn accept(ed: *Editor, item: Item) !void {
            if (item.id >= entries.len) return;
            const c = commands.find(entries[item.id].command) orelse return;
            // Opened from visual mode: the row acts on the selection.
            ed.restorePickerVisual();
            try ed.runCommand(c);
        }

        pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
            if (item.id >= entries.len) return;
            const c = commands.find(entries[item.id].command) orelse return;
            try out.text.print(ed.gpa, "{s}\n\n(command: {s})", .{ c.doc, c.name });
        }
    };
}

/// `SPC`: the leader is a menu. Every row's key is the key it always had, so
/// `SPC b` is still buffers; `/` here is a row (grep), so `i` filters.
const Leader = Menu("Leader", &.{
    .{ .key = ' ', .label = "Files", .command = "find_file" },
    .{ .key = 'b', .label = "Buffers", .command = "switch_buffer" },
    .{ .key = '/', .label = "Search the project (grep, C-r replace)", .command = "search_project" },
    .{ .key = '.', .label = "Explore this folder", .command = "browse_files" },
    .{ .key = 'f', .label = "Find: every other picker", .command = "all_pickers" },
    .{ .key = 'l', .label = "Code", .command = "code_menu" },
    .{ .key = 'r', .label = "Run (under gdb with breakpoints; C-Enter: always)", .command = "run_runner" },
    .{ .key = 'd', .label = "Debug (stack, stepping, breakpoints)", .command = "debug_menu" },
    .{ .key = ';', .label = "Run a shell command", .command = "run_shell" },
    .{ .key = 'g', .label = "Git (changed files; commit, push, pull...)", .command = "git_changed_files" },
    .{ .key = 'w', .label = "Windows", .command = "pick_windows" },
    .{ .key = 't', .label = "Toggles", .command = "pick_toggles" },
    .{ .key = 'p', .label = "Projects (and their sessions)", .command = "switch_project" },
    .{ .key = 'a', .label = "Claude", .command = "claude_menu" },
    .{ .key = '\'', .label = "Resume the last picker", .command = "resume_picker" },
    .{ .key = ',', .label = "Last jump (again: back)", .command = "jump_toggle" },
    .{ .key = 's', .label = "Save", .command = "save_file" },
    .{ .key = 'q', .label = "Close (window, buffer, editor)", .command = "smart_close" },
    .{ .key = 'Q', .label = "Quit", .command = "quit_menu" },
});

/// `SPC p`.
const ProjectsMenu = Menu("Projects", &.{
    .{ .key = 'p', .label = "Switch project", .command = "switch_project" },
    .{ .key = 's', .label = "Save this session", .command = "save_session" },
    .{ .key = 'l', .label = "Restore the session", .command = "load_session" },
});

/// `SPC a`.
const ClaudeMenu = Menu("Claude", &.{
    .{ .key = 'a', .label = "Claude panel", .command = "claude_panel" },
    .{ .key = 's', .label = "Send the file / selection", .command = "claude_send" },
    .{ .key = 'i', .label = "Ask about it...", .command = "claude_ask" },
    .{ .key = 'y', .label = "Accept the proposal", .command = "claude_accept" },
    .{ .key = 'n', .label = "Reject the proposal", .command = "claude_reject" },
});

/// `SPC Q`.
const QuitMenu = Menu("Quit", &.{
    .{ .key = 's', .label = "Save all and quit", .command = "save_and_quit" },
    .{ .key = 'Q', .label = "Quit without saving", .command = "quit_without_saving" },
});

/// The menus and the keys that reach them, for the keys picker.
const menus = [_]struct { []const u8, []const MenuEntry }{
    .{ "SPC ", Leader.menu_entries },
    .{ "SPC f ", Pickers.menu_entries },
    .{ "SPC l ", CodeMenu.menu_entries },
    .{ "SPC a ", ClaudeMenu.menu_entries },
    .{ "SPC Q ", QuitMenu.menu_entries },
};

/// `SPC l`: everything about the code under the cursor.
const CodeMenu = Menu("Code", &.{
    .{ .key = '.', .label = "Rename symbol", .command = "rename_symbol" },
    .{ .key = 'a', .label = "Code actions (fixes, refactors)", .command = "code_action" },
    .{ .key = 'f', .label = "Format the file", .command = "format_buffer" },
    .{ .key = 'd', .label = "Go to definition", .command = "goto_definition" },
    .{ .key = 'i', .label = "Go to implementations", .command = "goto_implementation" },
    .{ .key = 'r', .label = "Find references", .command = "find_references" },
    .{ .key = 'k', .label = "Documentation", .command = "hover" },
    .{ .key = 'l', .label = "Symbols (C-t: project)", .command = "goto_symbol" },
    .{ .key = 'w', .label = "Symbols in the project", .command = "workspace_symbols" },
    .{ .key = 'x', .label = "Errors and warnings", .command = "list_diagnostics" },
    .{ .key = 'c', .label = "Colour wheel (the colour here)", .command = "pick_color" },
    .{ .key = 'm', .label = "Manual pages", .command = "man_pages" },
    .{ .key = 't', .label = "Write a todo tag", .command = "todo_tag" },
    .{ .key = 'W', .label = "Trim trailing whitespace", .command = "trim_trailing_whitespace" },
});

/// `SPC w`: the windows, and new ones. The rows: the other windows, the
/// last used first (so `SPC w Enter` goes back to the previous one), the
/// one you're in last, then "+ New window right / below / terminal" (a new
/// window opens once you pick what it shows). The preview draws the layout.
/// Keys about where you are (split, sizes, maximise, only, its buffer,
/// terminal) act on the window you're in; Enter, `x` and `X` on the row.
const WindowList = struct {
    pub const title = "Windows";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    /// Ids of the rows that make a new window.
    const new_right = 1 << 20;
    const new_below = new_right + 1;
    const new_terminal = new_right + 2;

    pub fn fill(ed: *Editor, items: *Items) !void {
        const list = ed.window_list.items;
        var order: [64]usize = undefined;
        const n = @min(list.len, order.len);
        for (0..n) |i| order[i] = i;
        // Last used first; the one you're in at the end (so Enter flips).
        const Ctx = struct {
            ed: *Editor,
            fn less(c: @This(), a: usize, b: usize) bool {
                const wa = c.ed.window_list.items[a];
                const wb = c.ed.window_list.items[b];
                if ((wa == c.ed.window) != (wb == c.ed.window)) return wb == c.ed.window;
                return wa.used > wb.used;
            }
        };
        std.mem.sort(usize, order[0..n], Ctx{ .ed = ed }, Ctx.less);
        var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        for (order[0..n]) |i| {
            const w = list[i];
            const name = if (w.term != null) "terminal" else ed.windowBuffer(w).displayName();
            const text = std.fmt.bufPrint(&buf, "{d}  {s}", .{ i + 1, name }) catch continue;
            const detail: []const u8 = if (w == ed.window) "here" else if (w.term == null and ed.windowBuffer(w).modified) "[+]" else "";
            try items.append(.{ .text = text, .detail = detail, .id = @intCast(i) });
        }
        try items.append(.{ .text = "+ New window right...", .detail = "", .id = new_right });
        try items.append(.{ .text = "+ New window below...", .detail = "", .id = new_below });
        try items.append(.{ .text = "+ New terminal window", .detail = "", .id = new_terminal });
    }

    fn windowOf(ed: *Editor, item: ?Item) ?*Editor.Windows.Window {
        const it = item orelse return null;
        if (it.id >= ed.window_list.items.len) return null;
        return ed.window_list.items[it.id];
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        switch (item.id) {
            new_right => try newWindow(ed, .right),
            new_below => try newWindow(ed, .below),
            new_terminal => try command("terminal_window")(ed, null),
            else => if (windowOf(ed, item)) |w| ed.focusWindow(w),
        }
    }

    /// A new window beside the current one, showing what you pick in the
    /// Files picker next (nothing if you cancel it).
    fn newWindow(ed: *Editor, target: Editor.OpenTarget) !void {
        try command("find_file")(ed, null);
        ed.deferred_target = target;
    }

    /// The layout, drawn: every window as a box (the selected one in double
    /// lines), then the selected window's text at its cursor.
    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const sel = windowOf(ed, item.*);
        try drawLayout(ed, sel, out);
        const w = sel orelse return;
        if (w.term != null) return out.text.appendSlice(ed.gpa, "\n(a terminal)\n");
        const b = ed.windowBuffer(w);
        const t = &b.text;
        const at = t.lineOf(@min(ed.windowView(w).cursor, t.len()));
        try out.text.appendSlice(ed.gpa, "\n");
        for (at -| 3..@min(at + 12, t.lineCount())) |l| try out.text.print(ed.gpa, "{s}\n", .{t.lineSlice(l)});
    }

    fn drawLayout(ed: *Editor, sel: ?*Editor.Windows.Window, out: *Preview) !void {
        const W = 48;
        const H = 14;
        var grid: [H][W]u21 = undefined;
        for (&grid) |*row| @memset(row, ' ');
        const list = ed.window_list.items;
        if (list.len == 0) return;
        var x0: f32 = std.math.inf(f32);
        var y0: f32 = std.math.inf(f32);
        var x1: f32 = 0;
        var y1: f32 = 0;
        for (list) |w| {
            x0 = @min(x0, w.rect.x);
            y0 = @min(y0, w.rect.y);
            x1 = @max(x1, w.rect.x + w.rect.w);
            y1 = @max(y1, w.rect.y + w.rect.h);
        }
        const sw = @max(x1 - x0, 1);
        const sh = @max(y1 - y0, 1);
        // The selected one last, so its double lines win shared borders.
        var order: [65]*Editor.Windows.Window = undefined;
        var n: usize = 0;
        for (list) |w| if (w != sel and n < 64) {
            order[n] = w;
            n += 1;
        };
        if (sel) |s| {
            order[n] = s;
            n += 1;
        }
        for (order[0..n]) |w| {
            const cx0: usize = @intFromFloat(@round((w.rect.x - x0) / sw * (W - 1)));
            const cx1: usize = @intFromFloat(@round((w.rect.x + w.rect.w - x0) / sw * (W - 1)));
            const cy0: usize = @intFromFloat(@round((w.rect.y - y0) / sh * (H - 1)));
            const cy1: usize = @intFromFloat(@round((w.rect.y + w.rect.h - y0) / sh * (H - 1)));
            const double = w == sel;
            const hz: u21 = if (double) '═' else '─';
            const vt: u21 = if (double) '║' else '│';
            for (cx0..cx1 + 1) |x| {
                grid[cy0][x] = hz;
                grid[cy1][x] = hz;
            }
            for (cy0..cy1 + 1) |y| {
                grid[y][cx0] = vt;
                grid[y][cx1] = vt;
            }
            grid[cy0][cx0] = if (double) '╔' else '┌';
            grid[cy0][cx1] = if (double) '╗' else '┐';
            grid[cy1][cx0] = if (double) '╚' else '└';
            grid[cy1][cx1] = if (double) '╝' else '┘';
            // Its number and name inside, the focused one marked.
            const i = std.mem.indexOfScalar(*Editor.Windows.Window, list, w) orelse 0;
            const name = if (w.term != null) "terminal" else std.fs.path.basename(ed.windowBuffer(w).displayName());
            var label_buf: [80]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d} {s}{s}", .{ i + 1, name, if (w == ed.window) " *" else "" }) catch continue;
            if (cy1 > cy0 + 1 and cx1 > cx0 + 2) {
                var it = std.unicode.Utf8View.initUnchecked(label).iterator();
                var x = cx0 + 1;
                while (it.nextCodepoint()) |cp| : (x += 1) {
                    if (x >= cx1) break;
                    grid[cy0 + 1][x] = cp;
                }
            }
        }
        for (grid) |row| {
            var end: usize = W;
            while (end > 0 and row[end - 1] == ' ') end -= 1;
            for (row[0..end]) |cp| {
                var b: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &b) catch 1;
                try out.text.appendSlice(ed.gpa, b[0..len]);
            }
            try out.text.append(ed.gpa, '\n');
        }
    }

    /// `h j k l`: to the window that way from the one you're in.
    fn toward(comptime dir: Editor.Windows.Dir) *const fn (*Editor, ?Item) anyerror!void {
        return &struct {
            fn run(ed: *Editor, _: ?Item) anyerror!void {
                const w = ed.windows.neighbor(ed.window, dir) orelse return ed.setMessage(.info, "no window that way", .{});
                ed.focusWindow(w);
            }
        }.run;
    }

    /// Your window bigger or smaller along `axis`, whichever side its
    /// divider is on.
    fn grow(comptime axis: Editor.Windows.Axis, comptime delta: f32) *const fn (*Editor, ?Item) anyerror!void {
        return &struct {
            fn run(ed: *Editor, _: ?Item) anyerror!void {
                ed.zoom = null;
                Editor.Windows.resize(ed.window, axis, delta);
            }
        }.run;
    }

    /// `w` (`SPC w w`): back to the window you were in before this one.
    fn previous(ed: *Editor, _: ?Item) anyerror!void {
        var best: ?*Editor.Windows.Window = null;
        for (ed.window_list.items) |w| {
            if (w == ed.window) continue;
            if (best == null or w.used > best.?.used) best = w;
        }
        ed.focusWindow(best orelse return ed.setMessage(.info, "only one window", .{}));
    }

    /// `X`: your window's contents and the row's trade places.
    fn swap(ed: *Editor, item: ?Item) anyerror!void {
        const w = windowOf(ed, item) orelse return;
        ed.swapWindows(ed.window, if (w == ed.window) ed.windows.next(w) else w);
    }

    fn zoom(ed: *Editor, _: ?Item) anyerror!void {
        ed.toggleZoom(ed.window);
    }

    /// `x`: closes the row's window; you stay in yours (unless it's yours).
    fn closeThat(ed: *Editor, item: ?Item) anyerror!void {
        const w = windowOf(ed, item) orelse return;
        const mine = ed.window;
        ed.focusWindow(w);
        try command("window_close")(ed, null);
        for (ed.window_list.items) |x| if (x == mine) {
            ed.focusWindow(mine);
            break;
        };
    }

    pub const item_actions = [_]Action{
        .{ .label = "previous window", .key = 'w', .any = true, .run = previous },
        .{ .label = "left", .key = 'h', .any = true, .run = toward(.left) },
        .{ .label = "down", .key = 'j', .any = true, .run = toward(.down) },
        .{ .label = "up", .key = 'k', .any = true, .run = toward(.up) },
        .{ .label = "right", .key = 'l', .any = true, .run = toward(.right) },
        // Where you are: these act on the window you're in.
        .{ .label = "split right", .key = 'v', .any = true, .run = command("split_right") },
        .{ .label = "split below", .key = 's', .any = true, .run = command("split_down") },
        .{ .label = "maximise / back", .key = 'z', .stay = true, .any = true, .run = zoom },
        .{ .label = "only this one", .key = 'o', .any = true, .run = command("window_only") },
        .{ .label = "its buffer", .key = 'b', .any = true, .run = command("switch_buffer") },
        .{ .label = "terminal here", .key = 't', .any = true, .run = command("terminal_window") },
        .{ .label = "equal sizes", .key = '=', .stay = true, .any = true, .run = command("window_balance") },
        .{ .label = "wider", .key = '>', .stay = true, .any = true, .run = grow(.horizontal, 0.05) },
        .{ .label = "narrower", .key = '<', .stay = true, .any = true, .run = grow(.horizontal, -0.05) },
        .{ .label = "taller", .key = '+', .stay = true, .any = true, .run = grow(.vertical, 0.05) },
        .{ .label = "shorter", .key = '-', .stay = true, .any = true, .run = grow(.vertical, -0.05) },
        // A window as a thing: these act on the selected row.
        .{ .label = "close", .key = 'x', .ctrl = 'x', .stay = true, .run = closeThat },
        .{ .label = "swap with it", .key = 'X', .stay = true, .run = swap },
    };
};

/// `SPC t`: every setting with its state; Enter flips it and the list
/// stays (the colour scheme and text size are here too).
const Toggles = struct {
    pub const title = "Toggles";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;
    pub const stays_open = true;

    /// Rows that aren't on/off settings.
    const extra = [_]struct { []const u8, []const u8 }{
        .{ "Colour scheme...", "pick_theme" },
        .{ "Bigger text", "zoom_in" },
        .{ "Smaller text", "zoom_out" },
        .{ "Normal text size", "zoom_reset" },
    };

    pub fn fill(ed: *Editor, items: *Items) !void {
        for (&commands.all, 0..) |*c, i| {
            if (!std.mem.startsWith(u8, c.name, "toggle_")) continue;
            const state: []const u8 = if (ed.optionState(c.name["toggle_".len..])) |on| (if (on) "on" else "off") else "";
            try items.append(.{ .text = c.doc, .detail = state, .id = @intCast(i) });
        }
        for (extra) |e| {
            const i = commands.indexOf(e[1]) orelse continue;
            try items.append(.{ .text = e[0], .detail = "", .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= commands.all.len) return;
        const c = &commands.all[item.id];
        // These leave the list: a picker of their own, a buffer.
        if (std.mem.eql(u8, c.name, "pick_theme") or std.mem.eql(u8, c.name, "toggle_scratch")) ed.closePicker();
        try ed.runCommand(c);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= commands.all.len) return;
        const c = &commands.all[item.id];
        try out.text.print(ed.gpa, "{s}\n\n(command: {s})", .{ c.doc, c.name });
    }
};

/// A place an item stands for (path owned by the caller, 0-based
/// line/col), for sources whose items are places (`<C-q>` to quickfix).
pub const Location = struct { path: []u8, line: usize, col: usize };

pub fn hasLocations(kind: Kind) bool {
    return switch (kind) {
        inline else => |k| @hasDecl(Impl(k), "location"),
    };
}

pub fn location(kind: Kind, ed: *Editor, item: Item) !?Location {
    switch (kind) {
        inline else => |k| {
            if (@hasDecl(Impl(k), "location")) return Impl(k).location(ed, item);
            return null;
        },
    }
}

/// `location` for items whose detail is "path:line[:col]".
fn detailLocation(ed: *Editor, item: Item) !?Location {
    const loc = parseLocation(item.detail) orelse return null;
    return .{ .path = try ed.gpa.dupe(u8, loc.path), .line = loc.line, .col = loc.col };
}

pub fn preview(kind: Kind, ed: *Editor, item: *const Item, out: *Preview) !void {
    out.clear();
    switch (kind) {
        inline else => |k| try Impl(k).preview(ed, item, out),
    }
}

// ---------------------------------------------------------------------------

const Files = struct {
    pub const title = "Files";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    /// Directories never worth listing when walking without git.
    const skip_dirs = std.StaticStringMap(void).initComptime(.{
        .{"zig-out"}, .{"zig-pkg"}, .{"node_modules"}, .{"target"}, .{"__pycache__"},
    });

    /// How many visited files go first.
    const max_seeded = 30;

    /// The project's files you open most (mini.visits) come first, so an
    /// empty query already lists where you are likely going.
    pub fn fill(ed: *Editor, items: *Items) !void {
        // Open buffers first, then the files you visit most.
        try OpenRows.fill(ed, items, true);
        const opened = items.count();
        const root = ed.picker_root;
        const v = ed.loadedVisits();
        v.rank(ed.unixNow());
        const current = if (ed.buffer.path) |p| try ed.absolutePath(p) else null;
        defer if (current) |c| ed.gpa.free(c);
        var n: usize = 0;
        for (v.entries.items) |entry| {
            if (n == max_seeded) break;
            const p = entry.path;
            if (!(p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and p[root.len] == '/')) continue;
            // Not the file you are already in; not files that are gone.
            if (current) |c| if (std.mem.eql(u8, c, p)) continue;
            Io.Dir.cwd().access(ed.io, p, .{}) catch continue;
            const rel = p[root.len + 1 ..];
            const dup = for (0..opened) |i| {
                if (std.mem.eql(u8, items.get(i).text, rel)) break true;
            } else false;
            if (dup) continue;
            try items.append(.{ .text = rel });
            n += 1;
        }
    }

    pub fn produce(e: *Engine) anyerror!void {
        // Items already there are the visited files `fill` put first.
        try eachProjectFile(e, e.items.count(), addPath);
    }

    fn addPath(seeded: usize, e: *Engine, path: []const u8, n: usize) !void {
        for (0..seeded) |i| if (std.mem.eql(u8, e.items.get(i).text, path)) return;
        try e.items.append(.{ .text = path });
        if (n % 2048 == 0) try e.checkpoint();
    }

    /// Calls `onFile(ctx, engine, path, index)` for every file in the project:
    /// from ripgrep or git when available (so .gitignore applies), else by
    /// walking the directory.
    pub fn eachProjectFile(e: *Engine, ctx: anytype, comptime onFile: fn (@TypeOf(ctx), *Engine, []const u8, usize) anyerror!void) !void {
        if (haveRg(e.io)) {
            const Adapter = struct {
                inner: @TypeOf(ctx),
                n: usize = 0,
                fn record(a: *@This(), eng: *Engine, path: []const u8) !bool {
                    a.n += 1;
                    try onFile(a.inner, eng, path, a.n);
                    return true;
                }
            };
            var adapter: Adapter = .{ .inner = ctx };
            // Hidden files too (`.env`, `.github/`), not the repository's.
            if (try streamCommand(e, &.{ "rg", "--files", "--null", "--no-require-git", "--hidden", "-g", "!.git/" }, 0, &adapter, Adapter.record)) return;
        }
        if (try gitFiles(e, ctx, onFile)) return;
        try walk(e, ctx, onFile);
    }

    /// Inside a git repo, git knows exactly which files matter (.gitignore etc).
    fn gitFiles(e: *Engine, ctx: anytype, comptime onFile: anytype) !bool {
        const result = std.process.run(e.gpa, e.io, .{
            .cwd = .{ .path = e.root },
            .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        }) catch return false;
        defer e.gpa.free(result.stdout);
        defer e.gpa.free(result.stderr);
        if (!result.term.success()) return false;
        var it = std.mem.splitScalar(u8, result.stdout, 0);
        var n: usize = 0;
        while (it.next()) |path| {
            if (path.len == 0) continue;
            n += 1;
            try onFile(ctx, e, path, n);
        }
        return true;
    }

    fn walk(e: *Engine, ctx: anytype, comptime onFile: anytype) !void {
        const io = e.io;
        var root = try Io.Dir.cwd().openDir(io, e.root, .{ .iterate = true });
        defer root.close(io);
        var w = try root.walkSelectively(e.gpa);
        defer {
            // Close directories still open if we stop early.
            while (w.stack.items.len > 0) w.leave(io);
            w.deinit();
        }
        var n: usize = 0;
        while (true) {
            // An unreadable directory is skipped; the walker moves on.
            const entry = (w.next(io) catch continue) orelse break;
            // Hidden files and directories are skipped, like fd does.
            if (entry.basename[0] == '.') continue;
            switch (entry.kind) {
                .directory => {
                    if (skip_dirs.has(entry.basename)) continue;
                    w.enter(io, entry) catch {};
                },
                .file, .sym_link => {
                    n += 1;
                    try onFile(ctx, e, entry.path, n);
                },
                else => {},
            }
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try OpenRows.accept(ed, item);
    }

    pub const item_actions = OpenRows.actions;

    pub fn create(ed: *Editor, query: []const u8) !void {
        const path = try ed.pickerPath(query);
        defer ed.gpa.free(path);
        try ed.openFile(path);
        ed.setMessage(.info, "new file \"{s}\" (SPC s to create it on disk)", .{ed.buffer.displayName()});
    }

    pub const preview_limit = 1024 * 1024;

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (OpenRows.isOpen(item.*)) return OpenRows.preview(ed, item, out);
        const path = try ed.pickerPath(item.text);
        defer ed.gpa.free(path);
        try previewPath(ed, path, out);
    }

    fn previewPath(ed: *Editor, path: []const u8, out: *Preview) !void {
        const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(preview_limit)) catch |err| {
            const why = switch (err) {
                error.StreamTooLong => "file too large to preview",
                error.IsDir => "directory",
                else => @errorName(err),
            };
            try out.text.print(ed.gpa, "({s})", .{why});
            return;
        };
        defer ed.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) {
            try out.text.appendSlice(ed.gpa, "(binary file)");
            return;
        }
        try out.setCode(ed.gpa, data, path);
    }
};

/// `SPC .`: one folder's contents (folders first, as "name/"). Enter or `/`
/// goes into a folder, <BS> on an empty query goes up (see `Editor.browse*`).
const Browse = struct {
    pub const title = "Browse";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    const Entry = struct {
        name: []const u8,
        is_dir: bool,

        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            // Hidden entries after the rest.
            const ah = a.name[0] == '.';
            const bh = b.name[0] == '.';
            if (ah != bh) return bh;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    };

    pub fn fill(ed: *Editor, items: *Items) !void {
        var arena: std.heap.ArenaAllocator = .init(ed.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var dir = Io.Dir.cwd().openDir(ed.io, ed.browse_dir.items, .{ .iterate = true }) catch return;
        defer dir.close(ed.io);
        var entries: std.ArrayList(Entry) = .empty;
        var it = dir.iterate();
        while (it.next(ed.io) catch null) |e| {
            const is_dir = switch (e.kind) {
                .directory => true,
                // A link counts as what it points to.
                .sym_link => if (dir.statFile(ed.io, e.name, .{})) |st| st.kind == .directory else |_| false,
                else => false,
            };
            try entries.append(a, .{ .name = try a.dupe(u8, e.name), .is_dir = is_dir });
        }
        std.mem.sort(Entry, entries.items, {}, Entry.lessThan);
        for (entries.items) |e| {
            const text = if (e.is_dir) try std.fmt.allocPrint(a, "{s}/", .{e.name}) else e.name;
            try items.append(.{ .text = text });
        }
    }

    /// Typing searches below the folder too (`main.c` finds `src/main.c`):
    /// the visited files there first, then every file from `rg --files`.
    /// Only inside a project, so `~` or `/` aren't crawled.
    pub fn fillTyped(ed: *Editor, e: *Engine) !void {
        const dir = ed.browse_dir.items;
        e.root = try e.items.arena.allocator().dupe(u8, dir);
        e.home_filter = ed.options.home_filter;
        e.path_rank = true;
        const v = ed.loadedVisits();
        v.rank(ed.unixNow());
        var n: usize = 0;
        for (v.entries.items) |entry| {
            if (n == 30) break;
            const p = entry.path;
            if (!under(p, dir)) continue;
            const rel = p[dir.len + 1 ..];
            // Its own entries are listed already.
            if (std.mem.indexOfScalar(u8, rel, '/') == null) continue;
            Io.Dir.cwd().access(ed.io, p, .{}) catch continue;
            try e.items.append(.{ .text = rel });
            n += 1;
        }
    }

    fn under(path: []const u8, dir: []const u8) bool {
        return path.len > dir.len + 1 and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
    }

    /// `/home/you/x` as `~/x`.
    fn homeShort(buf: []u8, path: []const u8) []const u8 {
        const home = std.mem.span(std.c.getenv("HOME") orelse return path);
        if (!under(path, home)) return path;
        return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
    }

    /// Files under the folder, more than this are not listed.
    const max_below = 200_000;

    /// Elsewhere, as you type: everything under your home folder (`$HOME`),
    /// as `rg --files --hidden` lists it; with `home_filter` (a toggle, on by
    /// default) not these, which are never what you open by name.
    const max_home = 1_000_000;
    const home_filter = [_][]const u8{
        "!.git/",   "!node_modules/", "!*cache*/", "!*Cache*/",
        "!target/", "!build/",        "!dist/",    "!zig-out/",
    };

    pub fn produce(e: *Engine) anyerror!void {
        // The folder's files below it, in a project (not all of `~` or `/`).
        if (@import("../core/Project.zig").detect(e.io, e.root) != null) try Files.eachProjectFile(e, e.items.count(), addBelow);
    }

    const Elsewhere = struct {
        seeded: usize,
        fn add(c: Elsewhere, e: *Engine, path: []const u8) !bool {
            // Already listed as the folder's own (we're inside it).
            if (under(path, e.root)) return true;
            if (e.items.count() >= max_home) return false;
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const shown = homeShort(&buf, path);
            for (e.empty_limit..c.seeded) |i| if (std.mem.eql(u8, e.items.get(i).text, shown)) return true;
            try e.items.append(.{ .text = shown });
            return true;
        }
    };

    fn addBelow(seeded: usize, e: *Engine, path: []const u8, n: usize) !void {
        // The folder's own files are its entries; visited ones are there.
        if (std.mem.indexOfScalar(u8, path, '/') == null) return;
        for (e.empty_limit..seeded) |i| if (std.mem.eql(u8, e.items.get(i).text, path)) return;
        if (e.items.count() >= max_below) return error.Canceled;
        try e.items.append(.{ .text = path });
        if (n % 2048 == 0) try e.checkpoint();
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (std.mem.endsWith(u8, item.text, "/")) return ed.browseInto(item.text);
        const path = try ed.browsePath(item.text);
        defer ed.gpa.free(path);
        try ed.openFile(path);
    }

    /// A new file in this folder ("sub/name" makes the folder on save).
    /// A name ending in `/` is a new folder (made now, and entered);
    /// anything else is a new file.
    /// `c`: work in the folder shown (a cd: Files, search, the runner and
    /// the terminal start there).
    fn workHere(ed: *Editor, _: ?Item) anyerror!void {
        const dir = try ed.gpa.dupe(u8, ed.browse_dir.items);
        defer ed.gpa.free(dir);
        try ed.workIn(dir);
    }

    pub const item_actions = [_]Action{
        .{ .label = "work here (cd)", .key = 'c', .stay = true, .any = true, .run = workHere },
    };

    pub fn create(ed: *Editor, query: []const u8) !void {
        // A folder typed out (`~/code/x`, `/etc`): into it, not a new file.
        {
            const typed = try ed.browsePath(query);
            defer ed.gpa.free(typed);
            if (Io.Dir.cwd().openDir(ed.io, typed, .{})) |d| {
                var dir = d;
                dir.close(ed.io);
                return ed.browseInto(query);
            } else |_| {}
        }
        const path = try ed.browsePath(query);
        defer ed.gpa.free(path);
        if (std.mem.endsWith(u8, query, "/")) {
            Io.Dir.cwd().createDirPath(ed.io, path) catch |err|
                return ed.setMessage(.err, "could not make the folder: {s}", .{@errorName(err)});
            try ed.browseInto(query);
            return ed.setMessage(.info, "made folder \"{s}\"", .{query});
        }
        try ed.openFile(path);
        ed.setMessage(.info, "new file \"{s}\" (SPC s to create it on disk)", .{ed.buffer.displayName()});
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const path = try ed.browsePath(item.text);
        defer ed.gpa.free(path);
        if (std.mem.endsWith(u8, item.text, "/")) {
            // A folder: its first entries.
            var dir = Io.Dir.cwd().openDir(ed.io, path, .{ .iterate = true }) catch |err|
                return out.text.print(ed.gpa, "({s})", .{@errorName(err)});
            defer dir.close(ed.io);
            var it = dir.iterate();
            var n: usize = 0;
            while (it.next(ed.io) catch null) |e| : (n += 1) {
                if (n == 200) {
                    try out.text.appendSlice(ed.gpa, "...\n");
                    break;
                }
                try out.text.print(ed.gpa, "{s}{s}\n", .{ e.name, if (e.kind == .directory) "/" else "" });
            }
            if (n == 0) try out.text.appendSlice(ed.gpa, "(empty folder)");
            return;
        }
        try Files.previewPath(ed, path, out);
    }
};

/// A file's path for a list: inside the current project, relative to it;
/// under the home folder, with `~`; else as it is.
fn displayPath(ed: *Editor, abs: []const u8, buf: []u8) []const u8 {
    const root = ed.projectRoot();
    if (abs.len > root.len + 1 and std.mem.startsWith(u8, abs, root) and abs[root.len] == '/') return abs[root.len + 1 ..];
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len > 1 and std.mem.startsWith(u8, abs, home)) return std.fmt.bufPrint(buf, "~{s}", .{abs[home.len..]}) catch abs;
    return abs;
}

/// Files opened before, in any session (mini.visits).
///   `SPC f r` recent: the most recently opened first.
///   `SPC f v` frecent: the ones you keep going back to first (how often,
///   weighted by how lately), each with its number of visits.
const Recent = Visited(false);
const Frecent = Visited(true);

fn Visited(comptime by_frecency: bool) type {
    return struct {
        pub const title = if (by_frecency) "Frecent files" else "Recent files";
        pub const prefix: ?u8 = null;
        pub const start_mode: StartMode = .insert;

        pub fn fill(ed: *Editor, items: *Items) !void {
            const v = ed.loadedVisits();
            if (by_frecency) v.rank(ed.unixNow()) else v.rankRecent();
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            var count_buf: [24]u8 = undefined;
            // The file you're in last.
            const here = if (ed.buffer.path) |p| ed.absolutePath(p) catch null else null;
            defer if (here) |h| ed.gpa.free(h);
            var current: ?usize = null;
            for (v.entries.items, 0..) |e, i| {
                if (i == 300) break;
                if (here) |h| if (std.mem.eql(u8, h, e.path)) {
                    current = i;
                    continue;
                };
                const visits = if (by_frecency) std.fmt.bufPrint(&count_buf, "{d}\u{d7}", .{e.count}) catch "" else "";
                try items.append(.{ .text = displayPath(ed, e.path, &buf), .detail = visits, .id = @intCast(i) });
            }
            if (current) |i| try items.append(.{ .text = displayPath(ed, v.entries.items[i].path, &buf), .detail = "here", .id = @intCast(i) });
        }

        pub const pathOf = visitedPath;
        pub const accept = visitedAccept;
        pub const preview = visitedPreview;
    };
}

fn visitedPath(ed: *Editor, id: u32) ?[]const u8 {
    const entries = ed.visits.entries.items;
    return if (id < entries.len) entries[id].path else null;
}

fn visitedAccept(ed: *Editor, item: Item) !void {
    const p = try ed.gpa.dupe(u8, visitedPath(ed, item.id) orelse return);
    defer ed.gpa.free(p);
    try ed.openFile(p);
}

fn visitedPreview(ed: *Editor, item: *const Item, out: *Preview) !void {
    try Files.previewPath(ed, visitedPath(ed, item.id) orelse return, out);
}

/// `SPC f t`: todo comments (`TODO`, `FIXME`, `HACK`, `NOTE`, ...) in the
/// project (mini.hipatterns' words).
const Todos = struct {
    pub const title = "Todo comments";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    pub fn produce(e: *Engine) anyerror!void {
        if (!haveRg(e.io)) return Files.eachProjectFile(e, {}, addLines);
        _ = try streamCommand(e, &.{
            "rg",                    "--null",              "--line-number",         "--no-heading", "--color=never",
            "--no-require-git",      "--max-columns=300",   "--max-columns-preview", "-e",           hipatterns.words_regex,
        }, '\n', {}, addRgMatch);
    }

    /// Where the first todo word of `line` starts, if it has one.
    fn todoStart(line: []const u8) ?usize {
        for (line, 0..) |b, i| if (std.ascii.isUpper(b) and hipatterns.todoAt(line, i) != null) return i;
        return null;
    }

    /// "path\0line:text" from rg; the row shows the line from its todo word on.
    fn addRgMatch(_: void, e: *Engine, record: []const u8) !bool {
        if (e.items.count() >= Grep.max_matches) return false;
        const nul = std.mem.indexOfScalar(u8, record, 0) orelse return true;
        const rest = record[nul + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return true;
        var detail: [std.fs.max_path_bytes + 16]u8 = undefined;
        const where = std.fmt.bufPrint(&detail, "{s}:{s}", .{ record[0..nul], rest[0..colon] }) catch return true;
        const line = rest[colon + 1 ..];
        const text = std.mem.trim(u8, line[todoStart(line) orelse 0 ..], " \t\r");
        try e.items.append(.{ .text = text, .detail = where });
        return true;
    }

    fn addLines(_: void, e: *Engine, path: []const u8, _: usize) !void {
        var full_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ e.root, path }) catch return;
        const data = Io.Dir.cwd().readFileAlloc(e.io, full, e.gpa, .limited(Grep.max_file)) catch return;
        defer e.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) return; // binary
        var detail: [std.fs.max_path_bytes + 16]u8 = undefined;
        var lines = std.mem.splitScalar(u8, data, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            const start = todoStart(line) orelse continue;
            const text = std.mem.trim(u8, line[start..], " \t\r");
            const where = std.fmt.bufPrint(&detail, "{s}:{d}", .{ path, n }) catch continue;
            try e.items.append(.{ .text = text[0..@min(text.len, Grep.max_line)], .detail = where });
        }
    }

    pub const location = Grep.location;
    pub const accept = Grep.accept;
    pub const preview = Grep.preview;
};

/// `SPC t t`: colour schemes. Moving through them previews each on the whole
/// editor; Enter keeps one (remembered for next time), Esc goes back.
const Themes = struct {
    pub const title = "Colour scheme";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    const sample =
        \\//! A sample, in the selected colours.
        \\const std = @import("std");
        \\
        \\/// TODO: colours like #e6c384 show too.
        \\pub fn main() !void {
        \\    const answer: usize = 42;
        \\    for (0..answer) |i| {
        \\        std.debug.print("{d}: {s}\n", .{ i, "hello" });
        \\    }
        \\}
        \\
    ;

    pub fn fill(ed: *Editor, items: *Items) !void {
        for (ed.theme_names, 0..) |name, i| {
            try items.append(.{ .text = name, .detail = if (i == ed.theme_before) "current" else "", .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        ed.setTheme(item.id);
        if (item.id < ed.theme_names.len) ed.setMessage(.info, "colour scheme: {s}", .{ed.theme_names[item.id]});
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id < ed.theme_names.len) ed.theme_index = item.id;
        try out.setCode(ed.gpa, sample, "sample.zig");
    }
};

/// `SPC f n`: every message and notification so far, newest first. Enter
/// copies one.
const Messages = struct {
    pub const title = "Messages";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        var i = ed.history.items.len;
        while (i > 0) {
            i -= 1;
            const h = ed.history.items[i];
            try items.append(.{ .text = h.text, .detail = if (h.kind == .err) "error" else "", .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.registers.store(null, .yank, item.text, false);
        ed.setMessage(.info, "copied the message", .{});
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        // Wrapped: messages are one long line.
        var col: usize = 0;
        var words = std.mem.tokenizeScalar(u8, item.text, ' ');
        while (words.next()) |w| {
            if (col > 0 and col + w.len > 60) {
                try out.text.append(ed.gpa, '\n');
                col = 0;
            } else if (col > 0) {
                try out.text.append(ed.gpa, ' ');
                col += 1;
            }
            try out.text.appendSlice(ed.gpa, w);
            col += w.len;
        }
    }
};

/// The start screen (mini.starter), shown when zile opens without a file:
/// the files you were last in, then first steps.
const Start = struct {
    pub const title = "zile";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    const recent_count = 9;
    /// Ids at and above this are recent files (the visit's index added).
    pub const recent_base = 1000;

    /// Each with its key (a menu: the key runs the row; `q` quits, as on a
    /// dashboard).
    const actions = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "Find file", "f", "find_file", "The project's folder; type to search every file below it, and elsewhere." },
        .{ "Explore files", "e", "browse_files", "Walk through folders, one at a time." },
        .{ "Recent files", "r", "recent_files", "Every file opened before, the most recent first." },
        .{ "Search project", "/", "search_project", "Search the text of every file in the project." },
        .{ "Switch project", "p", "switch_project", "Projects opened before. One with a saved session comes back as you left it." },
        .{ "Restore session", "l", "load_session", "Reopen this project's files and splits as they were when you left." },
        .{ "Colour scheme", "c", "pick_theme", "Pick the editor's colours." },
        .{ "Quit", "q", "quit", "Leave zile." },
    };
    pub const row_keys: []const u8 = blk: {
        var k: [actions.len]u8 = undefined;
        for (actions, 0..) |a, i| k[i] = a[1][0];
        const r = k;
        break :blk &r;
    };

    pub fn fill(ed: *Editor, items: *Items) !void {
        const v = ed.loadedVisits();
        v.rankRecent();
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var n: usize = 0;
        for (v.entries.items, 0..) |e, i| {
            if (n == recent_count) break;
            Io.Dir.cwd().access(ed.io, e.path, .{}) catch continue;
            try items.append(.{ .text = displayPath(ed, e.path, &buf), .detail = "recent", .id = @intCast(recent_base + i) });
            n += 1;
        }
        for (actions, 0..) |a, i| {
            if (std.mem.eql(u8, a[2], "load_session") and !Editor.Session.exists(ed, ed.projectRoot())) continue;
            try items.append(.{ .text = a[0], .detail = a[1], .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= recent_base) return Recent.accept(ed, .{ .text = item.text, .id = item.id - recent_base });
        if (item.id >= actions.len) return;
        try ed.runCommand(commands.find(actions[item.id][2]) orelse return);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= recent_base) return Files.previewPath(ed, Recent.pathOf(ed, item.id - recent_base) orelse return, out);
        if (item.id < actions.len) try out.text.print(ed.gpa, "{s}\n\n{s}", .{ actions[item.id][0], actions[item.id][3] });
    }
};

/// Whether item `id` of the start screen is a file (it gets a file icon).
pub fn startItemIsFile(id: u32) bool {
    return id >= Start.recent_base;
}

/// `SPC f j`: the jumplist, newest first, with the line each jump left.
const Jumps = struct {
    pub const title = "Jumplist";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        var i = ed.jumps.items.len;
        while (i > 0) {
            i -= 1;
            const j = ed.jumps.items[i];
            var buf: [512]u8 = undefined;
            const name = if (j.buffer) |b| b.displayName() else j.path orelse "?";
            if (j.buffer) |b| {
                const t = &b.text;
                const line = t.lineOf(@min(j.pos, t.len()));
                const detail = std.fmt.bufPrint(&buf, "{s}:{d}", .{ name, line + 1 }) catch name;
                const text = std.mem.trim(u8, t.lineSlice(line), " \t");
                try items.append(.{ .text = if (text.len > 0) text else "(blank line)", .detail = detail, .id = @intCast(i) });
            } else {
                try items.append(.{ .text = "(closed file)", .detail = name, .id = @intCast(i) });
            }
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id < ed.jumps.items.len) try ed.goJump(item.id);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.jumps.items.len) return;
        const j = ed.jumps.items[item.id];
        if (j.buffer) |b| {
            try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
            out.focus_line = b.text.lineOf(@min(j.pos, b.text.len()));
        } else if (j.path) |p| try Files.previewPath(ed, p, out);
    }
};

/// `SPC f q`: the quickfix list, a picker like any other: each entry with
/// its file and line number, previewed at that line.
const Quickfix = struct {
    pub const title = "Quickfix";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        for (ed.quickfix.items, 0..) |q, i| {
            var buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "{s}:{d}", .{ shortPath(ed.projectRoot(), q.path), q.line + 1 }) catch q.path;
            try items.append(.{ .text = q.text, .detail = detail, .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.goQuickfix(item.id);
    }

    pub fn location(ed: *Editor, item: Item) !?Location {
        if (item.id >= ed.quickfix.items.len) return null;
        const q = ed.quickfix.items[item.id];
        return .{ .path = try ed.gpa.dupe(u8, q.path), .line = q.line, .col = q.col };
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.quickfix.items.len) return;
        const q = ed.quickfix.items[item.id];
        try previewAt(ed, q.path, q.line, out);
    }
};

/// <Tab> in a picker: where to open the selection.
/// <Tab> in a picker: what can be done with the row: its picker's actions
/// (with their keys), and where to open it for pickers of places.
const OpenIn = struct {
    pub const title = "Actions";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    /// Action rows' ids start here (open targets are 0..4).
    const action_base = 100;

    const targets = [_]struct { Editor.OpenTarget, []const u8, []const u8 }{
        .{ .here, "This window", "Enter" },
        .{ .right, "Split right", "Ctrl-v" },
        .{ .below, "Split below", "Ctrl-s" },
        .{ .left, "Split left", "" },
        .{ .above, "Split above", "" },
    };

    pub fn fill(ed: *Editor, items: *Items) !void {
        const origin = ed.action_origin;
        const has_row = if (ed.pending_choice) |c| c != .none else false;
        const places = if (origin) |o| Editor.opensPlaces(o) else true;
        if (places and has_row) for (targets, 0..) |t, i| try items.append(.{ .text = t[1], .detail = t[2], .id = @intCast(i) });
        const o = origin orelse return;
        var buf: [16]u8 = undefined;
        for (itemActions(o), 0..) |a, i| {
            if (!has_row and !a.any) continue;
            const key = if (a.ctrl != 0 and a.key != 0)
                std.fmt.bufPrint(&buf, "{c}  Ctrl-{c}", .{ a.key, a.ctrl }) catch ""
            else if (a.key != 0)
                std.fmt.bufPrint(&buf, "{c}", .{a.key}) catch ""
            else if (a.ctrl != 0) std.fmt.bufPrint(&buf, "Ctrl-{c}", .{a.ctrl}) catch "" else "";
            try items.append(.{ .text = a.label, .detail = key, .id = @intCast(action_base + i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id < targets.len) return ed.openPendingIn(targets[item.id][0]);
        if (item.id >= action_base) try ed.runPendingAction(item.id - action_base);
    }

    pub fn preview(ed: *Editor, _: *const Item, out: *Preview) !void {
        const c = ed.pending_choice orelse return;
        const what = switch (c) {
            .none => "",
            .item => |i| if (i.item.detail.len > 0 and i.kind != .files) i.item.detail else i.item.text,
            .create => |cr| cr.query,
        };
        try out.text.print(ed.gpa, "Opens {s}", .{what});
    }
};

/// `SPC p p`: projects opened before, most recent first; picking one finds
/// a file in it.
/// The folders `Projects` scans, set from the editor's options when the
/// picker opens (the worker thread can't read editor state).
var project_dirs: []const []const u8 = &.{};

fn expandHome(buf: []u8, shown: []const u8) []const u8 {
    if (shown.len == 0 or shown[0] != '~') return shown;
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return shown;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, shown[1..] }) catch shown;
}

fn shortenHome(buf: []u8, path: []const u8) []const u8 {
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len > 1 and std.mem.startsWith(u8, path, home)) return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
    return path;
}

const Projects = struct {
    pub const title = "Switch project";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    /// What makes a folder a project.
    const markers = [_][]const u8{ ".git", "build.zig", "Cargo.toml", "package.json", "go.mod", "Makefile" };
    const max_depth = 3;

    /// The ones opened before, most recent first.
    pub fn fill(ed: *Editor, items: *Items) !void {
        project_dirs = ed.options.project_dirs;
        // The one you're in last.
        const here = ed.projectRoot();
        var current: ?[]const u8 = null;
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        for (ed.knownProjects()) |root| {
            if (std.mem.eql(u8, root, here)) {
                current = root;
                continue;
            }
            try items.append(.{ .text = std.fs.path.basename(root), .detail = shortenHome(&buf, root) });
        }
        if (current) |root| try items.append(.{ .text = std.fs.path.basename(root), .detail = shortenHome(&buf, root) });
    }

    /// Then every project found under the project folders.
    pub fn produce(e: *Engine) anyerror!void {
        const known = e.items.count();
        for (project_dirs) |dir| try scan(e, known, dir, 0);
    }

    fn scan(e: *Engine, known: usize, path: []const u8, depth: usize) anyerror!void {
        var dir = Io.Dir.cwd().openDir(e.io, path, .{ .iterate = true }) catch return;
        defer dir.close(e.io);
        const is_project = for (markers) |m| {
            if (dir.access(e.io, m, .{})) |_| break true else |_| {}
        } else false;
        if (is_project and depth > 0) {
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const shown = shortenHome(&buf, path);
            for (0..known) |i| if (std.mem.eql(u8, e.items.get(i).detail, shown)) return;
            try e.items.append(.{ .text = std.fs.path.basename(path), .detail = shown });
            return; // not into a project for more
        }
        if (depth == max_depth) return;
        var it = dir.iterate();
        while (it.next(e.io) catch null) |entry| {
            if (entry.kind != .directory or entry.name[0] == '.' or Files.skip_dirs.has(entry.name)) continue;
            const child = try std.fs.path.join(e.gpa, &.{ path, entry.name });
            defer e.gpa.free(child);
            try scan(e, known, child, depth + 1);
        }
        try e.checkpoint();
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = try ed.gpa.dupe(u8, expandHome(&buf, item.detail));
        defer ed.gpa.free(root);
        try ed.switchProject(root);
    }

    /// The row's project folder (owned).
    fn rootOf(ed: *Editor, item: ?Item) !?[]u8 {
        const it = item orelse return null;
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        return try ed.gpa.dupe(u8, expandHome(&buf, it.detail));
    }

    fn files(ed: *Editor, item: ?Item) anyerror!void {
        const root = try rootOf(ed, item) orelse return;
        defer ed.gpa.free(root);
        try ed.exploreProject(root);
    }

    fn restore(ed: *Editor, item: ?Item) anyerror!void {
        const root = try rootOf(ed, item) orelse return;
        defer ed.gpa.free(root);
        if (!ed.restoreSession(root)) ed.setMessage(.info, "no session saved for it", .{});
    }

    fn grep(ed: *Editor, item: ?Item) anyerror!void {
        const root = try rootOf(ed, item) orelse return;
        defer ed.gpa.free(root);
        const f = @import("../core/Project.zig").detect(ed.io, root) orelse @import("../core/Project.zig").Found{ .root = root, .git = false };
        ed.next_picker_root = (ed.internProject(f.root, f.git) orelse return).root;
        try command("search_project")(ed, item);
    }

    fn forget(ed: *Editor, item: ?Item) anyerror!void {
        const root = try rootOf(ed, item) orelse return;
        defer ed.gpa.free(root);
        ed.forgetProject(root);
    }

    pub const item_actions = [_]Action{
        .{ .label = "files in it", .key = 'f', .run = files },
        .{ .label = "search in it", .key = 'g', .run = grep },
        .{ .label = "restore its session", .key = 'l', .run = restore },
        .{ .label = "save this session", .key = 's', .stay = true, .any = true, .run = command("save_session") },
        .{ .label = "forget it", .key = 'x', .ctrl = 'x', .stay = true, .run = forget },
    };

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        // Its top-level entries.
        var dir = Io.Dir.cwd().openDir(ed.io, expandHome(&buf, item.detail), .{ .iterate = true }) catch |err|
            return out.text.print(ed.gpa, "({s})", .{@errorName(err)});
        defer dir.close(ed.io);
        var it = dir.iterate();
        var n: usize = 0;
        while (it.next(ed.io) catch null) |e| : (n += 1) {
            if (n == 200) break;
            try out.text.print(ed.gpa, "{s}{s}\n", .{ e.name, if (e.kind == .directory) "/" else "" });
        }
    }
};

/// `SPC l t` (insert mode: `<C-t>`): a todo tag to write as a comment here.
const TodoTags = struct {
    pub const title = "Todo tag";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    const tags = [_][2][]const u8{
        .{ "TODO", "something to do" },       .{ "FIXME", "something broken" }, .{ "HACK", "a workaround to revisit" },
        .{ "BUG", "a known bug" },            .{ "NOTE", "worth knowing" },     .{ "WARN", "careful here" },
        .{ "PERF", "could be faster" },
    };

    pub fn fill(_: *Editor, items: *Items) !void {
        for (tags, 0..) |t, i| try items.append(.{ .text = t[0], .detail = t[1], .id = @intCast(i) });
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id < tags.len) try ed.writeTodoTag(tags[item.id][0]);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= tags.len) return;
        try out.text.print(ed.gpa, "Writes a comment on this line:\n\n{s}: \n\nand leaves you typing after it.\nSPC f t lists them all.", .{tags[item.id][0]});
    }
};

/// `SPC l m`: manual pages for C functions and system calls (sections 2
/// and 3). Enter opens the page in a buffer.
const ManPages = struct {
    pub const title = "Manual pages";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    pub fn produce(e: *Engine) anyerror!void {
        _ = try streamCommand(e, &.{ "apropos", "-s", "2,3", "." }, '\n', {}, add);
    }

    /// "name (3) - what it does"
    fn add(_: void, e: *Engine, record: []const u8) !bool {
        const open = std.mem.indexOf(u8, record, " (") orelse return true;
        const close = std.mem.indexOfScalarPos(u8, record, open, ')') orelse return true;
        const section = record[open + 2 .. close];
        // The C library and the kernel, not Perl's modules.
        if (section.len == 0 or (section[0] != '2' and section[0] != '3')) return true;
        if (std.mem.eql(u8, section, "3perl") or std.mem.eql(u8, section, "3pm")) return true;
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}({s})", .{ record[0..open], section }) catch return true;
        const dash = std.mem.indexOfPos(u8, record, close, "- ");
        try e.items.append(.{ .text = text, .detail = if (dash) |d| std.mem.trim(u8, record[d + 2 ..], " ") else "" });
        return true;
    }

    /// The page's text for "name(section)". Caller frees.
    fn page(ed: *Editor, entry: []const u8) !?[]u8 {
        const open = std.mem.lastIndexOfScalar(u8, entry, '(') orelse return null;
        if (entry.len < open + 3) return null;
        const r = std.process.run(ed.gpa, ed.io, .{ .argv = &.{ "man", entry[open + 1 .. entry.len - 1], entry[0..open] } }) catch return null;
        defer ed.gpa.free(r.stderr);
        errdefer ed.gpa.free(r.stdout);
        if (!r.term.success()) {
            ed.gpa.free(r.stdout);
            return null;
        }
        // Bold and underline arrive as overstrikes ("x\bx"): keep the letters.
        var n: usize = 0;
        for (r.stdout) |b| {
            if (b == 0x08) {
                n -|= 1;
            } else {
                r.stdout[n] = b;
                n += 1;
            }
        }
        return try ed.gpa.realloc(r.stdout, n);
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        const text = try page(ed, item.text) orelse return ed.setMessage(.err, "no manual page for {s}", .{item.text});
        defer ed.gpa.free(text);
        var label: [300]u8 = undefined;
        try ed.openTextBuffer(std.fmt.bufPrint(&label, "man {s}", .{item.text}) catch "man", text);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const text = try page(ed, item.text) orelse return;
        defer ed.gpa.free(text);
        try out.text.appendSlice(ed.gpa, text);
    }
};

/// A path for display: relative inside `cwd`, else its last two parts.
fn shortPath(cwd: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, cwd) and path.len > cwd.len + 1 and path[cwd.len] == '/') return path[cwd.len + 1 ..];
    if (!std.fs.path.isAbsolute(path)) return path;
    const base_start = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    const parent_start = std.mem.lastIndexOfScalar(u8, path[0..base_start], '/') orelse return path;
    return path[parent_start + 1 ..];
}

/// `SPC r e`: errors found in the last run's output.
const RunErrors = struct {
    pub const title = "Errors from the last run";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        for (ed.run_errors.items, 0..) |e, i| {
            var buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "{s}:{d}:{d}", .{ shortPath(ed.run_root, e.path), e.line, e.col }) catch e.path;
            try items.append(.{ .text = e.message, .detail = detail, .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= ed.run_errors.items.len) return;
        const e = ed.run_errors.items[item.id];
        try ed.jumpTo(e.path, e.line - 1, e.col - 1);
    }

    pub fn location(ed: *Editor, item: Item) !?Location {
        if (item.id >= ed.run_errors.items.len) return null;
        const e = ed.run_errors.items[item.id];
        return .{ .path = try ed.gpa.dupe(u8, e.path), .line = e.line - 1, .col = e.col - 1 };
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.run_errors.items.len) return;
        const e = ed.run_errors.items[item.id];
        try Files.previewPath(ed, e.path, out);
        out.focus_line = e.line - 1;
    }
};

/// The explorer's second list, under its own rows: files elsewhere whose
/// names match, searched for each query: the ones you opened anywhere
/// (another project), then your home folder (`fd --fixed-strings`, or `rg`
/// without fd), skipping `.git`, `node_modules`, caches and build output
/// with the `home_filter` toggle. A query of one letter searches nothing.
const GlobalFiles = struct {
    pub const title = "Elsewhere";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    pub fn fillTyped(ed: *Editor, e: *Engine) !void {
        e.root = try e.items.arena.allocator().dupe(u8, ed.browse_dir.items);
        e.home_filter = ed.options.home_filter;
        e.path_rank = true;
        e.strict_from = 0; // matched by file name (unless the query has a /)
        if (@import("builtin").is_test) return;
        const v = ed.loadedVisits();
        v.rank(ed.unixNow());
        var n: usize = 0;
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        for (v.entries.items) |entry| {
            if (n == 100) break;
            if (Browse.under(entry.path, e.root)) continue;
            Io.Dir.cwd().access(ed.io, entry.path, .{}) catch continue;
            try e.items.append(.{ .text = Browse.homeShort(&buf, entry.path) });
            n += 1;
        }
    }

    const skip = [_][]const u8{ ".git", "node_modules", "*cache*", "*Cache*", "target", "build", "dist", "zig-out" };

    pub fn produce(e: *Engine) anyerror!void {
        if (@import("builtin").is_test) return;
        const q = std.mem.trim(u8, e.producerQuery(), " ");
        if (q.len < 2) return;
        const home = std.mem.span(std.c.getenv("HOME") orelse return);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(e.gpa);
        const by_path = std.mem.indexOfScalar(u8, q, '/') != null;
        if (haveFd(e.io)) {
            try argv.appendSlice(e.gpa, &.{ "fd", "--hidden", "--type", "f", "--fixed-strings", "--print0" });
            if (by_path) try argv.append(e.gpa, "--full-path");
            if (e.home_filter) for (skip) |x| try argv.appendSlice(e.gpa, &.{ "--exclude", x });
            try argv.appendSlice(e.gpa, &.{ "--", q, home });
        } else if (haveRg(e.io)) {
            const glob = try std.fmt.allocPrint(e.gpa, "*{s}*", .{q});
            defer e.gpa.free(glob);
            try argv.appendSlice(e.gpa, &.{ "rg", "--files", "--null", "--hidden", "--iglob", glob });
            if (e.home_filter) for (skip) |x| try argv.appendSlice(e.gpa, &.{ "-g", try std.fmt.allocPrint(e.items.arena.allocator(), "!{s}/", .{x}) });
            try argv.append(e.gpa, home);
        } else return;
        const ctx: Browse.Elsewhere = .{ .seeded = e.items.count() };
        _ = try streamCommand(e, argv.items, 0, ctx, Browse.Elsewhere.add);
    }

    pub const accept = Browse.accept;
    pub const preview = Browse.preview;
};

/// `SPC b`: the buffers (`C-t` in Files: its "buffers" scope).
const Buffers = struct {
    pub const title = "Buffers";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    pub fn fill(ed: *Editor, items: *Items) !void {
        try OpenRows.fill(ed, items, false);
    }

    pub const accept = OpenRows.accept;
    pub const preview = OpenRows.preview;
    pub const item_actions = OpenRows.actions;
};

/// Rows for open buffers, shared by Files (where they come first) and
/// Buffers: their id is `flag | buffer index`, so a row knows whether it is
/// an open buffer or just a file.
const OpenRows = struct {
    const flag: u32 = 1 << 31;

    fn isOpen(item: Item) bool {
        return item.id & flag != 0;
    }

    /// The open buffers, most recently used first, the current one last.
    /// `relative`: paths relative to the picker's project, as Files lists
    /// them (so the project's own row for the file is dropped).
    fn fill(ed: *Editor, items: *Items, relative: bool) !void {
        const order = try ed.buffersByRecency(ed.gpa);
        defer ed.gpa.free(order);
        var rest: ?*@import("../core/Buffer.zig") = null;
        for (order) |b| {
            // The one you're in last (`SPC b Enter` flips to the previous).
            if (b == ed.buffer) {
                rest = b;
                continue;
            }
            try append(ed, items, b, relative);
        }
        if (rest) |b| try append(ed, items, b, relative);
    }

    fn append(ed: *Editor, items: *Items, b: *@import("../core/Buffer.zig"), relative: bool) !void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var text = b.displayName();
        if (relative) if (b.path) |p| {
            const abs = ed.absolutePath(p) catch return;
            defer ed.gpa.free(abs);
            const root = ed.picker_root;
            if (abs.len > root.len + 1 and std.mem.startsWith(u8, abs, root) and abs[root.len] == '/') {
                const rel = abs[root.len + 1 ..];
                @memcpy(buf[0..rel.len], rel);
                text = buf[0..rel.len];
            }
        };
        const detail: []const u8 = if (b == ed.buffer) "here" else if (b.modified) "[+]" else "";
        try items.append(.{ .text = text, .detail = detail, .id = flag | @as(u32, @intCast(ed.bufferIndex(b))) });
    }

    fn bufferOf(ed: *Editor, item: ?Item) ?*@import("../core/Buffer.zig") {
        const it = item orelse return null;
        if (!isOpen(it)) return null;
        const i = it.id & ~flag;
        if (i >= ed.buffers.items.len) return null;
        return ed.buffers.items[i];
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (bufferOf(ed, item)) |b| return ed.switchTo(b);
        // A file row (Files): open it.
        const path = try ed.pickerPath(item.text);
        defer ed.gpa.free(path);
        try ed.openFile(path);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const b = bufferOf(ed, item.*) orelse {
            const path = try ed.pickerPath(item.text);
            defer ed.gpa.free(path);
            return Files.previewPath(ed, path, out);
        };
        try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
        out.focus_line = b.text.lineOf(ed.cursorOf(b));
    }

    /// The row's buffer, opening its file first if it's a file row.
    fn openRow(ed: *Editor, item: ?Item) !?*@import("../core/Buffer.zig") {
        if (bufferOf(ed, item)) |b| return b;
        const it = item orelse return null;
        const path = try ed.pickerPath(it.text);
        defer ed.gpa.free(path);
        try ed.openFile(path);
        return ed.buffer;
    }

    /// Goes to the row's buffer (opening a file row), then runs `name`.
    fn onBuffer(comptime name: []const u8) *const fn (*Editor, ?Item) anyerror!void {
        return &struct {
            fn run(ed: *Editor, item: ?Item) anyerror!void {
                const b = try openRow(ed, item) orelse return;
                ed.switchTo(b);
                try command(name)(ed, item);
            }
        }.run;
    }

    fn close(ed: *Editor, item: ?Item) anyerror!void {
        const b = bufferOf(ed, item) orelse return ed.setMessage(.info, "not open", .{});
        if (b.modified) return ed.setMessage(.err, "\"{s}\" has unsaved changes: save it first (s)", .{b.displayName()});
        try ed.killBuffer(b);
    }

    fn closeOthers(ed: *Editor, item: ?Item) anyerror!void {
        const keep = bufferOf(ed, item);
        var i = ed.buffers.items.len;
        while (i > 0) {
            i -= 1;
            const b = ed.buffers.items[i];
            if (b != keep and !b.modified) try ed.killBuffer(b);
        }
    }

    fn save(ed: *Editor, item: ?Item) anyerror!void {
        const b = bufferOf(ed, item) orelse return ed.setMessage(.info, "not open: nothing to save", .{});
        if (b.path == null) return ed.setMessage(.err, "no file name: save it as (w)", .{});
        ed.saveBufferNow(b);
    }

    fn copyPath(comptime absolute: bool) *const fn (*Editor, ?Item) anyerror!void {
        return &struct {
            fn run(ed: *Editor, item: ?Item) anyerror!void {
                const it = item orelse return;
                const path: []const u8 = if (bufferOf(ed, item)) |b| (b.path orelse return ed.setMessage(.info, "no file", .{})) else it.text;
                const full = try ed.pickerPath(path);
                defer ed.gpa.free(full);
                const shown = if (absolute) try ed.absolutePath(full) else try ed.gpa.dupe(u8, path);
                defer ed.gpa.free(shown);
                try ed.registers.store('+', .yank, shown, false);
                ed.setMessage(.info, "copied {s}", .{shown});
            }
        }.run;
    }

    const actions = [_]Action{
        .{ .label = "close", .key = 'x', .ctrl = 'x', .stay = true, .run = close },
        .{ .label = "new", .key = 'n', .any = true, .run = command("new_buffer") },
        .{ .label = "save", .key = 's', .stay = true, .run = save },
        .{ .label = "save all", .key = 'S', .stay = true, .any = true, .run = command("save_all") },
        .{ .label = "rename / move...", .key = 'r', .run = onBuffer("rename_file") },
        .{ .label = "save as...", .key = 'w', .run = onBuffer("save_file_as") },
        .{ .label = "copy file to...", .key = 'c', .run = onBuffer("copy_file") },
        .{ .label = "revert from disk", .key = 'R', .run = onBuffer("revert_buffer") },
        .{ .label = "delete the file...", .key = 'D', .run = onBuffer("delete_file") },
        .{ .label = "close the others", .key = 'o', .stay = true, .any = true, .run = closeOthers },
        .{ .label = "copy path", .key = 'y', .stay = true, .run = copyPath(false) },
        .{ .label = "copy absolute path", .key = 'Y', .stay = true, .run = copyPath(true) },
    };
};

const Commands = struct {
    pub const title = "Command";
    pub const prefix: ?u8 = '>';
    pub const start_mode: StartMode = .insert;

    pub fn fill(ed: *Editor, items: *Items) !void {
        for (&commands.all, 0..) |*c, i| {
            if (c.hidden) continue;
            var buf: [64]u8 = undefined;
            var w: Io.Writer = .fixed(&buf);
            if (ed.keymap.firstBinding(.normal, c)) |seq| keys.formatSequenceDisplay(seq, &w) catch {};
            try items.append(.{ .text = c.name, .detail = w.buffered(), .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.runCommand(&commands.all[item.id]);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const c = &commands.all[item.id];
        try out.text.print(ed.gpa, "{s}\n\n{s}\n", .{ c.name, c.doc });
        if (item.detail.len > 0) try out.text.print(ed.gpa, "\nkey: {s}\n", .{item.detail});
    }
};

/// `SPC f l`: the current buffer's lines (Doom's swiper / consult-line).
const Lines = struct {
    pub const title = "Search buffer";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    pub fn fill(ed: *Editor, items: *Items) !void {
        const t = ed.text();
        var num: [16]u8 = undefined;
        for (0..t.lineCount()) |line| {
            const text = std.mem.trim(u8, t.lineSlice(line), " \t");
            if (text.len == 0) continue;
            const label = std.fmt.bufPrint(&num, "{d}", .{line + 1}) catch unreachable;
            try items.append(.{ .text = text, .detail = label, .id = @intCast(line) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        const t = ed.text();
        ed.setCursor(motions.firstNonBlank(t, @min(item.id, t.lineCount() - 1)));
    }

    pub fn location(ed: *Editor, item: Item) !?Location {
        const path = ed.buffer.path orelse return null;
        return .{ .path = try ed.gpa.dupe(u8, path), .line = item.id, .col = 0 };
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const b = ed.buffer;
        try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
        out.focus_line = item.id;
    }
};

// ---------------------------------------------------------------------------
// Sources that point into files: "path:line[:col]" details.

/// Parses a "path:line" or "path:line:col" detail (1-based) into 0-based parts.
fn parseLocation(detail: []const u8) ?struct { path: []const u8, line: usize, col: usize } {
    const last = std.mem.lastIndexOfScalar(u8, detail, ':') orelse return null;
    const n1 = std.fmt.parseInt(usize, detail[last + 1 ..], 10) catch return null;
    if (std.mem.lastIndexOfScalar(u8, detail[0..last], ':')) |prev| {
        if (std.fmt.parseInt(usize, detail[prev + 1 .. last], 10)) |line| {
            return .{ .path = detail[0..prev], .line = line -| 1, .col = n1 -| 1 };
        } else |_| {}
    }
    return .{ .path = detail[0..last], .line = n1 -| 1, .col = 0 };
}

fn jumpToDetail(ed: *Editor, item: Item) !void {
    const loc = parseLocation(item.detail) orelse return;
    try ed.jumpTo(loc.path, loc.line, loc.col);
}

/// Previews `path` around `line`, from its buffer if open (unsaved edits
/// included), else from disk.
fn previewAt(ed: *Editor, path: []const u8, line: usize, out: *Preview) !void {
    for (ed.buffers.items) |b| {
        if (b.path) |bp| if (std.mem.eql(u8, bp, path)) {
            try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), path);
            out.focus_line = line;
            return;
        };
    }
    const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(Files.preview_limit)) catch |err| {
        try out.text.print(ed.gpa, "({s})", .{@errorName(err)});
        return;
    };
    defer ed.gpa.free(data);
    try out.setCode(ed.gpa, data, path);
    out.focus_line = line;
}

fn previewDetail(ed: *Editor, item: *const Item, out: *Preview) !void {
    const loc = parseLocation(item.detail) orelse return;
    try previewAt(ed, loc.path, loc.line, out);
}

/// `SPC /`: search every line of the project, fuzzily.
///
/// With ripgrep, each query runs `rg` with a subsequence regex built from it
/// (`abc` -> `a.*?b.*?c`), streaming matches in, and the engine ranks them
/// fuzzily. Without it, every line of every file is loaded once and filtered
/// in memory.
const Grep = struct {
    pub const title = "Search project";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    /// Files larger than this are skipped, and lines are capped at `max_line`.
    const max_file = 1024 * 1024;
    const max_line = 300;
    /// rg results kept per query.
    const max_matches = 20_000;

    pub fn produce(e: *Engine) anyerror!void {
        if (!haveRg(e.io)) return Files.eachProjectFile(e, {}, addLines);
        const query = e.producerQuery();
        if (std.mem.trim(u8, query, " ").len == 0) return;
        const pattern = try fuzzyRegex(e.gpa, query);
        defer e.gpa.free(pattern);
        const max_cols = std.fmt.comptimePrint("--max-columns={d}", .{max_line});
        _ = try streamCommand(e, &.{
            "rg",                    "--null", "--line-number", "--no-heading", "--color=never", "--smart-case",
            "--no-require-git", // honor .gitignore outside git repos too
            max_cols, "--max-columns-preview", "-e", pattern,
        }, '\n', {}, addRgMatch);
    }

    /// "path\0line:text" from `rg --null --line-number`.
    fn addRgMatch(_: void, e: *Engine, record: []const u8) !bool {
        if (e.items.count() >= max_matches) return false;
        const nul = std.mem.indexOfScalar(u8, record, 0) orelse return true;
        const rest = record[nul + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return true;
        var detail: [std.fs.max_path_bytes + 16]u8 = undefined;
        const where = std.fmt.bufPrint(&detail, "{s}:{s}", .{ record[0..nul], rest[0..colon] }) catch return true;
        const text = std.mem.trim(u8, rest[colon + 1 ..], " \t\r");
        try e.items.append(.{ .text = text, .detail = where });
        return true;
    }

    /// `wake fn` -> `w.*?a.*?k.*?e.*?f.*?n`: the characters in order, spaces ignored.
    fn fuzzyRegex(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var it = std.unicode.Utf8View.initUnchecked(query).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (cp.len == 1 and cp[0] == ' ') continue;
            if (out.items.len > 0) try out.appendSlice(gpa, ".*?");
            if (cp.len == 1 and std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$#&-~", cp[0]) != null) try out.append(gpa, '\\');
            try out.appendSlice(gpa, cp);
        }
        return out.toOwnedSlice(gpa);
    }

    fn addLines(_: void, e: *Engine, path: []const u8, _: usize) !void {
        var full_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ e.root, path }) catch return;
        const data = Io.Dir.cwd().readFileAlloc(e.io, full, e.gpa, .limited(max_file)) catch return;
        defer e.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) return; // binary
        var detail: [std.fs.max_path_bytes + 16]u8 = undefined;
        var lines = std.mem.splitScalar(u8, data, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            const text = std.mem.trim(u8, line, " \t\r");
            if (text.len < 2) continue;
            const where = std.fmt.bufPrint(&detail, "{s}:{d}", .{ path, n }) catch continue;
            try e.items.append(.{ .text = text[0..@min(text.len, max_line)], .detail = where });
            if (e.items.count() % 4096 == 0) try e.checkpoint();
        }
    }

    pub fn location(ed: *Editor, item: Item) !?Location {
        const loc = parseLocation(item.detail) orelse return null;
        return .{ .path = try ed.pickerPath(loc.path), .line = loc.line, .col = loc.col };
    }

    // Paths are relative to the project searched.
    pub fn accept(ed: *Editor, item: Item) !void {
        const loc = parseLocation(item.detail) orelse return;
        const path = try ed.pickerPath(loc.path);
        defer ed.gpa.free(path);
        try ed.jumpTo(path, loc.line, loc.col);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const loc = parseLocation(item.detail) orelse return;
        const path = try ed.pickerPath(loc.path);
        defer ed.gpa.free(path);
        try previewAt(ed, path, loc.line, out);
    }
};

/// Definitions / references from the language server (`ed.locations`).
const Locations = struct {
    pub const title = "Locations";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [std.fs.max_path_bytes + 32]u8 = undefined;
        for (ed.locations.items) |loc| {
            const text = try lineText(ed, loc.path, loc.line);
            defer ed.gpa.free(text);
            const where = std.fmt.bufPrint(&detail, "{s}:{d}:{d}", .{ loc.path, loc.line + 1, loc.col + 1 }) catch continue;
            try items.append(.{ .text = std.mem.trim(u8, text, " \t"), .detail = where });
        }
    }

    /// The text of one line of a file (open buffer or disk). Caller frees.
    fn lineText(ed: *Editor, path: []const u8, line: usize) ![]u8 {
        for (ed.buffers.items) |b| {
            if (b.path) |bp| if (std.mem.eql(u8, bp, path)) {
                if (line >= b.text.lineCount()) return ed.gpa.dupe(u8, "");
                return ed.gpa.dupe(u8, b.text.lineSlice(line));
            };
        }
        const data = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(Files.preview_limit)) catch
            return ed.gpa.dupe(u8, path);
        defer ed.gpa.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        var i: usize = 0;
        while (it.next()) |l| : (i += 1) if (i == line) return ed.gpa.dupe(u8, l);
        return ed.gpa.dupe(u8, "");
    }

    pub const accept = jumpToDetail;
    pub const preview = previewDetail;
    pub const location = detailLocation;
};

/// `SPC f x`: language server diagnostics for all files.
const Diagnostics = struct {
    pub const title = "Diagnostics";
    pub const prefix: ?u8 = '!';
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [std.fs.max_path_bytes + 32]u8 = undefined;
        for (ed.lsps.items) |l| {
            for (l.diagnostics.keys(), l.diagnostics.values()) |path, list| {
                for (list) |d| {
                    const where = std.fmt.bufPrint(&detail, "{s}:{d}:{d}", .{ path, d.line + 1, d.col + 1 }) catch continue;
                    const first_line = std.mem.sliceTo(d.message, '\n');
                    try items.append(.{ .text = first_line, .detail = where, .id = @intFromEnum(d.severity) });
                }
            }
        }
    }

    pub const accept = jumpToDetail;
    pub const preview = previewDetail;
    pub const location = detailLocation;
};

test "location details" {
    const a = parseLocation("src/main.zig:12:5").?;
    try std.testing.expectEqualStrings("src/main.zig", a.path);
    try std.testing.expectEqual(11, a.line);
    try std.testing.expectEqual(4, a.col);
    const b = parseLocation("build.zig:3").?;
    try std.testing.expectEqualStrings("build.zig", b.path);
    try std.testing.expectEqual(2, b.line);
}

// ---------------------------------------------------------------------------
// External programs

var rg_state: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 yes, 2 no

/// Whether ripgrep is on PATH (checked once).
pub fn haveRg(io: Io) bool {
    const state = rg_state.load(.acquire);
    if (state != 0) return state == 1;
    const found = onPath(io, "rg");
    rg_state.store(if (found) 1 else 2, .release);
    return found;
}

pub fn onPath(io: Io, name: []const u8) bool {
    const path = std.c.getenv("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path), ':');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (dirs.next()) |dir| {
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (Io.Dir.accessAbsolute(io, full, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Runs `argv` and calls `onRecord(ctx, engine, record)` for every
/// `sep`-terminated record of its output as it streams in (`onRecord` returns
/// false to stop early). The process is registered with the engine so closing
/// or re-querying the picker kills it. Returns false if it could not start.
fn streamCommand(e: *Engine, argv: []const []const u8, sep: u8, ctx: anytype, comptime onRecord: anytype) !bool {
    var child = std.process.spawn(e.io, .{ .argv = argv, .cwd = .{ .path = e.root }, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return false;
    e.child_pid.store(child.id.?, .release);
    defer {
        e.child_pid.store(0, .release);
        child.kill(e.io);
    }
    const out = child.stdout.?;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(e.gpa);
    var chunk: [64 * 1024]u8 = undefined;
    var records: usize = 0;
    reading: while (true) {
        const n = out.readStreaming(e.io, &.{&chunk}) catch break;
        try buf.appendSlice(e.gpa, chunk[0..n]);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buf.items, start, sep)) |end| {
            const keep_going = try onRecord(ctx, e, buf.items[start..end]);
            start = end + 1;
            records += 1;
            if (!keep_going) break :reading;
            if (records % 1024 == 0) try e.checkpoint();
        }
        buf.replaceRangeAssumeCapacity(0, start, &.{});
    }
    return true;
}

test "fuzzy regex for rg" {
    const gpa = std.testing.allocator;
    const r = try Grep.fuzzyRegex(gpa, "a.b c");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("a.*?\\..*?b.*?c", r);
}

/// `SPC f s`: the current file's symbols (`ed.symbols`), in document order.
const Symbols = struct {
    pub const title = "Symbols";
    pub const prefix: ?u8 = '@';
    pub const start_mode: StartMode = .insert;

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [64]u8 = undefined;
        for (ed.symbols.items, 0..) |sym, i| {
            const label = std.fmt.bufPrint(&detail, "{s}  {d}", .{ sym.kind, sym.line + 1 }) catch sym.kind;
            try items.append(.{ .text = sym.name, .detail = label, .id = @intCast(i) });
        }
    }

    pub fn location(ed: *Editor, item: Item) !?Location {
        if (item.id >= ed.symbols.items.len) return null;
        const path = ed.buffer.path orelse return null;
        const sym = ed.symbols.items[item.id];
        return .{ .path = try ed.gpa.dupe(u8, path), .line = sym.line, .col = sym.col };
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= ed.symbols.items.len) return;
        const sym = ed.symbols.items[item.id];
        const t = ed.text();
        const line = @min(sym.line, t.lineCount() - 1);
        ed.setCursor(t.lineStart(line) + @min(sym.col, t.lineLen(line)));
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.symbols.items.len) return;
        const b = ed.buffer;
        try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
        out.focus_line = ed.symbols.items[item.id].line;
    }
};

// ---------------------------------------------------------------------------
// Confirmations: a two-row Yes/No picker.

/// `SPC b x`: delete `ed.confirm_target`'s file?
const ConfirmDelete = struct {
    pub const title = "Delete file?";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        const b = ed.confirm_target orelse return;
        try items.append(.{ .text = "No, keep it", .detail = "", .id = 0 });
        try items.append(.{ .text = "Yes, delete it", .detail = b.displayName(), .id = 1 });
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        const b = ed.confirm_target orelse return;
        ed.confirm_target = null;
        if (item.id != 1) return ed.setMessage(.info, "kept \"{s}\"", .{b.displayName()});
        // The buffer may have been closed while the picker was open.
        for (ed.buffers.items) |o| if (o == b) return ed.deleteFile(b);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const b = ed.confirm_target orelse return;
        if (item.id == 1) {
            try out.text.print(ed.gpa, "Removes \"{s}\" from disk and closes it.\nThis cannot be undone.", .{b.displayName()});
        } else try out.text.appendSlice(ed.gpa, "Leaves the file alone.");
    }
};

/// Text for one row: the first `max` bytes, line breaks shown as "↵".
fn oneLine(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    for (text) |b| {
        if (b == '\n') {
            if (n + 3 > buf.len) break;
            @memcpy(buf[n..][0..3], "↵");
            n += 3;
        } else {
            if (n + 1 > buf.len) break;
            buf[n] = if (b == '\t') ' ' else b;
            n += 1;
        }
    }
    return buf[0..n];
}

/// `SPC f y`: every register that holds something; Enter pastes it.
const RegisterList = struct {
    pub const title = "Registers";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    const names = "\"0123456789abcdefghijklmnopqrstuvwxyz-";

    pub fn fill(ed: *Editor, items: *Items) !void {
        var buf: [300]u8 = undefined;
        for (names) |name| {
            const v = ed.registers.get(name) orelse continue;
            const label = [_]u8{ '"', name };
            try items.append(.{ .text = oneLine(&buf, v.text), .detail = &label, .id = name });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.pasteRegister(@intCast(item.id));
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const v = ed.registers.get(@as(u8, @intCast(item.id))) orelse return;
        try out.text.appendSlice(ed.gpa, v.text);
    }
};

/// `SPC f m`: the marks (`m{letter}`), this file's and the global ones.
const Marks = struct {
    pub const title = "Marks";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    fn visible(ed: *Editor, m: Editor.Mark) bool {
        return std.ascii.isUpper(m.name) or m.buffer == ed.buffer;
    }

    pub fn fill(ed: *Editor, items: *Items) !void {
        var buf: [512]u8 = undefined;
        for (ed.marks.items, 0..) |m, i| {
            if (!visible(ed, m)) continue;
            const name = if (m.buffer) |b| b.displayName() else m.path orelse "?";
            if (m.buffer) |b| {
                const t = &b.text;
                const line = t.lineOf(@min(m.pos, t.len()));
                const detail = std.fmt.bufPrint(&buf, "{c}  {s}:{d}", .{ m.name, name, line + 1 }) catch name;
                const text = std.mem.trim(u8, t.lineSlice(line), " \t");
                try items.append(.{ .text = if (text.len > 0) text else "(blank line)", .detail = detail, .id = @intCast(i) });
            } else {
                const detail = std.fmt.bufPrint(&buf, "{c}  {s}", .{ m.name, name }) catch name;
                try items.append(.{ .text = "(closed file)", .detail = detail, .id = @intCast(i) });
            }
        }
        if (items.count() == 0) ed.setMessage(.info, "no marks yet (m and a letter sets one)", .{});
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= ed.marks.items.len) return;
        ed.pushJump();
        try ed.goMark(ed.marks.items[item.id], true);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.marks.items.len) return;
        const m = ed.marks.items[item.id];
        if (m.buffer) |b| {
            try out.setCode(ed.gpa, b.text.slice(0, b.text.len()), b.path);
            out.focus_line = b.text.lineOf(@min(m.pos, b.text.len()));
        } else if (m.path) |p| try Files.previewPath(ed, p, out);
    }
};

/// `SPC f u`: every state of the buffer's undo tree, newest first, branches
/// you undid away from included. Enter takes the buffer there.
const UndoHistory = struct {
    pub const title = "Undo history";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        const h = &ed.buffer.history;
        try h.commit(ed.gpa);
        var buf: [200]u8 = undefined;
        var detail_buf: [48]u8 = undefined;
        var i = h.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const node = h.nodes.items[i];
            var w: Io.Writer = .fixed(&buf);
            if (i == 0) {
                w.writeAll("the file as opened") catch {};
            } else for (node.ops, 0..) |op, k| {
                if (k > 0) w.writeAll("  ") catch break;
                var text_buf: [80]u8 = undefined;
                w.print("{s}{s}", .{ if (op.kind == .insert) "+ " else "- ", oneLine(&text_buf, op.text) }) catch break;
            }
            const here: []const u8 = if (i == h.current) "now" else if (i == h.saved) "saved" else "";
            const detail = std.fmt.bufPrint(&detail_buf, "{s}  #{d}", .{ here, i }) catch "";
            try items.append(.{ .text = w.buffered(), .detail = detail, .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.undoTo(item.id);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const h = &ed.buffer.history;
        if (item.id >= h.nodes.items.len) return;
        if (item.id == 0) return out.text.appendSlice(ed.gpa, "The file as it was when opened.");
        for (h.nodes.items[item.id].ops) |op| {
            var lines = std.mem.splitScalar(u8, op.text, '\n');
            while (lines.next()) |line| try out.text.print(ed.gpa, "{s} {s}\n", .{ if (op.kind == .insert) "+" else "-", line });
        }
    }
};

/// `SPC f k`: every key binding in every mode, searchable by what it does.
/// Enter runs it (a normal-mode command; others only say their keys).
const Help = struct {
    pub const title = "Keys";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    const mode_letters = [_]struct { keymap.Mode, []const u8 }{
        .{ .normal, "n" },   .{ .visual, "v" },        .{ .operator, "o" }, .{ .insert, "i" },
        .{ .picker, "p" },   .{ .picker_normal, "P" }, .{ .search, "/" },
    };

    fn sameKeys(a: []const keys.KeyEvent, b: []const keys.KeyEvent) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!x.eql(y)) return false;
        return true;
    }

    fn commandIndex(cmd: *const commands.Command) u32 {
        return @intCast((@intFromPtr(cmd) - @intFromPtr(&commands.all[0])) / @sizeOf(commands.Command));
    }

    pub fn fill(ed: *Editor, items: *Items) !void {
        var text_buf: [200]u8 = undefined;
        var detail_buf: [96]u8 = undefined;
        for (mode_letters, 0..) |ml, mi| {
            for (ed.keymap.modes.getPtrConst(ml[0]).items) |b| {
                // One row per key and command: the modes it works in together.
                var seen = false;
                for (mode_letters[0..mi]) |earlier| {
                    for (ed.keymap.modes.getPtrConst(earlier[0]).items) |o| {
                        if (o.command == b.command and sameKeys(o.seq, b.seq)) seen = true;
                    }
                }
                if (seen) continue;
                var w: Io.Writer = .fixed(&detail_buf);
                keys.formatSequenceDisplay(b.seq, &w) catch {};
                w.writeAll("  ") catch {};
                for (mode_letters[mi..]) |later| {
                    for (ed.keymap.modes.getPtrConst(later[0]).items) |o| {
                        if (o.command == b.command and sameKeys(o.seq, b.seq)) {
                            w.writeAll(later[1]) catch {};
                            break;
                        }
                    }
                }
                const text = std.fmt.bufPrint(&text_buf, "{s}  ({s})", .{ b.command.doc, b.command.name }) catch b.command.doc;
                try items.append(.{ .text = text, .detail = w.buffered(), .id = commandIndex(b.command) });
            }
        }
        // The menus' rows: `SPC b`, `SPC l r`...
        for (menus) |m| for (m[1]) |e| {
            const cmd = commands.find(e.command) orelse continue;
            const key: []const u8 = if (e.key == ' ') "SPC" else &[_]u8{e.key};
            const detail = std.fmt.bufPrint(&detail_buf, "{s}{s}  menu", .{ m[0], key }) catch continue;
            const text = std.fmt.bufPrint(&text_buf, "{s}  ({s})", .{ e.label, cmd.name }) catch continue;
            try items.append(.{ .text = text, .detail = detail, .id = commandIndex(cmd) });
        };
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= commands.all.len) return;
        const cmd = &commands.all[item.id];
        // Only what makes sense from here: a command with a normal-mode key,
        // or a menu row.
        const in_menu = std.mem.endsWith(u8, item.detail, "menu");
        if (!in_menu and ed.keymap.firstBinding(.normal, cmd) == null) return ed.setMessage(.info, "{s}: {s}", .{ item.detail, cmd.doc });
        try ed.runCommand(cmd);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= commands.all.len) return;
        const cmd = &commands.all[item.id];
        try out.text.print(ed.gpa, "{s}\n\n{s}\n\nkeys (n normal, v visual, o after an operator,\ni insert, p picker, P picker list, / search):\n", .{ cmd.name, cmd.doc });
        for (mode_letters) |ml| {
            for (ed.keymap.modes.getPtrConst(ml[0]).items) |b| {
                if (b.command != cmd) continue;
                var buf: [64]u8 = undefined;
                var w: Io.Writer = .fixed(&buf);
                keys.formatSequenceDisplay(b.seq, &w) catch {};
                try out.text.print(ed.gpa, "  {s}  {s}\n", .{ ml[1], w.buffered() });
            }
        }
    }
};

/// `SPC f SPC`: every picker there is, by what it lists.
/// `SPC f`: every picker, few of them: each has its scopes on `C-t`
/// (Files: project, open, recent, whole disk; Search: project, this file,
/// todos...).
const Pickers = Menu("Find", &.{
    .{ .key = 'f', .label = "Files (C-t: buffers, recent, whole disk)", .command = "find_file" },
    .{ .key = 'b', .label = "Buffers", .command = "switch_buffer" },
    .{ .key = 'r', .label = "Recent files (everywhere, latest first)", .command = "recent_files" },
    .{ .key = 'g', .label = "Search (C-t: this file, todos)", .command = "search_project" },
    .{ .key = 'x', .label = "Problems (C-t: last run, saved list)", .command = "list_diagnostics" },
    .{ .key = 'j', .label = "Places (C-t: marks)", .command = "jump_list" },
    .{ .key = 'c', .label = "Commands (C-t: keys)", .command = "command_picker" },
    .{ .key = 'e', .label = "Explore folders", .command = "browse_files" },
    .{ .key = 'p', .label = "Projects", .command = "switch_project" },
    .{ .key = 'y', .label = "Registers", .command = "pick_register" },
    .{ .key = 'u', .label = "Undo history", .command = "undo_history" },
    .{ .key = 'n', .label = "Notifications", .command = "message_history" },
    .{ .key = 'h', .label = "Start screen", .command = "start_screen" },
    .{ .key = 'T', .label = "Colour scheme", .command = "pick_theme" },
    .{ .key = 'M', .label = "Manual pages", .command = "man_pages" },
});

var fd_state: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 yes, 2 no

fn haveFd(io: Io) bool {
    const state = fd_state.load(.acquire);
    if (state != 0) return state == 1;
    const found = onPath(io, "fd");
    fd_state.store(if (found) 1 else 2, .release);
    return found;
}

/// `SPC f a` / `SPC f d`: files or folders anywhere on disk, by name. The
/// disk is searched for each query with `fd` (hidden and ignored files
/// included; system and cache folders left out), from three characters on.
/// A folder becomes the project to work in.
fn Anywhere(comptime folders: bool) type {
    return struct {
        pub const title = if (folders) "Find folder (anywhere)" else "Find file (anywhere)";
        pub const prefix: ?u8 = null;
        pub const start_mode: StartMode = .insert;

        const min_query = 3;
        const max_results = 5000;
        const skip = [_][]const u8{ "/proc", "/sys", "/dev", "/run", ".git", "node_modules", "target", "__pycache__", ".cache", ".cargo", ".rustup", ".zig-cache", "zig-pkg" };

        pub fn produce(e: *Engine) anyerror!void {
            const query = std.mem.trim(u8, e.producerQuery(), " ");
            if (query.len < min_query or !haveFd(e.io)) return;
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(e.gpa);
            try argv.appendSlice(e.gpa, &.{ "fd", "--absolute-path", "--fixed-strings", "--hidden", "--no-ignore", "--type", if (folders) "d" else "f", "--color", "never" });
            for (skip) |s| try argv.appendSlice(e.gpa, &.{ "--exclude", s });
            // fd matches names; a query with a slash is about the path.
            if (std.mem.indexOfScalar(u8, query, '/') != null) try argv.append(e.gpa, "--full-path");
            try argv.appendSlice(e.gpa, &.{ "--", query, "/" });
            _ = try streamCommand(e, argv.items, '\n', {}, add);
        }

        fn add(_: void, e: *Engine, record: []const u8) !bool {
            if (e.items.count() >= max_results) return false;
            const path = std.mem.trimEnd(u8, record, "/");
            if (path.len == 0) return true;
            // Folders show with a trailing slash, like the browser's.
            var buf: [Io.Dir.max_path_bytes + 1]u8 = undefined;
            const text = if (folders) std.fmt.bufPrint(&buf, "{s}/", .{path}) catch path else path;
            try e.items.append(.{ .text = text });
            return true;
        }

        pub fn accept(ed: *Editor, item: Item) !void {
            if (!folders) return ed.openFile(item.text);
            try ed.switchProject(std.mem.trimEnd(u8, item.text, "/"));
        }

        pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
            if (!folders) return Files.previewPath(ed, item.text, out);
            var dir = Io.Dir.cwd().openDir(ed.io, item.text, .{ .iterate = true }) catch |err|
                return out.text.print(ed.gpa, "({s})", .{@errorName(err)});
            defer dir.close(ed.io);
            var it = dir.iterate();
            var n: usize = 0;
            while (it.next(ed.io) catch null) |entry| : (n += 1) {
                if (n == 200) break;
                try out.text.print(ed.gpa, "{s}{s}\n", .{ entry.name, if (entry.kind == .directory) "/" else "" });
            }
        }
    };
}

/// `SPC l a`: what the language server offers to do here.
const CodeActions = struct {
    pub const title = "Code actions";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        for (ed.code_actions.items, 0..) |a, i| try items.append(.{ .text = a.title, .detail = a.kind, .id = @intCast(i) });
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.applyCodeAction(item.id);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.code_actions.items.len) return;
        const a = ed.code_actions.items[item.id];
        try out.text.print(ed.gpa, "{s}\n\n{s}", .{ a.title, if (a.kind.len > 0) a.kind else "action" });
    }
};

/// `SPC f w`: symbols across the project. The language server searches as
/// you type (`Editor.inputChanged` asks it; its answer refills the list).
const WorkspaceSymbols = struct {
    pub const title = "Project symbols";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [std.fs.max_path_bytes + 48]u8 = undefined;
        for (ed.workspace_symbols.items, 0..) |s, i| {
            const where = std.fmt.bufPrint(&detail, "{s}  {s}:{d}", .{ s.kind, s.path, s.line + 1 }) catch s.path;
            try items.append(.{ .text = s.name, .detail = where, .id = @intCast(i) });
        }
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (item.id >= ed.workspace_symbols.items.len) return;
        const s = ed.workspace_symbols.items[item.id];
        const path = try ed.gpa.dupe(u8, s.path);
        defer ed.gpa.free(path);
        try ed.jumpTo(path, s.line, s.col);
    }

    pub fn location(ed: *Editor, item: Item) !?Location {
        if (item.id >= ed.workspace_symbols.items.len) return null;
        const s = ed.workspace_symbols.items[item.id];
        return .{ .path = try ed.gpa.dupe(u8, s.path), .line = s.line, .col = s.col };
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        if (item.id >= ed.workspace_symbols.items.len) return;
        const s = ed.workspace_symbols.items[item.id];
        try previewAt(ed, s.path, s.line, out);
    }
};

/// `SPC r r`: the code runner. This project's commands, newest first:
/// Enter on the list runs the last one again, any other can be picked, and
/// typed text is a new command (it stays the first row, so Enter runs what
/// you typed, not an old command it resembles). `x` forgets one.
/// Ctrl-Enter runs it under gdb instead (building it first if need be).
const Runner = struct {
    pub const title = "Run";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;
    pub const create_first = true;
    pub const create_label = "Run ";

    pub fn fill(ed: *Editor, items: *Items) !void {
        const history = try ed.runnerHistory();
        defer {
            for (history) |c| ed.gpa.free(c);
            ed.gpa.free(history);
        }
        for (history, 0..) |c, i| try items.append(.{ .text = c, .detail = if (i == 0) "last" else "", .id = @intCast(i) });
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.runFromRunner(item.text);
    }

    pub fn create(ed: *Editor, query: []const u8) !void {
        try ed.runFromRunner(query);
    }

    pub const alt_accept: AltAccept = .{ .label = "debug", .run = debugIt };

    fn debugIt(ed: *Editor, text: []const u8) anyerror!void {
        try debugging.fromRunner(ed, text);
    }

    fn openDebug(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.open(ed);
    }

    fn edit(ed: *Editor, _: ?Item) anyerror!void {
        try ed.runnerEdit();
    }

    /// `c`: the command in the command editor (a vim buffer, any number of
    /// lines); with no row, an empty one.
    fn change(ed: *Editor, item: ?Item) anyerror!void {
        try ed.editCommand(if (item) |it| it.text else "", .runner, null);
    }

    pub const item_actions = [_]Action{
        .{ .label = "edit it", .key = 'e', .ctrl = 'e', .stay = true, .run = edit },
        .{ .label = "forget it", .key = 'x', .ctrl = 'x', .stay = true, .run = command("picker_delete") },
        .{ .label = "debugger", .key = 'd', .any = true, .run = openDebug },
        .{ .label = "change it (vim)", .key = 'c', .any = true, .run = change },
        .{ .label = "again", .key = '.', .any = true, .run = command("run_again") },
        .{ .label = "output", .key = 'o', .any = true, .run = command("run_output") },
        .{ .label = "errors", .key = 'E', .any = true, .run = command("run_errors") },
        .{ .label = "terminal", .key = 't', .any = true, .run = command("terminal_toggle") },
        .{ .label = "terminal in this window", .key = 'T', .any = true, .run = command("terminal_window") },
        .{ .label = "SQL statement", .key = 's', .any = true, .run = command("run_sql") },
        .{ .label = "SQL file", .key = 'S', .any = true, .run = command("run_sql_file") },
    };

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const folder = ed.commandFolder() catch return;
        defer ed.gpa.free(folder);
        const how = if (debugging.hasBreakpoints(ed)) "under gdb: this project has breakpoints\n(t in SPC d turns them off)" else "through your shell (C-Enter: under gdb)";
        try out.text.print(ed.gpa, "Runs in {s}\n{s}:\n\n{s}", .{ folder, how, item.text });
    }
};

/// `SPC d`: the debugger. Stopped, the rows are the stack (innermost first;
/// the preview shows a frame's arguments and locals, Enter goes to it),
/// then the breakpoints. The letters step: `n` next line, `s` into the call,
/// `f` finish the function, `c` continue, `p` pause, `x` stop. Breakpoints:
/// `b` on the cursor's line, `d` this one, `B` all, `t` all on/off (off:
/// kept, but runs run normally), `u` undo. `r` runs the project's command
/// (`SPC r Enter`: under gdb with breakpoints on), `R` under gdb always;
/// in `SPC r` that's Enter and Ctrl-Enter.
const Debug = struct {
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;
    pub const create_label = "Debug ";
    const Row = debugging.Row;

    pub const title = "Debug";

    /// The title, saying what the program is doing.
    pub fn liveTitle(ed: *Editor) []const u8 {
        if (ed.dbg.asking) return "Debug which program?";
        const d = ed.dbg.session orelse return if (ed.dbg.breakpoints_on) "Debug: breakpoints on (runs go through gdb)" else "Debug: breakpoints off (runs run normally)";
        return switch (d.state) {
            .starting => "Debug: starting",
            .running => "Debug: running (p pauses)",
            .stopped => "Debug: stopped",
            .exited => "Debug: ended",
        };
    }

    pub fn fill(ed: *Editor, items: *Items) !void {
        var detail: [Io.Dir.max_path_bytes + 32]u8 = undefined;
        // Asking which program a build made: only the programs found.
        if (ed.dbg.asking) {
            for (ed.dbg.found, 0..) |f, i| try items.append(.{ .text = f, .detail = "", .id = Row.id(.{ .program = @intCast(i) }) });
            return;
        }
        if (ed.dbg.session) |d| for (d.frames.items, 0..) |f, i| {
            const where = if (f.path) |p| std.fmt.bufPrint(&detail, "{s}:{d}", .{ std.fs.path.basename(p), f.line + 1 }) catch "" else "no source";
            try items.append(.{ .text = f.name, .detail = where, .id = Row.id(.{ .frame = @intCast(i) }) });
        };
        // Not debugging: the command Enter (or `R`) debugs.
        if (ed.dbg.session == null) if (try debugging.commandRow(ed)) |row| {
            defer ed.gpa.free(row.cmd);
            defer ed.gpa.free(row.from);
            try items.append(.{ .text = row.cmd, .detail = if (row.edited) "debug command" else "debug command (from the runner)", .id = Row.id(.command) });
        };
        for (ed.dbg.breakpoints.items, 0..) |b, i| {
            const dot = if (ed.dbg.breakpoints_on) "●" else "○";
            const shown = std.fmt.bufPrint(&detail, "{s} {s}:{d}", .{ dot, std.fs.path.basename(b.path), b.line + 1 }) catch continue;
            try items.append(.{ .text = shown, .detail = if (ed.dbg.breakpoints_on) "breakpoint" else "breakpoint (off)", .id = Row.id(.{ .breakpoint = @intCast(i) }) });
        }
    }

    /// Typed: a program and its arguments.
    pub fn create(ed: *Editor, query: []const u8) !void {
        try debugging.pickProgram(ed, query);
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        switch (Row.of(item.id)) {
            .command => try debugging.acceptCommandRow(ed),
            .program => try debugging.pickProgram(ed, item.text),
            .frame => |i| try debugging.showFrame(ed, i),
            .breakpoint => |i| {
                if (i >= ed.dbg.breakpoints.items.len) return;
                const b = ed.dbg.breakpoints.items[i];
                const path = try ed.gpa.dupe(u8, b.path);
                defer ed.gpa.free(path);
                try ed.jumpTo(path, b.line, 0);
                ed.centerCursor();
            },
        }
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        switch (Row.of(item.id)) {
            .command => {
                try out.text.print(ed.gpa, "Enter: runs under gdb\n\n  {s}\n\nin {s}\n\n", .{ item.text, ed.projectRoot() });
                const programs = try debugging.pickedPrograms(ed);
                defer {
                    for (programs) |x| ed.gpa.free(x);
                    ed.gpa.free(programs);
                }
                if (programs.len > 0) try out.text.print(ed.gpa, "its program: {s}\n\n", .{programs[0]});
                try out.text.appendSlice(ed.gpa, "e: change it (a debug build, other arguments, or\n   `zig build && ./zig-out/bin/app` to name the program).\nIt holds for this session; the runner's command stays as it is.");
            },
            .program => try out.text.print(ed.gpa, "Enter: debugs\n\n  {s}\n\n(type after it to add arguments)", .{item.text}),
            .breakpoint => |i| {
                if (i >= ed.dbg.breakpoints.items.len) return;
                const b = ed.dbg.breakpoints.items[i];
                try previewAt(ed, b.path, b.line, out);
            },
            .frame => |i| {
                const d = ed.dbg.session orelse return;
                if (i >= d.frames.items.len) return;
                const f = d.frames.items[i];
                try out.text.print(ed.gpa, "{s}", .{f.name});
                if (f.path) |p| try out.text.print(ed.gpa, "  {s}:{d}", .{ p, f.line + 1 });
                try out.text.appendSlice(ed.gpa, "\n\n");
                if (f.vars.items.len > 0) {
                    try out.text.appendSlice(ed.gpa, f.vars.items);
                } else if (f.vars_left > 0) {
                    try out.text.appendSlice(ed.gpa, "(asking gdb...)");
                } else if (i < debugging.frames_with_variables) {
                    try out.text.appendSlice(ed.gpa, "(no arguments or locals)");
                } else try out.text.appendSlice(ed.gpa, "(Enter goes there)");
            },
        }
    }

    fn stepper(comptime how: @import("../Debugger.zig").Step) *const fn (*Editor, ?Item) anyerror!void {
        return &struct {
            fn run(ed: *Editor, _: ?Item) anyerror!void {
                try debugging.step(ed, how);
            }
        }.run;
    }

    fn pause(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.pause(ed);
    }

    fn stop(ed: *Editor, _: ?Item) anyerror!void {
        debugging.stop(ed);
    }

    fn breakpoint(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.toggleBreakpoint(ed);
    }

    /// `d`: the row's breakpoint removed.
    fn removeRow(ed: *Editor, item: ?Item) anyerror!void {
        switch (Row.of((item orelse return).id)) {
            .breakpoint => |i| try debugging.removeBreakpoint(ed, i),
            else => ed.setMessage(.info, "d removes a breakpoint row", .{}),
        }
    }

    /// `e`: the debugger's command, in the command editor.
    fn editRow(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.editCommandRow(ed);
    }

    fn clearAll(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.clearBreakpoints(ed);
    }

    fn onOff(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.toggleBreakpointsOn(ed);
    }

    fn undo(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.undoBreakpoints(ed);
    }

    /// `r`: the project's runner command (`SPC r Enter`): under gdb with
    /// breakpoints on, else a plain run. With none yet, the runner opens.
    fn run(ed: *Editor, _: ?Item) anyerror!void {
        try ed.runAgain();
    }

    /// `R`: the runner command under gdb, breakpoints or not.
    fn runDebug(ed: *Editor, _: ?Item) anyerror!void {
        try debugging.again(ed);
    }

    /// `C-j` / `C-k`: the editor's cursor down / up, the picker staying
    /// open (to put a breakpoint on another line with `b`).
    fn cursorBy(comptime name: []const u8) *const fn (*Editor, ?Item) anyerror!void {
        return &struct {
            fn run(ed: *Editor, _: ?Item) anyerror!void {
                const c = commands.find(name) orelse return;
                try c.run(.{ .ed = ed, .count = 1, .has_count = false });
            }
        }.run;
    }

    pub const item_actions = [_]Action{
        .{ .label = "cursor down", .ctrl = 'j', .stay = true, .any = true, .keep_rows = true, .run = cursorBy("move_down") },
        .{ .label = "cursor up", .ctrl = 'k', .stay = true, .any = true, .keep_rows = true, .run = cursorBy("move_up") },
        .{ .label = "next", .key = 'n', .stay = true, .any = true, .run = stepper(.next) },
        .{ .label = "step in", .key = 's', .stay = true, .any = true, .run = stepper(.step_in) },
        .{ .label = "finish", .key = 'f', .stay = true, .any = true, .run = stepper(.step_out) },
        .{ .label = "continue", .key = 'c', .any = true, .run = stepper(.cont) },
        .{ .label = "pause", .key = 'p', .stay = true, .any = true, .run = pause },
        .{ .label = "breakpoint here", .key = 'b', .stay = true, .any = true, .run = breakpoint },
        .{ .label = "remove breakpoint", .key = 'd', .stay = true, .run = removeRow },
        .{ .label = "edit the command", .key = 'e', .any = true, .run = editRow },
        .{ .label = "breakpoints on/off", .key = 't', .stay = true, .any = true, .run = onOff },
        .{ .label = "remove all breakpoints", .key = 'B', .stay = true, .any = true, .run = clearAll },
        .{ .label = "undo (breakpoints)", .key = 'u', .stay = true, .any = true, .run = undo },
        .{ .label = "output", .key = 'o', .any = true, .run = command("run_output") },
        .{ .label = "run", .key = 'r', .any = true, .run = run },
        .{ .label = "run under gdb", .key = 'R', .any = true, .run = runDebug },
        .{ .label = "stop", .key = 'x', .stay = true, .any = true, .run = stop },
    };
};

/// `x` / `dd` in the file browser: delete `ed.browse_target`?
const ConfirmRemove = struct {
    pub const title = "Delete?";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        const target = ed.browse_target orelse return;
        try items.append(.{ .text = "No, keep it", .detail = "", .id = 0 });
        try items.append(.{ .text = "Yes, delete it", .detail = std.fs.path.basename(target), .id = 1 });
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        try ed.browseRemove(item.id == 1);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const target = ed.browse_target orelse return;
        if (item.id != 1) return out.text.appendSlice(ed.gpa, "Leaves it alone.");
        const st = Io.Dir.cwd().statFile(ed.io, target, .{}) catch null;
        const what: []const u8 = if (st != null and st.?.kind == .directory) "the folder and everything in it" else "the file";
        try out.text.print(ed.gpa, "Removes {s} from disk:\n{s}\n\nThis cannot be undone.", .{ what, target });
    }
};

// ---------------------------------------------------------------------------
// Git: a small menu of plain actions, branches, changed files.

/// `SPC g g`: everything git, in words.
const GitActions = struct {
    pub const title = "Git";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    const actions = [_]struct { []const u8, []const u8 }{
        .{ "Commit all changes...", "SPC g c" },
        .{ "Push", "" },
        .{ "Pull", "" },
        .{ "Switch branch / new branch...", "SPC g b" },
        .{ "Changed files", "SPC g s" },
        .{ "Set remote URL...", "" },
        .{ "Restore change at cursor", "SPC g r" },
        .{ "Reload HEAD", "SPC g u" },
        .{ "Make this a git repository (git init)", "SPC g i" },
        .{ "Commit that changed this line", "" },
    };
    pub const row_keys: []const u8 = "cpPbsRruil";

    pub fn fill(_: *Editor, items: *Items) !void {
        for (actions, 0..) |a, i| try items.append(.{ .text = a[0], .detail = row_keys[i .. i + 1], .id = @intCast(i) });
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        switch (item.id) {
            0 => ed.gitCommitPrompt(),
            1 => try ed.gitPush(),
            2 => try ed.gitPull(),
            3 => try ed.openPicker(.git_branches, ""),
            4 => try ed.openPicker(.git_changes, ""),
            5 => try ed.gitRemotePrompt(),
            6 => if (ed.hunkAtCursor()) |h| try ed.restoreHunk(h) else ed.setMessage(.info, "no change here", .{}),
            7 => ed.reloadGit(),
            8 => try ed.gitInit(),
            9 => if (commands.find("git_line_commit")) |c| try ed.runCommand(c),
            else => {},
        }
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        const help = [_][]const u8{
            "Saves your open files, asks for a message,\nthen stages everything and commits.",
            "Sends your commits to the remote (origin).\nThe first push sets up tracking automatically.",
            "Gets new commits from the remote.\nOnly fast-forwards, so it never makes a surprise merge.",
            "Lists your branches. Type a new name to create one.",
            "Lists files with uncommitted changes.",
            "Sets where Push and Pull go (the 'origin' remote).",
            "Puts the HEAD version of the change under the cursor back.",
            "Re-reads HEAD (after committing outside the editor).",
            "Runs git init in this project's folder (the working folder if there is no project), so commits, the gutter and ghost lines work here.",
        };
        if (item.id < help.len) try out.text.appendSlice(ed.gpa, help[item.id]);
    }
};

/// Branches; typing a new name offers to create it.
const GitBranches = struct {
    pub const title = "Branches";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .insert;

    pub fn fill(ed: *Editor, items: *Items) !void {
        if (!ed.inRepo()) return;
        const list = Git.branches(ed.gpa, ed.io, ed.gitRoot().?) orelse return;
        defer list.deinit(ed.gpa);
        var it = list.iterator();
        var current: ?[]const u8 = null;
        while (it.next()) |line| {
            if (line.len < 2) continue;
            // The one you're on last.
            if (line[0] == '*') {
                current = line[1..];
                continue;
            }
            try items.append(.{ .text = line[1..], .detail = "" });
        }
        if (current) |name| try items.append(.{ .text = name, .detail = "current" });
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (std.mem.eql(u8, item.detail, "current")) return ed.setMessage(.info, "already on {s}", .{item.text});
        try ed.gitSwitch(item.text, false);
    }

    pub fn create(ed: *Editor, name: []const u8) !void {
        try ed.gitSwitch(name, true);
    }

    pub fn preview(_: *Editor, _: *const Item, _: *Preview) !void {}
};

/// Files with uncommitted changes (`git status`).
/// `SPC g`: git, as a picker of what changed (Enter opens the file), with
/// everything else git does as its actions.
const GitChanges = struct {
    pub const title = "Git: changed files";
    pub const prefix: ?u8 = null;
    pub const start_mode: StartMode = .normal;

    pub fn fill(ed: *Editor, items: *Items) !void {
        if (!ed.inRepo()) return;
        const out = Git.status(ed.gpa, ed.io, ed.gitRoot().?) orelse return;
        defer ed.gpa.free(out);
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            if (line.len < 4) continue;
            var path = line[3..];
            // Renames: "old -> new"
            if (std.mem.indexOf(u8, path, " -> ")) |arrow| path = path[arrow + 4 ..];
            const abs = try std.fs.path.join(ed.gpa, &.{ ed.gitRoot().?, path });
            defer ed.gpa.free(abs);
            const rel = try ed.relativePath(abs);
            defer ed.gpa.free(rel);
            try items.append(.{ .text = rel, .detail = Git.describeStatus(line[0..2]) });
        }
        if (items.count() == 0) ed.setMessage(.info, "no changes", .{});
    }

    pub fn accept(ed: *Editor, item: Item) !void {
        if (std.mem.eql(u8, item.detail, "deleted")) return ed.setMessage(.info, "{s} was deleted", .{item.text});
        try ed.openFile(item.text);
    }

    pub fn preview(ed: *Editor, item: *const Item, out: *Preview) !void {
        try previewAt(ed, item.text, 0, out);
    }

    fn run(comptime f: anytype) *const fn (*Editor, ?Item) anyerror!void {
        return &struct {
            fn go(ed: *Editor, _: ?Item) anyerror!void {
                const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
                if (@typeInfo(R) == .error_union) try f(ed) else f(ed);
            }
        }.go;
    }

    pub const item_actions = [_]Action{
        .{ .label = "commit all...", .key = 'c', .any = true, .run = run(Editor.gitCommitPrompt) },
        .{ .label = "push", .key = 'p', .any = true, .run = run(Editor.gitPush) },
        .{ .label = "pull", .key = 'P', .any = true, .run = run(Editor.gitPull) },
        .{ .label = "branches", .key = 'b', .any = true, .run = command("git_branches") },
        .{ .label = "restore the change at the cursor", .key = 'r', .any = true, .run = command("git_restore_hunk") },
        .{ .label = "this line's commit", .key = 'l', .any = true, .run = command("git_line_commit") },
        .{ .label = "remote URL...", .key = 'R', .any = true, .run = run(Editor.gitRemotePrompt) },
        .{ .label = "reload HEAD", .key = 'u', .stay = true, .any = true, .run = run(Editor.reloadGit) },
        .{ .label = "git init", .key = 'i', .any = true, .run = run(Editor.gitInit) },
    };
};
