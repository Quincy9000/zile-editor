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
const pairs = @import("pairs.zig");
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
    /// With several cursors, runs at the primary only instead of at each one
    /// (undo, `.`, macros, cursor management). Leader commands always are.
    once: bool = false,
    /// A jump: the place it leaves goes on the jumplist (`<C-o>` returns).
    jump: bool = false,
    /// Works while the cursor is on a ghost line (otherwise the cursor
    /// returns to the text first, or the command is refused if it edits).
    ghost: bool = false,
};

pub const all = base ++ text_object_commands;

const base = [_]Command{
    // Motions: normal and visual mode, and as an operator's range.
    .{ .name = "move_left", .doc = "Left", .run = ghostCol(.left, motion(left, .exclusive, .reset)), .ghost = true },
    .{ .name = "move_right", .doc = "Right", .run = ghostCol(.right, motion(right, .exclusive, .reset)), .ghost = true },
    .{ .name = "move_down", .doc = "Down", .run = verticalRow(1), .ghost = true },
    .{ .name = "move_up", .doc = "Up", .run = verticalRow(-1), .ghost = true },
    .{ .name = "word_forward", .doc = "Next word", .run = wordMotion(.forward, false), .ghost = true },
    .{ .name = "word_backward", .doc = "Previous word", .run = wordMotion(.backward, false), .ghost = true },
    .{ .name = "word_end", .doc = "End of word", .run = wordMotion(.end, false), .ghost = true },
    .{ .name = "big_word_forward", .doc = "Next WORD", .run = wordMotion(.forward, true), .ghost = true },
    .{ .name = "big_word_backward", .doc = "Previous WORD", .run = wordMotion(.backward, true), .ghost = true },
    .{ .name = "big_word_end", .doc = "End of WORD", .run = wordMotion(.end, true), .ghost = true },
    .{ .name = "line_start", .doc = "Start of line", .run = ghostCol(.start, motion(lineStart, .exclusive, .reset)), .ghost = true },
    .{ .name = "first_non_blank", .doc = "First non-blank", .run = ghostCol(.first_non_blank, motion(firstNonBlank, .exclusive, .reset)), .ghost = true },
    .{ .name = "line_end", .doc = "End of line", .run = ghostCol(.end, motion(lineEnd, .inclusive, .eol)), .ghost = true },
    .{ .name = "goto_first_line", .doc = "First line (or line [count])", .run = motion(firstLine, .linewise, .reset) , .jump = true },
    .{ .name = "goto_last_line", .doc = "Last line (or line [count])", .run = motion(lastLine, .linewise, .reset) , .jump = true },
    .{ .name = "find_char", .doc = "Find character", .run = ghostFind(.{ .forward = true, .till = false }, motion(findChar(true, false), .inclusive, .reset)), .takes_char = true, .ghost = true },
    .{ .name = "find_char_backward", .doc = "Find character backward", .run = ghostFind(.{ .forward = false, .till = false }, motion(findChar(false, false), .exclusive, .reset)), .takes_char = true, .ghost = true },
    .{ .name = "till_char", .doc = "Till character", .run = ghostFind(.{ .forward = true, .till = true }, motion(findChar(true, true), .inclusive, .reset)), .takes_char = true, .ghost = true },
    .{ .name = "till_char_backward", .doc = "Till character backward", .run = ghostFind(.{ .forward = false, .till = true }, motion(findChar(false, true), .exclusive, .reset)), .takes_char = true, .ghost = true },
    .{ .name = "repeat_find", .doc = "Repeat f/t", .run = ghostFind(.repeat, repeatFind(false)), .ghost = true },
    .{ .name = "repeat_find_reverse", .doc = "Repeat f/t backward", .run = ghostFind(.repeat_reverse, repeatFind(true)), .ghost = true },
    .{ .name = "match_bracket", .doc = "Matching bracket", .run = motion(matchBracket, .inclusive, .reset) , .jump = true },
    .{ .name = "paragraph_forward", .doc = "Next paragraph", .run = motion(paragraphForward, .exclusive, .reset) , .jump = true },
    .{ .name = "paragraph_backward", .doc = "Previous paragraph", .run = motion(paragraphBackward, .exclusive, .reset) , .jump = true },
    .{ .name = "screen_top", .doc = "Top of screen", .run = motion(screenLine(.top), .linewise, .reset) , .jump = true },
    .{ .name = "screen_middle", .doc = "Middle of screen", .run = motion(screenLine(.middle), .linewise, .reset) , .jump = true },
    .{ .name = "screen_bottom", .doc = "Bottom of screen", .run = motion(screenLine(.bottom), .linewise, .reset) , .jump = true },
    .{ .name = "search_next", .doc = "Next match", .run = searchNextCmd(false), .ghost = true , .jump = true },
    .{ .name = "search_previous", .doc = "Previous match", .run = searchNextCmd(true), .ghost = true , .jump = true },

    // Search
    .{ .name = "search_forward", .doc = "Search forward", .run = startSearch(true, .search) },
    .{ .name = "search_backward", .doc = "Search backward", .run = startSearch(false, .search) },
    .{ .name = "snipe", .doc = "Jump to text on screen", .run = startSearch(true, .snipe) },
    .{ .name = "search_word_forward", .doc = "Search word under cursor", .run = searchWord(true) , .jump = true },
    .{ .name = "search_word_backward", .doc = "Search word under cursor backward", .run = searchWord(false) , .jump = true },
    .{ .name = "clear_search_highlight", .doc = "Clear search highlight", .run = clearSearchHighlight , .once = true },
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
    .{ .name = "completion_accept_or_tab", .doc = "Accept completion, next placeholder, or tab", .run = completionKey(.accept, snippetOrTab), .hidden = true },
    .{ .name = "ai_accept", .doc = "Take the AI suggestion", .run = aiAccept(.all), .hidden = true },
    .{ .name = "ai_accept_line", .doc = "Take a line of the AI suggestion", .run = aiAccept(.line), .hidden = true },
    .{ .name = "ai_accept_char", .doc = "Take a character of the AI suggestion", .run = aiAccept(.char), .hidden = true },
    .{ .name = "snippet_previous", .doc = "Previous placeholder", .run = snippetPrevious, .hidden = true },
    .{ .name = "completion_accept_or_newline", .doc = "Accept completion or newline", .run = completionKey(.accept, insertNewline), .hidden = true },
    .{ .name = "completion_accept", .doc = "Accept completion", .run = completionKey(.accept, null), .hidden = true },

    // Scrolling
    .{ .name = "half_page_down", .doc = "Half page down", .run = scroll(.half_page, 1), .ghost = true },
    .{ .name = "half_page_up", .doc = "Half page up", .run = scroll(.half_page, -1), .ghost = true },
    .{ .name = "page_down", .doc = "Page down", .run = scroll(.page, 1), .ghost = true },
    .{ .name = "page_up", .doc = "Page up", .run = scroll(.page, -1), .ghost = true },
    .{ .name = "scroll_down", .doc = "Scroll down", .run = scroll(.line, 1), .ghost = true },
    .{ .name = "scroll_up", .doc = "Scroll up", .run = scroll(.line, -1), .ghost = true },
    .{ .name = "fold_close", .doc = "Close fold", .run = foldCmd(.close) },
    .{ .name = "fold_open", .doc = "Open fold", .run = foldCmd(.open) },
    .{ .name = "fold_open_recursive", .doc = "Open all folds here", .run = foldCmd(.open_all_here) },
    .{ .name = "fold_toggle", .doc = "Toggle fold", .run = foldCmd(.toggle) },
    .{ .name = "fold_open_all", .doc = "Open all folds", .run = foldCmd(.open_everything) },
    .{ .name = "fold_close_all", .doc = "Close all folds", .run = foldCmd(.close_everything) },
    .{ .name = "fold_create", .doc = "Create fold", .run = operator(.fold) },
    .{ .name = "view_center", .doc = "Center line", .run = placeLine(.center, false), .ghost = true },
    .{ .name = "view_top", .doc = "Line to top", .run = placeLine(.top, false), .ghost = true },
    .{ .name = "view_bottom", .doc = "Line to bottom", .run = placeLine(.bottom, false), .ghost = true },
    .{ .name = "view_center_first_non_blank", .doc = "Center line, to first non-blank", .run = placeLine(.center, true) },
    .{ .name = "view_top_first_non_blank", .doc = "Line to top, to first non-blank", .run = placeLine(.top, true) },
    .{ .name = "view_bottom_first_non_blank", .doc = "Line to bottom, to first non-blank", .run = placeLine(.bottom, true) },

    // Operators: wait for a motion or text object (or act on the selection).
    .{ .name = "delete", .doc = "Delete", .run = operator(.delete), .repeat = true },
    .{ .name = "change", .doc = "Change", .run = operator(.change), .repeat = true },
    .{ .name = "yank", .doc = "Yank", .run = yankCmd, .ghost = true },
    .{ .name = "indent", .doc = "Indent", .run = operator(.indent), .repeat = true },
    .{ .name = "outdent", .doc = "Outdent", .run = operator(.outdent), .repeat = true },
    .{ .name = "lowercase", .doc = "Lowercase", .run = operator(.lowercase), .repeat = true },
    .{ .name = "uppercase", .doc = "Uppercase", .run = operator(.uppercase), .repeat = true },
    .{ .name = "toggle_case", .doc = "Toggle case", .run = operator(.toggle_case), .repeat = true },
    .{ .name = "operate_line", .doc = "Whole line", .run = operateLine, .hidden = true, .ghost = true },
    .{ .name = "cancel", .doc = "Cancel", .run = cancel, .hidden = true, .ghost = true },

    // Operator + motion shortcuts
    .{ .name = "delete_char", .doc = "Delete character", .run = opMotion(.delete, right, .exclusive), .repeat = true },
    .{ .name = "delete_char_before", .doc = "Delete character before", .run = opMotion(.delete, left, .exclusive), .repeat = true },
    .{ .name = "delete_to_line_end", .doc = "Delete to end of line", .run = opMotion(.delete, lineEnd, .inclusive), .repeat = true },
    .{ .name = "change_to_line_end", .doc = "Change to end of line", .run = opMotion(.change, lineEnd, .inclusive), .repeat = true },
    .{ .name = "yank_to_line_end", .doc = "Yank to end of line", .run = yankToLineEnd, .ghost = true },
    .{ .name = "substitute_line", .doc = "Substitute line", .run = opLines(.change), .repeat = true },

    // Editing
    .{ .name = "paste_after", .doc = "Paste after", .run = paste(false), .repeat = true },
    .{ .name = "paste_before", .doc = "Paste before", .run = paste(true), .repeat = true },
    .{ .name = "replace_char", .doc = "Replace character", .run = replaceChar, .repeat = true, .takes_char = true },
    .{ .name = "join_lines", .doc = "Join lines", .run = joinLines, .repeat = true },
    .{ .name = "toggle_case_char", .doc = "Toggle case of character", .run = toggleCaseChar, .repeat = true },
    .{ .name = "undo", .doc = "Undo", .run = undo , .once = true },
    .{ .name = "redo", .doc = "Redo", .run = redo , .once = true },
    .{ .name = "repeat_change", .doc = "Repeat last change", .run = repeatChange , .once = true },
    .{ .name = "record_macro", .doc = "Record macro (Q again to stop)", .run = recordMacro, .takes_char = true, .once = true },
    .{ .name = "play_macro", .doc = "Play macro (@@ for the last one)", .run = playMacro, .takes_char = true , .once = true },

    // Visual mode
    .{ .name = "visual_mode", .doc = "Visual mode", .run = visualMode(false), .ghost = true },
    .{ .name = "visual_line_mode", .doc = "Visual line mode", .run = visualMode(true), .ghost = true },
    .{ .name = "visual_swap_ends", .doc = "Other end of selection", .run = visualSwap },
    .{ .name = "exit_visual", .doc = "Leave visual mode", .run = exitVisual, .hidden = true, .ghost = true },

    // Toggles (SPC t)
    .{ .name = "toggle_ghost_lines", .doc = "Ghost lines", .run = toggle("ghost_lines", "ghost lines"), .ghost = true },
    .{ .name = "toggle_relative_numbers", .doc = "Relative numbers", .run = toggle("relative_numbers", "relative line numbers"), .ghost = true },
    .{ .name = "toggle_diagnostic_text", .doc = "Diagnostic messages", .run = toggle("diagnostic_text", "diagnostic messages"), .ghost = true },

    // Git (in a repository)
    .{ .name = "git_menu", .doc = "Git menu", .run = openPicker(.git_actions) },
    .{ .name = "git_commit", .doc = "Commit all changes", .run = gitAction(.commit) },
    .{ .name = "git_push", .doc = "Push", .run = gitAction(.push) },
    .{ .name = "git_pull", .doc = "Pull", .run = gitAction(.pull) },
    .{ .name = "git_branches", .doc = "Switch / new branch", .run = openPicker(.git_branches) },
    .{ .name = "git_changed_files", .doc = "Changed files", .run = openPicker(.git_changes) },
    .{ .name = "git_set_remote", .doc = "Set remote URL", .run = gitAction(.remote) },
    .{ .name = "git_restore_hunk", .doc = "Restore hunk from HEAD", .run = gitCmd(.restore), .ghost = true },
    .{ .name = "git_next_hunk", .doc = "Next change", .run = gitCmd(.next), .ghost = true , .jump = true },
    .{ .name = "git_previous_hunk", .doc = "Previous change", .run = gitCmd(.previous), .ghost = true , .jump = true },
    .{ .name = "git_reload", .doc = "Reload HEAD", .run = gitCmd(.reload), .ghost = true },

    // Entering insert mode
    .{ .name = "insert_before", .doc = "Insert before cursor", .run = insertAt(cursorPos), .repeat = true },
    .{ .name = "insert_after", .doc = "Insert after cursor", .run = insertAt(afterCursorPos), .repeat = true },
    .{ .name = "insert_line_start", .doc = "Insert at line start", .run = insertAt(firstNonBlankPos), .repeat = true },
    .{ .name = "insert_line_end", .doc = "Insert at line end", .run = insertAt(lineEndPos), .repeat = true },
    .{ .name = "open_below", .doc = "Open line below", .run = openLine(.below), .repeat = true },
    .{ .name = "open_above", .doc = "Open line above", .run = openLine(.above), .repeat = true },
    .{ .name = "normal_mode", .doc = "Normal mode", .run = normalMode },

    // Insert-mode editing
    .{ .name = "surround_or_snipe", .doc = "Surround (after y/d/c), else snipe", .run = surroundOrSnipe },
    .{ .name = "surround_add", .doc = "Surround with", .run = surroundStep(.add), .takes_char = true, .hidden = true },
    .{ .name = "surround_delete", .doc = "Delete surrounding", .run = surroundStep(.delete), .takes_char = true, .hidden = true },
    .{ .name = "surround_change_from", .doc = "Change surrounding", .run = surroundStep(.change_from), .takes_char = true, .hidden = true },
    .{ .name = "surround_change_to", .doc = "Change surrounding to", .run = surroundStep(.change_to), .takes_char = true, .hidden = true },
    .{ .name = "surround_visual", .doc = "Surround selection", .run = surroundStep(.visual), .takes_char = true, .repeat = true },
    .{ .name = "format_buffer", .doc = "Format (file, or the selected lines)", .run = formatCmd, .once = true },
    .{ .name = "toggle_ai_complete", .doc = "AI completion", .run = toggleAi },
    .{ .name = "toggle_format_on_save", .doc = "Format on save", .run = toggle("format_on_save", "format on save") },
    .{ .name = "zoom_in", .doc = "Bigger text", .run = zoom(.in), .once = true },
    .{ .name = "zoom_out", .doc = "Smaller text", .run = zoom(.out), .once = true },
    .{ .name = "zoom_reset", .doc = "Normal text size", .run = zoom(.reset), .once = true },
    .{ .name = "toggle_auto_pairs", .doc = "Auto pairs", .run = toggle("auto_pairs", "auto pairs") },
    // Multicursor (Doom's evil-mc keys: gz...).
    .{ .name = "cursor_next_match", .doc = "Cursor + next match", .run = cursorCmd(.next), .once = true },
    .{ .name = "cursor_previous_match", .doc = "Cursor + previous match", .run = cursorCmd(.previous), .once = true },
    .{ .name = "cursor_skip_match", .doc = "Skip to next match", .run = cursorCmd(.skip), .once = true },
    .{ .name = "cursor_all_matches", .doc = "Cursors on all matches", .run = cursorCmd(.all), .once = true },
    .{ .name = "cursor_down", .doc = "Cursor + move down", .run = cursorCmd(.down), .once = true },
    .{ .name = "cursor_up", .doc = "Cursor + move up", .run = cursorCmd(.up), .once = true },
    .{ .name = "cursor_undo", .doc = "Remove last cursor", .run = cursorCmd(.undo), .once = true },
    .{ .name = "cursor_clear", .doc = "Remove all cursors", .run = cursorCmd(.clear), .once = true },
    .{ .name = "cursors_line_starts", .doc = "Cursors at line starts", .run = cursorCmd(.line_starts), .once = true },
    .{ .name = "cursors_line_ends", .doc = "Cursors at line ends", .run = cursorCmd(.line_ends), .once = true },
    .{ .name = "insert_line_starts", .doc = "Insert at each line's start", .run = cursorCmd(.insert_starts), .once = true },
    .{ .name = "append_line_ends", .doc = "Append at each line's end", .run = cursorCmd(.insert_ends), .once = true },
    .{ .name = "cursors_from_matches", .doc = "Cursors on every match", .run = cursorCmd(.from_prompt), .once = true, .hidden = true },
    .{ .name = "insert_newline", .doc = "New line, keeping indentation", .run = insertNewline },
    .{ .name = "delete_backward", .doc = "Delete previous character", .run = deleteBackward },
    .{ .name = "delete_forward", .doc = "Delete next character", .run = deleteBy(motions.nextChar) },
    .{ .name = "delete_word_backward", .doc = "Delete previous word", .run = deleteBy(wordBackwardInLine) },
    .{ .name = "insert_tab", .doc = "Insert tab", .run = insertTab },

    // Files, buffers and session
    .{ .name = "save_file", .doc = "Save file", .run = saveFile },
    .{ .name = "browse_files", .doc = "Explore files (current folder)", .run = browseFiles },
    .{ .name = "new_file", .doc = "New file...", .run = fileCmd(.new) },
    .{ .name = "save_file_as", .doc = "Save file as...", .run = fileCmd(.save_as) },
    .{ .name = "rename_file", .doc = "Rename / move file...", .run = fileCmd(.rename) },
    .{ .name = "copy_file", .doc = "Copy file to...", .run = fileCmd(.copy) },
    .{ .name = "delete_file", .doc = "Delete file from disk", .run = fileCmd(.delete) },
    .{ .name = "yank_file_path", .doc = "Copy file path", .run = fileCmd(.yank_path) },
    .{ .name = "yank_absolute_path", .doc = "Copy absolute file path", .run = fileCmd(.yank_absolute_path) },
    .{ .name = "find_file", .doc = "Find file", .run = openPicker(.files) },
    .{ .name = "switch_buffer", .doc = "Switch buffer", .run = openPicker(.buffers) },
    .{ .name = "kill_buffer", .doc = "Kill buffer", .run = killBuffer },
    .{ .name = "next_buffer", .doc = "Next buffer", .run = cycleBuffer(1) , .jump = true },
    .{ .name = "previous_buffer", .doc = "Previous buffer", .run = cycleBuffer(-1) , .jump = true },
    .{ .name = "switch_project", .doc = "Switch project", .run = openPicker(.projects), .once = true },
    .{ .name = "claude_panel", .doc = "Claude Code panel", .run = claudeCmd(.panel), .once = true },
    .{ .name = "claude_send", .doc = "Send selection/file to Claude", .run = claudeCmd(.send), .once = true },
    .{ .name = "claude_ask", .doc = "Ask Claude about the selection", .run = claudeCmd(.ask), .once = true },
    .{ .name = "claude_accept", .doc = "Accept Claude's change", .run = claudeCmd(.accept), .once = true },
    .{ .name = "claude_reject", .doc = "Reject Claude's change", .run = claudeCmd(.reject), .once = true },
    .{ .name = "terminal_toggle", .doc = "Terminal popup", .run = termCmd(.toggle), .once = true },
    .{ .name = "run_runner", .doc = "Code runner (repeat with Enter)", .run = termCmd(.runner), .once = true },
    .{ .name = "run_command", .doc = "Run a command (multi-line editor)", .run = termCmd(.command), .once = true },
    .{ .name = "run_again", .doc = "Run the runner command again", .run = termCmd(.again), .once = true },
    .{ .name = "run_output", .doc = "Show run output", .run = termCmd(.output), .once = true },
    .{ .name = "run_errors", .doc = "Errors from the last run", .run = termCmd(.errors), .once = true },
    .{ .name = "quickfix_next", .doc = "Next quickfix entry", .run = qfCmd(.next), .once = true, .jump = true },
    .{ .name = "quickfix_previous", .doc = "Previous quickfix entry", .run = qfCmd(.previous), .once = true, .jump = true },
    .{ .name = "quickfix_list", .doc = "Quickfix list (j/k, Enter)", .run = qfCmd(.list), .once = true },
    .{ .name = "jump_older", .doc = "Back (jumplist)", .run = jumpCmd(.older), .once = true },
    .{ .name = "jump_newer", .doc = "Forward (jumplist)", .run = jumpCmd(.newer), .once = true },
    .{ .name = "jump_list", .doc = "Jumplist", .run = openPicker(.jumps), .once = true },
    .{ .name = "new_buffer", .doc = "New empty buffer", .run = bufferCmd(.new) },
    .{ .name = "last_buffer", .doc = "Other buffer (flip back)", .run = bufferCmd(.last) , .jump = true },
    .{ .name = "kill_other_buffers", .doc = "Kill other buffers", .run = bufferCmd(.kill_others) },
    .{ .name = "revert_buffer", .doc = "Revert from disk", .run = bufferCmd(.revert) },
    .{ .name = "save_all", .doc = "Save all buffers", .run = bufferCmd(.save_all) },
    // Windows (SPC w): s + direction splits, the direction alone moves.
    .{ .name = "split_left", .doc = "Split left", .run = windowCmd(.{ .split = .left }), .once = true },
    .{ .name = "split_down", .doc = "Split below", .run = windowCmd(.{ .split = .down }), .once = true },
    .{ .name = "split_up", .doc = "Split above", .run = windowCmd(.{ .split = .up }), .once = true },
    .{ .name = "split_right", .doc = "Split right", .run = windowCmd(.{ .split = .right }), .once = true },
    .{ .name = "window_left", .doc = "Window left", .run = windowCmd(.{ .focus = .left }), .once = true },
    .{ .name = "window_down", .doc = "Window below", .run = windowCmd(.{ .focus = .down }), .once = true },
    .{ .name = "window_up", .doc = "Window above", .run = windowCmd(.{ .focus = .up }), .once = true },
    .{ .name = "window_right", .doc = "Window right", .run = windowCmd(.{ .focus = .right }), .once = true },
    .{ .name = "window_next", .doc = "Next window", .run = windowCmd(.next), .once = true },
    .{ .name = "window_close", .doc = "Close window", .run = windowCmd(.close), .once = true },
    .{ .name = "window_only", .doc = "Close other windows", .run = windowCmd(.only), .once = true },
    .{ .name = "window_balance", .doc = "Equal sizes", .run = windowCmd(.balance), .once = true },
    .{ .name = "window_wider", .doc = "Wider", .run = windowCmd(.{ .resize = .{ .horizontal, 0.05 } }), .once = true },
    .{ .name = "window_narrower", .doc = "Narrower", .run = windowCmd(.{ .resize = .{ .horizontal, -0.05 } }), .once = true },
    .{ .name = "window_taller", .doc = "Taller", .run = windowCmd(.{ .resize = .{ .vertical, 0.05 } }), .once = true },
    .{ .name = "window_shorter", .doc = "Shorter", .run = windowCmd(.{ .resize = .{ .vertical, -0.05 } }), .once = true },
    .{ .name = "command_picker", .doc = "Run a command", .run = openPicker(.commands) },
    .{ .name = "resume_picker", .doc = "Resume last picker", .run = resumePicker },
    .{ .name = "smart_close", .doc = "Close (window, else buffer, else quit)", .run = smartClose, .once = true },
    .{ .name = "quit", .doc = "Quit", .run = quit },
    .{ .name = "save_and_quit", .doc = "Save all and quit", .run = saveAndQuit },
    .{ .name = "quit_without_saving", .doc = "Quit without saving", .run = quitWithoutSaving },

    // Inside the picker
    .{ .name = "picker_next", .doc = "Next result", .run = pickerMove(1, .wrap), .hidden = true },
    .{ .name = "picker_previous", .doc = "Previous result", .run = pickerMove(-1, .wrap), .hidden = true },
    .{ .name = "picker_page_down", .doc = "Page down", .run = pickerMove(10, .clamp), .hidden = true },
    .{ .name = "picker_page_up", .doc = "Page up", .run = pickerMove(-10, .clamp), .hidden = true },
    .{ .name = "picker_to_quickfix", .doc = "Send results to quickfix", .run = qfCmd(.from_picker), .hidden = true },
    .{ .name = "picker_accept", .doc = "Open the selection", .run = pickerAccept, .hidden = true },
    .{ .name = "picker_open_menu", .doc = "Open in... (split)", .run = pickerOpen(null), .hidden = true },
    .{ .name = "picker_open_right", .doc = "Open in a split to the right", .run = pickerOpen(.right), .hidden = true },
    .{ .name = "picker_open_below", .doc = "Open in a split below", .run = pickerOpen(.below), .hidden = true },
    .{ .name = "picker_slash", .doc = "Browser: enter folder", .run = browserKey('/'), .hidden = true },
    .{ .name = "picker_tilde", .doc = "Browser: home folder", .run = browserKey('~'), .hidden = true },
    .{ .name = "picker_normal_mode", .doc = "Picker: move through results", .run = pickerMode(.normal), .hidden = true },
    .{ .name = "picker_insert_mode", .doc = "Picker: type the query", .run = pickerMode(.insert), .hidden = true },
    .{ .name = "picker_first", .doc = "First result", .run = pickerMove(-1_000_000, .clamp), .hidden = true },
    .{ .name = "picker_last", .doc = "Last result", .run = pickerMove(1_000_000, .clamp), .hidden = true },
    .{ .name = "picker_browse_up", .doc = "Explorer: up a folder", .run = browseStep(.up), .hidden = true },
    .{ .name = "picker_browse_in", .doc = "Explorer: into the folder / open", .run = browseStep(.in), .hidden = true },
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
    any_quote,
    bracket: [2]u8,
    any_bracket,
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
    .{ .name = "any_quotes", .doc = "nearest quotes", .keys = "q", .kind = .any_quote },
    .{ .name = "any_brackets", .doc = "nearest ([{ brackets", .keys = "b", .kind = .any_bracket },
    .{ .name = "parens", .doc = "(parens)", .keys = "()", .kind = .{ .bracket = .{ '(', ')' } } },
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
                .any_quote => textobjects.anyQuote(t, pos, scope),
                .any_bracket => textobjects.anyBracket(t, pos, scope, c.count),
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
            // Across ghost lines (on one, or with some on screen) words are
            // found row by row, so they reach into and through ghost lines.
            const row_mode = ed.mode == .normal or (ed.mode == .visual and ed.ghost != null);
            if (row_mode and (ed.ghost != null or ed.hasGhosts())) return rowWords(ed, which, big, c.count);
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

// Word motions over screen rows (text and ghost lines), one line at a time.

const WordClass = enum { space, word, punct };

fn wordClass(b: u8, big: bool) WordClass {
    if (b == ' ' or b == '\t') return .space;
    if (big) return .word;
    if (b >= 0x80 or b == '_' or std.ascii.isAlphanumeric(b)) return .word;
    return .punct;
}

/// Start of the next word after `col` in `line`, if any.
fn nextWordIn(line: []const u8, col: usize, big: bool) ?usize {
    var i = col;
    if (i < line.len) {
        const cls = wordClass(line[i], big);
        if (cls != .space) while (i < line.len and wordClass(line[i], big) == cls) : (i += 1) {};
    }
    while (i < line.len and wordClass(line[i], big) == .space) i += 1;
    return if (i < line.len) i else null;
}

/// End of the next word ending after `col` in `line`, if any.
fn nextWordEndIn(line: []const u8, col: usize, big: bool) ?usize {
    var i = col + 1;
    while (i < line.len and wordClass(line[i], big) == .space) i += 1;
    if (i >= line.len) return null;
    const cls = wordClass(line[i], big);
    while (i + 1 < line.len and wordClass(line[i + 1], big) == cls) i += 1;
    return i;
}

/// Start of the word before `col` in `line`, if any.
fn prevWordIn(line: []const u8, col: usize, big: bool) ?usize {
    if (col == 0) return null;
    var i = @min(col, line.len) - 1;
    while (i > 0 and wordClass(line[i], big) == .space) i -= 1;
    if (wordClass(line[i], big) == .space) return null;
    const cls = wordClass(line[i], big);
    while (i > 0 and wordClass(line[i - 1], big) == cls) i -= 1;
    return i;
}

fn firstWordIn(line: []const u8) usize {
    return std.mem.indexOfNone(u8, line, " \t") orelse 0;
}

fn rowText(ed: *Editor, r: Editor.Row) []const u8 {
    return ed.rowText(r);
}

/// n / N: over ghost lines too (from normal mode), else the text motion.
fn searchNextCmd(comptime reverse: bool) Handler {
    const text_motion = motion(searchNext(reverse), .exclusive, .reset);
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            if (ed.mode == .normal and ed.usesRows()) {
                if (ed.searchNextRows(reverse, c.count)) |rp| ed.setRowPos(rp);
                return;
            }
            return text_motion(c);
        }
    }.run;
}

