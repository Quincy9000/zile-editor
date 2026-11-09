//! The command registry: every user-facing action is a named, documented
//! command. Keymaps bind keys to these, the command picker lists them, and help
//! is generated from their docs.
//!
//! Most commands are generated at comptime from small building blocks:
//!   motion(target, kind, col)     a cursor motion; also an operator's range
//!   operator(op)                  d c y > < gu gU g~
//!   textObject(kind, scope)       iw aw i" a( ip ...  (generated from a table)
//!   opMotion(op, target, kind)    shortcuts like x = dl, D = d$
//! so each family is written once and every motion works with every operator.

const std = @import("std");
const Editor = @import("Editor.zig");
const Text = @import("core/Text.zig");
const motions = @import("core/motions.zig");
const textobjects = @import("core/textobjects.zig");
const syntax_objects = @import("syntax/objects.zig");
const operators = @import("operators.zig");
const Picker = @import("picker/Picker.zig");

const Operator = operators.Operator;
const MotionKind = operators.MotionKind;

pub const Context = struct {
    ed: *Editor,
    /// The typed count, or 1.
    count: usize,
    has_count: bool,
    /// Register from a `"x` prefix.
    register: ?u8 = null,
    /// The character argument of `takes_char` commands.
    char: u21 = 0,
};

pub const Handler = *const fn (Context) anyerror!void;

pub const Command = struct {
    name: []const u8,
    /// One line; doubles as the which-key label.
    doc: []const u8,
    run: Handler,
    /// Not listed in the command picker (internal keys like picker navigation).
    hidden: bool = false,
    /// A change that `.` repeats.
    repeat: bool = false,
    /// Reads one more key into `Context.char` (f, t, r, q, @).
    takes_char: bool = false,
};

pub const all = base ++ text_object_commands;

