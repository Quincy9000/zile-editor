//! Per-mode key sequence -> command bindings, plus named groups for the
//! which-key menu.
//!
//! Keybinding philosophy (Doom Emacs style): vim motions and operators stay on
//! single keys, and everything else lives in nested leader menus
//! (`SPC s` save file, `SPC q q` quit, ...), discoverable through the
//! which-key popup. No ctrl-chord commands.
//!
//! Milestone 1 uses flat lists with linear lookup; a trie can replace the
//! storage later without changing `lookup` / `continuations`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const keys = @import("keys.zig");
const KeyEvent = keys.KeyEvent;
const commands = @import("../commands.zig");
const Command = commands.Command;

pub const Mode = enum {
    normal,
    insert,
    /// Typing a picker's query (its insert mode).
    picker,
    /// Moving through a picker's results with vim keys (<Esc> from typing).
    picker_normal,
    visual,
    /// After an operator, waiting for its motion or text object (`d` in `dw`).
    operator,
    /// Typing a `/` or `?` search.
    search,
};

pub const max_sequence = 8;

pub const Binding = struct {
    seq: []const KeyEvent,
    command: *const Command,
};

/// A named prefix shown in the which-key menu, e.g. `SPC f` -> "file".
pub const Group = struct {
    seq: []const KeyEvent,
    name: []const u8,
};

pub const Lookup = union(enum) {
    /// No binding starts with this sequence.
    none,
    /// Some binding starts with this sequence; wait for more keys.
    prefix,
    command: *const Command,
};

/// One row of the which-key menu: the next key and what it leads to.
pub const Continuation = struct {
    key: KeyEvent,
    label: []const u8,
    kind: enum { command, group },
};

pub const Keymap = struct {
    modes: std.EnumArray(Mode, std.ArrayList(Binding)) = .initFill(.empty),
    groups: std.ArrayList(Group) = .empty,
    /// Owns the lists and every runtime-bound `seq`.
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) Keymap {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(km: *Keymap) void {
        km.arena.deinit();
        km.* = undefined;
    }

    pub const BindError = keys.ParseError || Allocator.Error || error{UnknownCommand};

    /// Binds (or rebinds) `notation` in `mode` to the command named `command_name`.
    pub fn bind(km: *Keymap, mode: Mode, notation: []const u8, command_name: []const u8) BindError!void {
        const cmd = commands.find(command_name) orelse return error.UnknownCommand;
        var buf: [max_sequence]KeyEvent = undefined;
        const seq = try keys.parseSequence(notation, &buf);
        const a = km.arena.allocator();
        const list = km.modes.getPtr(mode);
        for (list.items) |*b| {
            if (seqEql(b.seq, seq)) {
                b.command = cmd;
                return;
            }
        }
        try list.append(a, .{ .seq = try a.dupe(KeyEvent, seq), .command = cmd });
    }

    pub fn lookup(km: *const Keymap, mode: Mode, seq: []const KeyEvent) Lookup {
        var exact: ?*const Command = null;
        var longer = false;
        for (km.modes.getPtrConst(mode).items) |b| {
            if (b.seq.len < seq.len) continue;
            if (!seqEql(b.seq[0..seq.len], seq)) continue;
            if (b.seq.len == seq.len) exact = b.command else longer = true;
        }
        // An exact match waits while a longer binding shares the prefix.
        // TODO: timeout to resolve "g" vs "gg"-style overlaps.
        if (longer) return .prefix;
        if (exact) |cmd| return .{ .command = cmd };
        return .none;
    }

    /// The first sequence bound to `cmd` in `mode` (table order), for display.
    pub fn firstBinding(km: *const Keymap, mode: Mode, cmd: *const Command) ?[]const KeyEvent {
        for (km.modes.getPtrConst(mode).items) |b| {
            if (b.command == cmd) return b.seq;
        }
        return null;
    }

    pub fn groupName(km: *const Keymap, seq: []const KeyEvent) ?[]const u8 {
        for (km.groups.items) |g| {
            if (seqEql(g.seq, seq)) return g.name;
        }
        return null;
    }

    /// The keys that can follow `prefix`, sorted for display. Fills `out`.
    pub fn continuations(km: *const Keymap, mode: Mode, prefix: []const KeyEvent, out: []Continuation) []Continuation {
        var n: usize = 0;
        outer: for (km.modes.getPtrConst(mode).items) |b| {
            if (b.seq.len <= prefix.len or !seqEql(b.seq[0..prefix.len], prefix)) continue;
            const key = b.seq[prefix.len];
            for (out[0..n]) |c| if (c.key.eql(key)) continue :outer;
            if (n == out.len) break;
            out[n] = if (b.seq.len == prefix.len + 1)
                .{ .key = key, .label = b.command.doc, .kind = .command }
            else
                .{ .key = key, .label = km.groupName(b.seq[0 .. prefix.len + 1]) orelse "...", .kind = .group };
            n += 1;
        }
        std.mem.sort(Continuation, out[0..n], {}, struct {
            fn lessThan(_: void, a: Continuation, b: Continuation) bool {
                return keyOrder(a.key, b.key);
            }
        }.lessThan);
        return out[0..n];
    }

    pub fn loadDefaults(km: *Keymap) Allocator.Error!void {
        const a = km.arena.allocator();
        for (default_bindings) |d| try km.modes.getPtr(d.mode).append(a, d.binding);
        try km.groups.appendSlice(a, &default_groups);
    }
};