const FindKind = union(enum) {
    find: struct { forward: bool, till: bool },
    repeat,
    repeat_reverse,
};

/// f / F / t / T and ; / , within a ghost line; elsewhere `normal`.
fn ghostFind(comptime kind: anytype, comptime normal: Handler) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const g = &(ed.ghost orelse return normal(c));
            var f: motions.Find = undefined;
            var repeat = false;
            if (@TypeOf(kind) == @TypeOf(.repeat)) {
                f = ed.last_find orelse return;
                if (kind == .repeat_reverse) f.forward = !f.forward;
                repeat = true;
            } else {
                f = motions.Find.init(c.char, kind.forward, kind.till) orelse return;
                ed.last_find = f;
            }
            // Search the ghost line as a one-line text.
            var tmp = try Text.init(ed.gpa, ed.ghostText(g.line, g.k));
            defer tmp.deinit(ed.gpa);
            if (motions.findInLine(&tmp, @min(g.col, tmp.len()), f, c.count, repeat)) |col| {
                g.col = col;
                ed.view.want_col = col;
            }
        }
    }.run;
}

/// w / b / e over rows: within the current line, then on to the next/previous
/// row (ghost or text). Empty lines count as words, like vim.
fn rowWords(ed: *Editor, which: anytype, big: bool, count: usize) void {
    var r = ed.cursorRow();
    var col = if (ed.ghost) |g| g.col else ed.view.cursor - ed.text().lineStart(ed.cursorLine());
    for (0..count) |_| {
        const line = rowText(ed, r);
        switch (which) {
            .forward => if (nextWordIn(line, col, big)) |c| {
                col = c;
            } else {
                const next = ed.nextRow(r);
                if (next.eql(r)) break;
                r = next;
                col = firstWordIn(rowText(ed, r));
            },
            .end => if (nextWordEndIn(line, col, big)) |c| {
                col = c;
            } else {
                // The first word end on a following non-empty row.
                var n = r;
                while (true) {
                    const next = ed.nextRow(n);
                    if (next.eql(n)) break;
                    n = next;
                    const text = rowText(ed, n);
                    const start = firstWordIn(text);
                    if (start < text.len) {
                        r = n;
                        col = if (start + 1 < text.len and wordClass(text[start + 1], big) == wordClass(text[start], big))
                            nextWordEndIn(text, start, big) orelse start
                        else
                            start;
                        break;
                    }
                }
            },
            .backward => if (prevWordIn(line, col, big)) |c| {
                col = c;
            } else {
                const prev = ed.prevRow(r);
                if (prev.eql(r)) break;
                r = prev;
                const text = rowText(ed, r);
                col = prevWordIn(text, text.len, big) orelse 0;
            },
        }
    }
    if (r.ghost) |k| {
        const anchor = if (ed.ghost) |g| (if (g.line == r.line) g.anchor else null) else null;
        ed.ghost = .{ .line = r.line, .k = k, .col = col, .anchor = anchor };
        ed.view.want_col = col;
    } else {
        ed.ghost = null;
        const t = ed.text();
        ed.setCursor(t.lineStart(r.line) + @min(col, t.lineLen(r.line)));
    }
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
            if (c.has_count) {
                ed.ghost = null;
                ed.gotoLine(@min(c.count - 1, t.lineCount() - 1));
            }
            if (first_non_blank and ed.ghost == null) ed.setCursor(motions.firstNonBlank(t, ed.cursorLine()));
            const rows = ed.view.rows;
            const so = ed.effectiveScrolloff();
            const up_rows: usize = switch (where) {
                .center => rows / 2,
                .top => so,
                .bottom => rows -| (so + 1),
            };
            ed.setTop(ed.stepRows(ed.cursorRow(), -@as(isize, @intCast(up_rows))));
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
    if (ed.ghost) |g| {
        // `yy` on a ghost line yanks [count] ghost lines of its hunk.
        const op = ed.op orelse return;
        ed.op = null;
        ed.mode = .normal;
        const h = ed.ghostHunk(g.line) orelse return;
        const last: u32 = @intCast(@min(g.k + c.count - 1, h.old_count - 1));
        return ed.yankGhostLines(g.line, g.k, last, op.register);
    }
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
// Ghost lines (old HEAD lines shown inline; read-only, yankable)

/// j/k: step screen rows, onto and through ghost lines. With an operator, or in
/// visual mode on text, they move over text lines only.
fn verticalRow(comptime dir: isize) Handler {
    const text_motion = motion(if (dir > 0) down else up, .linewise, .keep);
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            if (ed.mode == .operator or ed.mode == .insert or (ed.mode == .visual and ed.ghost == null)) {
                return text_motion(c);
            }
            const delta = dir * @as(isize, @intCast(c.count));
            var target = ed.stepRows(ed.cursorRow(), delta);
            if (ed.mode == .visual) {
                // A selection of ghost lines stays within its hunk.
                const g = ed.ghost.?;
                const h = ed.ghostHunk(g.line) orelse return;
                if (target.line != g.line or target.ghost == null) {
                    const k = std.math.clamp(@as(isize, g.k) + delta, 0, @as(isize, h.old_count) - 1);
                    target = .{ .line = g.line, .ghost = @intCast(k) };
                }
            }
            ed.setCursorRow(target);
        }
    }.run;
}