const base = [_]Command{
    // Motions: normal and visual mode, and as an operator's range.
    .{ .name = "move_left", .doc = "Left", .run = motion(left, .exclusive, .reset) },
    .{ .name = "move_right", .doc = "Right", .run = motion(right, .exclusive, .reset) },
    .{ .name = "move_down", .doc = "Down", .run = motion(down, .linewise, .keep) },
    .{ .name = "move_up", .doc = "Up", .run = motion(up, .linewise, .keep) },
    .{ .name = "word_forward", .doc = "Next word", .run = wordMotion(.forward, false) },
    .{ .name = "word_backward", .doc = "Previous word", .run = wordMotion(.backward, false) },
    .{ .name = "word_end", .doc = "End of word", .run = wordMotion(.end, false) },
    .{ .name = "big_word_forward", .doc = "Next WORD", .run = wordMotion(.forward, true) },
    .{ .name = "big_word_backward", .doc = "Previous WORD", .run = wordMotion(.backward, true) },
    .{ .name = "big_word_end", .doc = "End of WORD", .run = wordMotion(.end, true) },
    .{ .name = "line_start", .doc = "Start of line", .run = motion(lineStart, .exclusive, .reset) },
    .{ .name = "first_non_blank", .doc = "First non-blank", .run = motion(firstNonBlank, .exclusive, .reset) },
    .{ .name = "line_end", .doc = "End of line", .run = motion(lineEnd, .inclusive, .eol) },
    .{ .name = "goto_first_line", .doc = "First line (or line [count])", .run = motion(firstLine, .linewise, .reset) },
    .{ .name = "goto_last_line", .doc = "Last line (or line [count])", .run = motion(lastLine, .linewise, .reset) },
    .{ .name = "find_char", .doc = "Find character", .run = motion(findChar(true, false), .inclusive, .reset), .takes_char = true },
    .{ .name = "find_char_backward", .doc = "Find character backward", .run = motion(findChar(false, false), .exclusive, .reset), .takes_char = true },
    .{ .name = "till_char", .doc = "Till character", .run = motion(findChar(true, true), .inclusive, .reset), .takes_char = true },
    .{ .name = "till_char_backward", .doc = "Till character backward", .run = motion(findChar(false, true), .exclusive, .reset), .takes_char = true },
    .{ .name = "repeat_find", .doc = "Repeat f/t", .run = repeatFind(false) },
    .{ .name = "repeat_find_reverse", .doc = "Repeat f/t backward", .run = repeatFind(true) },
    .{ .name = "match_bracket", .doc = "Matching bracket", .run = motion(matchBracket, .inclusive, .reset) },
    .{ .name = "paragraph_forward", .doc = "Next paragraph", .run = motion(paragraphForward, .exclusive, .reset) },
    .{ .name = "paragraph_backward", .doc = "Previous paragraph", .run = motion(paragraphBackward, .exclusive, .reset) },
    .{ .name = "screen_top", .doc = "Top of screen", .run = motion(screenLine(.top), .linewise, .reset) },
    .{ .name = "screen_middle", .doc = "Middle of screen", .run = motion(screenLine(.middle), .linewise, .reset) },
    .{ .name = "screen_bottom", .doc = "Bottom of screen", .run = motion(screenLine(.bottom), .linewise, .reset) },
    .{ .name = "search_next", .doc = "Next match", .run = motion(searchNext(false), .exclusive, .reset) },
    .{ .name = "search_previous", .doc = "Previous match", .run = motion(searchNext(true), .exclusive, .reset) },

    // Search
    .{ .name = "search_forward", .doc = "Search forward", .run = startSearch(true, .search) },
    .{ .name = "search_backward", .doc = "Search backward", .run = startSearch(false, .search) },
    .{ .name = "snipe", .doc = "Jump to text on screen", .run = startSearch(true, .snipe) },
    .{ .name = "search_word_forward", .doc = "Search word under cursor", .run = searchWord(true) },
    .{ .name = "search_word_backward", .doc = "Search word under cursor backward", .run = searchWord(false) },
    .{ .name = "clear_search_highlight", .doc = "Clear search highlight", .run = clearSearchHighlight },
    .{ .name = "search_accept", .doc = "Go to the match", .run = searchAccept, .hidden = true },
    .{ .name = "search_cancel", .doc = "Cancel the search", .run = searchCancel, .hidden = true },
    .{ .name = "search_buffer", .doc = "Search buffer lines", .run = openPicker(.lines) },
    .{ .name = "search_project", .doc = "Search project", .run = openPicker(.grep) },

    // Language server (zls)
    .{ .name = "goto_definition", .doc = "Go to definition", .run = lspRequest(.definition) },
    .{ .name = "find_references", .doc = "Find references", .run = lspRequest(.references) },
    .{ .name = "hover", .doc = "Show documentation", .run = lspRequest(.hover) },
    .{ .name = "rename_symbol", .doc = "Rename symbol", .run = renameSymbol },
    .{ .name = "goto_symbol", .doc = "Go to symbol", .run = gotoSymbol },
    .{ .name = "list_diagnostics", .doc = "List errors", .run = openPicker(.diagnostics) },
    .{ .name = "completion_next", .doc = "Next completion", .run = completionKey(.next, null), .hidden = true },
    .{ .name = "completion_previous", .doc = "Previous completion", .run = completionKey(.previous, null), .hidden = true },
    .{ .name = "completion_down", .doc = "Next completion or down", .run = completionKey(.next, motion(down, .linewise, .keep)), .hidden = true },
    .{ .name = "completion_up", .doc = "Previous completion or up", .run = completionKey(.previous, motion(up, .linewise, .keep)), .hidden = true },
    .{ .name = "completion_accept_or_tab", .doc = "Accept completion or tab", .run = completionKey(.accept, insertTab), .hidden = true },
    .{ .name = "completion_accept_or_newline", .doc = "Accept completion or newline", .run = completionKey(.accept, insertNewline), .hidden = true },
    .{ .name = "completion_accept", .doc = "Accept completion", .run = completionKey(.accept, null), .hidden = true },

    // Scrolling
    .{ .name = "half_page_down", .doc = "Half page down", .run = scroll(.half_page, 1) },
    .{ .name = "half_page_up", .doc = "Half page up", .run = scroll(.half_page, -1) },
    .{ .name = "page_down", .doc = "Page down", .run = scroll(.page, 1) },
    .{ .name = "page_up", .doc = "Page up", .run = scroll(.page, -1) },
    .{ .name = "scroll_down", .doc = "Scroll down", .run = scroll(.line, 1) },
    .{ .name = "scroll_up", .doc = "Scroll up", .run = scroll(.line, -1) },
    .{ .name = "fold_close", .doc = "Close fold", .run = foldCmd(.close) },
    .{ .name = "fold_open", .doc = "Open fold", .run = foldCmd(.open) },
    .{ .name = "fold_open_recursive", .doc = "Open all folds here", .run = foldCmd(.open_all_here) },
    .{ .name = "fold_toggle", .doc = "Toggle fold", .run = foldCmd(.toggle) },
    .{ .name = "fold_open_all", .doc = "Open all folds", .run = foldCmd(.open_everything) },
    .{ .name = "fold_close_all", .doc = "Close all folds", .run = foldCmd(.close_everything) },
    .{ .name = "fold_create", .doc = "Create fold", .run = operator(.fold) },
    .{ .name = "view_center", .doc = "Center line", .run = placeLine(.center, false) },
    .{ .name = "view_top", .doc = "Line to top", .run = placeLine(.top, false) },
    .{ .name = "view_bottom", .doc = "Line to bottom", .run = placeLine(.bottom, false) },
    .{ .name = "view_center_first_non_blank", .doc = "Center line, to first non-blank", .run = placeLine(.center, true) },
    .{ .name = "view_top_first_non_blank", .doc = "Line to top, to first non-blank", .run = placeLine(.top, true) },
    .{ .name = "view_bottom_first_non_blank", .doc = "Line to bottom, to first non-blank", .run = placeLine(.bottom, true) },

    // Operators: wait for a motion or text object (or act on the selection).
    .{ .name = "delete", .doc = "Delete", .run = operator(.delete), .repeat = true },
    .{ .name = "change", .doc = "Change", .run = operator(.change), .repeat = true },
    .{ .name = "yank", .doc = "Yank", .run = operator(.yank) },
    .{ .name = "indent", .doc = "Indent", .run = operator(.indent), .repeat = true },
    .{ .name = "outdent", .doc = "Outdent", .run = operator(.outdent), .repeat = true },
    .{ .name = "lowercase", .doc = "Lowercase", .run = operator(.lowercase), .repeat = true },
    .{ .name = "uppercase", .doc = "Uppercase", .run = operator(.uppercase), .repeat = true },
    .{ .name = "toggle_case", .doc = "Toggle case", .run = operator(.toggle_case), .repeat = true },
    .{ .name = "operate_line", .doc = "Whole line", .run = operateLine, .hidden = true },
    .{ .name = "cancel", .doc = "Cancel", .run = cancel, .hidden = true },

    // Operator + motion shortcuts
    .{ .name = "delete_char", .doc = "Delete character", .run = opMotion(.delete, right, .exclusive), .repeat = true },
    .{ .name = "delete_char_before", .doc = "Delete character before", .run = opMotion(.delete, left, .exclusive), .repeat = true },
    .{ .name = "delete_to_line_end", .doc = "Delete to end of line", .run = opMotion(.delete, lineEnd, .inclusive), .repeat = true },
    .{ .name = "change_to_line_end", .doc = "Change to end of line", .run = opMotion(.change, lineEnd, .inclusive), .repeat = true },
    .{ .name = "yank_to_line_end", .doc = "Yank to end of line", .run = opMotion(.yank, lineEnd, .inclusive) },
    .{ .name = "substitute_line", .doc = "Substitute line", .run = opLines(.change), .repeat = true },

    // Editing
    .{ .name = "paste_after", .doc = "Paste after", .run = paste(false), .repeat = true },
    .{ .name = "paste_before", .doc = "Paste before", .run = paste(true), .repeat = true },
    .{ .name = "replace_char", .doc = "Replace character", .run = replaceChar, .repeat = true, .takes_char = true },
    .{ .name = "join_lines", .doc = "Join lines", .run = joinLines, .repeat = true },
    .{ .name = "toggle_case_char", .doc = "Toggle case of character", .run = toggleCaseChar, .repeat = true },
    .{ .name = "undo", .doc = "Undo", .run = undo },
    .{ .name = "redo", .doc = "Redo", .run = redo },
    .{ .name = "repeat_change", .doc = "Repeat last change", .run = repeatChange },
    .{ .name = "record_macro", .doc = "Record macro (q again to stop)", .run = recordMacro, .takes_char = true },
    .{ .name = "play_macro", .doc = "Play macro (@@ for the last one)", .run = playMacro, .takes_char = true },

    // Visual mode
    .{ .name = "visual_mode", .doc = "Visual mode", .run = visualMode(false) },
    .{ .name = "visual_line_mode", .doc = "Visual line mode", .run = visualMode(true) },
    .{ .name = "visual_swap_ends", .doc = "Other end of selection", .run = visualSwap },
    .{ .name = "exit_visual", .doc = "Leave visual mode", .run = exitVisual, .hidden = true },

    // Entering insert mode
    .{ .name = "insert_before", .doc = "Insert before cursor", .run = insertAt(cursorPos), .repeat = true },
    .{ .name = "insert_after", .doc = "Insert after cursor", .run = insertAt(afterCursorPos), .repeat = true },
    .{ .name = "insert_line_start", .doc = "Insert at line start", .run = insertAt(firstNonBlankPos), .repeat = true },
    .{ .name = "insert_line_end", .doc = "Insert at line end", .run = insertAt(lineEndPos), .repeat = true },
    .{ .name = "open_below", .doc = "Open line below", .run = openLine(.below), .repeat = true },
    .{ .name = "open_above", .doc = "Open line above", .run = openLine(.above), .repeat = true },
    .{ .name = "normal_mode", .doc = "Normal mode", .run = normalMode },

    // Insert-mode editing
    .{ .name = "insert_newline", .doc = "New line, keeping indentation", .run = insertNewline },
    .{ .name = "delete_backward", .doc = "Delete previous character", .run = deleteBy(motions.prevChar) },
    .{ .name = "delete_forward", .doc = "Delete next character", .run = deleteBy(motions.nextChar) },
    .{ .name = "delete_word_backward", .doc = "Delete previous word", .run = deleteBy(wordBackwardInLine) },
    .{ .name = "insert_tab", .doc = "Insert tab", .run = insertTab },

    // Files, buffers and session
    .{ .name = "save_file", .doc = "Save file", .run = saveFile },
    .{ .name = "find_file", .doc = "Find file", .run = openPicker(.files) },
    .{ .name = "switch_buffer", .doc = "Switch buffer", .run = openPicker(.buffers) },
    .{ .name = "kill_buffer", .doc = "Kill buffer", .run = killBuffer },
    .{ .name = "next_buffer", .doc = "Next buffer", .run = cycleBuffer(1) },
    .{ .name = "previous_buffer", .doc = "Previous buffer", .run = cycleBuffer(-1) },
    .{ .name = "command_picker", .doc = "Run a command", .run = openPicker(.commands) },
    .{ .name = "resume_picker", .doc = "Resume last picker", .run = resumePicker },
    .{ .name = "quit", .doc = "Quit", .run = quit },
    .{ .name = "save_and_quit", .doc = "Save all and quit", .run = saveAndQuit },
    .{ .name = "quit_without_saving", .doc = "Quit without saving", .run = quitWithoutSaving },

    // Inside the picker
    .{ .name = "picker_next", .doc = "Next result", .run = pickerMove(1, .wrap), .hidden = true },
    .{ .name = "picker_previous", .doc = "Previous result", .run = pickerMove(-1, .wrap), .hidden = true },
    .{ .name = "picker_page_down", .doc = "Page down", .run = pickerMove(10, .clamp), .hidden = true },
    .{ .name = "picker_page_up", .doc = "Page up", .run = pickerMove(-10, .clamp), .hidden = true },
    .{ .name = "picker_accept", .doc = "Open the selection", .run = pickerAccept, .hidden = true },
    .{ .name = "picker_close", .doc = "Close the picker", .run = pickerClose, .hidden = true },

    // Text inputs (picker query, search prompt)
    .{ .name = "input_delete_char", .doc = "Delete a character", .run = inputEdit(.char), .hidden = true },
    .{ .name = "input_delete_word", .doc = "Delete a word", .run = inputEdit(.word), .hidden = true },
    .{ .name = "input_clear", .doc = "Clear the input", .run = inputEdit(.all), .hidden = true },
};

