# zile: design

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
| `SPC f s` | save file (asks for a name if it has none) | done |
| `SPC f n` | new file (prompt prefilled with the current folder) | done |
| `SPC f S` | save as (buffer adopts the new path; never overwrites) | done |
| `SPC f R` | rename / move file (makes folders; LSP, git, language follow) | done |
| `SPC f C` | copy file to a new path and open it | done |
| `SPC f D` | delete file from disk (Yes/No picker), closes its buffer | done |
| `SPC f y` / `SPC f Y` | copy relative / absolute path to the clipboard | done |
| `ys{motion}{c}`, `yss{c}`, `ds{c}`, `cs{old}{new}`, visual `S{c}` | surround, nvim-surround style. `)` plain pair, `(` with inner spaces; `b` nearest bracket, `q` nearest quote, `t` tag (delete/change); other punctuation wraps with itself. `ds`/`cs` seek the nearest pair like text objects. `s` after other operators is still snipe | done |
| `s…<Tab>` / `/…<Tab>` | cursors on every match (on screen / in the file), each selected: `c` changes all, `<Esc>` leaves plain cursors | done |
| visual `I` / `A` | a cursor on each selected line, typing at its start / end | done |
| `qn` `qN` `qs` `qa` | cursor + next / previous match of the word (or selection), skip a match, all matches | done |
| `qj` `qk`, visual `qI` `qA` | cursor + move down / up; cursors at line starts / ends without inserting | done |
| `qu` `qq`, `<Esc>` in normal | remove the last cursor; remove all | done |
| `Q{reg}` … `Q`, `@{reg}` | record / play a macro (`q` is the multicursor menu) | done |
| `<C-o>` / `<C-i>` (`<Tab>`), `SPC s j` | jumplist: back / forward, or pick from a list (newest first, previewed) | done |
| `SPC w s` + `h/j/k/l` | split: a new window on that side showing this buffer (focus moves into it) | done |
| `SPC w h/j/k/l`, `SPC w w` | focus the window on that side; the next window (wrapping) | done |
| `SPC w d` / `SPC w c`, `SPC w o`, `SPC w =` | close window, close the others, equal sizes | done |
| `SPC w >` `<` `+` `-` | wider, narrower, taller, shorter | done |
| `SPC b N`, `SPC b b` / `SPC b l` / ``SPC ` ``, `SPC b O`, `SPC b r`, `SPC b s` / `SPC b S` | new empty buffer, flip to the other buffer (picker: `SPC b B` / `SPC ,`), kill others (keeps unsaved), revert from disk, save / save all | done |
| in pickers: `<Tab>`, `<C-v>`, `<C-s>` | "Open in..." menu (this window, split right/below/left/above); open in a split right / below. Works for files, buffers, grep, references, symbols, diagnostics, jumps, run errors, git changes, explorer files; on a project (`SPC p p`) the split opens once a file is picked | done |
| `zile -t` | terminal mode: the same editor drawn in the terminal; automatic when there is no display (SSH) or no window can open | done |
| `zile <path>` | a file (trailing `/` and `..` resolved); a folder opens the explorer there; a file that can't be opened leaves a message instead of not starting | done |
| `SPC p p`, `SPC p f` | switch project (projects opened before, most recent first; picking one finds a file in it); find file in project | done |
| AI ghost completion, `SPC t a` | while typing in insert mode (at a line's end, or before closing `)]}"';,`), a local model through Ollama fills in the middle (`/api/generate` with `prompt` + `suffix`; `$ZILE_AI_MODEL`, default `qwen2.5-coder:1.5b-base`; `$OLLAMA_HOST`). Shown in gray at the cursor (first line inline, more below); typing it out keeps it, `<A-;>` takes all of it, `<A-l>` a line, `<A-Right>` a character (the rest stays offered); anything else drops it. `<Tab>` stays with the completion menu and placeholders, so the two never fight. One worker thread, latest request only, sent after a 120 ms pause; replies used only if the cursor and text are unchanged. No answer from Ollama turns it off with a message (`SPC t a` retries) | done |
| `SPC c f`, `SPC t f` | format the file (visual: the selected lines, when the server can) with the language server, else the language's formatter (`zig fmt`, `rustfmt`, `clang-format`, `ruff format`, `jq`) run in the project root; changed lines only, one undo step, cursor kept. Format on save (on by default; `SPC t f` toggles); a failed format still saves | done |
| completion → function | arguments arrive as snippet placeholders: the current one is highlighted and typing replaces it; `<Tab>` / `<S-Tab>` next / previous (a fresh one keeps its text), `<BS>` clears it, the last `<Tab>` goes to the server's final cursor; in Zig/C/Rust, when the call ends its line, one more `<Tab>` goes to the end of the statement, adding the `;` | done |
| signature help | `(` (the server's trigger characters) shows the call's signature above the cursor with the current parameter highlighted and its doc; `,` updates it, `)` / leaving insert mode closes it; it follows placeholder jumps | done |
| `SPC t p` | toggle autopairs (on by default): `(` → `()`, closers and quotes step over, quotes skip word neighbors, `<CR>` in `{}` opens a block | done |
| `SPC g g` | git menu (plain-English actions: commit, push, pull, branches, changed files, set remote, ...) | done |
| `SPC g c` / `SPC g b` / `SPC g s` | commit all (saves, prompts for a message) / switch or create branch / changed files | done |
| `SPC g r` / `SPC g n` / `SPC g p` / `SPC g R` | git: restore hunk / next / previous change / reload HEAD | done |
| `SPC t g` / `SPC t r` / `SPC t d` | toggles: ghost lines / relative numbers / diagnostic messages (fields of `Editor.Options`, one comptime `toggle(field)` command each) | done |
| `SPC q` | smart close: the focused window if there are several, else the current buffer if there are several (unsaved ones are kept, with a message), else quit (refuses if unsaved) | done |
| `SPC Q s` / `SPC Q Q` | save all and quit / quit without saving | done |
| `SPC SPC`, `SPC f f` | find file in project (fuzzy, + create) | done |
| `SPC .`, `SPC f e` | explore files (browser): one folder at a time, starting at the current file's folder. `Enter`/`/` on a folder goes in, `Enter` on a file opens it, `<BS>` on an empty query goes up (selecting where you came from), `~` home, `/` on an empty query the root; a new name offers "Create" | done |
| `SPC ,`, `SPC b B` / `SPC b k` | buffer picker / kill buffer | done |
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
| `SPC o t`, `<C-\>` | terminal popup: your `$SHELL`, kept running while hidden; every key goes to it; `<C-\>` hides; `<S-PageUp/Down>` / wheel scroll back; `<C-S-v>` pastes | done |
| `SPC r r` | code runner: prompt prefilled with this project's last command (remembered across restarts), so `<CR>` runs it again | done |
| `SPC r c` | command editor: a floating vim buffer (any number of lines, full editing: motions, operators, surround, multicursor, undo); starts in insert mode; in normal mode `<CR>` runs it via `$SHELL -c`, `<Esc>` cancels; leader menus wait until it closes | done |
| `SPC r R`, `SPC r o` | run the runner command again without asking; show the last run | done |
| in a finished run | `r` run again, `e` errors in the quickfix panel, `q` / `<Esc>` close, `j` / `k` scroll | done |
| `SPC r e` | errors from the last run (`path:line:col` from zig/gcc/clang/go, rust `-->`, python `File "…", line N`) in the quickfix panel | done |
| pickers: insert / normal mode | insert (typing filters) and normal (`j`/`k`, `gg`/`G`, `<C-d>`/`<C-u>`; `i`/`a`/`/` type; `q` / `<Esc>` close; `h`/`l` up/in in the explorer). `<Esc>` while typing goes to normal. Each source declares `start_mode`: searchable lists start typing, short step-through lists (quickfix, references, diagnostics, jumplist, git changes/menu, confirmations, "Open in") start in normal | done |
| `SPC x x`, `]q` / `[q` | the quickfix picker, docked at the bottom (sources with `follow` dock: no preview, the editor shows the selection). Starts in normal mode at the current entry; `<CR>` keeps the place. `]q` / `[q` step through without it (jumps) | done |
| in pickers: `<C-q>` | send every current match to the quickfix list and open it (grep, buffer lines, symbols, references, diagnostics, run errors) | done |
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
- **Jumplist (done):** `Editor.jumps` holds the places jumps left (buffer +
  byte position, plus the path so a closed file reopens), one per line,
  at most 100. Commands flagged `jump` (gg, G, %, {, }, H/M/L, n/N, *, #,
  hunk and buffer moves) record before running; searches and snipes record
  their origin; `jumpTo` (definitions, locations) and pickers that navigate
  record too. Edits shift entries like cursors. `<C-o>` from the newest
  place first records it, so `<C-i>` comes back.
- **Projects (done):** `core/Project.zig`: a file's project is the nearest
  folder above it with `.git`, else with a build file (`build.zig`,
  `Cargo.toml`, `go.mod`, `package.json`, ...). Projects are interned by the
  editor; buffers point at theirs. The current project is the focused
  buffer's (else the last one entered, else the cwd's): the file and grep
  pickers list it (`picker_root`; results resolve against it), the runner
  and shell start in it and the runner remembers per project, git (menu,
  ghost lines, commits) uses its repo, and each language server runs per
  (language, project) with that root. The status line and window headers
  show "project  path/in/project". Opened projects are remembered in
  `$XDG_STATE_HOME/zile/projects` for `SPC p p`.