/// h / l / 0 / ^ / $ move within a ghost line; elsewhere they are `normal`.
fn ghostCol(comptime action: enum { left, right, start, first_non_blank, end }, comptime normal: Handler) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const g = &(ed.ghost orelse return normal(c));
            const text = ed.ghostText(g.line, g.k);
            g.col = switch (action) {
                .left => g.col -| c.count,
                .right => @min(g.col + c.count, text.len -| 1),
                .start => 0,
                .first_non_blank => std.mem.indexOfNone(u8, text, " \t") orelse 0,
                .end => text.len -| 1,
            };
            ed.view.want_col = if (action == .end) std.math.maxInt(usize) else g.col;
        }
    }.run;
}

/// `y`: on ghost lines, yanks the selection (visual) or waits for `y` (`yy`).
fn yankCmd(c: Context) !void {
    const ed = c.ed;
    if (ed.ghost) |g| {
        if (ed.mode == .visual) {
            try ed.yankGhostLines(g.line, g.anchor orelse g.k, g.k, c.register);
            ed.exitVisual();
            return;
        }
        if (ed.mode == .normal) return ed.beginOperator(.yank, c);
        return;
    }
    try operator(.yank)(c);
}

/// `Y`: yank to the end of the line (also on a ghost line).
fn yankToLineEnd(c: Context) !void {
    const ed = c.ed;
    if (ed.ghost) |g| {
        const text = ed.ghostText(g.line, g.k);
        try ed.registers.store(c.register, .yank, text[@min(g.col, text.len)..], false);
        return;
    }
    try opMotion(.yank, lineEnd, .inclusive)(c);
}