// ---------------------------------------------------------------------------
// Text objects: one table, expanded into `inner_*` and `around_*` commands
// here and into `i?`/`a?` bindings by the keymap.

pub const ObjectKind = union(enum) {
    word: bool, // big
    quote: u8,
    bracket: [2]u8,
    paragraph,
    line,
    tag,
    /// From the syntax tree (function, class, argument).
    syntax: syntax_objects.Object,
};

pub const ObjectSpec = struct {
    name: []const u8,
    doc: []const u8,
    /// Keys after `i`/`a` that select it (`ib`, `i(` and `i)` are all parens).
    keys: []const u8,
    kind: ObjectKind,
    /// Which-key labels when "inner X" / "around X" don't describe it.
    labels: ?[2][]const u8 = null,
};

pub const text_object_specs = [_]ObjectSpec{
    .{ .name = "word", .doc = "word", .keys = "w", .kind = .{ .word = false } },
    .{ .name = "big_word", .doc = "WORD", .keys = "W", .kind = .{ .word = true } },
    .{ .name = "double_quotes", .doc = "\"quotes\"", .keys = "\"", .kind = .{ .quote = '"' } },
    .{ .name = "single_quotes", .doc = "'quotes'", .keys = "'", .kind = .{ .quote = '\'' } },
    .{ .name = "backticks", .doc = "`backticks`", .keys = "`", .kind = .{ .quote = '`' } },
    .{ .name = "parens", .doc = "(parens)", .keys = "()b", .kind = .{ .bracket = .{ '(', ')' } } },
    .{ .name = "brackets", .doc = "[brackets]", .keys = "[]", .kind = .{ .bracket = .{ '[', ']' } } },
    .{ .name = "braces", .doc = "{braces}", .keys = "{}B", .kind = .{ .bracket = .{ '{', '}' } } },
    .{ .name = "angles", .doc = "<angles>", .keys = "<>", .kind = .{ .bracket = .{ '<', '>' } } },
    .{ .name = "paragraph", .doc = "paragraph", .keys = "p", .kind = .paragraph },
    .{ .name = "line", .doc = "line", .keys = "l", .kind = .line, .labels = .{ "in line", "all lines" } },
    .{ .name = "tag", .doc = "<tag> block", .keys = "t", .kind = .tag },
    .{ .name = "function", .doc = "function", .keys = "f", .kind = .{ .syntax = .function } },
    .{ .name = "class", .doc = "class/struct", .keys = "c", .kind = .{ .syntax = .class } },
    .{ .name = "argument", .doc = "argument", .keys = "a", .kind = .{ .syntax = .argument } },
};