- **Windows (done):** `Windows.zig` is a tree of splits (side by side or
  stacked, with a ratio) whose leaves are windows, each with a buffer and its
  own `View`. The focused window's live state stays in `Editor.buffer`/`view`
  so editing code is unchanged; focusing swaps it in and out. Edits shift the
  cursors of other windows on the same buffer. The renderer lays out the tree
  every frame (on whole cells), and draws each window clipped to its
  rectangle with rlgl's matrix translated to its origin, so drawing code
  stays in local coordinates; unfocused windows are drawn by temporarily
  swapping in their buffer/view (`peekWindow`) and re-highlighting their
  visible lines. With several windows each has a header line (file name).
  Mouse clicks and the wheel focus the window under the pointer.
- **Multicursor (done):** extra cursors live in `Editor.cursors`; the primary
  is `view`. A command's keys are collected until it completes (idle again, or
  in insert mode) and then replayed at every extra cursor from the mode the
  command began in, so every motion, operator, text object, surround and
  `.` works per cursor with no per-command code; in insert mode each key
  replays at once, so typing shows everywhere live. `insertAt`/`delete`
  shift stored cursors. Commands marked `once` (undo/redo, `.`, macros,
  cursor management) and all leader commands run at the primary only; `.`
  and macros still reach every cursor because their queued keys replay.
  Replays don't write registers' history for `.` and skip LSP completion.
  Undo/redo and switching buffers drop the extra cursors.