fn gitAction(comptime action: enum { commit, push, pull, remote }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            switch (action) {
                .commit => c.ed.gitCommitPrompt(),
                .push => try c.ed.gitPush(),
                .pull => try c.ed.gitPull(),
                .remote => try c.ed.gitRemotePrompt(),
            }
        }
    }.run;
}

/// Flips the boolean `Options` field `name` and reports it.
fn toggle(comptime name: []const u8, comptime label: []const u8) Handler {
    if (@FieldType(Editor.Options, name) != bool) @compileError("not a boolean option: " ++ name);
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const on = !@field(ed.options, name);
            @field(ed.options, name) = on;
            if (!ed.options.ghost_lines) ed.ghost = null;
            ed.setMessage(.info, label ++ " {s}", .{if (on) "on" else "off"});
        }
    }.run;
}

fn gitCmd(comptime action: enum { restore, next, previous, reload }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            if (ed.gitRoot() == null) return ed.setMessage(.info, "not in a git repository", .{});
            switch (action) {
                .restore => {
                    const h = ed.hunkAtCursor() orelse return ed.setMessage(.info, "no change here", .{});
                    try ed.restoreHunk(h);
                },
                .next => ed.jumpHunk(true),
                .previous => ed.jumpHunk(false),
                .reload => {
                    ed.reloadGit();
                    ed.setMessage(.info, "reloaded HEAD", .{});
                },
            }
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
            if (ed.ghost) |*g| {
                // Selections on ghost lines are always whole lines.
                if (ed.mode == .visual) return ed.exitVisual();
                ed.mode = .visual;
                ed.visual_line = true;
                g.anchor = g.k;
                return;
            }
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
    if (try pairs.splitPair(c.ed)) return;
    var indent_buf: [256]u8 = undefined;
    const indent = copyIndent(c.ed, c.ed.cursorLine(), &indent_buf);
    try c.ed.insertText("\n");
    try c.ed.insertText(indent);
}

