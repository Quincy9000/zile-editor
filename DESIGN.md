# edit: design

A modal text editor in Zig 0.17, rendered with raylib. It uses vim/neovim editing
(operator then motion: `dw`, `ci"`) with Doom Emacs-style leader menus, and works
the way modern editors do: one picker for everything, built-in LSP and
tree-sitter, and an embedded terminal (libghostty-vt).

## Principles

1. **One command registry.** Every action is a named command with a doc string
   (`src/commands.zig`). Keys bind to commands, the picker lists commands, and
   help is generated from them. There is no ex command language.
2. **One picker engine.** Files, buffers, commands, symbols, references,
   diagnostics, code actions, help, themes and text prompts (rename, save-as) are
   all sources feeding a fuzzy-matched list. Completion reuses the engine with a
   popup anchored at the cursor.
3. **The main thread owns editor state.** Worker threads (LSP readers, file
   walker, grep, matcher) post messages to a `std.Io.Queue` that the main loop
   drains each frame. The one exception is the terminal (see below).
4. **Core logic is headless.** `Editor` and everything under `core/` and `input/`
   (except `glfw.zig`) have no raylib dependency and are unit-tested by feeding
   key notation: `ed.feed("ihello<Esc>")`.
5. **Comptime over repetition.** Command families are generated from building
   blocks, and default keybindings are parsed and validated at compile time.

## Layout

```
src/
  main.zig            window, main loop: drain input -> update -> draw
  Editor.zig          all editor state; handleKey; editing primitives
  commands.zig        command registry (comptime-generated families)
  core/
    Text.zig          text storage (array + line index now; rope later)
    Buffer.zig        Text + file association; atomic save; eol/CRLF handling
    motions.zig       pure (text, pos) -> pos motions
  input/
    keys.zig          KeyEvent, vim notation parse/format
    keymap.zig        mode -> key sequence -> command
    glfw.zig          ordered key/char stream from chained GLFW callbacks
  ui/
    Font.zig  Theme.zig  render.zig
planned: picker/  syntax/  lsp/  terminal/  ui/layout.zig (split tree)
```

## Keybindings (Doom Emacs style)

Vim motions, operators and text objects stay on single keys. Every other command
lives in a nested leader menu under `SPC`, shown by the which-key popup as soon
as a prefix is typed (groups as `+name`, commands by their doc). There are no
ctrl-chord commands and no ex command line. Default bindings and groups are
tables in `input/keymap.zig`, validated at compile time. A group with nothing
under it is a compile error.