- **Seeking pairs, like mini.ai (done):** bracket and quote objects use the
  pair around the cursor; outside one they jump to the next pair ahead (up to
  50 lines), else the previous one. `ib`/`ab` is the nearest of `()` `[]` `{}`
  and `iq`/`aq` the nearest of `"` `'` `` ` ``; `i(`, `i[`, `i{`, `i<`, `i"` and so on are
  one kind each, and they seek too.
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

## Git and ghost lines

Only inside a git repository (`git rev-parse --show-toplevel`, checked the
first time a file opens). Each tracked buffer keeps its HEAD version
(`git show HEAD:path`, normalized like `Buffer.load`) and a line diff against
it (`git/diff.zig`: common prefix/suffix trimmed, Myers on the middle,
recomputed before each key / frame when the buffer changed).

- **Gutter:** green bar for added lines, yellow for changed; with ghost lines
  off, a red tick where lines were deleted.
- **Ghost lines** (`SPC t g` toggles, on by default): the old HEAD lines of
  changed/deleted hunks are shown inline below the new lines, tinted red. They
  are real rows: `j`/`k` walk onto them, `h l 0 ^ $` move within them,
  `yy`/`Y`/`V`+`y` yank them; `w b e W B E`, `f t F T ; ,`, `/ ? n N` and
  snipe all reach into them (search scans rows in file order, including inside
  closed folds, which it opens). Editing commands are refused with a hint and
  any other command returns to the text. They are never written to the file.
- **Rows:** `Editor.Row` = text line or ghost line (`ghost` = index into the
  hunk's old lines, shown before text line `line`). `nextRow`/`prevRow`/
  `stepRows`/`rowsFrom` handle folds and ghosts together; scrolling, `zz`,
  clicks, the cursor and the renderer all use them.
- **Keys:** `SPC t g` toggle ghost lines, `SPC g r` restore the hunk at the
  cursor from HEAD (undoable), `SPC g n`/`SPC g p` next/previous change,
  `SPC g R` reload HEAD (after committing outside the editor).
- **Simple git UI** (deliberately not magit): `SPC g g` is a picker of
  actions in words. Commit = save open files, `git add -A`, `git commit -m`
  (message from a prompt box). Push = `git push -u origin HEAD` (sets up
  tracking the first time). Pull = `git pull --ff-only` (never a surprise
  merge). Branches picker with a "Create branch" row. Changed files picker from
  `git status`. Set remote prompts for origin's URL (prefilled). Commands run in
  the background (`git/Job.zig`) and report one readable line; after a pull or
  branch switch, unmodified buffers reload from disk.
- Next: stage individual hunks, blame, diff against the index.

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

**Built (popup + runner):** `terminal/Pty.zig` (forkpty, TERM=xterm-256color,
resize, hangup/kill, exit status), `terminal/Terminal.zig` (reader thread
polling the PTY, emulator under an `Io.Mutex`, write-back replies from the
reader, key encoding via ghostty's encoder with the terminal's current modes,
bracketed paste, scrollback, a `draw(ctx)` walk of the render-state snapshot),
`terminal/RunMemory.zig` (last runner command per project in
`$XDG_STATE_HOME/zile/run-commands`). Runs save open files first and go
through `$SHELL -c`; when one ends, "exited N in Ts" is printed under its
output. Build: `dep.artifact("ghostty-vt-static")` + translate-c of `vt.h`
with the artifact's emitted include tree and `GHOSTTY_STATIC`.
`terminal/errors.zig` strips escapes from the run's captured output and keeps
locations whose files exist.
Not yet: terminals as split panes, terminal-normal mode (motions/yank over
scrollback), CJK/emoji glyphs (atlas).

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

## Terminal mode (`zile -t`)

One binary: it opens a window when it can, and draws in the terminal
otherwise (`-t`, no `DISPLAY`/`WAYLAND_DISPLAY`, or the window fails to
open). raylib is built with `SUPPORT_CLIPBOARD_IMAGE=0`, its only direct X11
call, so the binary needs nothing but libc to start; GLFW loads X11/GL
itself when a window opens.

- **Drawing:** `ui/gfx.zig` is the UI's primitives (clear, rect, glyph,
  clip, offset, cursor), sent to raylib or to `tui/Grid.zig`. The UI keeps
  working in pixels; in a terminal a cell is 10x20 "pixels" and the grid
  maps calls onto cells: full rects paint backgrounds (opaque ones clear the
  text under them, translucent ones tint), thin horizontal lines near a
  cell's bottom underline (colored underlines), thin vertical ones draw `│`
  in empty cells (dividers, git signs), text is one codepoint per cell, and
  the terminal's own cursor goes where the UI says (block/bar/underline).
- **Output** (`tui/Tui.zig`): raw mode on the alternate screen; each frame
  writes only changed cells (truecolor SGR) inside synchronized-output
  markers.
- **Input** (`tui/input.zig`): kitty keyboard protocol (`CSI > 1 u`) so
  `<Esc>`, `<C-i>`/`<Tab>`, `<C-S-v>` stay distinct where supported; xterm
  sequences, control bytes, `ESC`+key as Alt, UTF-8, bracketed paste (goes
  where typing would; `p` in normal mode), SGR mouse (click, wheel). A
  self-pipe wakes the loop for worker threads.
- **Clipboard:** yanks go to the system clipboard with OSC 52 (works over
  SSH in most terminals); pasting uses the terminal's own paste.
- **Limits:** zoom is the terminal's; 1px borders and bars don't exist
  (popups are set apart by color); wide (CJK) characters may misalign.

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
  packages into `./zig-pkg` fails. `zig-pkg` and `.zig-cache` are symlinks to
  sibling directories on a case-sensitive filesystem (siblings, because some
  build steps reach `../../.zig-cache` from inside a package). Don't use
  `ZIG_LOCAL_PKG_DIR`: it makes package roots absolute, and Zig 0.17 then
  rejects packages with relative path dependencies (libghostty-vt).

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
ZILE_TEST_KEYS='3jwi// hi<Esc><Space>f' ZILE_TEST_SCREENSHOT=/tmp/shot.png zig build run -- file.zig
```
`ZILE_TEST_KEYS` feeds key notation at startup; `ZILE_TEST_SCREENSHOT` saves a
PNG of the first frames and exits.