const text_object_commands = blk: {
    var out: [text_object_specs.len * 2]Command = undefined;
    for (text_object_specs, 0..) |spec, i| {
        for ([_]textobjects.Scope{ .inner, .around }, 0..) |scope, j| {
            out[i * 2 + j] = .{
                .name = @tagName(scope) ++ "_" ++ spec.name,
                .doc = if (spec.labels) |l| l[j] else (if (scope == .inner) "inner " else "around ") ++ spec.doc,
                .run = textObject(spec.kind, scope),
            };
        }
    }
    const result = out;
    break :blk result;
};

fn textObject(comptime kind: ObjectKind, comptime scope: textobjects.Scope) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            const pos = ed.view.cursor;
            const r = switch (kind) {
                .word => |big| textobjects.word(t, pos, scope, big, c.count),
                .quote => |q| textobjects.quote(t, pos, q, scope),
                .bracket => |b| textobjects.bracket(t, pos, b[0], b[1], scope, c.count),
                .paragraph => textobjects.paragraph(t, pos, scope),
                .line => textobjects.lineObject(t, pos, scope),
                .tag => textobjects.tag(t, pos, scope, c.count),
                .syntax => |obj| if (ed.buffer.syntax) |*s| syntax_objects.find(s, t, pos, obj, scope, c.count) else null,
            } orelse return fail(ed);
            switch (ed.mode) {
                .operator => try ed.applyPending(r),
                .visual => ed.selectRange(r),
                else => {},
            }
        }
    }.run;
}

// ---------------------------------------------------------------------------
// Lookup

const by_name: std.StaticStringMap(*const Command) = .initComptime(blk: {
    @setEvalBranchQuota(all.len * all.len * 100);
    var kvs: [all.len]struct { []const u8, *const Command } = undefined;
    for (&all, 0..) |*c, i| {
        for (all[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, c.name)) @compileError("duplicate command name: " ++ c.name);
        }
        kvs[i] = .{ c.name, c };
    }
    const result = kvs;
    break :blk result;
});

/// Runtime lookup, e.g. for user keymaps and the command picker.
pub fn find(name: []const u8) ?*const Command {
    return by_name.get(name);
}

/// Comptime lookup: an unknown name is a compile error.
pub fn get(comptime name: []const u8) *const Command {
    return comptime by_name.get(name) orelse @compileError("unknown command: " ++ name);
}

// ---------------------------------------------------------------------------
// Motions

/// Where a motion goes from `from`, or null if it fails (e.g. `fx` with no x).
const Target = fn (ed: *Editor, from: usize, c: Context) ?usize;

/// What happens to the sticky column: reset it, keep it (j/k), or stick to
/// line ends ($).
const Col = enum { reset, keep, eol };

fn motion(comptime target: Target, comptime kind: MotionKind, comptime col: Col) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const from = c.ed.view.cursor;
            const to = target(c.ed, from, c) orelse return fail(c.ed);
            try finishMotion(c.ed, from, to, kind, col);
        }
    }.run;
}

/// Moves the cursor, or, with an operator pending, applies it to the span.
fn finishMotion(ed: *Editor, from: usize, to: usize, kind: MotionKind, col: Col) !void {
    if (ed.mode == .operator) return ed.applyPending(operators.motionRange(ed.text(), from, to, kind));
    switch (col) {
        .reset => ed.setCursor(to),
        .keep => ed.gotoLine(ed.text().lineOf(to)),
        .eol => {
            const t = ed.text();
            // In insert mode <End> goes past the last character.
            ed.setCursor(if (ed.mode == .insert) t.lineEnd(t.lineOf(to)) else to);
            ed.view.want_col = std.math.maxInt(usize);
        },
    }
}