fn seqEql(a: []const KeyEvent, b: []const KeyEvent) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

/// Alphabetical, case-insensitive with lowercase first ("q" before "Q"),
/// then special keys.
fn keyOrder(a: KeyEvent, b: KeyEvent) bool {
    const ka = sortKey(a);
    const kb = sortKey(b);
    return if (ka[0] != kb[0]) ka[0] < kb[0] else ka[1] < kb[1];
}

fn sortKey(ev: KeyEvent) [2]u32 {
    return switch (ev.key) {
        .codepoint => |cp| blk: {
            const lower: u32 = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
            break :blk .{ lower, @intFromBool(cp >= 'A' and cp <= 'Z') };
        },
        .special => |s| .{ 0x110000 + @as(u32, @intFromEnum(s)), 0 },
    };
}

// ---------------------------------------------------------------------------
// Defaults, parsed and validated at compile time: a typo in a key notation or
// command name is a compile error, and startup does no parsing.

/// The leader key. Becomes configurable with the config system.
pub const leader = "<Space>";

/// Normal-mode leader menus. Every group must lead somewhere (checked below).
const group_table = [_]struct { []const u8, []const u8 }{
    .{ "q", "cursors" },
};

// Mode sets, so a key that works the same in several modes is listed once.
const N = &[_]Mode{.normal};
const I = &[_]Mode{.insert};
const P = &[_]Mode{.picker};
const V = &[_]Mode{.visual};
const O = &[_]Mode{.operator};
const NV = &[_]Mode{ .normal, .visual };
const NVO = &[_]Mode{ .normal, .visual, .operator };
const S = &[_]Mode{.search};
const PS = &[_]Mode{ .picker, .search };
const PN = &[_]Mode{.picker_normal};
/// A picker, typing or not.
const PA = &[_]Mode{ .picker, .picker_normal };