/// <A-;> / <A-l> / <A-Right>: all of the gray AI suggestion, a line of
/// it, or one character.
fn aiAccept(comptime part: Editor.AiPart) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            _ = try c.ed.acceptAiSuggestion(part);
        }
    }.run;
}

/// <Tab> without a completion popup: the next placeholder, else a tab.
/// `SPC t a`: AI completion on/off (on again also retries a model that
/// couldn't be reached).
fn toggleAi(c: Context) !void {
    const ed = c.ed;
    const on = !ed.options.ai_complete or ed.ai_unreachable;
    ed.options.ai_complete = on;
    ed.ai_unreachable = false;
    ed.clearAiSuggestion();
    ed.setMessage(.info, "AI completion {s}", .{if (on) "on" else "off"});
}

/// `SPC c f`: the file, or in visual mode the selected lines.
fn formatCmd(c: Context) !void {
    const ed = c.ed;
    if (ed.mode == .visual) {
        const t = ed.text();
        const first = t.lineOf(@min(ed.view.anchor, ed.view.cursor));
        const last = t.lineOf(@max(ed.view.anchor, ed.view.cursor));
        ed.exitVisual();
        return ed.formatBuffer(.{ first, last }, false);
    }
    try ed.formatBuffer(null, false);
}

fn zoom(comptime how: enum { in, out, reset }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            switch (how) {
                .in => c.ed.zoom_request += @intCast(c.count),
                .out => c.ed.zoom_request -= @intCast(c.count),
                .reset => c.ed.zoom_reset = true,
            }
        }
    }.run;
}