/// A failed motion cancels a pending operator.
fn fail(ed: *Editor) void {
    if (ed.mode == .operator) ed.resetCommand();
}

fn stepN(t: *const Text, from: usize, n: usize, comptime step: fn (*const Text, usize) usize) usize {
    var p = from;
    for (0..n) |_| p = step(t, p);
    return p;
}

fn leftInLine(t: *const Text, p: usize) usize {
    return if (p > t.lineStart(t.lineOf(p))) motions.prevChar(t, p) else p;
}

fn rightInLine(t: *const Text, p: usize) usize {
    return if (p < t.lineEnd(t.lineOf(p))) motions.nextChar(t, p) else p;
}

fn left(ed: *Editor, from: usize, c: Context) ?usize {
    return stepN(ed.text(), from, c.count, leftInLine);
}

fn right(ed: *Editor, from: usize, c: Context) ?usize {
    return stepN(ed.text(), from, c.count, rightInLine);
}

// j/k count a closed fold as one line.
fn down(ed: *Editor, from: usize, c: Context) ?usize {
    const t = ed.text();
    const line = t.lineOf(from);
    const target = ed.stepVisible(line, @intCast(c.count));
    if (target == ed.visibleLine(line)) return null;
    return t.lineStart(target);
}

fn up(ed: *Editor, from: usize, c: Context) ?usize {
    const t = ed.text();
    const line = t.lineOf(from);
    const target = ed.stepVisible(line, -@as(isize, @intCast(c.count)));
    if (target == ed.visibleLine(line)) return null;
    return t.lineStart(target);
}

fn wordMotion(comptime which: enum { forward, backward, end }, comptime big: bool) Handler {
    const step = switch (which) {
        .forward => motions.wordForward,
        .backward => motions.wordBackward,
        .end => motions.wordEnd,
    };
    const kind: MotionKind = if (which == .end) .inclusive else .exclusive;
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            const from = ed.view.cursor;
            // vim's special case: `cw` on a word changes to its end, not up to
            // the next word.
            if (which == .forward and ed.pendingOperator() == .change and !motions.isSpaceAt(t, from)) {
                var to = motions.wordEndCurrent(t, from, big);
                for (1..c.count) |_| to = motions.wordEnd(t, to, big);
                return finishMotion(ed, from, to, .inclusive, .reset);
            }
            var to = from;
            for (0..c.count) |_| to = step(t, to, big);
            try finishMotion(ed, from, to, kind, .reset);
        }
    }.run;
}

fn lineStart(ed: *Editor, from: usize, _: Context) ?usize {
    const t = ed.text();
    return t.lineStart(t.lineOf(from));
}

fn firstNonBlank(ed: *Editor, from: usize, _: Context) ?usize {
    const t = ed.text();
    return motions.firstNonBlank(t, t.lineOf(from));
}

/// `$`: the last character of the line ([count - 1] lines down).
fn lineEnd(ed: *Editor, from: usize, c: Context) ?usize {
    const t = ed.text();
    const line = @min(t.lineOf(from) + c.count - 1, t.lineCount() - 1);
    if (t.lineLen(line) == 0) return t.lineStart(line);
    return motions.prevChar(t, t.lineEnd(line));
}

fn firstLine(ed: *Editor, _: usize, c: Context) ?usize {
    const t = ed.text();
    return motions.firstNonBlank(t, if (c.has_count) @min(c.count - 1, t.lineCount() - 1) else 0);
}

fn lastLine(ed: *Editor, _: usize, c: Context) ?usize {
    const t = ed.text();
    const last = t.lineCount() - 1;
    return motions.firstNonBlank(t, if (c.has_count) @min(c.count - 1, last) else last);
}

fn findChar(comptime forward: bool, comptime till: bool) Target {
    return struct {
        fn target(ed: *Editor, from: usize, c: Context) ?usize {
            const f = motions.Find.init(c.char, forward, till) orelse return null;
            ed.last_find = f;
            return motions.findInLine(ed.text(), from, f, c.count, false);
        }
    }.target;
}

fn repeatFind(comptime reverse: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            var f = ed.last_find orelse return fail(ed);
            if (reverse) f.forward = !f.forward;
            const from = ed.view.cursor;
            const to = motions.findInLine(ed.text(), from, f, c.count, true) orelse return fail(ed);
            try finishMotion(ed, from, to, if (f.forward) .inclusive else .exclusive, .reset);
        }
    }.run;
}

fn matchBracket(ed: *Editor, from: usize, _: Context) ?usize {
    return motions.matchBracket(ed.text(), from);
}

fn paragraphForward(ed: *Editor, from: usize, c: Context) ?usize {
    return motions.paragraphForward(ed.text(), from, c.count);
}

fn paragraphBackward(ed: *Editor, from: usize, c: Context) ?usize {
    return motions.paragraphBackward(ed.text(), from, c.count);
}

fn screenLine(comptime where: enum { top, middle, bottom }) Target {
    return struct {
        fn target(ed: *Editor, _: usize, c: Context) ?usize {
            const t = ed.text();
            const first = ed.view.top;
            const last = @min(first + ed.view.rows - 1, t.lineCount() - 1);
            // Like vim, H and L stay `scrolloff` lines from the edge (unless at
            // the start/end of the text).
            const so = ed.effectiveScrolloff();
            const line = switch (where) {
                .top => @min(@max(first + c.count - 1, if (first == 0) 0 else first + so), last),
                .middle => first + (last - first) / 2,
                .bottom => @max((last + 1) -| c.count, if (last == t.lineCount() - 1) last else last -| so, first),
            };
            return motions.firstNonBlank(t, @min(line, last));
        }
    }.target;
}

