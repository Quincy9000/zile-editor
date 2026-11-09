//! Per-mode key sequence -> command bindings, plus named groups for the
//! which-key menu.
//!
//! Keybinding philosophy (Doom Emacs style): vim motions and operators stay on
//! single keys, and everything else lives in nested leader menus
//! (`SPC f s` save file, `SPC q q` quit, ...), discoverable through the
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
    picker,
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
    .{ leader ++ "b", "buffer" },
    .{ leader ++ "c", "code" },
    .{ leader ++ "f", "file" },
    .{ leader ++ "g", "git" },
    .{ leader ++ "q", "quit" },
    .{ leader ++ "s", "search" },
    .{ leader ++ "t", "toggle" },
    .{ leader ++ "w", "window" },
    .{ leader ++ "o", "open" },
    .{ leader ++ "r", "run" },
    .{ leader ++ "ws", "split" },
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

const binding_table = [_]struct { []const Mode, []const u8, []const u8 }{
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
    .{ NVO, "t", "till_char" },
    .{ NVO, "T", "till_char_backward" },
    .{ NVO, ";", "repeat_find" },
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
    // Our own: `s` snipes (jump to on-screen text) instead of vim's substitute.
    .{ NV, "s", "snipe" },
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

    .{ NV, "<C-d>", "half_page_down" },
    .{ NV, "<C-u>", "half_page_up" },
    .{ NV, "<C-f>", "page_down" },
    .{ NV, "<PageDown>", "page_down" },
    .{ NV, "<C-b>", "page_up" },
    .{ NV, "<PageUp>", "page_up" },
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
    // Our own: `r` finds references (vim's replace-char is in the command picker).
    .{ N, "r", "find_references" },
    .{ NV, "J", "join_lines" },
    .{ N, "~", "toggle_case_char" },
    .{ N, "u", "undo" },
    .{ N, "<C-r>", "redo" },
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
    .{ N, leader ++ "<Space>", "find_file" },
    .{ N, leader ++ ".", "browse_files" },
    .{ N, leader ++ ",", "switch_buffer" },
    .{ N, leader ++ ":", "command_picker" },
    .{ N, leader ++ "'", "resume_picker" },
    .{ N, leader ++ "ff", "find_file" },
    .{ N, leader ++ "fe", "browse_files" },
    .{ N, leader ++ "fs", "save_file" },
    .{ N, leader ++ "fn", "new_file" },
    .{ N, leader ++ "fS", "save_file_as" },
    .{ N, leader ++ "fR", "rename_file" },
    .{ N, leader ++ "fC", "copy_file" },
    .{ N, leader ++ "fD", "delete_file" },
    .{ N, leader ++ "fy", "yank_file_path" },
    .{ N, leader ++ "fY", "yank_absolute_path" },
    .{ N, leader ++ "bb", "last_buffer" },
    .{ N, leader ++ "bB", "switch_buffer" },
    .{ N, leader ++ "bk", "kill_buffer" },
    .{ N, leader ++ "bn", "next_buffer" },
    .{ N, leader ++ "bp", "previous_buffer" },
    .{ N, leader ++ "bl", "last_buffer" },
    .{ N, "<C-o>", "jump_older" },
    .{ N, "<C-i>", "jump_newer" },
    .{ N, "<Tab>", "jump_newer" },
    .{ N, leader ++ "sj", "jump_list" },
    .{ N, leader ++ "ot", "terminal_toggle" },
    .{ N, leader ++ "rr", "run_runner" },
    .{ N, leader ++ "rR", "run_again" },
    .{ N, leader ++ "rc", "run_command" },
    .{ N, leader ++ "ro", "run_output" },
    .{ N, leader ++ "`", "last_buffer" },
    .{ N, leader ++ "bN", "new_buffer" },
    .{ N, leader ++ "bO", "kill_other_buffers" },
    .{ N, leader ++ "br", "revert_buffer" },
    .{ N, leader ++ "bs", "save_file" },
    .{ N, leader ++ "bS", "save_all" },
    .{ N, leader ++ "wsh", "split_left" },
    .{ N, leader ++ "wsj", "split_down" },
    .{ N, leader ++ "wsk", "split_up" },
    .{ N, leader ++ "wsl", "split_right" },
    .{ N, leader ++ "wh", "window_left" },
    .{ N, leader ++ "wj", "window_down" },
    .{ N, leader ++ "wk", "window_up" },
    .{ N, leader ++ "wl", "window_right" },
    .{ N, leader ++ "ww", "window_next" },
    .{ N, leader ++ "wd", "window_close" },
    .{ N, leader ++ "wc", "window_close" },
    .{ N, leader ++ "wo", "window_only" },
    .{ N, leader ++ "w=", "window_balance" },
    .{ N, leader ++ "w>", "window_wider" },
    .{ N, leader ++ "w<lt>", "window_narrower" },
    .{ N, leader ++ "w+", "window_taller" },
    .{ N, leader ++ "w-", "window_shorter" },
    .{ N, leader ++ "ss", "search_buffer" },
    .{ N, leader ++ "/", "search_project" },
    .{ N, leader ++ "sp", "search_project" },
    .{ N, leader ++ "cd", "goto_definition" },
    .{ N, leader ++ "cD", "find_references" },
    .{ N, leader ++ "ck", "hover" },
    .{ N, leader ++ "cr", "rename_symbol" },
    .{ N, leader ++ "c.", "rename_symbol" },
    .{ N, leader ++ "cl", "goto_symbol" },
    .{ N, leader ++ "cx", "list_diagnostics" },
    .{ N, "gd", "goto_definition" },
    .{ N, "gr", "find_references" },
    .{ N, "K", "hover" },
    .{ N, leader ++ "gg", "git_menu" },
    .{ N, leader ++ "gc", "git_commit" },
    .{ N, leader ++ "gb", "git_branches" },
    .{ N, leader ++ "gs", "git_changed_files" },
    .{ N, leader ++ "gr", "git_restore_hunk" },
    .{ N, leader ++ "gn", "git_next_hunk" },
    .{ N, leader ++ "gp", "git_previous_hunk" },
    .{ N, leader ++ "gR", "git_reload" },
    .{ N, leader ++ "tg", "toggle_ghost_lines" },
    .{ N, leader ++ "tr", "toggle_relative_numbers" },
    .{ N, leader ++ "td", "toggle_diagnostic_text" },
    .{ N, leader ++ "tp", "toggle_auto_pairs" },
    .{ N, leader ++ "qq", "quit" },
    .{ N, leader ++ "qs", "save_and_quit" },
    .{ N, leader ++ "qQ", "quit_without_saving" },

    // Insert mode: unbound keys type.
    .{ I, "<Esc>", "normal_mode" },
    .{ I, "<CR>", "completion_accept_or_newline" },
    .{ I, "<Tab>", "completion_accept_or_tab" },
    .{ I, "<C-y>", "completion_accept" },
    .{ I, "<C-n>", "completion_next" },
    .{ I, "<C-p>", "completion_previous" },
    .{ I, "<C-Space>", "completion_next" },
    .{ I, "<Down>", "completion_down" },
    .{ I, "<Up>", "completion_up" },
    .{ I, "<BS>", "delete_backward" },
    .{ I, "<Del>", "delete_forward" },
    .{ I, "<C-w>", "delete_word_backward" },
    .{ I, "<Left>", "move_left" },
    .{ I, "<Right>", "move_right" },
    .{ I, "<Home>", "line_start" },
    .{ I, "<End>", "line_end" },

    // Picker: unbound keys type into the query.
    .{ P, "<Esc>", "picker_close" },
    .{ P, "<C-g>", "picker_close" },
    .{ P, "<C-c>", "picker_close" },
    .{ P, "<CR>", "picker_accept" },
    .{ P, "/", "picker_slash" },
    .{ P, "~", "picker_tilde" },
    .{ P, "<Down>", "picker_next" },
    .{ P, "<C-n>", "picker_next" },
    .{ P, "<C-j>", "picker_next" },
    .{ P, "<Up>", "picker_previous" },
    .{ P, "<C-p>", "picker_previous" },
    .{ P, "<C-k>", "picker_previous" },
    .{ P, "<PageDown>", "picker_page_down" },
    .{ P, "<PageUp>", "picker_page_up" },
    .{ PS, "<BS>", "input_delete_char" },
    .{ PS, "<C-w>", "input_delete_word" },
    .{ PS, "<C-u>", "input_clear" },
};

