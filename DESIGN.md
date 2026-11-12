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

## Keybindings: the leader is a picker

Vim motions, operators and text objects stay on single keys. Everything else
starts at `SPC`, which opens the **Leader menu**: a picker listing every
entry point with its key beside it (`b` buffers, `l` code, `r` run...).
Pressing a row's key runs it, so `SPC b` reads and types like a leader
sequence, but what you see is a list you can filter (`i`) rather than a
which-key popup. There is no which-key anywhere: vim prefixes (`g`, `z`, `[`,
`]`, `q`, operators) wait silently like vim's, and `SPC f k` (keys) searches
every binding, the menus' rows included. In visual mode `SPC` keeps the
selection for the row that runs (`SPC l a` code actions on it, `SPC f f`
files with it as the query). No ex command line. Bindings are tables in
`input/keymap.zig`; menus are `Menu(...)` sources in `picker/sources.zig`.

### Leader layout: pickers are the menus

The leader keeps a few entry points, and each opens a picker that *is* the
menu: you see every row, type to filter, and act on rows right there, so
there is no which-key hunting for the key of one action. Every picker shows
its actions along its bottom: the letters after `<Esc>`, the Ctrl keys while
typing, and `<Tab>` for the full list (with "open in a split" for pickers of
places). Menus (`SPC l`, `SPC g`) show each row's key beside it: the key runs
the row, `/` types to filter.