// ---------------------------------------------------------------------------
// Scrolling

const ScrollAmount = enum { line, half_page, page };

fn scroll(comptime amount: ScrollAmount, comptime dir: isize) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const count: isize = @intCast(c.count);
            const rows: isize = @intCast(ed.view.rows);
            switch (amount) {
                .line => ed.scrollLines(dir * count),
                // vim: <C-d>/<C-u> move the view and the cursor by the same amount.
                .half_page => {
                    const n = dir * @max(@divTrunc(rows, 2), 1);
                    ed.scrollLines(n);
                    ed.moveLines(n);
                },
                .page => {
                    const n = dir * count * @max(rows - 2, 1);
                    ed.scrollLines(n);
                    ed.moveLines(n);
                },
            }
        }
    }.run;
}

const FoldAction = enum { close, open, open_all_here, toggle, open_everything, close_everything };

/// zc / zo / zO / za / zR / zM (zd deletes a fold = zo). Syntax folds come
/// from the tree; manual ones from `zf`.
fn foldCmd(comptime action: FoldAction) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            const folds = &ed.buffer.folds;
            const line = ed.cursorLine();
            switch (action) {
                .open => if (!folds.open(t, line, false)) ed.setMessage(.info, "no closed fold here", .{}),
                .open_all_here => _ = folds.open(t, line, true),
                .open_everything => folds.clear(),
                .close => try closeFold(ed, line),
                .toggle => if (ed.foldAt(line) != null) {
                    _ = folds.open(t, line, false);
                } else try closeFold(ed, line),
                .close_everything => {
                    const s = &(ed.buffer.syntax orelse return);
                    var ranges: std.ArrayList(syntax_objects.FoldLines) = .empty;
                    defer ranges.deinit(ed.gpa);
                    try syntax_objects.allFolds(ed.gpa, s, t, &ranges);
                    for (ranges.items) |f| try folds.add(ed.gpa, t, f.first, f.last);
                },
            }
            if (ed.foldAt(ed.cursorLine())) |f| ed.setCursor(motions.firstNonBlank(t, f.first));
        }
    }.run;
}

/// Closes the innermost syntax fold around `line` that isn't closed yet, so
/// repeating `zc` closes the next level out.
fn closeFold(ed: *Editor, line: usize) !void {
    const t = ed.text();
    const s = &(ed.buffer.syntax orelse return ed.setMessage(.info, "no fold here (zf{{motion}} makes one)", .{}));
    var buf: [32]syntax_objects.FoldLines = undefined;
    for (syntax_objects.foldsAround(s, t, line, &buf)) |f| {
        if (ed.buffer.folds.isClosed(t, f.first, f.last)) continue;
        return ed.buffer.folds.add(ed.gpa, t, f.first, f.last);
    }
    ed.setMessage(.info, "no fold here (zf{{motion}} makes one)", .{});
}

/// zz / zt / zb (and z. / z<CR> / z-, which also go to the first non-blank):
/// scrolls so the cursor line (or line [count]) sits at the center, top or
/// bottom of the view, keeping `scrolloff`.
fn placeLine(comptime where: enum { center, top, bottom }, comptime first_non_blank: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            if (c.has_count) ed.gotoLine(@min(c.count - 1, t.lineCount() - 1));
            if (first_non_blank) ed.setCursor(motions.firstNonBlank(t, ed.cursorLine()));
            const line = ed.cursorLine();
            const rows = ed.view.rows;
            const so = ed.effectiveScrolloff();
            const up_rows: usize = switch (where) {
                .center => rows / 2,
                .top => so,
                .bottom => rows -| (so + 1),
            };
            ed.view.top = ed.stepVisible(line, -@as(isize, @intCast(up_rows)));
        }
    }.run;
}

// ---------------------------------------------------------------------------
// Operators

fn operator(comptime op: Operator) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (ed.mode) {
                .visual => {
                    const r = ed.visualRange();
                    ed.exitVisual();
                    try operators.apply(ed, op, r, c.register);
                },
                .normal => ed.beginOperator(op, c),
                else => {},
            }
        }
    }.run;
}

/// A doubled operator (`dd`, `cc`, `yy`, `>>`, `guu`): [count] whole lines.
fn operateLine(c: Context) !void {
    const ed = c.ed;
    if (ed.mode != .operator) return;
    const t = ed.text();
    const first = ed.cursorLine();
    try ed.applyPending(operators.linesRange(t, first, @min(first + c.count - 1, t.lineCount() - 1)));
}

fn cancel(c: Context) !void {
    c.ed.resetCommand();
}

/// An operator applied to a fixed motion (`x` = `dl`, `D` = `d$`).
fn opMotion(comptime op: Operator, comptime target: Target, comptime kind: MotionKind) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const from = ed.view.cursor;
            const to = target(ed, from, c) orelse return;
            try operators.apply(ed, op, operators.motionRange(ed.text(), from, to, kind), c.register);
        }
    }.run;
}

/// An operator applied to [count] whole lines (`S` = `cc`).
fn opLines(comptime op: Operator) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            const first = ed.cursorLine();
            const r = operators.linesRange(t, first, @min(first + c.count - 1, t.lineCount() - 1));
            try operators.apply(ed, op, r, c.register);
        }
    }.run;
}

// ---------------------------------------------------------------------------
// Editing