const binding_table = [_]struct { []const Mode, []const u8, []const u8 }{
    // The leader is a menu (a picker): everything else is a row in it, or
    // in the pickers it opens. No which-key.
    .{ NV, leader, "leader_menu" },
    // Motions: move in normal/visual mode, give an operator its range.
    .{ NVO, "h", "move_left" },
    .{ NVO, "<Left>", "move_left" },
    .{ NV, "<BS>", "move_left" },
    .{ NVO, "l", "move_right" },
    .{ NVO, "<Right>", "move_right" },
    .{ NVO, "j", "move_down" },
    .{ NVO, "<Down>", "move_down" },
    .{ NVO, "k", "move_up" },
    .{ NVO, "<Up>", "move_up" },
    .{ NVO, "w", "word_forward" },
    .{ NVO, "b", "word_backward" },
    .{ NVO, "e", "word_end" },
    .{ NVO, "W", "big_word_forward" },
    .{ NVO, "B", "big_word_backward" },
    .{ NVO, "E", "big_word_end" },
    .{ NVO, "0", "line_start" },
    .{ NVO, "<Home>", "line_start" },
    .{ NVO, "^", "first_non_blank" },
    .{ NVO, "$", "line_end" },
    .{ NVO, "<End>", "line_end" },
    .{ NVO, "gg", "goto_first_line" },
    .{ NVO, "G", "goto_last_line" },
    .{ NVO, "f", "find_char" },
    .{ NVO, "F", "find_char_backward" },
    // `t` is the teleport (snipe) as a motion; after an operator it is still
    // vim's till (`dt)`).
    .{ O, "t", "till_char" },
    .{ NV, "t", "snipe" },
    .{ NVO, "T", "till_char_backward" },
    // `.` after a find repeats it (see `repeat_change`); `;` is free.
    .{ V, ".", "repeat_find" },
    .{ NVO, ",", "repeat_find_reverse" },
    .{ NVO, "%", "match_bracket" },
    .{ NVO, "}", "paragraph_forward" },
    .{ NVO, "{", "paragraph_backward" },
    .{ NVO, "H", "screen_top" },
    .{ NVO, "M", "screen_middle" },
    .{ NVO, "L", "screen_bottom" },
    .{ NVO, "n", "search_next" },
    .{ NVO, "N", "search_previous" },

    // Search
    .{ NVO, "/", "search_forward" },
    .{ NVO, "?", "search_backward" },
    // Our own: `t` snipes (teleports to on-screen text); `s` is not vim's substitute.
    // `s` is Helix's select: prompt, then a cursor on every match inside the
    // selection (the whole file from normal mode).
    .{ NV, "s", "cursors_in_selection" },
    // nvim-surround: `ys{motion}{char}`, `yss{char}`, `ds{char}`, `cs{old}{new}`.
    // `s` after other operators is still the snipe motion.
    .{ O, "s", "surround_or_snipe" },
    .{ V, "S", "surround_visual" },
    // Multicursor under `q` (macros record with `Q`). Visual I/A: a cursor on
    // every selected line, typing at its start/end.
    .{ NV, "qn", "cursor_next_match" },
    .{ NV, "qN", "cursor_previous_match" },
    .{ NV, "qs", "cursor_skip_match" },
    .{ NV, "qa", "cursor_all_matches" },
    .{ N, "qj", "cursor_down" },
    .{ N, "qk", "cursor_up" },
    .{ NV, "qu", "cursor_undo" },
    .{ NV, "qq", "cursor_clear" },
    .{ V, "qI", "cursors_line_starts" },
    .{ V, "qA", "cursors_line_ends" },
    .{ V, "I", "insert_line_starts" },
    .{ V, "A", "append_line_ends" },
    .{ S, "<Tab>", "cursors_from_matches" },
    .{ N, "*", "search_word_forward" },
    .{ N, "#", "search_word_backward" },
    .{ N, "<Esc>", "clear_search_highlight" },
    .{ S, "<CR>", "search_accept" },
    .{ S, "<Esc>", "search_cancel" },
    .{ S, "<C-g>", "search_cancel" },
    // The replace prompt's list (no-ops in a search).
    .{ S, "<Down>", "replace_next" },
    .{ S, "<C-n>", "replace_next" },
    .{ S, "<C-j>", "replace_next" },
    .{ S, "<Up>", "replace_previous" },
    .{ S, "<C-p>", "replace_previous" },
    .{ S, "<C-k>", "replace_previous" },
    .{ S, "<S-Tab>", "replace_skip_file" },

    .{ NV, "<C-d>", "half_page_down" },
    .{ NV, "<C-u>", "half_page_up" },
    .{ NV, "<C-f>", "page_down" },
    .{ NV, "<PageDown>", "page_down" },
    .{ NV, "<C-b>", "page_up" },
    .{ NV, "<PageUp>", "page_up" },
    .{ NV, "<C-j>", "half_page_down" },
    .{ NV, "<C-k>", "half_page_up" },
    .{ NVO, "<C-h>", "first_non_blank" },
    .{ NVO, "<C-l>", "line_end" },
    .{ NV, "<A-j>", "shift_text_down" },
    .{ NV, "<A-k>", "shift_text_up" },
    .{ NV, "<A-h>", "shift_text_left" },
    .{ NV, "<A-l>", "shift_text_right" },
    // The shape of the code: up / down the tree, along it, carrying a node.
    .{ NV, "<A-u>", "grow_selection" },
    .{ NV, "<A-i>", "shrink_selection" },
    .{ NV, "<A-n>", "next_sibling" },
    .{ NV, "<A-p>", "previous_sibling" },
    .{ NV, "<A-N>", "swap_next" },
    .{ NV, "<A-P>", "swap_previous" },
    .{ NV, "<A-f>", "next_function" },
    .{ NV, "<A-F>", "previous_function" },
    .{ NV, "<A-c>", "cycle_case" },
    .{ NV, "<C-e>", "scroll_down" },
    .{ NV, "<C-y>", "scroll_up" },
    .{ N, "zc", "fold_close" },
    .{ N, "zo", "fold_open" },
    .{ N, "zO", "fold_open_recursive" },
    .{ N, "za", "fold_toggle" },
    .{ N, "zR", "fold_open_all" },
    .{ N, "zM", "fold_close_all" },
    .{ N, "zd", "fold_open" },
    .{ NV, "zf", "fold_create" },
    .{ NV, "zz", "view_center" },
    .{ NV, "zt", "view_top" },
    .{ NV, "zb", "view_bottom" },
    .{ NV, "z.", "view_center_first_non_blank" },
    .{ NV, "z<CR>", "view_top_first_non_blank" },
    .{ NV, "z-", "view_bottom_first_non_blank" },

    // Operators (in visual mode they act on the selection).
    .{ NV, "d", "delete" },
    .{ NV, "c", "change" },
    .{ NV, "y", "yank" },
    .{ NV, ">", "indent" },
    .{ NV, "<lt>", "outdent" },
    .{ N, "gu", "lowercase" },
    .{ N, "gU", "uppercase" },
    .{ N, "g~", "toggle_case" },
    .{ V, "u", "lowercase" },
    .{ V, "U", "uppercase" },
    .{ V, "~", "toggle_case" },
    .{ V, "x", "delete" },
    // Doubled operators: dd cc yy >> << guu gUU g~~.
    .{ O, "d", "operate_line" },
    .{ O, "c", "operate_line" },
    .{ O, "y", "operate_line" },
    .{ O, ">", "operate_line" },
    .{ O, "<lt>", "operate_line" },
    .{ O, "u", "operate_line" },
    .{ O, "U", "operate_line" },
    .{ O, "~", "operate_line" },
    .{ O, "<Esc>", "cancel" },

    // Normal-mode editing
    .{ N, "x", "delete_char" },
    .{ N, "<Del>", "delete_char" },
    .{ N, "X", "delete_char_before" },
    .{ N, "D", "delete_to_line_end" },
    .{ N, "C", "change_to_line_end" },
    .{ N, "Y", "yank_to_line_end" },
    .{ N, "S", "substitute_line" },
    .{ NV, "p", "paste_after" },
    .{ N, "P", "paste_before" },
    .{ NV, "gp", "paste_inline_after" },
    .{ N, "gP", "paste_inline_before" },
    // Our own: `r` finds references (vim's replace-char is in the command picker).
    .{ N, "r", "replace_char" },
    .{ NV, "J", "join_lines" },
    .{ N, "~", "toggle_case_char" },
    .{ N, "u", "undo" },
    .{ N, "<C-r>", "redo" },
    .{ N, "U", "redo" },
    .{ N, ".", "repeat_change" },
    .{ N, "Q", "record_macro" },
    .{ N, "@", "play_macro" },
    .{ N, "i", "insert_before" },
    .{ N, "a", "insert_after" },
    .{ N, "I", "insert_line_start" },
    .{ N, "A", "insert_line_end" },
    .{ N, "o", "open_below" },
    .{ N, "O", "open_above" },

    // Visual mode
    .{ NV, "v", "visual_mode" },
    .{ NV, "V", "visual_line_mode" },
    .{ V, "o", "visual_swap_ends" },
    .{ V, "<Esc>", "exit_visual" },

    // Leader menus (Doom Emacs layout). The first binding of a command is the
    // one shown next to it in the command picker.
    .{ N, "<C-o>", "jump_older" },
    .{ N, "<C-i>", "jump_newer" },
    .{ N, "<Tab>", "jump_newer" },
    .{ N, "]q", "quickfix_next" },
    .{ N, "[q", "quickfix_previous" },
    // Resize mode: the menu stays open; h/j/k/l move a border that way.
    .{ N, "gd", "goto_definition" },
    .{ N, "K", "hover" },
    // SPC q closes whatever is in front: the window, else the buffer, else
    // the editor. SPC Q is for quitting with everything else open.

    // Insert mode: unbound keys type.
    // mini.nvim operators: comment, replace with register, exchange, sort,
    // duplicate, align; doubled (or + the operator's last key) for a line.
    .{ NV, "gc", "comment" },
    .{ O, "gc", "comment_object" },
    // The usual editor key; a terminal without the kitty protocol sends it
    // as Ctrl-_.
    .{ &[_]Mode{ .normal, .visual, .insert }, "<C-/>", "toggle_comment" },
    .{ &[_]Mode{ .normal, .visual, .insert }, "<C-_>", "toggle_comment" },
    .{ NV, "gr", "replace_with_register" },
    .{ NV, "gx", "exchange" },
    .{ NV, "gs", "sort" },
    .{ NV, "gm", "multiply" },
    .{ NV, "ga", "align" },
    .{ O, "r", "replace_line" },
    .{ O, "x", "exchange_line" },
    .{ O, "m", "multiply_line" },
    .{ N, "gS", "split_join" },
    .{ N, "gV", "select_last_change" },
    // mini.bracketed: ] forward, [ backward.
    .{ N, "]b", "next_buffer" },
    .{ N, "[b", "previous_buffer" },
    .{ N, "]d", "next_diagnostic" },
    .{ N, "[d", "previous_diagnostic" },
    .{ N, "]h", "git_next_hunk" },
    .{ N, "[h", "git_previous_hunk" },
    .{ N, "]c", "next_comment" },
    .{ N, "[c", "previous_comment" },
    .{ N, "]x", "next_conflict" },
    .{ N, "[x", "previous_conflict" },
    .{ N, "]j", "jump_newer" },
    .{ N, "[j", "jump_older" },
    .{ NVO, "]i", "indent_scope_bottom" },
    .{ NVO, "[i", "indent_scope_top" },
    .{ N, "m", "set_mark" },
    .{ NVO, "'", "goto_mark_line" },
    .{ NVO, "`", "goto_mark" },
    .{ I, "<C-t>", "todo_tag" },

    // ------------------------------------------------------------------
    // Leader menus, by what you are doing. Top level: only what is done
    // constantly, all without shift.
    // Pickers that are menus: everything about buffers, windows, settings,
    // the code, running and git is a row or an action in them.
    // SPC f, find: every picker, one letter each.
    // SPC l, lsp / code: acting on the code under the cursor.
    // What the server lists is here too (as well as under find).
    // SPC b, buffer and file: housekeeping for what is open.
    // SPC g, git.
    // SPC r, run: shell commands and terminals.
    // SPC w, window.
    // SPC p, project.
    // SPC t, toggle (and the theme).
    // SPC a, ai.
    // SPC Q, quit (shifted on purpose).

    .{ I, "<Esc>", "normal_mode" },
    .{ I, "<CR>", "completion_accept_or_newline" },
    .{ I, "<Tab>", "completion_accept_or_tab" },
    .{ I, "<S-Tab>", "snippet_previous" },
    // The gray AI suggestion: all of it, a line, a character.
    .{ I, "<A-;>", "ai_accept" },
    .{ I, "<A-l>", "ai_accept_line" },
    .{ I, "<A-Right>", "ai_accept_char" },
    .{ I, "<C-y>", "completion_accept" },
    .{ I, "<C-n>", "completion_next" },
    .{ I, "<C-p>", "completion_previous" },
    .{ I, "<C-Space>", "completion_next" },
    .{ I, "<Down>", "completion_down" },
    .{ I, "<Up>", "completion_up" },
    .{ I, "<BS>", "delete_backward" },
    .{ I, "<Del>", "delete_forward" },
    .{ I, "<C-w>", "delete_word_backward" },
    .{ I, "<C-;>", "append_semicolon" },
    .{ I, "<Left>", "move_left" },
    .{ I, "<Right>", "move_right" },
    .{ I, "<Home>", "line_start" },
    .{ I, "<End>", "line_end" },

    // Picker: unbound keys type into the query.
    // Pickers have two modes: typing the query (insert), and moving through
    // the results with vim keys (normal, <Esc> from typing).
    .{ P, "<Esc>", "picker_normal_mode" },
    .{ PN, "<Esc>", "picker_close" },
    .{ PN, "q", "picker_close" },
    .{ PA, "<C-g>", "picker_close" },
    .{ PA, "<C-c>", "picker_close" },
    .{ PA, "<CR>", "picker_accept" },
    .{ PA, "<C-CR>", "picker_accept_alt" },
    .{ PA, "<Tab>", "picker_open_menu" },
    .{ PA, "<C-q>", "picker_to_quickfix" },
    .{ PA, "<C-r>", "picker_replace" },
    .{ PA, "<C-t>", "picker_scope" },
    .{ PA, "<C-v>", "picker_open_right" },
    .{ PA, "<C-s>", "picker_open_below" },
    .{ P, "/", "picker_slash" },
    .{ P, "~", "picker_tilde" },
    .{ P, "<Left>", "input_left" },
    .{ P, "<Right>", "input_right" },
    .{ P, "<Home>", "input_home" },
    .{ P, "<End>", "input_end" },
    .{ PA, "<Down>", "picker_next" },
    .{ PA, "<C-n>", "picker_next" },
    .{ PA, "<C-j>", "picker_next" },
    .{ PN, "j", "picker_next" },
    .{ PA, "<Up>", "picker_previous" },
    .{ PA, "<C-p>", "picker_previous" },
    .{ PA, "<C-k>", "picker_previous" },
    .{ PN, "k", "picker_previous" },
    .{ PA, "<PageDown>", "picker_page_down" },
    .{ PA, "<PageUp>", "picker_page_up" },
    .{ PN, "<C-d>", "picker_page_down" },
    .{ PN, "<C-u>", "picker_page_up" },
    .{ PN, "gg", "picker_first" },
    .{ PN, "G", "picker_last" },
    .{ PN, "i", "picker_insert_mode" },
    .{ PN, "a", "picker_insert_mode" },
    .{ PN, "I", "picker_insert_mode" },
    .{ PN, "A", "picker_insert_mode" },
    .{ PN, "/", "picker_insert_mode" },
    // In the explorer: h goes up a folder, l goes in (or opens).
    // On the selected row: the browser's file operations (in the buffer
    // list, x / dd closes a buffer and n / o makes a new one).
    .{ PN, "o", "picker_new_folder" },
    .{ PN, "n", "picker_new_file" },
    .{ PN, "r", "picker_rename" },
    .{ PN, "m", "picker_move" },
    .{ PN, "x", "picker_delete" },
    .{ PN, "dd", "picker_delete" },
    .{ PN, "yy", "picker_copy" },
    .{ PN, "p", "picker_paste" },
    .{ PN, "h", "picker_browse_up" },
    .{ PN, "l", "picker_browse_in" },
    .{ PS, "<BS>", "input_delete_char" },
    .{ PS, "<C-w>", "input_delete_word" },
    .{ PS, "<C-u>", "input_clear" },
};