/// `iw`/`aw`, `i(`/`ib`/`a)`, ... for every text object, in visual and
/// operator-pending mode.
const text_object_table = blk: {
    const specs = commands.text_object_specs;
    var n: usize = 0;
    for (specs) |spec| n += spec.keys.len * 2;
    var out: [n]struct { []const Mode, []const u8, []const u8 } = undefined;
    var i: usize = 0;
    for (specs) |spec| {
        for (spec.keys) |k| {
            const key = if (k == '<') "<lt>" else &[_]u8{k};
            out[i] = .{ &[_]Mode{ .visual, .operator }, "i" ++ key, "inner_" ++ spec.name };
            out[i + 1] = .{ &[_]Mode{ .visual, .operator }, "a" ++ key, "around_" ++ spec.name };
            i += 2;
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
    @setEvalBranchQuota(1_000_000);
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
    @setEvalBranchQuota(100_000);
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

    const top = km.continuations(.normal, try keys.parseSequence(leader, &buf), &out);
    var found_file = false;
    for (top) |c| {
        if (c.key.eql(KeyEvent.char('f'))) {
            try testing.expectEqualStrings("file", c.label);
            try testing.expectEqual(.group, c.kind);
            found_file = true;
        }
    }
    try testing.expect(found_file);

    const quit = km.continuations(.normal, try keys.parseSequence(leader ++ "q", &buf), &out);
    try testing.expectEqual(3, quit.len);
    try testing.expect(quit[0].key.eql(KeyEvent.char('q'))); // lowercase sorts first
    try testing.expect(quit[1].key.eql(KeyEvent.char('Q')));
    try testing.expect(quit[2].key.eql(KeyEvent.char('s')));
    try testing.expectEqual(.command, quit[1].kind);
}