fn paste(comptime before: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const v = ed.registers.get(c.register) orelse return ed.setMessage(.err, "nothing to paste", .{});
            // Copy it: replacing a selection below may overwrite registers.
            const text = try ed.gpa.dupe(u8, v.text);
            defer ed.gpa.free(text);
            const value: @TypeOf(v) = .{ .text = text, .linewise = v.linewise };
            if (ed.mode == .visual) {
                // Replace the selection, keeping the pasted text in the register.
                const r = ed.visualRange();
                ed.exitVisual();
                try operators.apply(ed, .delete, r, '_');
                return operators.paste(ed, value, c.count, true);
            }
            try operators.paste(ed, value, c.count, before);
        }
    }.run;
}

fn replaceChar(c: Context) !void {
    _ = try operators.replaceChars(c.ed, c.char, c.count);
}

fn joinLines(c: Context) !void {
    const ed = c.ed;
    if (ed.mode == .visual) {
        const t = ed.text();
        const a = t.lineOf(ed.view.anchor);
        const b = t.lineOf(ed.view.cursor);
        ed.exitVisual();
        ed.gotoLine(@min(a, b));
        return operators.join(ed, @max(a, b) - @min(a, b) + 1);
    }
    try operators.join(ed, c.count);
}

/// `~` in normal mode: toggles case and moves past the characters.
fn toggleCaseChar(c: Context) !void {
    const ed = c.ed;
    const t = ed.text();
    const from = ed.view.cursor;
    const to = stepN(t, from, c.count, rightInLine);
    if (to == from) return;
    try operators.apply(ed, .toggle_case, .{ .start = from, .end = to }, null);
    ed.setCursor(to);
}

fn undo(c: Context) !void {
    try c.ed.undo(c.count);
}

fn redo(c: Context) !void {
    try c.ed.redo(c.count);
}

fn repeatChange(c: Context) !void {
    try c.ed.repeatLastChange(c.count, c.has_count);
}

fn recordMacro(c: Context) !void {
    c.ed.startMacro(c.char);
}

fn playMacro(c: Context) !void {
    try c.ed.playMacro(c.char, c.count);
}

// ---------------------------------------------------------------------------
// Visual mode

fn visualMode(comptime line: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            if (ed.mode != .visual) return ed.enterVisual(line);
            // Same key leaves visual mode; the other switches kind.
            if (ed.visual_line == line) ed.exitVisual() else ed.visual_line = line;
        }
    }.run;
}

fn visualSwap(c: Context) !void {
    const v = &c.ed.view;
    std.mem.swap(usize, &v.anchor, &v.cursor);
    v.want_col = null;
}

fn exitVisual(c: Context) !void {
    c.ed.exitVisual();
}

// ---------------------------------------------------------------------------
// Insert mode

/// A cursor position computed from the editor (e.g. "first non-blank").
const Position = fn (*Editor) usize;

fn insertAt(comptime target: Position) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const pos = target(c.ed);
            c.ed.setMode(.insert);
            c.ed.setCursor(pos);
        }
    }.run;
}

fn cursorPos(ed: *Editor) usize {
    return ed.view.cursor;
}

fn afterCursorPos(ed: *Editor) usize {
    const t = ed.text();
    return @min(motions.nextChar(t, ed.view.cursor), t.lineEnd(ed.cursorLine()));
}

fn lineEndPos(ed: *Editor) usize {
    return ed.text().lineEnd(ed.cursorLine());
}

fn firstNonBlankPos(ed: *Editor) usize {
    return motions.firstNonBlank(ed.text(), ed.cursorLine());
}

fn openLine(comptime where: enum { above, below }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            const line = ed.cursorLine();
            // Copy the indent first: inserting may reallocate the text.
            var indent_buf: [256]u8 = undefined;
            const indent = copyIndent(ed, line, &indent_buf);
            ed.setMode(.insert);
            switch (where) {
                .below => {
                    ed.setCursor(t.lineEnd(line));
                    try ed.insertText("\n");
                    try ed.insertText(indent);
                },
                .above => {
                    ed.setCursor(t.lineStart(line));
                    try ed.insertText(indent);
                    const after_indent = ed.view.cursor;
                    try ed.insertText("\n");
                    ed.setCursor(after_indent);
                },
            }
        }
    }.run;
}

fn copyIndent(ed: *Editor, line: usize, buf: []u8) []const u8 {
    const t = ed.text();
    const indent = t.slice(t.lineStart(line), motions.firstNonBlank(t, line));
    const n = @min(indent.len, buf.len);
    @memcpy(buf[0..n], indent[0..n]);
    return buf[0..n];
}

fn normalMode(c: Context) !void {
    const ed = c.ed;
    // Like vim, leaving insert mode steps back onto the last inserted char.
    const pos = leftInLine(ed.text(), ed.view.cursor);
    ed.setMode(.normal);
    ed.setCursor(pos);
}

/// Insert-mode deletion between the cursor and `step` (no register).
fn deleteBy(comptime step: fn (*const Text, usize) usize) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const from = c.ed.view.cursor;
            const to = step(c.ed.text(), from);
            try c.ed.deleteRange(@min(from, to), @max(from, to));
        }
    }.run;
}

/// Insert-mode <C-w>: back one word, but not past the start of the line
/// unless already there (then it joins lines, like <BS>).
fn wordBackwardInLine(t: *const Text, p: usize) usize {
    const start = t.lineStart(t.lineOf(p));
    const target = motions.wordBackward(t, p, false);
    return if (target < start and p > start) start else target;
}

fn insertNewline(c: Context) !void {
    var indent_buf: [256]u8 = undefined;
    const indent = copyIndent(c.ed, c.ed.cursorLine(), &indent_buf);
    try c.ed.insertText("\n");
    try c.ed.insertText(indent);
}