fn snippetOrTab(c: Context) !void {
    if (c.ed.snippetStep(true)) return;
    try insertTab(c);
}

fn snippetPrevious(c: Context) !void {
    _ = c.ed.snippetStep(false);
}

/// <BS>: a fresh placeholder goes whole, else one character.
fn deleteBackward(c: Context) !void {
    if (try c.ed.snippetBackspace()) return;
    try deleteBy(motions.prevChar)(c);
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

/// `s` after an operator: `ys` starts a surround (`ysiw)`, `yss)`), `ds` and
/// `cs` read the pair to delete or change. After other operators it is still
/// the snipe motion (`gUs...`).
fn surroundOrSnipe(c: Context) !void {
    const ed = c.ed;
    const op = ed.op orelse return;
    switch (op.op) {
        .yank => ed.op.?.op = .surround, // still waiting for a motion
        .surround => {
            // `yss`: [count] lines.
            const t = ed.text();
            const first = ed.cursorLine();
            const r = operators.linesRange(t, first, @min(first + op.count * c.count - 1, t.lineCount() - 1));
            ed.op = null;
            ed.setMode(.normal);
            ed.awaitSurroundChar(r);
        },
        .delete, .change => {
            ed.op = null;
            ed.setMode(.normal);
            if (op.op == .delete) ed.awaitChar("surround_delete", op.count) else ed.awaitChar("surround_change_from", op.count);
        },
        else => try startSearch(true, .snipe)(c),
    }
}

fn surroundStep(comptime step: enum { add, delete, change_from, change_to, visual }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            // These finish a change that `.` repeats.
            if (step != .change_from) ed.capture_repeatable = true;
            switch (step) {
                .add => try pairs.add(ed, ed.surround_range, c.char, false),
                .delete => try pairs.delete(ed, c.char, c.count),
                .change_from => {
                    ed.surround_from = c.char;
                    ed.awaitChar("surround_change_to", c.count);
                },
                .change_to => try pairs.change(ed, ed.surround_from, c.char, c.count),
                .visual => {
                    if (ed.mode != .visual) return;
                    const r = ed.visualRange();
                    ed.exitVisual();
                    try pairs.add(ed, r, c.char, r.linewise);
                },
            }
        }
    }.run;
}