/// `iw`/`aw`, `i(`/`ib`/`a)`, ... for every text object, in visual and
/// operator-pending mode; `in(` / `an(` the next one and `iN(` / `aN(` the
/// previous one (mini.ai); `g[(` / `g](` move to its edges.
const text_object_table = blk: {
    const specs = commands.text_object_specs;
    var n: usize = 0;
    for (specs) |spec| n += spec.keys.len * (if (spec.seek) 8 else 4);
    var out: [n]struct { []const Mode, []const u8, []const u8 } = undefined;
    var i: usize = 0;
    const VO = &[_]Mode{ .visual, .operator };
    for (specs) |spec| {
        for (spec.keys) |k| {
            const key = if (k == '<') "<lt>" else &[_]u8{k};
            out[i] = .{ VO, "i" ++ key, "inner_" ++ spec.name };
            out[i + 1] = .{ VO, "a" ++ key, "around_" ++ spec.name };
            out[i + 2] = .{ NVO, "g[" ++ key, "goto_start_" ++ spec.name };
            out[i + 3] = .{ NVO, "g]" ++ key, "goto_end_" ++ spec.name };
            i += 4;
            if (!spec.seek) continue;
            out[i] = .{ VO, "in" ++ key, "inner_next_" ++ spec.name };
            out[i + 1] = .{ VO, "an" ++ key, "around_next_" ++ spec.name };
            out[i + 2] = .{ VO, "iN" ++ key, "inner_previous_" ++ spec.name };
            out[i + 3] = .{ VO, "aN" ++ key, "around_previous_" ++ spec.name };
            i += 4;
        }
    }
    const result = out;
    break :blk result;
};

