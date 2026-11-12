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
const debugging = @import("debugging.zig");
const Editor = @import("Editor.zig");
const Text = @import("core/Text.zig");
const motions = @import("core/motions.zig");
const textobjects = @import("core/textobjects.zig");
const syntax_objects = @import("syntax/objects.zig");
const operators = @import("operators.zig");
const pairs = @import("pairs.zig");
const tags = @import("tags.zig");
const Picker = @import("picker/Picker.zig");
const textops = @import("textops.zig");
const indents = @import("core/indent.zig");
const comment = @import("core/comment.zig");

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
    /// Run from a menu (`SPC w r l`), the menu stays open for the next key
    /// (`l l h`), until a key it doesn't have (that key then acts as usual).
    sticky: bool = false,
    /// Works while the cursor is on a ghost line (otherwise the cursor
    /// returns to the text first, or the command is refused if it edits).
    ghost: bool = false,
    /// A program it runs: when that isn't installed, running the command
    /// just says so ("git isn't installed").
    needs: []const u8 = "",
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
    .{ .name = "cursors_in_selection", .doc = "Cursors on matches in the selection", .run = selectIn },
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
    .{ .name = "goto_implementation", .doc = "Go to implementations", .run = lspRequest(.implementation) },
    .{ .name = "code_action", .doc = "Code actions (fixes, refactors)", .run = lspRequest(.code_actions), .once = true },
    .{ .name = "workspace_symbols", .doc = "Symbols in the project", .run = lspRequest(.workspace_symbols), .once = true },
    .{ .name = "find_file_anywhere", .doc = "Find a file anywhere on disk", .run = openPicker(.files_anywhere), .once = true },
    .{ .name = "find_folder", .doc = "Find a folder anywhere (work there)", .run = openPicker(.folders_anywhere), .once = true },
    .{ .name = "todo_tag", .doc = "Write a todo tag (TODO, FIXME...)", .run = openPicker(.todo_tags), .once = true },
    .{ .name = "man_pages", .doc = "Manual pages (C functions, system calls)", .run = openPicker(.man), .once = true, .needs = "man" },
    .{ .name = "all_pickers", .doc = "Every picker", .run = openPicker(.pickers), .once = true },
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
    .{ .name = "paste_after", .doc = "Paste after", .run = pasteMode(false, false), .repeat = true },
    .{ .name = "paste_before", .doc = "Paste before", .run = pasteMode(true, false), .repeat = true },
    .{ .name = "paste_inline_after", .doc = "Paste inline after (a yanked line without its newline)", .run = pasteMode(false, true), .repeat = true },
    .{ .name = "paste_inline_before", .doc = "Paste inline before (a yanked line without its newline)", .run = pasteMode(true, true), .repeat = true },
    .{ .name = "replace_char", .doc = "Replace character", .run = replaceChar, .repeat = true, .takes_char = true },
    .{ .name = "shift_text_down", .doc = "Move line/selection down", .run = moveCmd(.down) },
    .{ .name = "shift_text_up", .doc = "Move line/selection up", .run = moveCmd(.up) },
    .{ .name = "shift_text_left", .doc = "Move line/selection left", .run = moveCmd(.left) },
    .{ .name = "shift_text_right", .doc = "Move line/selection right", .run = moveCmd(.right) },
    .{ .name = "join_lines", .doc = "Join lines", .run = joinLines, .repeat = true },
    .{ .name = "toggle_case_char", .doc = "Toggle case of character", .run = toggleCaseChar, .repeat = true },
    .{ .name = "undo", .doc = "Undo", .run = undo , .once = true },
    .{ .name = "redo", .doc = "Redo", .run = redo , .once = true },
    .{ .name = "append_semicolon", .doc = "Add ; at the end of the line", .run = appendSemicolon },
    .{ .name = "select_last_change", .doc = "Select the last change or yank", .run = selectLastChange, .once = true },
    .{ .name = "toggle_scratch", .doc = "Scratch pad", .run = toggleScratch, .once = true },
    .{ .name = "repeat_change", .doc = "Repeat last change", .run = repeatChange , .once = true },
    .{ .name = "record_macro", .doc = "Record macro (Q again to stop; QQ quits without saving)", .run = recordMacro, .takes_char = true, .once = true },
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
    .{ .name = "git_menu", .doc = "Git menu", .run = openPicker(.git_actions), .needs = "git" },
    .{ .name = "pick_windows", .doc = "Windows (split, close, resize, focus)", .run = openPicker(.windows) },
    .{ .name = "pick_toggles", .doc = "Toggles (every setting, the colour scheme, text size)", .run = openPicker(.toggles) },
    .{ .name = "jump_toggle", .doc = "Back to the last jump, and again: back here", .run = jumpToggle, .once = true },
    .{ .name = "leader_menu", .doc = "Leader menu (everything)", .run = openPicker(.leader), .once = true },
    .{ .name = "projects_menu", .doc = "Projects and sessions", .run = openPicker(.leader_projects) },
    .{ .name = "claude_menu", .doc = "Claude", .run = openPicker(.leader_claude) },
    .{ .name = "quit_menu", .doc = "Quit", .run = openPicker(.leader_quit) },
    .{ .name = "code_menu", .doc = "Code (rename, actions, format, definitions, symbols...)", .run = openPicker(.code_menu) },
    .{ .name = "git_commit", .doc = "Commit all changes", .run = gitAction(.commit), .needs = "git" },
    .{ .name = "git_push", .doc = "Push", .run = gitAction(.push), .needs = "git" },
    .{ .name = "git_pull", .doc = "Pull", .run = gitAction(.pull), .needs = "git" },
    .{ .name = "git_branches", .doc = "Switch / new branch", .run = openPicker(.git_branches), .needs = "git" },
    .{ .name = "git_changed_files", .doc = "Changed files", .run = openPicker(.git_changes), .needs = "git" },
    .{ .name = "git_init", .doc = "Make this a git repository", .run = gitAction(.init), .needs = "git" },
    .{ .name = "git_set_remote", .doc = "Set remote URL", .run = gitAction(.remote), .needs = "git" },
    .{ .name = "git_restore_hunk", .doc = "Restore hunk from HEAD", .run = gitCmd(.restore), .ghost = true, .needs = "git" },
    .{ .name = "git_next_hunk", .doc = "Next change", .run = gitCmd(.next), .ghost = true , .jump = true },
    .{ .name = "git_previous_hunk", .doc = "Previous change", .run = gitCmd(.previous), .ghost = true , .jump = true },
    .{ .name = "git_reload", .doc = "Reload HEAD", .run = gitCmd(.reload), .ghost = true },

    // Entering insert mode
    .{ .name = "insert_before", .doc = "Insert before cursor", .run = insertAt(cursorPos), .repeat = true },
    .{ .name = "insert_after", .doc = "Insert after cursor", .run = insertAt(afterCursorPos), .repeat = true },
    .{ .name = "insert_line_start", .doc = "Insert at line start", .run = insertAt(firstNonBlankPos), .repeat = true },
    .{ .name = "insert_line_end", .doc = "Insert at line end", .run = insertAt(lineEndPos), .repeat = true },
    .{ .name = "open_below", .doc = "Open line below", .run = openLine(.below), .repeat = true, .ghost = true },
    .{ .name = "open_above", .doc = "Open line above", .run = openLine(.above), .repeat = true, .ghost = true },
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
    .{ .name = "find_file", .doc = "Files (the project's folder; type to search below it)", .run = findFile },
    .{ .name = "switch_buffer", .doc = "Switch buffer", .run = openPicker(.buffers) },
    .{ .name = "kill_buffer", .doc = "Kill buffer", .run = killBuffer },
    .{ .name = "next_buffer", .doc = "Next buffer", .run = cycleBuffer(1) , .jump = true },
    .{ .name = "previous_buffer", .doc = "Previous buffer", .run = cycleBuffer(-1) , .jump = true },
    .{ .name = "switch_project", .doc = "Switch project", .run = openPicker(.projects), .once = true },
    .{ .name = "claude_panel", .doc = "Claude Code panel", .run = claudeCmd(.panel), .once = true, .needs = "claude" },
    .{ .name = "claude_send", .doc = "Send selection/file to Claude", .run = claudeCmd(.send), .once = true, .needs = "claude" },
    .{ .name = "claude_ask", .doc = "Ask Claude about the selection", .run = claudeCmd(.ask), .once = true, .needs = "claude" },
    .{ .name = "claude_accept", .doc = "Accept Claude's change", .run = claudeCmd(.accept), .once = true },
    .{ .name = "claude_reject", .doc = "Reject Claude's change", .run = claudeCmd(.reject), .once = true },
    .{ .name = "terminal_window", .doc = "Terminal here (in this window)", .run = termCmd(.window), .once = true },
    .{ .name = "terminal_toggle", .doc = "Terminal popup", .run = termCmd(.toggle), .once = true },
    .{ .name = "run_runner", .doc = "Code runner (commands run here)", .run = termCmd(.runner), .once = true },
    .{ .name = "run_shell", .doc = "Run a shell command (one-off)", .run = termCmd(.shell), .once = true },
    .{ .name = "run_command", .doc = "Run a command (multi-line editor)", .run = termCmd(.command), .once = true },
    .{ .name = "run_again", .doc = "Run the runner command again", .run = termCmd(.again), .once = true },
    .{ .name = "run_sql", .doc = "Run the SQL statement (or selection)", .run = runSql(false), .once = true },
    .{ .name = "run_sql_file", .doc = "Run the whole SQL file", .run = runSql(true), .once = true },
    .{ .name = "run_output", .doc = "Show run output", .run = termCmd(.output), .once = true },
    .{ .name = "run_errors", .doc = "Errors from the last run", .run = termCmd(.errors), .once = true },
    .{ .name = "debug_menu", .doc = "Debugger: stack, stepping, breakpoints", .run = debugCmd(.menu), .once = true },
    .{ .name = "debug_breakpoint", .doc = "Breakpoint on this line (toggle)", .run = debugCmd(.breakpoint), .once = true },
    .{ .name = "debug_next", .doc = "Debugger: next line", .run = debugCmd(.next), .once = true, .needs = "gdb" },
    .{ .name = "debug_step_in", .doc = "Debugger: step into the call", .run = debugCmd(.step_in), .once = true, .needs = "gdb" },
    .{ .name = "debug_finish", .doc = "Debugger: finish the function", .run = debugCmd(.step_out), .once = true, .needs = "gdb" },
    .{ .name = "debug_continue", .doc = "Debugger: continue", .run = debugCmd(.cont), .once = true, .needs = "gdb" },
    .{ .name = "debug_stop", .doc = "Debugger: stop the program", .run = debugCmd(.stop), .once = true },
    .{ .name = "quickfix_next", .doc = "Next quickfix entry", .run = qfCmd(.next), .once = true, .jump = true },
    .{ .name = "quickfix_previous", .doc = "Previous quickfix entry", .run = qfCmd(.previous), .once = true, .jump = true },
    .{ .name = "quickfix_list", .doc = "Quickfix list: errors, a run's or the project's", .run = qfCmd(.list), .once = true },
    .{ .name = "quickfix_clear", .doc = "Back to the project's errors", .run = qfCmd(.clear), .once = true },
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
    .{ .name = "window_border_left", .doc = "Border left", .run = windowCmd(.{ .border = .left }), .once = true, .sticky = true },
    .{ .name = "window_border_down", .doc = "Border down", .run = windowCmd(.{ .border = .down }), .once = true, .sticky = true },
    .{ .name = "window_border_up", .doc = "Border up", .run = windowCmd(.{ .border = .up }), .once = true, .sticky = true },
    .{ .name = "window_border_right", .doc = "Border right", .run = windowCmd(.{ .border = .right }), .once = true, .sticky = true },
    .{ .name = "window_balance_stay", .doc = "Equal sizes", .run = windowCmd(.balance), .once = true, .sticky = true },
    .{ .name = "command_picker", .doc = "Editor commands", .run = openPicker(.commands) },
    .{ .name = "resume_picker", .doc = "Resume last picker", .run = resumePicker },
    .{ .name = "smart_close", .doc = "Close (window, else buffer, else quit)", .run = smartClose, .once = true },
    .{ .name = "quit", .doc = "Quit", .run = quit },
    .{ .name = "save_and_quit", .doc = "Save all and quit", .run = saveAndQuit },
    .{ .name = "quit_without_saving", .doc = "Quit without saving", .run = quitWithoutSaving },

    // mini.nvim: comment, operators, align, splitjoin, trailspace.
    .{ .name = "comment", .doc = "Comment / uncomment", .run = operator(.comment), .repeat = true },
    .{ .name = "toggle_comment", .doc = "Comment / uncomment line(s)", .run = toggleComment, .repeat = true },
    .{ .name = "comment_object", .doc = "comment block", .run = commentObject, .hidden = true },
    .{ .name = "replace_with_register", .doc = "Replace with register", .run = operator(.replace), .repeat = true },
    .{ .name = "exchange", .doc = "Exchange (twice: swaps two texts)", .run = operator(.exchange) },
    .{ .name = "sort", .doc = "Sort lines / list items", .run = operator(.sort), .repeat = true },
    .{ .name = "multiply", .doc = "Duplicate", .run = operator(.multiply), .repeat = true },
    .{ .name = "replace_line", .doc = "Whole line", .run = operatorLine(.replace), .hidden = true },
    .{ .name = "exchange_line", .doc = "Whole line", .run = operatorLine(.exchange), .hidden = true },
    .{ .name = "multiply_line", .doc = "Whole line", .run = operatorLine(.multiply), .hidden = true },
    .{ .name = "align", .doc = "Align lines on a character", .run = operator(.@"align"), .repeat = true },
    .{ .name = "align_char", .doc = "Align on", .run = alignChar, .takes_char = true, .hidden = true },
    .{ .name = "split_join", .doc = "Split / join arguments", .run = splitJoin, .repeat = true },
    .{ .name = "trim_trailing_whitespace", .doc = "Trim trailing whitespace", .run = trimTrailing, .once = true },
    // mini.bracketed
    .{ .name = "next_diagnostic", .doc = "Next diagnostic", .run = bracketed(.diagnostic, true), .once = true, .jump = true },
    .{ .name = "previous_diagnostic", .doc = "Previous diagnostic", .run = bracketed(.diagnostic, false), .once = true, .jump = true },
    .{ .name = "next_conflict", .doc = "Next conflict marker", .run = bracketed(.conflict, true), .once = true, .jump = true },
    .{ .name = "previous_conflict", .doc = "Previous conflict marker", .run = bracketed(.conflict, false), .once = true, .jump = true },
    .{ .name = "next_comment", .doc = "Next comment block", .run = bracketed(.comment, true), .once = true, .jump = true },
    .{ .name = "previous_comment", .doc = "Previous comment block", .run = bracketed(.comment, false), .once = true, .jump = true },
    .{ .name = "indent_scope_top", .doc = "Top of indent scope", .run = motion(indentEdge(false), .linewise, .reset), .jump = true },
    .{ .name = "indent_scope_bottom", .doc = "Bottom of indent scope", .run = motion(indentEdge(true), .linewise, .reset), .jump = true },
    // More toggles
    .{ .name = "toggle_highlight_patterns", .doc = "Todo words and colours", .run = toggle("highlight_patterns", "todo and colour highlights") },
    .{ .name = "toggle_cursor_word", .doc = "Word under cursor", .run = toggle("cursor_word", "word under cursor highlight") },
    .{ .name = "toggle_indent_scope", .doc = "Indent scope guide", .run = toggle("indent_scope", "indent scope guide") },
    .{ .name = "toggle_wrap", .doc = "Line wrap", .run = toggle("wrap", "line wrap") },
    .{ .name = "toggle_code_lens", .doc = "Code lens", .run = toggle("code_lens", "code lens") },
    .{ .name = "toggle_home_filter", .doc = "Home search skips .git, node_modules, caches, build output", .run = toggle("home_filter", "home search filter") },
    .{ .name = "toggle_sticky_context", .doc = "Sticky context (the scope headers above the window)", .run = toggle("sticky_context", "sticky context") },
    .{ .name = "grow_selection", .doc = "Select the next node up the syntax tree", .run = structureCmd(.grow), .once = true },
    .{ .name = "shrink_selection", .doc = "Back to the selection before growing it", .run = structureCmd(.shrink), .once = true },
    .{ .name = "next_sibling", .doc = "To the next sibling node (argument, statement, field...)", .run = structureCmd(.next) },
    .{ .name = "previous_sibling", .doc = "To the previous sibling node", .run = structureCmd(.previous) },
    .{ .name = "swap_next", .doc = "Swap the node with the next sibling (carry it right)", .run = structureCmd(.swap_next), .repeat = true },
    .{ .name = "swap_previous", .doc = "Swap the node with the previous sibling (carry it left)", .run = structureCmd(.swap_previous), .repeat = true },
    .{ .name = "next_function", .doc = "To the next function", .run = structureCmd(.function_next), .jump = true },
    .{ .name = "previous_function", .doc = "To the previous function", .run = structureCmd(.function_previous), .jump = true },
    .{ .name = "cycle_case", .doc = "Next case: snake_case, camelCase, PascalCase, SCREAMING_CASE, kebab-case", .run = structureCmd(.case), .repeat = true },
    .{ .name = "toggle_trailing_space", .doc = "Trailing whitespace", .run = toggle("trailing_space", "trailing whitespace highlight") },
    .{ .name = "toggle_trim_on_save", .doc = "Trim whitespace on save", .run = toggle("trim_on_save", "trim trailing whitespace on save") },
    .{ .name = "toggle_icons", .doc = "File icons", .run = toggle("icons", "file icons") },
    .{ .name = "toggle_smooth_scroll", .doc = "Smooth scrolling", .run = toggle("smooth_scroll", "smooth scrolling") },
    .{ .name = "toggle_inlay_hints", .doc = "Type hints (from the server)", .run = toggle("inlay_hints", "inline type hints") },
    .{ .name = "toggle_git_blame", .doc = "Git blame on the cursor line", .run = toggle("git_blame", "inline git blame") },
    // Pickers and state
    .{ .name = "recent_files", .doc = "Recent files", .run = openPicker(.recent), .once = true },
    .{ .name = "frecent_files", .doc = "Frecent files (most used lately)", .run = openPicker(.frecent), .once = true },
    .{ .name = "search_todos", .doc = "Todo comments in project", .run = openPicker(.todos), .once = true },
    .{ .name = "pick_theme", .doc = "Colour scheme", .run = openPicker(.themes), .once = true },
    .{ .name = "message_history", .doc = "Messages", .run = openPicker(.messages), .once = true },
    .{ .name = "start_screen", .doc = "Start screen", .run = openPicker(.start), .once = true },
    .{ .name = "save_session", .doc = "Save session", .run = sessionCmd(.save), .once = true },
    .{ .name = "load_session", .doc = "Restore session", .run = sessionCmd(.load), .once = true },
    .{ .name = "set_mark", .doc = "Set mark (a-z here, A-Z anywhere)", .run = setMark, .takes_char = true, .once = true },
    .{ .name = "goto_mark_line", .doc = "To a mark's line", .run = gotoMark(false), .takes_char = true, .jump = true },
    .{ .name = "goto_mark", .doc = "To a mark", .run = gotoMark(true), .takes_char = true, .jump = true },
    .{ .name = "pick_mark", .doc = "Marks", .run = openPicker(.marks), .once = true },
    .{ .name = "pick_register", .doc = "Registers (Enter pastes)", .run = openPicker(.registers), .once = true },
    .{ .name = "undo_history", .doc = "Undo history", .run = openPicker(.undo), .once = true },
    .{ .name = "help_keys", .doc = "Keys and commands", .run = openPicker(.help), .once = true },
    .{ .name = "pick_color", .doc = "Colour wheel (edit the colour here)", .run = pickColor, .once = true },
    .{ .name = "git_line_commit", .doc = "Commit that changed this line", .run = gitLineCommit, .once = true, .needs = "git" },

    // Inside the picker
    .{ .name = "picker_next", .doc = "Next result", .run = pickerMove(1, .wrap), .hidden = true },
    .{ .name = "picker_previous", .doc = "Previous result", .run = pickerMove(-1, .wrap), .hidden = true },
    .{ .name = "picker_page_down", .doc = "Page down", .run = pickerMove(10, .clamp), .hidden = true },
    .{ .name = "picker_page_up", .doc = "Page up", .run = pickerMove(-10, .clamp), .hidden = true },
    .{ .name = "picker_to_quickfix", .doc = "Send results to quickfix", .run = qfCmd(.from_picker), .hidden = true },
    .{ .name = "picker_scope", .doc = "Picker: the next scope (project, open, file...)", .run = pickerScope, .once = true, .hidden = true },
    .{ .name = "picker_replace", .doc = "Grep picker: replace the matches across the project", .run = replaceCmd(.start), .once = true, .hidden = true },
    .{ .name = "replace_next", .doc = "Replace: next line", .run = replaceCmd(.next), .once = true, .hidden = true },
    .{ .name = "replace_previous", .doc = "Replace: previous line", .run = replaceCmd(.previous), .once = true, .hidden = true },
    .{ .name = "replace_skip_file", .doc = "Replace: skip (or take back) the whole file", .run = replaceCmd(.skip_file), .once = true, .hidden = true },
    .{ .name = "picker_accept", .doc = "Open the selection", .run = pickerAccept, .hidden = true },
    .{ .name = "picker_accept_alt", .doc = "Accept the other way (the runner: under the debugger)", .run = pickerAcceptAlt, .hidden = true },
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
    // Acting on the selected row (the file browser, the buffer list).
    .{ .name = "picker_new_folder", .doc = "Browser: new folder (buffers: new buffer)", .run = pickerOp(.new_folder), .hidden = true },
    .{ .name = "picker_new_file", .doc = "Browser: new file (buffers: new buffer)", .run = pickerOp(.new_file), .hidden = true },
    .{ .name = "picker_rename", .doc = "Browser: rename", .run = pickerOp(.rename), .hidden = true },
    .{ .name = "picker_move", .doc = "Browser: move", .run = pickerOp(.move), .hidden = true },
    .{ .name = "picker_delete", .doc = "Browser: delete (buffers: close it)", .run = pickerOp(.delete), .hidden = true },
    .{ .name = "picker_copy", .doc = "Browser: copy", .run = pickerOp(.copy), .hidden = true },
    .{ .name = "picker_paste", .doc = "Browser: paste here", .run = pickerOp(.paste), .hidden = true },

    // Text inputs (picker query, search prompt)
    .{ .name = "input_delete_char", .doc = "Delete a character", .run = inputEdit(.char), .hidden = true },
    .{ .name = "input_delete_word", .doc = "Delete a word", .run = inputEdit(.word), .hidden = true },
    .{ .name = "input_clear", .doc = "Clear the input", .run = inputEdit(.all), .hidden = true },
    .{ .name = "input_left", .doc = "Cursor left in the query", .run = inputMove(.left), .hidden = true },
    .{ .name = "input_right", .doc = "Cursor right in the query", .run = inputMove(.right), .hidden = true },
    .{ .name = "input_home", .doc = "Query start", .run = inputMove(.home), .hidden = true },
    .{ .name = "input_end", .doc = "Query end", .run = inputMove(.end), .hidden = true },
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
    /// The cursor's indent scope (`ai`: with its border lines).
    indent,
    /// A `{ }` block with its header line(s), as whole lines.
    statement,
    /// One item of a bracketed, comma-separated list (by the text alone).
    argument,
};