fn claudeCmd(comptime action: enum { panel, send, ask, accept, reject }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .panel => ed.toggleClaude() catch |err| ed.setMessage(.err, "could not start Claude Code: {s}", .{@errorName(err)}),
                .send => try ed.claudeMention(),
                .ask => try ed.claudeAskPrompt(),
                .accept => ed.claudeResolve(true),
                .reject => ed.claudeResolve(false),
            }
        }
    }.run;
}

fn termCmd(comptime action: enum { toggle, runner, command, again, output, errors }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .toggle => try ed.toggleShell(),
                .runner => try ed.runPrompt(true),
                .command => try ed.runPrompt(false),
                .again => try ed.runAgain(),
                .output => ed.showRunOutput(),
                .errors => try ed.showRunErrors(),
            }
        }
    }.run;
}

fn qfCmd(comptime action: enum { next, previous, list, from_picker }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            switch (action) {
                .next => try c.ed.stepQuickfix(true, c.count),
                .previous => try c.ed.stepQuickfix(false, c.count),
                .list => try c.ed.showQuickfix(),
                .from_picker => try c.ed.pickerToQuickfix(),
            }
        }
    }.run;
}

fn jumpCmd(comptime dir: enum { older, newer }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            switch (dir) {
                .older => try c.ed.jumpOlder(c.count),
                .newer => try c.ed.jumpNewer(c.count),
            }
        }
    }.run;
}

fn bufferCmd(comptime action: enum { new, last, kill_others, revert, save_all }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .new => try ed.newBuffer(),
                .last => try ed.lastBuffer(),
                .kill_others => try ed.killOtherBuffers(),
                .revert => {
                    ed.reloadBuffer(ed.buffer) catch |err| return ed.setMessage(.err, "could not revert: {s}", .{@errorName(err)});
                    ed.setMessage(.info, "reverted \"{s}\" from disk", .{ed.buffer.displayName()});
                },
                .save_all => ed.saveAll(),
            }
        }
    }.run;
}

const WindowAction = union(enum) {
    split: Editor.Windows.Dir,
    focus: Editor.Windows.Dir,
    next,
    close,
    only,
    balance,
    resize: struct { Editor.Windows.Axis, f32 },
};

fn windowCmd(comptime action: WindowAction) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .split => |d| try ed.splitWindow(d),
                .focus => |d| for (0..c.count) |_| ed.focusDirection(d),
                .next => for (0..c.count) |_| ed.focusNext(),
                .close => ed.closeWindow(),
                .only => try ed.onlyWindow(),
                .balance => ed.windows.balance(),
                .resize => |r| Editor.Windows.resize(ed.window, r[0], r[1] * @as(f32, @floatFromInt(c.count))),
            }
        }
    }.run;
}