fn insertTab(c: Context) !void {
    const ed = c.ed;
    if (!ed.options.expand_tab) return ed.insertText("\t");
    const col = ed.cursorCol();
    const spaces = motions.nextTabStop(col, ed.options.tab_width) - col;
    const buf: [16]u8 = @splat(' ');
    try ed.insertText(buf[0..@min(spaces, buf.len)]);
}

// ---------------------------------------------------------------------------
// Files, buffers, pickers

fn saveFile(c: Context) !void {
    const ed = c.ed;
    const n = ed.buffer.save(ed.gpa, ed.io) catch |err| switch (err) {
        error.NoPath => {
            ed.setMessage(.err, "no file name (save-as arrives with the picker)", .{});
            return;
        },
        else => return err,
    };
    ed.setMessage(.info, "\"{s}\" {d}L, {d}B written", .{ ed.buffer.displayName(), ed.text().lineCount(), n });
    if (ed.lspFor(ed.buffer)) |l| l.didSave(ed.buffer);
}

fn quit(c: Context) !void {
    const ed = c.ed;
    for (ed.buffers.items) |b| if (b.modified) {
        ed.setMessage(.err, "\"{s}\" has unsaved changes: SPC q s saves all and quits, SPC q Q discards", .{b.displayName()});
        return;
    };
    ed.should_quit = true;
}

/// Saves every modified buffer, then quits. Refuses if one has no file name.
fn saveAndQuit(c: Context) !void {
    const ed = c.ed;
    for (ed.buffers.items) |b| if (b.modified and b.path == null) {
        ed.setMessage(.err, "a modified buffer has no file name; save or discard it first", .{});
        return;
    };
    for (ed.buffers.items) |b| if (b.modified) {
        _ = b.save(ed.gpa, ed.io) catch |err| {
            ed.setMessage(.err, "could not save \"{s}\": {s}", .{ b.displayName(), @errorName(err) });
            return;
        };
        if (ed.lspFor(b)) |l| l.didSave(b);
    };
    ed.should_quit = true;
}

fn quitWithoutSaving(c: Context) !void {
    c.ed.should_quit = true;
}

fn openPicker(comptime kind: Picker.Kind) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            try c.ed.openPicker(kind, "");
        }
    }.run;
}

fn resumePicker(c: Context) !void {
    const ed = c.ed;
    const kind = ed.resume_kind orelse {
        ed.setMessage(.info, "no picker to resume", .{});
        return;
    };
    // openPicker copies the query; resume_query is overwritten on close.
    const query = try ed.gpa.dupe(u8, ed.resume_query.items);
    defer ed.gpa.free(query);
    try ed.openPicker(kind, query);
}

fn killBuffer(c: Context) !void {
    try c.ed.killBuffer(c.ed.buffer);
}

fn cycleBuffer(comptime delta: isize) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            c.ed.cycleBuffer(delta * @as(isize, @intCast(c.count)));
        }
    }.run;
}

fn pickerMove(comptime delta: isize, comptime how: enum { wrap, clamp }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const p = c.ed.picker orelse return;
            switch (how) {
                .wrap => p.move(delta),
                .clamp => p.moveClamped(delta),
            }
        }
    }.run;
}

fn inputEdit(comptime what: enum { char, word, all }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const input = ed.activeInput() orelse return;
            // <BS> on an empty search prompt cancels it, like vim.
            if (what == .char and ed.mode == .search and input.items().len == 0) return ed.cancelSearch();
            switch (what) {
                .char => input.deleteChar(),
                .word => input.deleteWord(),
                .all => input.clear(),
            }
            try ed.inputChanged();
        }
    }.run;
}

// ---------------------------------------------------------------------------
// Search

fn startSearch(comptime forward: bool, comptime kind: Editor.PromptKind) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            c.ed.startSearch(forward, kind);
        }
    }.run;
}

fn gotoSymbol(c: Context) !void {
    try c.ed.showSymbols();
}

fn renameSymbol(c: Context) !void {
    try c.ed.startRename();
}

fn searchNext(comptime reverse: bool) Target {
    return struct {
        fn target(ed: *Editor, from: usize, c: Context) ?usize {
            const pos = ed.searchNext(from, reverse, c.count) orelse return null;
            ed.revealLine(ed.text().lineOf(pos));
            return pos;
        }
    }.target;
}

fn searchWord(comptime forward: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            try c.ed.searchWord(forward, c.count);
        }
    }.run;
}

// ---------------------------------------------------------------------------
// Language server

fn lspRequest(comptime what: enum { definition, references, hover }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const l = c.ed.languageServer() orelse return;
            switch (what) {
                .definition => try l.requestDefinition(c.ed),
                .references => try l.requestReferences(c.ed),
                .hover => try l.requestHover(c.ed),
            }
        }
    }.run;
}

/// An insert-mode key that drives the completion popup when it is open and
/// otherwise does `fallback` (or, with none, asks for completions).
fn completionKey(comptime action: enum { next, previous, accept }, comptime fallback: ?Handler) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            if (ed.completion) |*comp| return switch (action) {
                .next => comp.move(1),
                .previous => comp.move(-1),
                .accept => ed.acceptCompletion(),
            };
            if (fallback) |f| return f(c);
            if (action != .accept) try ed.requestCompletion();
        }
    }.run;
}

fn clearSearchHighlight(c: Context) !void {
    c.ed.search_highlight = false;
}

fn searchAccept(c: Context) !void {
    try c.ed.acceptSearch();
}

fn searchCancel(c: Context) !void {
    c.ed.cancelSearch();
}

fn pickerAccept(c: Context) !void {
    try c.ed.acceptPicker();
}

fn pickerClose(c: Context) !void {
    c.ed.closePicker();
}