pub const ObjectSpec = struct {
    name: []const u8,
    doc: []const u8,
    /// Keys after `i`/`a` that select it (`ib`, `i(` and `i)` are all parens).
    keys: []const u8,
    kind: ObjectKind,
    /// Which-key labels when "inner X" / "around X" don't describe it.
    labels: ?[2][]const u8 = null,
    /// Also gets "next" / "previous" forms: `in(` `an(`, `iN(` `aN(`.
    seek: bool = true,
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
    .{ .name = "line", .doc = "line", .keys = "l", .kind = .line, .labels = .{ "in line", "all lines" }, .seek = false },
    .{ .name = "indent", .doc = "indent scope", .keys = "i", .kind = .indent, .seek = false },
    .{ .name = "statement", .doc = "statement (header + block)", .keys = "s", .kind = .statement },
    .{ .name = "tag", .doc = "<tag> block", .keys = "t", .kind = .tag },
    .{ .name = "function", .doc = "function", .keys = "f", .kind = .{ .syntax = .function } },
    .{ .name = "class", .doc = "class/struct", .keys = "c", .kind = .{ .syntax = .class } },
    .{ .name = "argument", .doc = "argument", .keys = "a", .kind = .argument },
};

/// Which instance of an object: the one at the cursor (seeking ahead when
/// not in one), or strictly the next / previous one (mini.ai's `n` / `l`;
/// `l` is the line object here, so "previous" is `N`).
const Which = enum { here, next, previous };