fn browseFiles(c: Context) !void {
    try c.ed.browse();
}

fn saveFile(c: Context) !void {
    try c.ed.saveCurrent();
}

fn fileCmd(comptime action: enum { new, save_as, rename, copy, delete, yank_path, yank_absolute_path }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .new => try ed.filePrompt(.new_file),
                .save_as => try ed.filePrompt(.save_as),
                .rename => try ed.filePrompt(.rename_file),
                .copy => try ed.filePrompt(.copy_file),
                .delete => try ed.deleteFilePrompt(),
                .yank_path => try ed.yankPath(false),
                .yank_absolute_path => try ed.yankPath(true),
            }
        }
    }.run;
}

/// `SPC q`: closes the focused window if there are several code windows (or
/// it's a terminal panel), else hides the panel, else closes the current
/// buffer if there are several, else the editor.
fn smartClose(c: Context) !void {
    const ed = c.ed;
    // A terminal panel (Claude) closes like a window, but doesn't count as
    // one of the code windows: the last code window hides the panel first.
    if (ed.window.term != null or ed.codeWindowCount() > 1) return ed.closeWindow();
    for (ed.window_list.items) |w| if (w.term != null) {
        ed.focusWindow(w);
        ed.closeWindow();
        ed.setMessage(.info, "Claude panel hidden (SPC a a shows it again)", .{});
        return;
    };
    if (ed.buffers.items.len > 1) {
        const name = try ed.gpa.dupe(u8, ed.buffer.displayName());
        defer ed.gpa.free(name);
        const before = ed.buffers.items.len;
        try ed.killBuffer(ed.buffer);
        if (ed.buffers.items.len < before) ed.setMessage(.info, "closed {s}", .{name});
        return;
    }
    try quit(c);
}

fn quit(c: Context) !void {
    const ed = c.ed;
    for (ed.buffers.items) |b| if (b.modified) {
        ed.setMessage(.err, "\"{s}\" has unsaved changes: SPC Q s saves all and quits, SPC Q Q discards", .{b.displayName()});
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

fn pickerMode(comptime m: enum { normal, insert }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            if (c.ed.picker == null) return;
            c.ed.mode = if (m == .normal) .picker_normal else .picker;
        }
    }.run;
}

fn browseStep(comptime dir: enum { up, in }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const p = c.ed.picker orelse return;
            if (p.kind != .browse) return;
            switch (dir) {
                .up => try c.ed.browseUp(),
                .in => {
                    // Folders: go in, staying in normal mode. Files: open.
                    p.sync();
                    if (p.itemAt(p.selected)) |item| if (std.mem.endsWith(u8, item.text, "/")) {
                        const name = try c.ed.gpa.dupe(u8, item.text);
                        defer c.ed.gpa.free(name);
                        return c.ed.browseInto(name);
                    };
                    try c.ed.acceptPicker();
                },
            }
        }
    }.run;
}

fn pickerMove(comptime delta: isize, comptime how: enum { wrap, clamp }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const p = c.ed.picker orelse return;
            // Move through the results of what was typed, even if the key
            // came before they were shown (the match pass is quick).
            p.sync();
            switch (how) {
                .wrap => p.move(delta),
                .clamp => p.moveClamped(delta),
            }
        }
    }.run;
}

/// Keys that navigate in the file browser and are plain text elsewhere:
/// `/` enters the selected folder (or the root, on an empty query), `~` on an
/// empty query goes home.
fn browserKey(comptime char: u8) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const p = ed.picker orelse return;
            if (p.kind == .browse) {
                const empty = p.query.items().len == 0;
                switch (char) {
                    '/' => {
                        p.sync();
                        if (p.itemAt(p.selected)) |item| if (std.mem.endsWith(u8, item.text, "/")) {
                            const name = try ed.gpa.dupe(u8, item.text);
                            defer ed.gpa.free(name);
                            return ed.browseInto(name);
                        };
                        if (empty) return ed.browseInto("/");
                    },
                    '~' => if (empty) {
                        if (std.c.getenv("HOME")) |h| return ed.browseInto(std.mem.span(h));
                    },
                    else => comptime unreachable,
                }
            }
            try p.query.insert(ed.gpa, char);
            try ed.inputChanged();
        }
    }.run;
}

fn inputEdit(comptime what: enum { char, word, all }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const input = ed.activeInput() orelse return;
            if (what == .char and input.items().len == 0) {
                // <BS> on an empty search prompt cancels it, like vim; in the
                // file browser it goes up a folder.
                if (ed.mode == .search) return ed.cancelSearch();
                if (ed.picker) |p| if (p.kind == .browse) return ed.browseUp();
            }
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
    // With extra cursors, <Esc> removes them first.
    if (c.ed.cursors.items.len > 0) return c.ed.clearCursors();
    c.ed.search_highlight = false;
}

fn cursorCmd(comptime action: enum { next, previous, skip, all, down, up, undo, clear, line_starts, line_ends, insert_starts, insert_ends, from_prompt }) Handler {
    return &struct {
        const move = verticalRow(if (action == .up) -1 else 1);
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .next => try ed.cursorAtMatch(.next),
                .previous => try ed.cursorAtMatch(.previous),
                .skip => try ed.cursorAtMatch(.skip),
                .all => try ed.cursorAtMatch(.all),
                .down, .up => {
                    for (0..c.count) |_| {
                        try ed.addCursorHere();
                        try move(.{ .ed = ed, .count = 1, .has_count = false });
                    }
                    ed.setMessage(.info, "{d} cursors", .{ed.cursors.items.len + 1});
                },
                .undo => ed.removeLastCursor(),
                .clear => ed.clearCursors(),
                .line_starts => try ed.cursorsOnLines(false, false),
                .line_ends => try ed.cursorsOnLines(true, false),
                .insert_starts => try ed.cursorsOnLines(false, true),
                .insert_ends => try ed.cursorsOnLines(true, true),
                .from_prompt => try ed.cursorsFromPrompt(),
            }
        }
    }.run;
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

/// <Tab>: the "Open in..." menu; <C-v> / <C-s>: straight into a split.
fn pickerOpen(comptime target: ?Editor.OpenTarget) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            if (target) |t| return c.ed.acceptPickerAs(t);
            try c.ed.pickerOpenMenu();
        }
    }.run;
}

fn pickerClose(c: Context) !void {
    c.ed.closePicker();
}