| keys | group / command | status |
|---|---|---|
| `SPC f s` | save file | done |
| `SPC q q` / `SPC q s` / `SPC q Q` | quit (refuses if any buffer is unsaved) / save all and quit / quit without saving | done |
| `SPC SPC`, `SPC .`, `SPC f f` | find file (+ create) | done (`SPC .`/`SPC f f` to become a directory browser) |
| `SPC ,`, `SPC b b` / `SPC b k` | switch / kill buffer | done |
| `SPC b n` / `SPC b p` | next / previous buffer | done |
| `SPC :` | command picker (M-x) | done |
| `SPC '` | resume last picker | done |
| `SPC f r` | recent files | picker |
| `SPC s s` | search buffer lines | done |
| `/` `?` `n` `N` `*` `#` | in-buffer search (incremental, highlighted) | done |
| `s` | **snipe** (ours, replaces vim's `s`): type text, jumps as soon as one match is left on screen; `RET` = first match, then `n`/`N`; works after operators (`ds…`) and in visual mode | done |
| `SPC /`, `SPC s p` | live fuzzy grep over every project line | done |
| `gd` / `SPC c d`, `r` / `gr` / `SPC c D` | definition, references (zls); `r` is ours, replacing vim's replace-char | done |
| `K` / `SPC c k` | hover docs (zls) | done |
| `SPC c x` | diagnostics picker (zls) | done |
| `SPC c l` | go to symbol: zls documentSymbol, else a tree-sitter outline | done |
| `SPC s i` / `SPC c j` | symbols in buffer / workspace | LSP |
| `SPC c r` (also `SPC c .`) | rename symbol (zls): prompt prefilled with the name, edits applied across files as one undo step each | done |
| `SPC c a` / `SPC c f` | code action / format | LSP |
| `SPC w v` / `SPC w s` / `SPC w hjkl` / `SPC w d` | splits | layout |
| `SPC o t` | open terminal | terminal |
| `SPC h k` / `SPC h f` / `SPC h h` | describe key / command, search help | picker |

## Picker

There is one picker. A prefix typed into it switches the source, so any picker
can become any other:

| prefix | source |
|---|---|
| none | files (+ "Create `<query>`" row when nothing matches exactly) |
| `>` | commands (`>42` jumps to line 42) |
| `@` / `#` | document / workspace symbols (LSP) |
| `!` | diagnostics |
| `/` | live grep |
| `?` | help: commands, keybindings, options, doc pages |

Lists without a prefix: references, definitions (when there is more than one),
code actions, buffers, jumplist, registers, terminals.

- **Implementation** (`src/picker/`): `fuzzy.zig` (fzf-style DP scoring +
  match positions), `Items.zig` (lock-free append-only store: one producer,
  many readers), `Engine.zig` (worker thread per open picker: runs the
  producer, matches, publishes snapshots, wakes the UI), `sources.zig`
  (comptime-dispatched source structs), `Picker.zig` (query, selection,
  preview), `ui/picker_view.zig`. Picker keys are commands in the `.picker`
  keymap mode; unbound keys type into the query.
- **Delivery.** Sources are *static* (commands, buffers: filled on the main
  thread), *streaming* (files: `rg --files --no-require-git`, else `git
  ls-files`, else a walk that skips hidden/build dirs, in batches on the
  worker), or *query-driven* (grep with rg: a fresh engine per query runs `rg`
  with a subsequence regex and streams matches; the previous rg is killed and
  its results stay on screen until the new ones arrive). Without rg, grep
  loads every project line once and filters in memory.
- **Matching** runs on the worker. It is incremental: new items are scored as
  they arrive, and a query that extends the previous one only rescans the
  previous matches. Snapshots carry the query generation they answer; Enter
  waits for the current generation, so it never accepts a stale result.
- **Commands with arguments chain into a second step.** `>write ` switches to
  path completion and `>theme ` lists themes. A picker with zero items is the
  generic text prompt.
- **Actions.** `Enter` runs the default; `C-v`/`C-s` open in a split; `Tab`
  marks items; `C-q` freezes results into a resumable list (the quickfix
  replacement); `SPC '` resumes the last picker. (Ctrl keys *inside* the picker
  are list navigation, not commands.)
- **Preview pane** shows highlighted file contents at the target line, or the
  doc for help items. It collapses on narrow windows.
- **Help is data.** Command docs, the keymap and `docs/*.md` (embedded, one
  entry per heading) are all searchable.

## Modal editing

Vim grammar: counts, operators + motions + text objects, registers, `.`,
macros. Modern parts:
- **Selections are the core primitive.** A normal-mode cursor is a 1-wide
  selection. Motions are pure functions, so multiple cursors only add a loop.
- **Which-key popup** for pending prefixes, generated from the keymap and
  command docs (see Keybindings).
- **Tree-sitter text objects (done):** `if`/`af` function, `ic`/`ac`
  class/struct, `ia`/`aa` argument (`syntax/objects.zig`). The grammars don't
  ship textobject queries, so each language lists its function/class/list
  node types; "inner" is between the body's braces (linewise like `i{`), or the
  indented block for Python. Zig: call arguments are direct children of
  `call_expression`, and `ac` on `const Foo = struct {...};` takes the whole
  declaration.
- **Defaults:** system clipboard, mouse support, persistent undo tree, smooth
  scrolling.
- **Config in ZON** (`std.zon.parse`): keymaps, theme, per-language settings.

## Grammar implementation

- **Commands carry their grammar role.** Motions are generated by
  `motion(target, kind, col)`: one function moves the cursor in normal/visual
  mode and gives a pending operator its range (`exclusive` / `inclusive` /
  `linewise`, with vim's exclusive-at-line-start adjustment). Text objects and
  their `i?`/`a?` bindings are generated from one spec table. Operators enter
  the `.operator` keymap mode, where doubled keys (`dd`, `>>`, `guu`) map to
  `operate_line`.
- **Undo** (`core/History.zig`) records insert/delete ops into an open group,
  committed when the editor returns to idle (an insert session is one step).
  Groups form a tree; undoing then editing branches. `[+]` is "current node !=
  saved node", so undoing back to the saved state clears it.
- **Dot repeat and macros replay keys.** The keys of a change (from the first
  key in normal mode until idle again) are captured; `.` and `@x` push keys
  onto a queue processed before new input. Macros are stored in registers as
  key notation.

## Text storage

`Text` exposes insert/delete, line index and byte<->(line, col) conversion. The
milestone-1 implementation is one `ArrayList(u8)` + line starts. It will be
replaced by a **persistent rope**: a B-tree of ~1KB leaves, nodes caching byte
and newline counts, unchanged parts shared between versions. That gives cheap
undo snapshots and immutable snapshots for workers.

Like vim, the final newline of a file is not part of the text (`Buffer` strips it
on load and restores it on save). CRLF files are stored as LF and restored on
save.

LSP positions: negotiate `positionEncoding: utf-8`. The UTF-16 fallback is
converted within a single line, so the rope needs no UTF-16 bookkeeping.

## Syntax (tree-sitter)

- **Adding a language:** `zig fetch --save=ts_<lang> git+<grammar repo>#<tag>`
  and add a row to `grammars` in `build.zig`. Each grammar compiles into its own
  static library (they ship different `tree_sitter/parser.h`); `build.zig`
  generates a `grammars` module (name, extensions, embedded
  `queries/highlights.scm`), and `syntax/languages.zig` declares each
  `tree_sitter_<name>` entry point with `@extern` at comptime. A grammar repo
  whose own `build.zig` doesn't build on 0.17 must be pinned to a tag without
  one (Zig runs dependency build scripts; tree-sitter-c is on v0.24.1).
- **Edits:** every text change goes through `Buffer.insert/delete`, which
  reports it to `Syntax` (`ts_tree_edit`) first; undo/redo replay through the
  same functions (`History.undo(gpa, target: anytype)`). `Editor.tick`
  reparses incrementally (at most once per frame) and highlights only the
  visible byte range, cached by tree version.
- **Queries:** the grammar repos' own `highlights.scm` (nvim-style capture
  names), mapped to theme styles by longest dotted prefix
  (`syntax/highlight.zig`). Later captures override earlier ones. Predicates
  `#eq?`, `#any-of?`, `#match?`, `#lua-match?` (and `not-` forms) are
  supported; their regexes use a small engine (`syntax/Regex.zig`) covering
  what highlight queries use. Injections (code fences in markdown) come later.
- **Previews** parse their text from scratch (up to 256 KB).

## Folding

`core/Folds.zig` keeps a buffer's closed folds as byte ranges that shift with
edits (the outermost closed fold decides what is hidden). Fold candidates come
from the syntax tree (a `folds` node list per language in
`syntax/objects.zig`) or from `zf{motion}`. Everything that counts screen lines
goes through `Editor.stepVisible` / `rowsBetween` / `screenRow`, so `j`/`k`,
scrolling, `zz`, clicks and popups treat a closed fold as one line. Linewise
operators extend to whole folds (`dd` on a fold deletes it); jumps (search,
`n`, `gd`, pickers) open the folds they land in; insert mode opens the fold.
Keys: `zc zo zO za zR zM zd zf`.

## Search

`/` and `?` open a prompt (the `.search` keymap mode, sharing `LineInput` and
the `input_*` editing commands with the picker). The cursor jumps to the first
match as you type and every match is highlighted; `<CR>` accepts, `<Esc>`
restores the cursor and view. `n`/`N` are motions (so `dn` works) and report
`[i/n]` and wrapping. `*`/`#` search the word under the cursor as a whole
word. `<Esc>` in normal mode clears the highlight. Smart case, literal text
(regex is a TODO). `SPC s s` is the line picker for the buffer.

## LSP

Current state: `lsp/Client.zig` (stdio transport, reader thread, messages held
until `initialize` is answered), `lsp/Lsp.zig` (one instance per server,
full-text `didChange` once per frame, diagnostics by path, request
bookkeeping), `lsp/Completion.zig`. Servers are a built-in table in
`Lsp.servers` (no config yet): zig -> `zls`, c -> `clangd`, rust ->
`rust-analyzer`; each starts when the first file of its language opens.
Completion trigger characters come from each server's `initialize` reply;
completion matching uses `filterText` (clangd labels carry a bullet or
signature).
Gotcha: empty params must be `struct {}{}`; `.{}` serializes as `[]` and zls
exits with a ParseError. Next: per-language server config, incremental sync,
signature help, code actions, rename, formatting.

Original plan:

- Spawn with `std.process.spawn(io, ...)`. A reader thread parses
  `Content-Length` frames and posts them to the main queue.
- Hand-written structs for the ~15 messages needed (`ignore_unknown_fields`).
- Order: lifecycle + incremental sync -> diagnostics -> definition/references ->
  hover -> completion -> signature help, code actions, rename, formatting, inlay
  hints.
- Every request records the document version it was made for; stale responses
  are dropped.

## Terminal (libghostty-vt)

`zig fetch --save=ghostty https://release.files.ghostty.org/libghostty-vt/1.0.0/libghostty-vt-1.0.0.tar.gz`

- Requires exactly Zig 0.17. Provides VT parsing, terminal state, a render-state
  API with per-row dirty tracking, key/mouse/focus/paste encoders (including the
  kitty keyboard protocol), selection and search. No PTY, no drawing.
- Use the **C API** (stable from 1.0, documented) through the `ghostty-vt-static`
  artifact + translate-c, not the Zig module (undocumented, unstable).

```
src/terminal/
  Pty.zig        forkpty(), TIOCSWINSZ on resize, reader thread
  Terminal.zig   GhosttyTerminal + mutex + effect callbacks
  TermView.zig   a pane type in the split layout, drawn from GhosttyRenderState
  shell/         OSC 133 integration for bash/zsh (fish 4 emits it itself)
```

- **Threading** (the one exception to rule 3): each terminal's reader thread
  calls `ghostty_terminal_vt_write` under that terminal's mutex, then
  `glfw.wake()`. The main thread locks only around
  `ghostty_render_state_begin_update` and draws from the snapshot.
- **Effects** run on the reader thread: PTY replies are written directly;
  title/cwd/bell/notifications are posted to the main queue. OSC 52 clipboard
  *reads* are denied by default (they must answer synchronously, and GLFW's
  clipboard is main-thread-only). Writes are allowed.
- **Drawing:** dirty rows only, prepared rows cached by
  `GHOSTTY_RENDER_STATE_ROW_DATA_ID`, editor theme palette pushed into the
  terminal, synchronized output honored via `RENDER_HOLD` with a 1s timeout.
- **Modes:** terminal-insert sends everything to the PTY except one escape chord
  (`<C-\><C-n>`, configurable). Terminal-normal turns the scrollback into a
  read-only buffer, so all motions, visual mode, yank and search work on terminal
  output.
- **Picker hooks:** list terminals by title + cwd; with OSC 133, a picker of
  previous commands (jump to or yank a command's output); "errors from the last
  command" collects `path:line:col` matches.
- Use ghostty's Unicode width functions in the editor too, so buffers and
  terminals agree on column widths.

## Platform notes

- **raylib is built from source** (`build.zig.zon`, git tag 6.2). The system
  `libraylib.so` exports no GLFW symbols, and both of the following need them:
  - **Ordered input:** raylib splits key presses and typed chars into separate
    queues, losing their relative order within a frame. `input/glfw.zig` chains
    its own GLFW key/char callbacks in front of raylib's to get one ordered
    stream. The window comes from `glfwGetCurrentContext()`, because raylib's
    `GetWindowHandle()` returns the native X11/Wayland handle on Linux.
  - **Idle CPU:** `EnableEventWaiting()` sleeps until input; worker threads call
    `glfwPostEmptyEvent()` (`glfw.wake()`) to wake the loop.
- **Fonts:** raylib bakes a fixed atlas at load time, with no fallback and no
  shaping. An on-demand glyph cache is needed for CJK, emoji and Nerd Font icons
  (urgent once the terminal lands). HiDPI scaling is not handled yet.
- **Package directory:** on a case-insensitive filesystem (NTFS), extracting
  raylib into `./zig-pkg` fails. Set `ZIG_LOCAL_PKG_DIR` to a directory on a
  case-sensitive filesystem.

## Milestones

1. **(done)** Window, font, file rendering and scrolling, ordered input layer,
   basic normal/insert mode, counts, save, mouse click/scroll, leader menus +
   which-key popup.
2. **(done)** Picker engine with files (+ create), buffers and commands sources,
   multiple buffers, wired to the leader menus above.
3. **(done)** Vim grammar: operators (`d c y > < gu gU g~`) x motions
   (`hjkl w b e W B E 0 ^ $ gg G f F t T ; , % { } H M L`) x text objects
   (`iw aw iW aW i" i' i` i( ib i[ i{ iB i< ip il` + `a` forms; `il` = line without indentation, `al` = all lines, as in recent neovim), counts on both
   sides, registers (`"a-z`, `"A-Z` append, `"0-9`, `"-`, `"_`, `"+`; unnamed
   synced with the system clipboard), undo tree (`u`, `C-r`), `.`, macros
   (`q`, `@`, `@@`), visual/visual-line mode, `x X s S C D Y p P r J ~`.
   Deferred: regex search patterns, visual block /
   multiple cursors, marks, `gv`, counts on insert (`3ihi<Esc>`), `.` after
   visual-mode operators.
4. **(done)** Tree-sitter highlighting (zig, c, json, python, rust) in buffers
   and picker previews; `/` search.
5. **(done, zls only, not configurable yet)** LSP: full-document sync,
   diagnostics (underline, colored line number, end-of-line message, picker),
   definition/references (jump or picker), hover, completion popup (auto on
   `.` and after two identifier chars; `C-n`/`C-p`/arrows move, `Tab`/`RET`/
   `C-y` accept). Live project grep (`SPC /`).
6. Terminal (libghostty-vt). Depends only on the input layer, glyph cache and
   split layout, so it can move earlier.
7. Completion, code actions, rename, formatting, splits, rope, help docs,
   config.

## Debugging

```
zig build test                                        # headless core tests
EDIT_TEST_KEYS='3jwi// hi<Esc><Space>f' EDIT_TEST_SCREENSHOT=/tmp/shot.png zig build run -- file.zig
```
`EDIT_TEST_KEYS` feeds key notation at startup; `EDIT_TEST_SCREENSHOT` saves a
PNG of the first frames and exits.