/// Per spec: `inner_X`, `around_X`; with `seek`, `inner_next_X`,
/// `around_next_X`, `inner_previous_X`, `around_previous_X`; and the motions
/// `goto_start_X` / `goto_end_X` (`g[` / `g]`: to the object's edges).
const text_object_commands = blk: {
    @setEvalBranchQuota(100_000);
    var n: usize = 0;
    for (text_object_specs) |spec| n += if (spec.seek) 8 else 4;
    var out: [n]Command = undefined;
    var i: usize = 0;
    for (text_object_specs) |spec| {
        for ([_]Which{ .here, .next, .previous }) |which| {
            if (which != .here and !spec.seek) continue;
            for ([_]textobjects.Scope{ .inner, .around }, 0..) |scope, j| {
                const plain = if (spec.labels) |l| l[j] else (if (scope == .inner) "inner " else "around ") ++ spec.doc;
                out[i] = switch (which) {
                    .here => .{ .name = @tagName(scope) ++ "_" ++ spec.name, .doc = plain, .run = textObject(spec.kind, scope, which) },
                    else => .{
                        .name = @tagName(scope) ++ "_" ++ @tagName(which) ++ "_" ++ spec.name,
                        .doc = @tagName(which) ++ " " ++ spec.doc,
                        .run = textObject(spec.kind, scope, which),
                    },
                };
                i += 1;
            }
        }
        out[i] = .{ .name = "goto_start_" ++ spec.name, .doc = "start of " ++ spec.doc, .run = objectEdge(spec.kind, false), .jump = true };
        out[i + 1] = .{ .name = "goto_end_" ++ spec.name, .doc = "end of " ++ spec.doc, .run = objectEdge(spec.kind, true), .jump = true };
        i += 2;
    }
    const result = out;
    break :blk result;
};