| key | picker | its actions / rows |
|---|---|---|
| `SPC` | Leader menu | every row below, on its key; `i` filters |
| `SPC SPC` (and `SPC .`) | Files: the explorer | starts as the project's folder (`SPC .`: the current file's), its entries only; typing searches two ways at once: **here** (the folder's entries and every file below it, the ones you visit most first; instant, ranked by the file name then nearness) and, under a line, **elsewhere** (`files_global`, a second engine run per query: files you opened in other places, then `fd --fixed-strings` over `$HOME`, skipping `.git`, `node_modules`, caches and build output unless `SPC t` turns that off), so `main.zig` shows this project's first and `zshrc` finds `~/.zshrc` from any project; Create is the last row; a folder path typed out (`src/`, `~/code/x`, `/etc`, `../y`) goes there with `/` or Enter, `/` with nothing typed starts at the root, `BS` on nothing goes up; `c` works here (a cd: Files, search, the runner and the terminal start from this folder from now on); `o n r m x yy p` the explorer's file operations; `C-t` scopes: folder · buffers · recent everywhere · whole disk |
| `SPC b` | Files, open scope | `x` / `C-x` close, `n` new, `s` save, `S` save all, `r` rename / move, `w` save as, `c` copy to, `R` revert, `D` delete the file, `o` close the others, `y` / `Y` copy path |
| `SPC w` | Windows | rows: the other windows (last used first), the one you're in last (`SPC w Enter` flips back), then `+ New window right… / below…` (pick what it shows in Files; cancel: no window) and `+ New terminal window`; the preview draws the layout (selected window double-lined, yours `*`); `w` (`SPC w w`) back to the previous window and again to toggle, `h j k l` the window that way from yours, keys about where you are act on the window you're in: `v` / `s` split, `z` maximise / back, `b` its buffer, `o` only, `=` equal, `>` `<` `+` `-` grow / shrink (stays open), `t` terminal; keys about a window as a thing act on the selected row: Enter go there, `x` close, `X` swap with yours |
| `SPC d` | Debug | gdb: see Debugger below |
| `SPC t` | toggles | every setting with its on / off state; Enter flips it and the list stays; colour scheme, text size |
| `SPC l` | code (menu) | `.` rename, `r` references, `a` actions, `f` format, `d` definition, `i` implementations, `k` docs, `l` symbols (`C-t`: project), `w` project symbols, `x` errors, `c` colour wheel, `m` man pages, `t` todo tag, `W` trim whitespace |
| `SPC r` | runner | your commands, newest first: Enter runs, type a new one; `e` / `C-e` edit, `x` / `C-x` forget, `c` multi-line, `.` again, `o` output, `E` errors, `t` terminal, `T` terminal here |
| `SPC g` | Git: changed files | Enter opens one; `c` commit all, `p` push, `P` pull, `b` branches, `r` restore the change at the cursor, `l` this line's commit, `R` remote URL, `u` reload HEAD, `i` git init |
| `SPC /` | Search | `C-t` scopes: project · this file · todos; `C-r` replace across the project |
| `SPC f` | Find (menu) | few pickers, each with its scopes on `C-t`: `f` Files, `b` buffers, `r` recent files, `g` Search (project · this file · todos), `x` Problems (errors · last run · saved list), `j` Places (jumps · marks), `c` Commands (commands · keys), `e` explore, `p` projects, `y` registers, `u` undo history, `n` notifications, `h` start screen, `T` colour scheme, `M` man pages |
| `SPC p` | Projects | the ones opened before (most recent first, yours last), then every project under the project folders; Enter switches (restoring its session if nothing of it is open, else the Files explorer at its root); `f` files in it, `g` search in it, `l` restore its session, `s` save this session, `x` forget it; `Tab`: into a split |
| others (Leader rows) | | `.` browse, `;` shell command, `'` resume picker, `,` last jump (again: back), `s` save, `q` close; `SPC a` Claude (`a` `s` `i` `y` `n`), `SPC Q` quit (`s` `Q`) |

In visual mode `SPC l a` (code actions), `SPC l f` (format the lines) and
Ctrl-Enter (run the selected SQL) act on the selection.

The table below is the history of what was built, with its keys in this layout.

| keys | group / command | status |
|---|---|---|
| `SPC s` | save file (asks for a name if it has none) | done |
| `SPC b n` | new file (prompt prefilled with the current folder) | done |
| `SPC b w` | save as (buffer adopts the new path; never overwrites) | done |
| `SPC b r` | rename / move file (makes folders; LSP, git, language follow) | done |
| `SPC b c` | copy file to a new path and open it | done |
| `SPC b x` | delete file from disk (Yes/No picker), closes its buffer | done |
| `SPC b y` / `SPC b f` | copy relative / absolute path to the clipboard | done |
| `ys{motion}{c}`, `yss{c}`, `ds{c}`, `cs{old}{new}`, visual `S{c}` | surround, nvim-surround style. `)` plain pair, `(` with inner spaces; `b` nearest bracket, `q` nearest quote, `t` tag (delete/change); other punctuation wraps with itself. `ds`/`cs` seek the nearest pair like text objects. `s` after other operators is still snipe | done |
| `s…<Tab>` / `/…<Tab>` | cursors on every match (on screen / in the file), each selected: `c` changes all, `<Esc>` leaves plain cursors | done |
| visual `I` / `A` | a cursor on each selected line, typing at its start / end | done |
| `qn` `qN` `qs` `qa` | cursor + next / previous match of the word (or selection), skip a match, all matches | done |
| `s` | Helix's select: prompt, then a cursor on every match inside the selection (the whole file from normal mode); `c` changes them all. `t` is the snipe (teleport); `dt` etc. keep vim's till | done |
| `qj` `qk`, visual `qI` `qA` | cursor + move down / up; cursors at line starts / ends without inserting | done |
| `qu` `qq`, `<Esc>` in normal | remove the last cursor; remove all | done |
| `Q{reg}` … `Q`, `@{reg}` | record / play a macro (`q` is the multicursor menu) | done |
| `<C-o>` / `<C-i>` (`<Tab>`), `SPC f j` | jumplist: back / forward, or pick from a list (newest first, previewed) | done |
| `SPC w s` + `h/j/k/l` | split: a new window on that side showing this buffer (focus moves into it) | done |
| `SPC w h/j/k/l`, `SPC w w` | focus the window on that side; the next window (wrapping) | done |
| `SPC w d` / `SPC w c`, `SPC w o`, `SPC w =` | close window, close the others, equal sizes | done |
| `SPC w r` + `h/j/k/l`, `=` | resize mode (stays open): move the border on that side (the window's other border if none) left/down/up/right, two columns or one row per press; `=` equal sizes; any other key leaves and acts as usual. `SPC w <` / `>` move a border left / right the same way | done |
| `SPC b e`, `SPC b b` / `SPC b b` / ``SPC ` ``, `SPC b o`, `SPC b d`, `SPC b s` / `SPC b a` | new empty buffer, flip to the other buffer (picker: `SPC f b` / `SPC ,`), kill others (keeps unsaved), revert from disk, save / save all | done |
| in pickers: `<Tab>`, `<C-v>`, `<C-s>` | "Open in..." menu (this window, split right/below/left/above); open in a split right / below. Works for files, buffers, grep, references, symbols, diagnostics, jumps, run errors, git changes, explorer files; on a project (`SPC p p`) the split opens once a file is picked | done |
| `zile -t` | terminal mode: the same editor drawn in the terminal; automatic when there is no display (SSH) or no window can open | done |
| `zile <path>` | a file (trailing `/` and `..` resolved); a folder opens the explorer there; a file that can't be opened leaves a message instead of not starting | done |
| `SPC p p`, `SPC f f` | switch project (projects opened before, most recent first; picking one finds a file in it); find file in project | done |
| `SPC r w` | the current window becomes your shell (its file stays underneath); `exit` or `SPC q` ends the shell and shows the file again. Terminal windows (this and the Claude panel) are modal: Esc Esc (two within ~1/3 s; the first still reaches the program) is normal mode, where `SPC` commands work, `j`/`k` and `Ctrl-d`/`Ctrl-u` scroll and other keys do nothing; `i`/`a`/`Enter` type into the program again | done |
| `SPC a a` | Claude Code panel: `claude` in a terminal window on the right (project root), connected to zile; `SPC a a` again focuses / hides it, Esc Esc is normal mode (see `SPC r w`); in the panel `Ctrl-C` closes it (Claude keeps running; it interrupts with Esc) and `Ctrl-Shift-C` sends Claude a real Ctrl-C | done |
| `SPC a s`, `SPC a i` | mention the selected lines (visual) or the file in Claude's prompt (`@path#L…`); with an instruction typed into a popup (pasted into Claude's prompt, Enter there sends) | done |
| `SPC a y` / `SPC a n` | accept / reject Claude's proposed edit, shown as a diff in the code window (removed lines as ghost lines); the proposal can be edited before accepting | done |
| AI ghost completion, `SPC t a` | while typing in insert mode (at a line's end, or before closing `)]}"';,`), a local model through Ollama fills in the middle (`/api/generate` with `prompt` + `suffix`; `$ZILE_AI_MODEL`, default `qwen2.5-coder:1.5b-base`; `$OLLAMA_HOST`). Shown in gray at the cursor (first line inline, more below); typing it out keeps it, `<A-;>` takes all of it, `<A-l>` a line, `<A-Right>` a character (the rest stays offered); anything else drops it. `<Tab>` stays with the completion menu and placeholders, so the two never fight. One worker thread, latest request only, sent after a 120 ms pause; replies used only if the cursor and text are unchanged. No answer from Ollama turns it off with a message (`SPC t a` retries) | done |
| `SPC l f`, `SPC t f` | format the file (visual: the selected lines, when the server can) with the language server, else the language's formatter (`zig fmt`, `rustfmt`, `clang-format`, `ruff format`, `jq`) run in the project root; changed lines only, one undo step, cursor kept. Format on save (on by default; `SPC t f` toggles); a failed format still saves | done |
| completion → function | arguments arrive as snippet placeholders (`<Esc>` with some never filled in removes them, and the commas beside them: `f(a: A, b: B)` becomes `f()`): the current one is highlighted and typing replaces it; `<Tab>` / `<S-Tab>` next / previous (a fresh one keeps its text), `<BS>` clears it, the last `<Tab>` goes to the server's final cursor; in Zig/C/Rust, when the call ends its line, one more `<Tab>` goes to the end of the statement, adding the `;` | done |
| completion order | an exact match of what was typed first (case ignored), then the better fuzzy match, then the shorter name, then the server's order: `drawtext` offers `DrawText` before `DrawTexture` |
| completion → documentation | the selected suggestion's documentation (the server's) in a box beside the list; it and `K`'s hover are shown as plain wrapped text (`lsp/docs.zig`: images, escapes and link syntax taken out, the link's address kept) | done |
| completion → CSS values | after `property: ` the property's values are listed with nothing typed, as an enum's after a `.` (in a stylesheet, a page's `<style>` and `style=""`); taking a property (`justify-content: \|;`) lists them at once (the server asks for it: `editor.action.triggerSuggest`). With nothing typed the list is the server's alone, in its order | done |
| completion → `(` | typing `(` with the suggestions open takes the selected one first (its name only), then the `(` opens the call with its closing pair: `drawtex(` → `drawText(\|)` | done |
| signature help | `(` (the server's trigger characters) shows the call's signature above the cursor with the current parameter highlighted and its doc; `,` updates it, `)` / leaving insert mode closes it; it follows placeholder jumps | done |
| `<Tab>` before a closer | steps over a closing bracket or quote: `f("text|")` → `f("text"|)` → `f("text")|` (with autopairs on; not at the start of a line, and not on a quote that opens a string) | done |
| `SPC t p` | toggle autopairs (on by default): `(` → `()`, closers and quotes step over, quotes skip word neighbors, `<CR>` in `{}` opens a block | done |
| `SPC g g` | git menu (plain-English actions: commit, push, pull, branches, changed files, set remote, ...) | done |
| `SPC g c` / `SPC g b` / `SPC g s` | commit all (saves, prompts for a message) / switch or create branch / changed files | done |
| `SPC g r` / `SPC g n` / `SPC g p` / `SPC g u` | git: restore hunk / next / previous change / reload HEAD | done |
| `SPC t g` / `SPC t r` / `SPC t d` | toggles: ghost lines / relative numbers / diagnostic messages (fields of `Editor.Options`, one comptime `toggle(field)` command each) | done |
| `SPC q` | smart close: the focused window if there are several code windows (or it is the Claude panel); with one code window left, the Claude panel is hidden first; else the current buffer if there are several (unsaved ones are kept, with a message), else quit (refuses if unsaved) | done |
| `SPC Q s` / `SPC Q Q`, `QQ` | save all and quit / quit without saving (`QQ`: the same, no leader; `Qq` still records macro q) | done |
| `SPC SPC`, `SPC f f` | find file in project (fuzzy, + create) | done |
| `SPC .`, `SPC f e` | explore files (browser): one folder at a time, starting at the current file's folder. `Enter`/`/` on a folder goes in, `Enter` on a file opens it, `<BS>` on an empty query goes up (selecting where you came from), `~` home, `/` on an empty query the root; a new name offers "Create" | done |
| `SPC ,`, `SPC f b` / `SPC b k` | buffer picker / kill buffer | done |
| `]b` / `[b` | next / previous buffer | done |
| `SPC f c` | command picker (M-x) | done |
| `SPC '` | resume last picker | done |
| `SPC f r` | recent files (see mini.nvim features) | done |
| `SPC f l` | search buffer lines | done |
| `/` `?` `n` `N` `*` `#` | in-buffer search (incremental, highlighted) | done |
| `t` | **snipe** (ours, "teleport"): type text, jumps as soon as one match is left on screen; `RET` = first match, then `n`/`N`; in visual mode too. After an operator `t` is still vim's till, and `s` is the snipe motion (`gUs…`) | done |
| `SPC /`, `SPC f g` | live fuzzy grep over every project line | done |
| `<C-r>` in `SPC /` | search and replace across the project (grug-far, simpler): the query becomes an exact search (smart case, `rg --fixed-strings`), a prompt takes the replacement, and every line with matches shows as it is (red) and as it will be (green), grouped by file; `↑`/`↓` move, `Tab` skips a line, `S-Tab` a file, `Enter` replaces (each file one undo step; autosave writes them; a match whose text changed since the search is left alone), `Esc` goes back to the grep picker (`Replace.zig`) | done |
| `gd` / `SPC l d`, `SPC l u` | definition, references (zls). `r` is vim's replace-character again and `gr` is replace-with-register | done |
| `K` / `SPC l k` | hover docs (zls) | done |
| `SPC f x` | diagnostics picker (zls) | done |
| `SPC f s` | go to symbol: zls documentSymbol, else a tree-sitter outline | done |
| `SPC s i` / `SPC c j` | symbols in buffer / workspace | LSP |
| `SPC l r` (also `SPC l r`) | rename symbol (zls): prompt prefilled with the name, edits applied across files as one undo step each | done |
| `SPC l a` / `SPC l f` | code action / format | LSP |
| `SPC w v` / `SPC w s` / `SPC w hjkl` / `SPC w d` | splits | layout |
| `SPC r t` | terminal popup: your `$SHELL`, kept running while hidden; every key goes to it; Esc Esc hides; `<S-PageUp/Down>` / wheel scroll back; `<C-S-v>` pastes | done |
| `SPC ;` | run any shell command: a one-line prompt that starts empty; what runs is not remembered as the runner's command | done |
| `SPC r r`, `SPC ;`, `SPC r t` / `w` | commands run in the folder of the code you are in: from the current file's folder up to its project root, the nearest folder with a build file (build.zig, Makefile, Cargo.toml, ...), else the project root; a file in no project runs in its own folder. Paths in a run's errors are relative to it |
| `SPC r r` | code runner (now a picker: this project's commands, newest first; Enter runs the last again, `Tab` puts the selected command in the query line to add to or cut down before running it, typed text is a new command and stays the first row, `x` forgets one). Formerly: prompt prefilled with this project's last command (remembered across restarts), so `<CR>` runs it again | done |
| `SPC r c` | command editor: a floating vim buffer (any number of lines, full editing: motions, operators, surround, multicursor, undo); starts in insert mode; in normal mode `<CR>` runs it via `$SHELL -c`, `<Esc>` cancels; leader menus wait until it closes | done |
| `SPC r .` / `SPC r .`, `SPC r o` | run the runner command again without asking; show the last run | done |
| in a finished run | `r` run again, `e` errors in the quickfix panel, `q` / `<Esc>` close, `j` / `k` scroll | done |
| `SPC r e` | errors from the last run (`path:line:col` from zig/gcc/clang/go, rust `-->`, python `File "…", line N`) in the quickfix panel | done |
| pickers: insert / normal mode | insert (typing filters) and normal (`j`/`k`, `gg`/`G`, `<C-d>`/`<C-u>`; `i`/`a`/`/` type; `q` / `<Esc>` close; `h`/`l` up/in in the explorer). `<Esc>` while typing goes to normal. Each source declares `start_mode`: searchable lists start typing, short step-through lists (quickfix, references, diagnostics, jumplist, git changes/menu, confirmations, "Open in") start in normal | done |
| `SPC f q`, `]q` / `[q` | the quickfix list as a picker like any other: each entry with its file and line number, previewed at that line. Starts in normal mode at the current entry; `<CR>` goes there (`<C-v>` / `<C-s>` in a split). `]q` / `[q` step through without it (jumps). With no list of your own it is the project's errors and warnings from the language server, live (this file's first; `]q` / `[q` go by the cursor); a run's errors or `<C-q>` results replace that until a run passes or `x in the quickfix picker` | done |
| in pickers: `<C-q>` | send every current match to the quickfix list and open it (grep, buffer lines, symbols, references, diagnostics, run errors) | done |
| `SPC h k` / `SPC h f` / `SPC f k` | describe key / command, search help | picker |

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
- **What you're on goes last.** A picker never starts on the thing you
  already have (unless it's the only row): buffers, windows, recent files,
  projects and branches list the current one last, so `SPC b Enter` and
  `SPC w Enter` flip back to the previous buffer / window.
- **Scopes, not more pickers.** Pickers that differ only in what they
  range over are one picker with scopes; `C-t` steps through them keeping
  the query, and the bottom bar shows them (`C-t project · open · ...`).
  Groups (`sources.scope_groups`): Files (folder, buffers, recent everywhere,
  whole disk), Search (project, this file, todos), Symbols (this file,
  project), Problems (errors, last run, saved list), Places (jumps, marks),
  Commands (commands, keys).
- **Vim keys on the query.** After `<Esc>` (normal mode), `j`/`k` still move
  through the results and the rest edit the query like a line: `h l w b e W
  B E 0 ^ $`, `x X D C s S`, `d c y` with those motions or `iw aw` (`dd cc
  yy`: all of it), `p P`, `u`, and `i a I A` back to typing at the cursor.
  The explorer, buffers, runner and quickfix keep `h l x dd p o n r m` for
  their rows. While typing, `←` `→` `Home` `End` move the cursor
  (`LineInput` has one).
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
- **Sticky menus (done):** a command flagged `sticky`, run from a menu,
  keeps the menu's prefix typed so the next key is looked up in it again
  (hydra-like): `SPC w r l l h`. A key the menu doesn't have leaves it and is
  then handled on its own.
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
- **Arguments (done):** `ia`/`aa` work on the text alone
  (`textobjects.argument`), so in any file and any brackets: `()`, `[]`,
  `{}` and `<>` where it reads as a bracket (`Vec<T>`, not `a < b`). An
  argument runs from the list's bracket or a comma to the next comma or the
  closing bracket, at that list's own level (nested brackets and strings are
  skipped; `:` and `=` are just text). `aa` takes the comma that keeps the
  list whole, or the lines of an argument on lines of its own.
- **Tree-sitter text objects (done):** `if`/`af` function, `ic`/`ac`
  class/struct (`syntax/objects.zig`). The grammars don't
  ship textobject queries, so each language lists its function/class/list
  node types; "inner" is between the body's braces (linewise like `i{`), or the
  indented block for Python. Zig: call arguments are direct children of
  `call_expression`, and `ac` on `const Foo = struct {...};` takes the whole
  declaration.
- **Defaults:** system clipboard, mouse support, persistent undo tree, smooth
  scrolling.
- **Config in ZON** (`std.zon.parse`): keymaps, theme, per-language settings.

## More pickers

Everything that lists things is a picker (`SPC f SPC` lists them all).

| keys | picker |
|---|---|
| `SPC f SPC` / `SPC f k` / `SPC l m` | every picker; every key binding in every mode (Enter runs it); manual pages, sections 2 and 3 (opens in a buffer) |
| `SPC r r` | the runner: this project's commands, newest first; typed text is a new command and stays the first row (`create_first`); `x` forgets one. `SPC ;` is a separate one-off prompt |
| `SPC f y` / `SPC f m` / `SPC f u` | registers (Enter pastes); marks (`m{letter}`, `'{letter}`, `` `{letter} ``; upper-case ones are global); the undo tree, branches included (`History.goTo`) |
| `SPC f r` / `SPC f v` | recent files (last opened first) / frecent files (most used lately first, with visit counts) |
| `SPC f a` / `SPC f d` | files / folders anywhere on disk (`fd` per query, from three characters; a folder becomes the project) |
| `SPC l a` / `SPC f w` / `SPC l i` | code actions (edit, `codeAction/resolve`, or a command answered through `workspace/applyEdit`); project symbols, searched by the server as you type (`Picker.refill`); implementations |
| `SPC l t`, insert `<C-t>` | write a todo tag as a comment here |
| `SPC p p` | also lists projects found under `Options.project_dirs` (three levels deep) |
| visual `SPC /`, `SPC SPC` | grep / find files for the selection |
| in `SPC .` (list) | `o` folder, `n` file, `r` rename, `m` move, `x` / `dd` delete (asks; permanent), `yy` / `p` copy and paste; open buffers follow a move |
| in `SPC ,` (list) | `x` / `dd` close the buffer, `n` new buffer |

## mini.nvim features

Built in, not plugins; each is on by default unless noted, and visual ones
have a toggle under `SPC t`.

| keys | what (mini module) | where |
|---|---|---|
| `gc{motion}`, `gcc`, visual `gc`, `dgc`, `Ctrl-/` | comment / uncomment lines with the language's prefix, at the block's smallest indent; `gc` after an operator is the comment block (comment) | `core/comment.zig`, `textops.zig` |
| `gr{motion}` / `grr` | replace with a register, which is kept (operators). `gr` used to be references: those are `SPC l u` | `textops.zig` |
| `gx{motion}` twice / `gxx` | exchange two texts; the first is highlighted until the second is picked, `<Esc>` cancels | |
| `gs{motion}` / `gss` | sort lines, or within a line its `,` (else `;`, else space) separated parts | |
| `gm{motion}` / `gmm` | duplicate (lines below, text right after) | |
| `ga{motion}{char}` | align lines on the first `char`; for `,` and `:` what follows is lined up; `=` keeps `+=`, `!=` whole (align, not interactive) | |
| `gS` | split the bracketed list at the cursor one argument per line, or join it back; a trailing comma in zig, rust, python, go (splitjoin) | |
| `in(` `an(` / `iN(` `aN(` | the next / previous object, for every text object but line and indent (ai's `n` / `l`; `l` is the line object here) | `commands.zig` (generated from the spec table) |
| `ii` / `ai`, `[i` / `]i` | the indent scope (with its border lines); jump to its top / bottom border, again for the next scope out (indentscope) | `core/indent.zig` |
| `is` / `as` | the statement: a `{ }` block with its header, as whole lines — `fn foo(...) {` (a signature over several lines too) or `if (x) {` through the closing `}`, a whole `} else {` / `} catch {` chain; on a header line that block, else the innermost around the cursor (`2is` one out); `as` adds the doc comments and attributes above and the blank lines after; `ins` / `iNs` the next / previous one | `core/textobjects.zig` |
| `Alt-u` / `Alt-i` | grow the selection to the next node up the syntax tree (from a cursor: the node under it) / back down the way it grew (to the cursor at the end); helix's `Alt-o`/`Alt-i` (`syntax/objects.zig` `expand`) | `objects.zig` |
| `Alt-n` / `Alt-p` | to the next / previous sibling node: the next argument, statement, field, JSX prop or function (from a cursor: the biggest node starting under it; climbs when there is none); a selection becomes the sibling | `objects.zig` |
| `Alt-N` / `Alt-P` | carry the node (cursor or selection) past its next / previous sibling: `f(a, b)` -> `f(b, a)`; it stays under the cursor / selected, so again carries it further; one undo step; `.` repeats | `objects.zig` |
| `Alt-f` / `Alt-F` | next / previous function (declarations, methods, named arrows like `const Foo = () =>`; not every callback); a jump | `objects.zig` |
| `Alt-c` | cycle the name's case (or each name in the selection): snake_case -> camelCase -> PascalCase -> SCREAMING_CASE -> kebab-case; `_lead`/`trail_` underscores kept; `.` repeats | `core/case.zig` |
| sticky context, `SPC t k` | the first lines of the scopes the top of the window is inside (function, class, `if`, JSX element, object...) pinned over its top rows, highlighted, up to 3, never over the cursor (treesitter-context) | `render.zig` `drawContext` |
| `y`, `p` / `P`, `gp` / `gP` | a yank leaves the cursor where it is (in visual mode, where `v` was pressed; vim's goes to the start); paste; `p` leaves the cursor on the last pasted line (or character), `P` on the first, so pastes in a row with either stack in order; `gp` / `gP` paste inline (a line yanked whole goes inside `foo()` without its newline or indent) | `operators.zig` |
| `g[` / `g]` + object key | to the first / last character of that object | |
| `]b ]d ]h ]c ]x ]j ]q` and `[...` | next / previous buffer, diagnostic, git hunk, comment block, conflict marker, jump, quickfix entry (bracketed) | `Editor.jump*` |
| `f` `t` `F` `T` | reach the next occurrence on any line, ignoring letter case (`fa` finds `A` too); the other targets are highlighted until the next key (jump) | `motions.findAcross` |
| `SPC f t` | todo comments in the project (rg, else a scan) | `sources.Todos` |
| `SPC f r` | recent files, by frecency across sessions; the file picker lists a project's most used files first (visits) | `Visits.zig` |
| `SPC p s` / `SPC p l` | save / restore the project's session: its files, cursors and splits. Saved on quit and when `SPC p p` leaves a project; `SPC p p` into a project with nothing open restores it (sessions) | `Session.zig` |
| `SPC t t` | colour scheme picker with live preview; remembered (hues / base16) | `ui/Theme.zig` |
| `SPC f n` | message and notification history; Enter copies | |
| `SPC f h` | the start screen: recent files and first steps; shown when started without a file (starter) | `sources.Start` |
| `SPC g l`, `SPC t b` | the commit that last changed this line (popup); inline blame on the cursor line, off by default (git) | `git/Blame.zig` |
| `SPC l c` | the colour wheel on the colour literal at the cursor (else the next on the line): `h`/`l` hue around it (`H`/`L` big steps), `k`/`j` saturation out / in, `K`/`J` brightness, `a`/`A` opacity for `#rrggbbaa`, counts (`20l`); `Enter` writes it in the form it had (one undo step), `y` copies, `r` resets, `Esc` cancels. The literal in the text shows the colour live. Strips instead of a wheel in a terminal | `ColorPicker.zig` |
| `SPC l w`, `SPC t x` | trim trailing whitespace; do it on every save (off by default) (trailspace) | |
| `SPC t h` `w` `i` `s` `I` `m` | toggles: todo / colour highlights, cursor word, indent guide, trailing space, icons, smooth scrolling | |

- **Highlights** are drawn by the renderer per visible line (`core/hipatterns.zig`
  scans a line): todo words (in comments only, when there is a grammar) on a
  coloured background, `#rgb` / `#rrggbb` / `#rrggbbaa` on their own colour,
  `0xRRGGBB` underlined in it; other occurrences of the word under the cursor;
  trailing whitespace; a guide line down the cursor's indent scope.
- **Notifications** (`Editor.notify` / `progress`): toasts at the top right for
  things that happen on their own (git jobs, files reloaded, a language
  server's `$/progress` and `window/showMessage`), fading after 4 s. Answers
  to a key still go to the status line (`setMessage`). Both are kept in the
  history.
- **Smooth scrolling** is visual only: `View.scroll_offset` is how many rows
  the drawn text still is from `top`; `Editor.animate(dt)` (window UI only)
  adds the distance when `top` moves and decays it. While anything moves
  (`wantsFrames`), the loop wakes itself instead of waiting for input.
- **Icons** are Nerd Font glyphs baked into the atlas (`ui/icons.zig`); a font
  without them turns the option off.
- **Themes**: "zile" is hand-tuned; the rest are derived at compile time from
  nine-colour palettes (`Theme.fromPalette`). Adding one is a row in `palettes`.
- **State** lives in `$XDG_STATE_HOME/zile/` (`visits`, `sessions/<hash>`,
  `theme`); tests set `Editor.state_dir` or write nothing.

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

## Languages without recompiling

`~/.config/zile/languages.toml` (`$XDG_CONFIG_HOME`) adds languages and
changes built-in ones (`config/config.zig`, read with the built-in TOML grammar
by `config/toml.zig`):

```toml
[[language]]
name = "lua"
extensions = ["lua"]
comment = "--"                    # or ["<!--", "-->"]
indent = 3
formatter = ["stylua", "-"]       # `{path}` is the file's path
server = ["lua-language-server"]  # or { command = [...], language-id = "...", linter = true, markers = [...] }
grammar = { url = "https://github.com/tree-sitter-grammars/tree-sitter-lua", rev = "v0.4.0" }
# also: path = "sub/folder" (repos with several grammars), symbol = "c_sharp" (entry point name)
```

`zile --grammar install [name...]` fetches each grammar (a shallow `git fetch`
of exactly `rev` into `~/.cache/zile/grammar-src/<name>`), builds `parser.c`
(+ `scanner.c` / `scanner.cc`) with `zig cc -shared` (`$ZILE_CC` overrides) and
installs `parser.so` and the repo's `queries/*.scm` into
`~/.local/share/zile/grammars/<name>/`. At startup each listed language with a
`parser.so` there is opened (`dlopen`, `tree_sitter_<symbol>`, ABI checked
against the linked tree-sitter) and registered (`languages.register`; a
built-in of the same name is replaced). `zile --grammar list` shows every
language, where its grammar comes from and whether its highlight query
compiles. `~/.config/zile/queries/<name>/highlights.scm` replaces any
language's highlighting, built-in ones too. Config servers are added to
`Lsp.servers` and win over built-in ones for their language; a config
formatter wins over the server's formatting; comment and indent override the
defaults. Problems (bad TOML with its line, a grammar not built yet, a parser
of the wrong ABI) show as notifications at startup. Not configurable yet: folds
and text objects (`objects.zig` specs) for new languages.

## Everyday (from the nvim config)

| What | Does |
|---|---|
| autosave | a modified file is written when you leave it (another buffer or window) or zile loses focus (the window's focus; in a terminal, its focus reports, mode 1004). Not on quit: `QQ` still discards. Claude's proposals are never saved behind your back. `options.autosave` |
| reopen where you were | the cursor's line and column are kept per file in the visits file (`count last line col path`), and a file opens there |
| persistent undo | on every save the undo tree is written to `$XDG_STATE_HOME/zile/undo/<hash of path>` with a hash of the text; opening the file brings it back if the text still matches (else a fresh history) |
| line wrap | on by default (`SPC t l`): long lines break at word boundaries, later rows under the line's indentation (`Editor.segments`; inlay hints count). Each line has rows (`Row.sub`): its code lens row, then its pieces. `j`/`k` move by screen row keeping the screen column (as `gj`/`gk`), a count moves whole lines; operators and visual mode stay linewise. No sideways scrolling while wrapping. The renderer draws each row through a column window (`win_left`, `win_right`, `win_indent`). |
| code lens | `textDocument/codeLens` once the text is still (as inlay hints), titles filled in with `codeLens/resolve`; a dim row above the line, several joined with ` \| ` (`SPC t c`). vtsls is asked for reference and implementation counts. The cursor steps over lens rows. |
| mouse | a drag selects (visual), a double-click selects the word, a triple-click the line; letting go copies the selection to the clipboard, with a flash and a note (as kitty and the nvim config) |
| `U` | redo (`<C-r>` too) |
| insert `<C-;>` | a `;` at the end of the line, the cursor staying |
| `gV` | selects the text last changed or yanked |
| `SPC t s` | the scratch pad: `$XDG_DATA_HOME/zile/scratch.md` in a window at the bottom; again saves and closes it |
| standalone Zig | a `.zig` file with no `build.zig` above it is checked on open and save in the background: `zig ast-check`, then `build-exe` (if it has `pub fn main`) and `test` (if it has tests) with `-fno-emit-bin`, again with `-lc` when it needs libc; its errors become diagnostics (`ZigCheck.zig`) |
| saving JS/TS | eslint's `source.fixAll.eslint`, then vtsls's organize imports, then prettier, then write; each step waits at most 2 s for its server |
| JSON | `vscode-json-language-server` with schemas for `package.json`, `tsconfig*.json`, `app.json` (Expo) and `eas.json`; prettier formats JSON (and YAML) |
| SQL completion | keywords, tables and columns of the database (loaded in the background with psql / sqlite3 when a SQL file is shown, again after a statement that creates, alters or drops); after `name.` only that table's columns, aliases (`from users u`) included; the file's words too |

## Shell and SQL

**Bash** (tree-sitter-bash): `.sh` `.bash` `.zsh`, dotfiles (`.bashrc`,
`.zshrc`, `.profile`, `.xinitrc`...), `PKGBUILD`, and any file whose first line
is a `#!` naming a shell (`languages.forShebang`, which also knows python,
node, deno and bun). `#` comments, `shfmt` formatting. No server built in
(`bash-language-server` isn't installed; add it in `languages.toml`).

**Binary files** open as a hex dump (`core/hex.zig`, the `xxd` layout:
offset, 16 bytes in pairs, their text); `[hex]` in the status line. Edit
the hex digits with the usual keys; saving reads the hex back, top to
bottom, into the file's bytes (the offsets and text column are only for
reading, so bytes can be added or removed), and refuses a line that isn't
hex. Binary = a NUL byte in the first 8 KB; up to 16 MB.

**Go** (tree-sitter-go v0.23.4): `.go`; `gopls`; `gofmt` on save; tabs
in a new file; `af` functions and methods, `ac` structs / interfaces with
their name, `ia` parameters and arguments; folds; `Alt-f` skips `func`
literals.

**Lua** (tree-sitter-lua v0.2.0, tree-sitter-grammars): `.lua`
`.rockspec` `.luacheckrc` and `#!` lua / luajit; `--` comments;
`lua-language-server`; `stylua` on save; `af`/`if` functions (also
`local f = function() … end`), `ia` arguments, `ic` tables, folds for
functions, blocks and tables.

**`.env` files** (`.env`, `.env.local`, `.env.production`, `app.env`:
`languages.isEnvFile`) use the bash grammar: keys, quoted values, `#`
comments, `${VAR}`. They're not formatted on save (shfmt would rewrite
`KEY=a b`) and no language server gets them.

**SQL** (tree-sitter-sql, pinned to its `gh-pages` commit: only that branch
carries the generated parser): `.sql` `.psql` `.pgsql`, `--` comments,
`pg_format` formatting. Ctrl-Enter in a SQL file runs the statement at the
cursor (from the `;` before it to its own; quotes and `--` comments
skipped), in insert mode too (you stay typing); in visual mode the selected
lines. The whole file: "Run the whole SQL file" in the command picker
(`sql.zig`). The runner (`SPC r`) is shell commands only. A statement runs in the
background (`sql.Results`: `psql -q --csv` / `sqlite3 -csv`, no shell) and
its rows open in the **SQL results grid** (`ResultGrid.zig`, docked
like a picker, over the code): a cell cursor moved with vim's keys (`hjkl`,
`w` / `b` next / previous cell, on across rows, `0` `$` `gg` `G`, counts,
Ctrl-d/u), `v` (or Ctrl-v) a block of cells, `V` rows, `y` yanks the cell
or the selection (tabs between values, a line per row), `Y` the row, `/`
searches the cells (`n` / `N`, around the end), `o` the results as a table
in a buffer (`sql.tableText`, never wrapped), Esc / `q` closes. The line
under the rows shows the cell at the cursor in full. "SQL results" in the command picker
brings the last ones back. Results that arrive while you type don't open
over you (a message says how many rows). An error is the database's own
words in a box at the cursor; no rows back is a message. The whole file
still runs as a script in the run popup. Not yet: stopping a statement
that runs long, row counts of an UPDATE. The database, as
the nvim config: `$DATABASE_URL`, else `DATABASE_URL` in the nearest `.env`
above the file, then above the working folder. `postgres://` runs `psql -X -v
ON_ERROR_STOP=1`, `sqlite:path` (or a `.db` / `.sqlite` path) `sqlite3 -header
-column -bail`, in the run popup (`r` again, `y` yank, timing). The URL reaches
the command as `$ZILE_DB`, so a password never shows in the command line or
messages (`sql.redact` hides it in the "psql on ..." message). Not yet: table
and column completion from the database.

## Config files: TOML, YAML, JSON

Tree-sitter grammars for all three (`.toml`; `.yaml` `.yml`; `.json` `.jsonc`
`.json5` `.webmanifest`): highlighting, folds (tables, mappings, objects,
arrays) and `ic` / `ia` over tables / objects and arrays. `#` comments in TOML
and YAML, `//` in JSONC. New files indent by two. Formatting: `jq` for JSON,
prettier for YAML, `taplo` for TOML when installed.

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
  `SPC g u` reload HEAD (after committing outside the editor).
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
(regex is a TODO). `SPC f l` is the line picker for the buffer.

## LSP

Current state: `lsp/Client.zig` (stdio transport, reader thread, messages held
until `initialize` is answered), `lsp/Lsp.zig` (one instance per server,
full-text `didChange` once per frame, diagnostics by path, request
bookkeeping), `lsp/Completion.zig`. Servers are a built-in table in
`Lsp.servers` (no config yet, see below); each starts when the first file of
its language opens in a project.
A server's error output goes to `$XDG_CACHE_HOME/zile/lsp/<name>.log`
(replaced at each start). One that exits is started again on the next tick
(its files reopened), up to 3 times; each notification says why, from the
log's last line.
Completion trigger characters come from each server's `initialize` reply;
completion matching uses `filterText` (clangd labels carry a bullet or
signature).
Gotcha: empty params must be `struct {}{}`; `.{}` serializes as `[]` and zls
exits with a ParseError. Next: per-language server config, incremental sync,
signature help, code actions, rename, formatting.

**Inlay hints** (type and parameter labels, `SPC t v` toggles): the server is
asked (`textDocument/inlayHint`) for the lines in view and a screenful either
side, again once the text has been still for 250 ms or the view leaves what was
asked, and when it sends `workspace/inlayHint/refresh`. Hints live on the
buffer (`Buffer.hints`, byte offsets kept in place by `Buffer.insert` /
`delete`) and are drawn in front of the text they belong to: the renderer adds
each hint's width to every column after it (text, cursor, selection, search
matches, diagnostics, popups; `Editor.hintShift`), and clicks map back
(`hintVisualToText`). No hints on the line being typed on in insert mode; they
return with Esc. An answer for text that has since changed is dropped.

**Servers** (`Lsp.servers`): zls, clangd, rust-analyzer; `vtsls` for
JavaScript, TypeScript and TSX (one per project for all three; `.jsx` is
`javascriptreact`, `.tsx` `typescriptreact`); `vscode-html-language-server`;
`vscode-css-language-server`. A row marked `linter` runs beside a file's main
server for diagnostics only: `vscode-eslint-language-server`, started only in
projects with an eslint config at the root (looked for once per project), given
nvim-lspconfig's settings (flat config when `eslint.config.*` exists); its
messages end in the rule's name. `Editor.diagnostics` merges every server's for
a file; completion, hover and the rest go to the main server.

**A missing bracket** (`lsp/balance.zig`): a file that doesn't parse loses its
types and errors after the mistake, so the server is sent it closed at the end
(the missing `}` `)` `]` appended; never for HTML, where a `(` is prose), and
the real text is opened beside it as `zile-real-<name>` in the same folder; the
diagnostics of both are shown (the added lines' dropped), and our own "unclosed
'{'" stands in when the real text's has no syntax error.

## Web: HTML, CSS, JavaScript, TypeScript, JSX

Grammars: tree-sitter html, css, javascript (also `.jsx`), typescript and tsx
(`build.zig` rows may name a source folder and several highlight files; TS's
queries add to JavaScript's). zile's own `queries/jsx.scm` and
`queries/html.scm` come last: element and component names (`div`, `View`),
props / attributes and `<` `>` `</` `/>` get the `tag`, `tag_attribute` and
`tag_delimiter` styles (night-owl: teal, green, teal). Formatting is prettier's (`prettierd`, else
`prettier --stdin-filepath`), even where the server could format. Files with no
indentation yet indent by two.

| What | Does | Status |
|---|---|---|
| `>` ending an opening tag | adds the closing tag: `<div|` -> `<div>|</div>`; not for void elements (`<br>`) or `<x />`; `<>` gets `</>` | done |
| `</` | closes the innermost open element (`</li>`); on a line of its own, at the opening tag's indentation | done |
| `<CR>` in `<div>|</div>` | content on its own indented line | done |
| editing a tag name | its partner changes as you type (`ciw`, `x`, insert mode; either tag), one undo step; tags are paired from the tree-sitter tree (`tags.zig`) | done |
| `<Tab>` after an Emmet abbreviation | `ul>li.item$*3`, `.card`, `a`, `View.box`, `p{text}`, `(dt+dd)*2`, `^`; tab stops in empty contents and attribute values; `className` in JSX, void elements self-close there (`emmet.zig`) | done |
| completion between tags | HTML elements, and in JSX components (as the nvim `jsx_tags` source: the common React Native ones, names on `import` lines, capitalized `function`/`const` definitions): `view` -> `<View></View>` | done |
| snippets in completion | ported from the nvim config (`snippets.zig`): React Native (`rnc` `us` `ue` `ufe` `uc` `um` `ur` `press` `input` `sty` `flatlist`) in `.jsx`/`.tsx`, `af` `aa` `tc` `fetch` `log` in the JS family, `intf` `type` `props` in TS; an exact trigger goes first, otherwise after the server's items; written in the file's indentation; <Esc> keeps their defaults | done |
| comments | `<!-- -->` in HTML, `/* */` in CSS, `{/* */}` on lines among JSX children (`//` elsewhere) | done |
| `it` / `at` | tag objects, skipping `{...}` in JSX attributes | done |
| `if` `ic` `ia`, folds | functions (incl. arrows, methods), classes / interfaces / enums, arguments; CSS rules; HTML elements | done |

In JSX a `<` starts a tag only where an expression can start (after `(`, `=`,
`=>`, `return`, another tag...), so TypeScript generics (`Array<string>`) are
left alone; in HTML not inside `<script>` / `<style>`; `.ts` files have no tags.

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

## Debugger (gdb)

`debugging.zig` is the editor's side (what to debug, the stop, breakpoints;
its state is `Editor.dbg`). `Debugger.zig` speaks the Debug Adapter Protocol to `gdb -i dap` (through the
LSP's stdio client; started with `setsid` so gdb doesn't take the terminal,
and killed with SIGKILL: gdb ignores SIGTERM). The program runs on the run
popup's own terminal (gdb's `inferior-tty`, held open by a waiting process),
so its output and input work as in a plain run; Ctrl-C there pauses it.

- **Starting.** In `SPC r`, Ctrl-Enter runs the command under gdb; plain
  Enter does too when the project has breakpoints switched on. `SPC d r`
  runs the last runner command the same way, `R` under gdb always.
- **From a command to a program** (`Debugger.plan`): `./app args` and
  `make && ./app` name it; `zig run x.zig` is built to a path zile chooses;
  `cargo run --bin x` is `target/debug/x`. `zig build run` / `cargo run`
  don't say: the build runs first, then compiled programs (ELF executables)
  are looked for where the build system puts them (`zig-out/bin`,
  `target/debug`) and, with none there, anywhere in the folder (hidden
  folders skipped): one is used; several are listed in `SPC d` ("Debug
  which program?", newest first; Enter starts it without building again).
  The pick holds for the session only (nothing on disk).
- **The debugger's command.** The first time a runner command is debugged
  in a session it comes up in the command editor (a vim buffer, "Debug
  command"), to change for the debugger: take release flags out, other
  arguments, or `zig build && ./zig-out/bin/app` to name the program. Enter
  debugs it, and that runner command debugs as it for the session; the
  runner's own command is untouched. It's the first row of `SPC d` when
  idle (Enter debugs, `e` changes it). Commands are built as written:
  release flags only get a note that variables may be missing.
- **Runner:** `c` on a row opens that command in the same vim editor
  (Enter runs it and it joins the history); `e` / `C-e` puts it in the
  query line for a quick change.
- **Stopped** (breakpoint, step, crash): the editor goes to the innermost
  frame in your code (`▶`, tinted line) and `SPC d` opens: rows are the
  stack, the preview a frame's arguments and locals. `n` next, `s` step in,
  `f` finish, `c` continue, `p` pause, `x` stop, `o` output.
- **Values**: what is inside a variable (a struct's fields, a slice's
  items, what a pointer points at) is listed indented under it, three
  levels down, 32 of each; for the frame it stopped in at once, for
  another when you look at it. This is gdb's own reading of the program,
  so it is the same for C, C++, Rust and Zig.
- **Printers** (`src/gdb_setup.py`, embedded and sent to gdb at the
  start): what gdb doesn't find on its own. C needs none; C++'s come with
  the compiler and gdb loads them. Rust's (`String`, `Vec`, `HashMap`)
  come with the toolchain but only `rust-gdb` says where: a Rust program
  gets them from the `rustc` its folder uses; an enum reads as its variant
  (`Some(42)`, `Named` with its fields). Zig has none, so they are here: a
  `[]u8` is its text, a slice its items, an optional what it holds or
  `null`, an error union its value or `error.X`, a tagged union `.tag`
  and that field.
- **Breakpoints** (`●`, kept for the session): `b` on the cursor's line,
  `d` remove the row's, `B` remove all, `t` all on/off (off: kept, hollow
  `○`, runs run normally), `u` undo. `C-j` / `C-k` move the editor's cursor
  with the picker open.
- Breakpoints follow their lines as you edit (a buffer tells a line
  listener when lines are added or removed); gdb gets the new lines at the
  next debug. A build's program is looked for off the main thread.
- Not yet: Zig pretty printers, values inline,
  expanding structs, evaluating expressions.

## Claude Code (IDE protocol)

`ai/WsServer.zig`: a WebSocket server on 127.0.0.1 (random port; the
`X-Claude-Code-Ide-Authorization` token checked in constant time; ping/close
answered; one JSON-RPC message per text frame) on its own thread.
`ai/Claude.zig`: the lock file `$CLAUDE_CONFIG_DIR|~/.claude/ide/<port>.lock`
(0600 in a 0700 dir; `pid`, `workspaceFolders` = cwd + projects, `ideName`,
`transport: "ws"`, `authToken`), rewritten when projects change and removed
on exit; MCP `initialize` (echoes a supported protocol version), `tools/list`,
and the tools `openDiff` (blocking: a proposal buffer with the current file
as its diff base; `SPC a y` answers `FILE_SAVED` + the text, `SPC a n`
`DIFF_REJECTED`), `close_tab`, `closeAllDiffTabs`, `openFile`,
`getDiagnostics`, selection / open editors / workspace queries,
`checkDocumentDirty`, `saveDocument`. It sends `selection_changed` when the
cursor or selection moves and `at_mentioned` for `SPC a s` (queued until
connected). The panel runs `claude` with `CLAUDE_CODE_SSE_PORT=<port>`, so it
connects to this editor. Claude writes accepted files itself; buffers
whose files change on disk reload (checked each second; unsaved buffers are
left alone). Terminals can now be windows (`Window.term`, borrowed).

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

## Building

`zig build` installs a debug zile to `zig-out/bin/zile` (for development:
safety checks, slow to start: ~0.65 s to the first frame of a 12k-line file).
`zig build release` installs an optimized one to `zig-out/release/zile` for
everyday use (on its own screen in 1 ms, first frame ~80 ms). In terminal
mode zile switches to the alternate screen before loading anything, so a
launcher that leaves its own screen first (yazi) doesn't show the old
terminal contents meanwhile.

## Debugging

```
zig build test                                        # headless core tests
zig build test -Dtest-filter=debugging                # only tests whose names match
ZILE_TEST_KEYS='3jwi// hi<Esc><Space>f' ZILE_TEST_SCREENSHOT=/tmp/shot.png zig build run -- file.zig
```
`ZILE_TEST_KEYS` feeds key notation at startup; `ZILE_TEST_SCREENSHOT` saves a
PNG of the first frames and exits.