/// Parses key notation at compile time into static memory.
fn comptimeSeq(comptime notation: []const u8) []const KeyEvent {
    comptime {
        @setEvalBranchQuota(10_000);
        var buf: [max_sequence]KeyEvent = undefined;
        const seq = keys.parseSequence(notation, &buf) catch |err|
            @compileError("bad key notation '" ++ notation ++ "': " ++ @errorName(err));
        const owned = buf[0..seq.len].*;
        return &owned;
    }
}

const Default = struct { mode: Mode, binding: Binding };

/// Every (mode, binding) pair, expanded from the tables above at compile time.
const default_bindings = blk: {
    @setEvalBranchQuota(4_000_000);
    const tables = binding_table ++ text_object_table;
    var n: usize = 0;
    for (tables) |d| n += d[0].len;
    var out: [n]Default = undefined;
    var i: usize = 0;
    for (tables) |d| {
        const binding: Binding = .{ .seq = comptimeSeq(d[1]), .command = commands.get(d[2]) };
        for (d[0]) |mode| {
            out[i] = .{ .mode = mode, .binding = binding };
            i += 1;
        }
    }
    const result = out;
    break :blk result;
};

const default_groups = blk: {
    @setEvalBranchQuota(2_000_000);
    var out: [group_table.len]Group = undefined;
    for (group_table, 0..) |g, i| {
        const seq = comptimeSeq(g[0]);
        var used = false;
        for (default_bindings) |d| {
            const b = d.binding;
            if (d.mode == .normal and b.seq.len > seq.len and seqEql(b.seq[0..seq.len], seq)) used = true;
        }
        if (!used) @compileError("group '" ++ g[0] ++ "' has no bindings under it");
        out[i] = .{ .seq = seq, .name = g[1] };
    }
    const result = out;
    break :blk result;
};

const testing = std.testing;

test "which-key continuations" {
    var km: Keymap = .init(testing.allocator);
    defer km.deinit();
    try km.loadDefaults();

    var buf: [max_sequence]KeyEvent = undefined;
    var out: [32]Continuation = undefined;

    // SPC is one command (the leader menu); prefixes like `q` still list
    // what follows them (the keys picker uses that).
    try testing.expectEqual(0, km.continuations(.normal, try keys.parseSequence(leader, &buf), &out).len);
    const cursors = km.continuations(.normal, try keys.parseSequence("q", &buf), &out);
    try testing.expect(cursors.len >= 4);
}