/// The object of `kind` at `pos`.
fn objectAt(ed: *Editor, comptime kind: ObjectKind, scope: textobjects.Scope, pos: usize, count: usize) ?textobjects.Range {
    const t = ed.text();
    return switch (kind) {
        .word => |big| textobjects.word(t, pos, scope, big, count),
        .quote => |q| textobjects.quote(t, pos, q, scope),
        .any_quote => textobjects.anyQuote(t, pos, scope),
        .any_bracket => textobjects.anyBracket(t, pos, scope, count),
        .bracket => |b| textobjects.bracket(t, pos, b[0], b[1], scope, count),
        .paragraph => textobjects.paragraph(t, pos, scope),
        .line => textobjects.lineObject(t, pos, scope),
        .tag => textobjects.tag(t, pos, scope, count),
        .syntax => |obj| if (ed.buffer.syntax) |*s| syntax_objects.find(s, t, pos, obj, scope, count) else null,
        .argument => textobjects.argument(t, pos, scope),
        .statement => textobjects.statement(t, pos, scope, count),
        .indent => blk: {
            const s = indents.scope(t, t.lineOf(pos), ed.options.tab_width, true) orelse break :blk null;
            if (scope == .inner) break :blk operators.linesRange(t, s.first, s.last);
            break :blk operators.linesRange(t, s.top orelse s.first, s.bottom orelse s.last);
        },
    };
}

/// Whether an object of `kind` can begin (going forward) or end (going
/// backward) at byte `b`: keeps the search for the next one cheap.
fn objectCandidate(comptime kind: ObjectKind, b: u8, forward: bool) bool {
    return switch (kind) {
        .bracket => |p| b == (if (forward) p[0] else p[1]),
        .any_bracket => std.mem.indexOfScalar(u8, if (forward) "([{" else ")]}", b) != null,
        .quote => |q| b == q,
        .any_quote => b == '"' or b == '\'' or b == '`',
        // A block starts at its `{` (the header is found from there).
        .statement => b == @as(u8, if (forward) '{' else '}'),
        // Arguments start after a bracket or comma, and end before one.
        .argument => true,
        else => b != ' ' and b != '\t' and b != '\n',
    };
}

