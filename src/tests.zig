//! Test root for everything that runs headlessly (no raylib).

comptime {
    _ = @import("input/keys.zig");
    _ = @import("input/keymap.zig");
    _ = @import("core/Text.zig");
    _ = @import("core/motions.zig");
    _ = @import("core/Buffer.zig");
    _ = @import("core/Folds.zig");
    _ = @import("git/diff.zig");
    _ = @import("git/Git.zig");
    _ = @import("core/History.zig");
    _ = @import("core/textobjects.zig");
    _ = @import("Registers.zig");
    _ = @import("syntax/Regex.zig");
    _ = @import("syntax/highlight.zig");
    _ = @import("syntax/languages.zig");
    _ = @import("syntax/Syntax.zig");
    _ = @import("syntax/objects.zig");
    _ = @import("input/LineInput.zig");
    _ = @import("core/search.zig");
    _ = @import("lsp/Client.zig");
    _ = @import("lsp/Completion.zig");
    _ = @import("picker/sources.zig");
    _ = @import("picker/fuzzy.zig");
    _ = @import("picker/Items.zig");
    _ = @import("picker/Engine.zig");
    _ = @import("picker/Picker.zig");
    _ = @import("commands.zig");
    _ = @import("Editor.zig");
    _ = @import("Windows.zig");
    _ = @import("terminal/Pty.zig");
    _ = @import("terminal/RunMemory.zig");
    _ = @import("terminal/Terminal.zig");
    _ = @import("terminal/errors.zig");
}