/// The first object of `kind` that starts after the cursor (or the last
/// that ends before it), within a few thousand bytes.
fn seekObject(ed: *Editor, comptime kind: ObjectKind, scope: textobjects.Scope, pos: usize, forward: bool) ?textobjects.Range {
    const t = ed.text();
    const reach = 8000;
    if (forward) {
        var p = pos + 1;
        while (p < @min(t.len(), pos + reach)) : (p += 1) {
            if (!objectCandidate(kind, t.byteAt(p), true)) continue;
            const r = objectAt(ed, kind, scope, p, 1) orelse continue;
            if (r.start > pos) return r;
        }
        return null;
    }
    var p = pos;
    while (p > pos -| reach) {
        p -= 1;
        if (!objectCandidate(kind, t.byteAt(p), false)) continue;
        const r = objectAt(ed, kind, scope, p, 1) orelse continue;
        if (r.end <= pos) return r;
    }
    return null;
}

fn textObject(comptime kind: ObjectKind, comptime scope: textobjects.Scope, comptime which: Which) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const pos = ed.view.cursor;
            const r = switch (which) {
                .here => objectAt(ed, kind, scope, pos, c.count),
                .next => seekObject(ed, kind, scope, pos, true),
                .previous => seekObject(ed, kind, scope, pos, false),
            } orelse return fail(ed);
            switch (ed.mode) {
                .operator => try ed.applyPending(r),
                .visual => ed.selectRange(r),
                else => {},
            }
        }
    }.run;
}

/// `g[` / `g]` + an object's key: a motion to its first / last character.
fn objectEdge(comptime kind: ObjectKind, comptime end: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            const from = ed.view.cursor;
            const r = objectAt(ed, kind, .around, from, c.count) orelse return fail(ed);
            const to = if (!end) r.start else if (r.end > r.start) motions.prevChar(t, r.end) else r.start;
            try finishMotion(ed, from, to, if (end) .inclusive else .exclusive, .reset);
        }
    }.run;
}

/// `gc` after an operator: the block of comment lines at the cursor.
fn commentObject(c: Context) !void {
    const ed = c.ed;
    const t = ed.text();
    const b = comment.block(t, ed.cursorLine(), textops.commentStyle(ed, ed.cursorLine())) orelse return fail(ed);
    const r = operators.linesRange(t, b[0], b[1]);
    switch (ed.mode) {
        .operator => try ed.applyPending(r),
        .visual => ed.selectRange(r),
        else => {},
    }
}

/// `[i` / `]i`: the line above / below the cursor's indent scope (its
/// border); pressed again it goes on to the next scope out.
fn indentEdge(comptime bottom: bool) Target {
    return struct {
        fn target(ed: *Editor, from: usize, _: Context) ?usize {
            const t = ed.text();
            const s = indents.scope(t, t.lineOf(from), ed.options.tab_width, false) orelse return null;
            const line = if (bottom) s.bottom orelse s.last else s.top orelse s.first;
            return motions.firstNonBlank(t, line);
        }
    }.target;
}

/// A doubled mini operator (`grr`, `gxx`, `gmm`): the whole line. After
/// another operator the key means nothing (`dr` is not `dd`).
fn operatorLine(comptime op: Operator) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            if (c.ed.pendingOperator() != op) return c.ed.resetCommand();
            try operateLine(c);
        }
    }.run;
}

/// `<C-/>`: comments or uncomments [count] lines (visual: the selected
/// lines) in any mode. The cursor stays on the text it was on.
fn toggleComment(c: Context) !void {
    const ed = c.ed;
    const t = ed.text();
    const line = ed.cursorLine();
    var first = line;
    var last = @min(line + c.count - 1, t.lineCount() - 1);
    if (ed.mode == .visual) {
        first = t.lineOf(@min(ed.view.anchor, ed.view.cursor));
        last = t.lineOf(@max(ed.view.anchor, ed.view.cursor));
        ed.exitVisual();
    }
    const col = ed.view.cursor - t.lineStart(line);
    const indent = motions.firstNonBlank(t, line) - t.lineStart(line);
    const old_len = t.lineLen(line);
    try textops.toggleComment(ed, first, last);
    // The prefix came or went before the cursor: move with the text.
    const new_len = t.lineLen(line);
    const moved = if (col < indent) col else if (new_len >= old_len) col + (new_len - old_len) else col -| (old_len - new_len);
    ed.setCursor(t.lineStart(line) + @min(moved, new_len));
}

fn alignChar(c: Context) !void {
    c.ed.capture_repeatable = true;
    try textops.alignLines(c.ed, c.ed.align_range, c.char);
}

fn splitJoin(c: Context) !void {
    try textops.splitJoin(c.ed);
}

fn trimTrailing(c: Context) !void {
    const n = try textops.trimTrailing(c.ed);
    c.ed.setMessage(.info, "trimmed {d} line(s)", .{n});
}

fn bracketed(comptime what: enum { diagnostic, conflict, comment }, comptime forward: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            for (0..c.count) |_| switch (what) {
                .diagnostic => c.ed.jumpDiagnostic(forward),
                .conflict => c.ed.jumpConflict(forward),
                .comment => c.ed.jumpComment(forward),
            };
        }
    }.run;
}

fn sessionCmd(comptime what: enum { save, load }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (what) {
                .save => ed.saveSession(true),
                .load => if (!ed.restoreSession(ed.projectRoot())) ed.setMessage(.info, "no saved session for this project", .{}),
            }
        }
    }.run;
}

fn setMark(c: Context) !void {
    c.ed.setMark(c.char);
}

/// `'x` (the mark's line) and `` `x `` (the exact place): motions inside
/// this buffer, a jump when the mark is in another file.
fn gotoMark(comptime exact: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const m = ed.findMark(c.char) orelse {
                fail(ed);
                return ed.setMessage(.info, "mark {u} is not set", .{c.char});
            };
            if (m.buffer != ed.buffer) {
                if (ed.mode != .normal) return fail(ed);
                try ed.goMark(m.*, exact);
                return;
            }
            const t = ed.text();
            const pos = @min(m.pos, t.len());
            const from = ed.view.cursor;
            ed.revealLine(t.lineOf(pos));
            if (exact) return finishMotion(ed, from, pos, .exclusive, .reset);
            try finishMotion(ed, from, motions.firstNonBlank(t, t.lineOf(pos)), .linewise, .reset);
        }
    }.run;
}

fn pickColor(c: Context) !void {
    c.ed.openColorPicker();
}

fn gitLineCommit(c: Context) !void {
    try c.ed.showLineCommit();
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
/// The index of command `name` in `all`.
pub fn indexOf(name: []const u8) ?usize {
    for (&all, 0..) |*c, i| if (std.mem.eql(u8, c.name, name)) return i;
    return null;
}

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
            ed.find_shown = true;
            if (ed.mode != .operator) {
                ed.find_dot = true;
                ed.snipe_dot = false;
            }
            // `f` as a motion looks along the line from its start, wherever
            // the cursor is, so one key finds the first match and `;` walks
            // on to the rest. (After an operator, `f` still starts at the
            // cursor: `dfx` deletes forward.)
            if (forward and !till and ed.mode != .operator) {
                const t = ed.text();
                const ls = t.lineStart(t.lineOf(from));
                const le = t.lineEnd(t.lineOf(from));
                const line = t.slice(ls, le);
                var at: usize = 0;
                var n: usize = 0;
                while (motions.indexOfFold(line, at, f.needle())) |m| {
                    n += 1;
                    if (n == c.count) return ls + m;
                    at = m + 1;
                }
            }
            return motions.findAcross(ed.text(), from, f, c.count, false);
        }
    }.target;
}

fn repeatFind(comptime reverse: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            if (ed.snipe_dot) {
                const next = comptime searchNextCmd(reverse);
                return next(c);
            }
            var f = ed.last_find orelse return fail(ed);
            if (reverse) f.forward = !f.forward;
            const from = ed.view.cursor;
            const to = motions.findAcross(ed.text(), from, f, c.count, true) orelse return fail(ed);
            ed.find_shown = true;
            ed.find_dot = true;
            ed.snipe_dot = false;
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
                    // A yank leaves the cursor where it was before `v`.
                    if (op == .yank) ed.setCursor(@min(ed.visual_origin, ed.text().len()));
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
            // Wrapped lines and lens rows: a row at a time on screen (lens
            // rows skipped); a count moves whole lines.
            if (ed.layered() and ed.mode == .normal and ed.ghost == null) {
                if (c.has_count) {
                    const t = ed.text();
                    const line = ed.stepVisible(t.lineOf(ed.view.cursor), delta);
                    return ed.setCursorRow(.{ .line = line, .sub = @intCast(ed.lensRows(line)) });
                }
                var r = ed.cursorRow();
                var n = @abs(delta);
                while (n > 0) : (n -= 1) {
                    var next = if (dir > 0) ed.nextRow(r) else ed.prevRow(r);
                    // Over a lens row (it isn't text).
                    while (next.ghost == null and next.sub < ed.lensRows(next.line)) {
                        const further = if (dir > 0) ed.nextRow(next) else ed.prevRow(next);
                        if (further.eql(next)) break;
                        next = further;
                    }
                    if (next.eql(r) or (next.ghost == null and next.sub < ed.lensRows(next.line))) break;
                    r = next;
                }
                return ed.setCursorRow(r);
            }
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

fn gitAction(comptime action: enum { commit, push, pull, remote, init }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            switch (action) {
                .commit => c.ed.gitCommitPrompt(),
                .push => try c.ed.gitPush(),
                .pull => try c.ed.gitPull(),
                .remote => try c.ed.gitRemotePrompt(),
                .init => try c.ed.gitInit(),
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

/// `p` / `P`; `gp` / `gP` (`inline`): as text within the line, so a line
/// yanked whole goes inside `foo()` instead of below: without its newline
/// and its first line's indent.
fn pasteMode(comptime before: bool, comptime inline_: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const v = ed.registers.get(c.register) orelse return ed.setMessage(.err, "nothing to paste", .{});
            // Copy it: replacing a selection below may overwrite registers.
            const text = try ed.gpa.dupe(u8, if (inline_) inlineText(v.text) else v.text);
            defer ed.gpa.free(text);
            if (text.len == 0) return;
            const value: @TypeOf(v) = .{ .text = text, .linewise = v.linewise and !inline_ };
            if (ed.mode == .visual) {
                // Replace the selection, keeping the pasted text in the register.
                const r = ed.visualRange();
                ed.exitVisual();
                try operators.apply(ed, .delete, r, '_');
                return operators.paste(ed, value, c.count, true, true);
            }
            try operators.paste(ed, value, c.count, before, !before);
        }
    }.run;
}

/// Text for an inline paste: no leading indent, no trailing newline.
fn inlineText(text: []const u8) []const u8 {
    return std.mem.trimStart(u8, std.mem.trimEnd(u8, text, "\r\n"), " \t");
}

fn structureCmd(comptime action: enum { grow, shrink, next, previous, swap_next, swap_previous, function_next, function_previous, case }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            for (0..@max(c.count, 1)) |_| switch (action) {
                .grow => try ed.growSelection(),
                .shrink => ed.shrinkSelection(),
                .next => ed.siblingNode(true),
                .previous => ed.siblingNode(false),
                .swap_next => try ed.swapNode(true),
                .swap_previous => try ed.swapNode(false),
                .function_next => ed.functionJump(true),
                .function_previous => ed.functionJump(false),
                .case => try ed.cycleCase(),
            };
        }
    }.run;
}

/// `SPC SPC`: the explorer at the project's root; typing searches every
/// file below it as well as its own entries.
fn findFile(c: Context) !void {
    const root = try c.ed.gpa.dupe(u8, c.ed.projectRoot());
    defer c.ed.gpa.free(root);
    try c.ed.setBrowseDir(root);
    try openPicker(.browse)(c);
}

fn jumpToggle(c: Context) !void {
    try c.ed.jumpToggle();
}

fn pickerScope(c: Context) !void {
    try c.ed.pickerNextScope();
}

fn replaceCmd(comptime action: enum { start, next, previous, skip_file }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            if (action == .start) return ed.startReplace();
            const r = ed.replace orelse return;
            switch (action) {
                .start => unreachable,
                .next => r.move(1),
                .previous => r.move(-1),
                .skip_file => r.toggleFile(),
            }
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

const MoveDir = enum { down, up, left, right };

fn moveCmd(comptime dir: MoveDir) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            if (c.ed.ghost != null) return;
            for (0..c.count) |_| {
                const moved = switch (dir) {
                    .down, .up => try moveLines(c.ed, dir == .down),
                    .left, .right => try moveSideways(c.ed, dir == .right),
                };
                if (!moved) break;
            }
        }
    }.run;
}

/// mini.move: swaps the current line (or the selected lines) with the one
/// below/above. The cursor and selection travel with the text.
fn moveLines(ed: *Editor, to_down: bool) !bool {
    const t = ed.text();
    const visual = ed.mode == .visual;
    const a = t.lineOf(if (visual) @min(ed.view.anchor, ed.view.cursor) else ed.view.cursor);
    const b = t.lineOf(if (visual) @max(ed.view.anchor, ed.view.cursor) else ed.view.cursor);
    const gpa = ed.gpa;
    if (to_down) {
        if (b + 1 >= t.lineCount()) return false;
        const other = try gpa.dupe(u8, t.lineSlice(b + 1));
        defer gpa.free(other);
        const shift = other.len + 1;
        const cur = ed.view.cursor + shift;
        const anchor = ed.view.anchor + shift;
        try ed.deleteRangeKeepCursor(t.lineEnd(b), t.lineEnd(b + 1));
        const ins = try std.mem.concat(gpa, u8, &.{ other, "\n" });
        defer gpa.free(ins);
        try ed.insertAt(ed.text().lineStart(a), ins);
        ed.view.cursor = cur;
        ed.view.anchor = anchor;
    } else {
        if (a == 0) return false;
        const other = try gpa.dupe(u8, t.lineSlice(a - 1));
        defer gpa.free(other);
        const shift = other.len + 1;
        const cur = ed.view.cursor - shift;
        const anchor = ed.view.anchor -| shift;
        const old_end = t.lineEnd(b);
        try ed.deleteRangeKeepCursor(t.lineStart(a - 1), t.lineStart(a));
        const ins = try std.mem.concat(gpa, u8, &.{ "\n", other });
        defer gpa.free(ins);
        try ed.insertAt(old_end - shift, ins);
        ed.view.cursor = cur;
        ed.view.anchor = anchor;
    }
    ed.view.want_col = null;
    ed.scrollToCursor();
    return true;
}

/// mini.move: shifts the line (or linewise selection) by an indent level, or
/// moves a charwise selection one character along its line.
fn moveSideways(ed: *Editor, to_right: bool) !bool {
    const t = ed.text();
    if (ed.mode == .visual and !ed.visual_line) {
        const r = ed.visualRange();
        const line = t.lineOf(r.start);
        if (t.lineOf(r.end -| 1) != line) return false;
        var delta: usize = undefined;
        if (to_right) {
            if (r.end >= t.lineEnd(line)) return false;
            const next = motions.nextChar(t, r.end);
            delta = next - r.end;
            var buf: [8]u8 = undefined;
            @memcpy(buf[0..delta], t.slice(r.end, next));
            try ed.deleteRangeKeepCursor(r.end, next);
            try ed.insertAt(r.start, buf[0..delta]);
            ed.view.cursor += delta;
            ed.view.anchor += delta;
        } else {
            if (r.start <= t.lineStart(line)) return false;
            const prev = motions.prevChar(t, r.start);
            delta = r.start - prev;
            var buf: [8]u8 = undefined;
            @memcpy(buf[0..delta], t.slice(prev, r.start));
            try ed.deleteRangeKeepCursor(prev, r.start);
            try ed.insertAt(r.end - delta, buf[0..delta]);
            ed.view.cursor -= delta;
            ed.view.anchor -= delta;
        }
        ed.scrollToCursor();
        return true;
    }
    const visual = ed.mode == .visual;
    const range = if (visual) ed.visualRange() else operators.linesRange(t, ed.cursorLine(), ed.cursorLine());
    const col = ed.view.cursor - t.lineStart(t.lineOf(ed.view.cursor));
    const old_len = t.lineLen(t.lineOf(ed.view.cursor));
    const anchor_line = t.lineOf(ed.view.anchor);
    const anchor_col = ed.view.anchor - t.lineStart(anchor_line);
    const anchor_len = t.lineLen(anchor_line);
    const cur_line = t.lineOf(ed.view.cursor);
    try operators.apply(ed, if (to_right) .indent else .outdent, range, null);
    const nt = ed.text();
    if (visual) {
        const na = nt.lineStart(anchor_line) + @min(nt.lineLen(anchor_line), anchor_col + nt.lineLen(anchor_line) -| anchor_len);
        ed.view.anchor = na;
    }
    const grown = nt.lineLen(cur_line);
    const pos = if (grown >= old_len) col + (grown - old_len) else col -| (old_len - grown);
    ed.view.cursor = nt.lineStart(cur_line) + @min(pos, grown);
    ed.view.want_col = null;
    return true;
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

/// `.`: the find just made again (`f` then `.` walks the matches), else the
/// last change.
fn repeatChange(c: Context) !void {
    if (c.ed.snipe_dot) {
        const next = comptime searchNextCmd(false);
        return next(c);
    }
    if (c.ed.find_dot and c.ed.last_find != null) {
        const again = comptime ghostFind(.repeat, repeatFind(false));
        return again(c);
    }
    try c.ed.repeatLastChange(c.count, c.has_count);
}

fn recordMacro(c: Context) !void {
    // `QQ` quits at once, unsaved changes or not (like `SPC Q Q`). Macros
    // record into lower-case registers: `Qq` is the one for register q.
    if (c.char == 'Q') return quitWithoutSaving(c);
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
            // `v` again in charwise visual: line mode, over every line the
            // selection touches.
            if (!line and !ed.visual_line) {
                ed.visual_line = true;
                return;
            }
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

const OpenWhere = enum { above, below };

fn openLine(comptime asked: OpenWhere) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const t = ed.text();
            var where = asked;
            var line = ed.cursorLine();
            // On a ghost line (read-only): the new line goes in the text
            // next to the ghost lines, `O` after the line above them and
            // `o` before the line below them.
            if (ed.ghost) |g| {
                ed.ghost = null;
                const last = t.lineCount() - 1;
                if (asked == .above and g.line > 0) {
                    line = g.line - 1;
                    where = .below;
                } else if (g.line <= last) {
                    line = g.line;
                    where = .above;
                } else {
                    line = last;
                    where = .below;
                }
            }
            // Copy the indent first: inserting may reallocate the text. Below a
            // line that opens a block it is a level deeper, and so is a line
            // above the one that closes it.
            var indent_buf: [256]u8 = undefined;
            var indent: []const u8 = undefined;
            if (where == .below) {
                indent = ed.newlineIndent(line, t.lineEnd(line), &indent_buf);
            } else if (ed.isBlankLine(t, line)) {
                // Above a blank line: where the code above it is.
                indent = ed.contextIndent(line, &indent_buf);
            } else {
                const own = copyIndent(ed, line, &indent_buf);
                const first = motions.firstNonBlank(t, line);
                const closes = first < t.lineEnd(line) and std.mem.indexOfScalar(u8, "})]", t.byteAt(first)) != null;
                var unit_buf: [16]u8 = undefined;
                const unit: []const u8 = if (closes) ed.indentUnit(&unit_buf) else "";
                if (own.len + unit.len <= indent_buf.len) @memcpy(indent_buf[own.len..][0..unit.len], unit);
                indent = indent_buf[0..@min(own.len + unit.len, indent_buf.len)];
            }
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
    // Arguments never filled in don't stay behind as text.
    try ed.dropUnfilledPlaceholders();
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
    if (try tags.splitTags(c.ed)) return;
    if (try pairs.splitPair(c.ed)) return;
    // The line's indentation, a level deeper after an opening bracket.
    var indent_buf: [256]u8 = undefined;
    const indent = c.ed.newlineIndent(c.ed.cursorLine(), c.ed.view.cursor, &indent_buf);
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

/// `SPC l f`: the file, or in visual mode the selected lines.
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
    // After an Emmet abbreviation in markup: its markup.
    if (try c.ed.expandEmmet()) return;
    // Before a closing bracket or quote: step over it (`f("x|")` -> `f("x"|)`).
    if (try pairs.tabOut(c.ed)) return;
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
    if (ed.usesTabs()) return ed.insertText("\t");
    const col = ed.cursorCol();
    const spaces = motions.nextTabStop(col, @max(ed.indentWidth(), 1)) - col;
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
        .sort => try operateLine(c), // `gss`
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

fn termCmd(comptime action: enum { toggle, window, runner, command, again, output, errors, shell }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .toggle => try ed.toggleShell(),
                .window => ed.openTermWindow() catch |err| ed.setMessage(.err, "could not start the shell: {s}", .{@errorName(err)}),
                .runner => try ed.runPrompt(true),
                .shell => ed.shellPrompt(),
                .command => try ed.runPrompt(false),
                .again => try ed.runAgain(),
                .output => ed.showRunOutput(),
                .errors => try ed.showRunErrors(),
            }
        }
    }.run;
}

fn debugCmd(comptime action: enum { menu, breakpoint, next, step_in, step_out, cont, stop }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            switch (action) {
                .menu => try debugging.open(ed),
                .breakpoint => try debugging.toggleBreakpoint(ed),
                .next => try debugging.step(ed, .next),
                .step_in => try debugging.step(ed, .step_in),
                .step_out => try debugging.step(ed, .step_out),
                .cont => try debugging.step(ed, .cont),
                .stop => debugging.stop(ed),
            }
        }
    }.run;
}

fn qfCmd(comptime action: enum { next, previous, list, from_picker, clear }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            switch (action) {
                .next => try c.ed.stepQuickfix(true, c.count),
                .previous => try c.ed.stepQuickfix(false, c.count),
                .list => try c.ed.showQuickfix(),
                .from_picker => try c.ed.pickerToQuickfix(),
                .clear => c.ed.resetQuickfix(),
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
    border: Editor.Windows.Dir,
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
                .border => |d| {
                    // Two columns (or one row) per press.
                    const cells: f32 = if (d == .left or d == .right) 2 else 1;
                    if (!ed.windows.moveBorder(ed.window, d, cells * @as(f32, @floatFromInt(c.count))))
                        ed.setMessage(.info, "no border that way", .{});
                },
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
    for (ed.window_list.items) |w| if (w.term) |t| {
        const claude = ed.isClaudeTerm(t);
        ed.focusWindow(w);
        ed.closeWindow();
        if (claude) ed.setMessage(.info, "Claude panel hidden (SPC a a shows it again)", .{}) else ed.setMessage(.info, "terminal closed", .{});
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
            const ed = c.ed;
            // From a selection (within one line): it is the query.
            var buf: [200]u8 = undefined;
            var query: []const u8 = "";
            // A menu keeps the selection for the row it runs.
            const menu = @import("picker/sources.zig").rowKeys(kind).len > 0;
            if (ed.mode == .visual and !menu) {
                const r = ed.visualRange();
                const text = std.mem.trim(u8, ed.text().slice(r.start, r.end), " \t");
                if (!r.linewise and text.len > 0 and text.len < buf.len and std.mem.indexOfScalar(u8, text, '\n') == null) {
                    // A first character that would switch pickers (`@import`
                    // is not a request for symbols) stays text behind a space.
                    const guard = @intFromBool(@import("picker/sources.zig").byPrefix(text[0]) != null);
                    buf[0] = ' ';
                    @memcpy(buf[guard..][0..text.len], text);
                    query = buf[0 .. text.len + guard];
                }
                ed.exitVisual();
            }
            try ed.openPicker(kind, query);
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
            const p = c.ed.picker orelse return;
            c.ed.mode = if (m == .normal) .picker_normal else .picker;
            // Like vim, <Esc> leaves the cursor on the last character typed.
            if (m == .normal) p.query.cursor = p.query.prev(p.query.cursor);
            c.ed.query_op = null;
            c.ed.query_obj = null;
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

/// Keys that act on the selected row: file operations in the browser, and
/// in the buffer list closing a buffer or starting a new one.
fn pickerOp(comptime op: Editor.BrowseOp) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const p = ed.picker orelse return;
            switch (p.kind) {
                .browse => try ed.browseOp(op),
                .runner => if (op == .delete) try ed.pickerForgetCommand(),
                // The quickfix list: back to the project's live errors.
                .quickfix => if (op == .delete) {
                    ed.closePicker();
                    ed.resetQuickfix();
                },
                .buffers => switch (op) {
                    .delete => try ed.pickerKillBuffer(),
                    .new_folder, .new_file => {
                        ed.closePicker();
                        try ed.newBuffer();
                    },
                    else => {},
                },
                else => {},
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
                        // Nothing typed: the start of a path from the root.
                        if (empty) return ed.browseInto("/");
                        // What you typed names a folder here (`src`,
                        // `src/core`, `~/code`): into it.
                        {
                            const typed = try ed.browsePath(p.query.items());
                            defer ed.gpa.free(typed);
                            if (std.Io.Dir.cwd().openDir(ed.io, typed, .{})) |d| {
                                var dir = d;
                                dir.close(ed.io);
                                const name = try ed.gpa.dupe(u8, p.query.items());
                                defer ed.gpa.free(name);
                                return ed.browseInto(name);
                            } else |_| {}
                        }
                        p.sync();
                        if (p.itemAt(p.selected)) |item| if (std.mem.endsWith(u8, item.text, "/")) {
                            const name = try ed.gpa.dupe(u8, item.text);
                            defer ed.gpa.free(name);
                            return ed.browseInto(name);
                        };
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

fn inputMove(comptime to: enum { left, right, home, end }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const input = c.ed.activeInput() orelse return;
            input.cursor = switch (to) {
                .left => input.prev(input.cursor),
                .right => input.next(input.cursor),
                .home => 0,
                .end => input.items().len,
            };
        }
    }.run;
}

fn inputEdit(comptime what: enum { char, word, all }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const ed = c.ed;
            const input = ed.activeInput() orelse return;
            if (what == .char and input.items().len == 0) {
                // <BS> on an empty `/` or snipe prompt cancels it, like vim; in
                // the file browser it goes up a folder. Boxed prompts (run a
                // command, rename, commit...) stay open: clearing the text is
                // how you start over, and a held <BS> shouldn't close them.
                if (ed.mode == .search) {
                    if (ed.search_prompt) |sp| if (sp.kind.boxed()) return;
                    return ed.cancelSearch();
                }
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

fn selectIn(c: Context) !void {
    c.ed.startSelectIn();
}

fn runSql(comptime whole: bool) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            try c.ed.runSql(whole);
        }
    }.run;
}

/// Insert-mode <C-;>: a `;` at the end of the line (unless one is there),
/// the cursor staying where it is.
fn appendSemicolon(c: Context) !void {
    const ed = c.ed;
    const t = ed.text();
    const line = ed.cursorLine();
    const ls = t.lineStart(line);
    const body = std.mem.trimEnd(u8, t.slice(ls, t.lineEnd(line)), " \t");
    if (std.mem.endsWith(u8, body, ";")) return;
    try ed.insertAt(ls + body.len, ";");
}

fn selectLastChange(c: Context) !void {
    c.ed.selectLastChange();
}

fn toggleScratch(c: Context) !void {
    try c.ed.toggleScratch();
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

fn lspRequest(comptime what: enum { definition, references, hover, implementation, code_actions, workspace_symbols }) Handler {
    return &struct {
        fn run(c: Context) anyerror!void {
            const l = c.ed.languageServer() orelse return;
            switch (what) {
                .definition => try l.requestDefinition(c.ed),
                .references => try l.requestReferences(c.ed),
                .hover => try l.requestHover(c.ed),
                .implementation => try l.requestImplementation(c.ed),
                .code_actions => {
                    // The cursor's line, or the selected lines.
                    const ed = c.ed;
                    const t = ed.text();
                    var first = ed.cursorLine();
                    var last = first;
                    if (ed.mode == .visual) {
                        first = t.lineOf(@min(ed.view.anchor, ed.view.cursor));
                        last = t.lineOf(@max(ed.view.anchor, ed.view.cursor));
                        ed.exitVisual();
                    }
                    try l.requestCodeActions(ed, first, last);
                },
                .workspace_symbols => try c.ed.showWorkspaceSymbols(),
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
            if (ed.completionShown()) |comp| return switch (action) {
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
    if (c.ed.exchange_mark != null) {
        c.ed.exchange_mark = null;
        c.ed.setMessage(.info, "exchange cancelled", .{});
    }
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

fn pickerAcceptAlt(c: Context) !void {
    try c.ed.acceptPickerAlt();
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
