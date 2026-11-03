# Helix default keymap and selection model: catalogue for picking a v1 subset

Question: what does Helix's default keymap contain, how does its selection model work, and which parts need tree-sitter (TS), LSP, or picker UI rather than being pure editing? The aim is a table we can pick a v1 command subset from.

All sources are pinned to helix-editor/helix master at commit [`ba40e54`](https://github.com/helix-editor/helix/tree/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc) (committed 2026-09-29, fetched 2026-11-03). Short names used below:

| Short name | File |
|---|---|
| `keymap.md` | [book/src/keymap.md](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/book/src/keymap.md) |
| `default.rs` | [helix-term/src/keymap/default.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/keymap/default.rs) |
| `commands.rs` | [helix-term/src/commands.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs) |
| `selection.rs` | [helix-core/src/selection.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs) |
| `transaction.rs` | [helix-core/src/transaction.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/transaction.rs) |
| `history.rs` | [helix-core/src/history.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/history.rs) |
| `movement.rs` | [helix-core/src/movement.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/movement.rs) |
| `textobject.rs` | [helix-core/src/textobject.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/textobject.rs) |
| `ui/editor.rs` | [helix-term/src/ui/editor.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/ui/editor.rs) |
| `document.rs` | [helix-view/src/document.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/document.rs) |
| `register.rs` | [helix-view/src/register.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/register.rs) |
| `textobjects.md`, `registers.md`, `surround.md`, `usage.md`, `jumplist.md` | [book/src/](https://github.com/helix-editor/helix/tree/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/book/src) |

Where the book and the code disagree, the code (`default.rs`) is authoritative. Disagreements found are listed in [Doc vs code discrepancies](#doc-vs-code-discrepancies).

---

## 1. Selection model (helix-core)

### Range
- `Range { anchor, head, old_visual_position }`. The **head** moves when you extend; the **anchor** stays put. They can be in either order or equal ([selection.rs L20-63](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L20-L63)).
- Positions are **char offsets with gap indexing**: index `n` is the gap between char `n-1` and char `n`. A range is **half-open `[from, to)` whatever its direction**, so two adjacent non-empty ranges do not overlap (same doc comment).
- **Block-cursor convention:** the user-visible cursor is one grapheme wide, on the head side, pointing inward. `cursor()` returns `prev_grapheme_boundary(head)` when `head > anchor`, otherwise `head` ([L332-341](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L332-L341)). `put_cursor(idx, extend)` handles the anchor fix-ups that keep both ends behaving like 1-wide blocks ([L343-371](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L343-L371)).
- `old_visual_position` remembers the column you came from for vertical moves (the "sticky column"). Any map or extend clears it.
- Invariants are restored by `ensure_invariants`. Every range becomes at least 1 char wide (`min_width_1`) and grapheme-aligned, then the selection is normalized ([L662-665](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L662-L665)). **In practice a "cursor" is a 1-char selection, not a zero-width one.**
- Mapping through edits: `Range::map` maps both ends with sticky associations. A forward range uses anchor `AfterSticky` and head `BeforeSticky`, so text inserted at either edge stays *outside* the selection ([L174-203](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L174-L203)). `ChangeSet::update_positions` maps a sorted position list in O(N+M) ([transaction.rs L374-388](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/transaction.rs#L374-L388)).

### Selection
- `Selection { ranges: SmallVec<[Range;1]>, primary_index }`. It is **never empty** ([L414-420](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L414-L420)).
- **Normalize** sorts the ranges by `from` and merges overlapping ones. If a merge swallows the primary range, the merged range becomes primary ([L557-587](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L557-L587)). Adjacent ranges are *not* merged; `merge_consecutive_ranges` (`Alt-_`) does that explicitly.
- `push` adds a range and **makes it primary** ([L450-455](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L450-L455)). This is how `C` and select-mode `n` grow multicursor.
- `into_single` keeps only the primary range (`,`). `remove(i)` refuses to remove the last range.
- **Regex ops** (pure functions in selection.rs, [L767-882](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/selection.rs#L767-L882)):
  - `select_on_matches` (`s`): each match inside each range becomes a range.
  - `split_on_matches` (`S`): the text *between* matches becomes ranges.
  - `split_on_newline` (`Alt-s`): one range per line.
  - `keep_or_remove_matches` (`K` / `Alt-K`): keep or drop ranges that contain a match.
  - All four reset `primary_index` to 0 and do not keep range direction (marked as TODOs in the source).

### Transaction, undo, history
- `ChangeSet` is a list of `Retain(n) / Delete(n) / Insert(text)` operations. It supports `compose`, `invert(original)`, `apply`, `map_pos`. `Transaction = ChangeSet + Option<Selection>` and is "a single undoable unit" ([transaction.rs L571-628](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/transaction.rs#L571-L628)). Multicursor edits are built per range with `change_by_selection` / `delete_by_selection`, giving one ChangeSet for all cursors.
- `History` is a **tree** of revisions stored in a `Vec`. Each revision has a parent, a last_child, its transaction, an inversion (needed because Delete doesn't store the deleted text) and a timestamp. `u` / `U` walk parent / last-child. `earlier` / `later` (`Alt-u` / `Alt-U`) walk by revision count or by time ([history.rs L13-66](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/history.rs#L13-L66)). Stated limitations: selection-only changes do not create revisions, and history is unbounded.
- **Undo granularity:** `Document` accumulates applied changes in `self.changes`. `append_changes_to_history` composes them into one revision, which also records the current selection ([document.rs L1804-1825](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/document.rs#L1804-L1825)). The editor calls it **after every key handled outside Insert mode** ([ui/editor.rs L1575-1579](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/ui/editor.rs#L1575-L1579)). The result:
  - One normal-mode command, e.g. `d` on 50 cursors, is one undo step.
  - A whole insert session, from entering insert to `Esc`, is one undo step, together with the `c` that started it.
  - `Ctrl-s` in insert mode (`commit_undo_checkpoint`) splits the session.
  - Jumps (`push_jump`) and paste also commit.
  - Undo first commits any pending changes ([document.rs L1682-1704](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/document.rs#L1682-L1704)).

### Motion semantics (selection-first)
- In Normal mode a motion **replaces** each range with a new one, usually the span it travelled over. `w` selects from the current position to the next word start, because `range_to_target` resets the anchor at the boundary where it starts ([movement.rs L216-308, L416-489](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-core/src/movement.rs#L216-L308)). In Select mode the same keys call the `extend_*` variants, which keep the anchor ([default.rs L342-380](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/keymap/default.rs#L342-L380)).
- Every motion and command runs on **all ranges** (`selection.transform(...)`). Multicursor is not a separate feature; it is the default case.
- `x` selects the whole line including its newline. Pressing it again on an already line-selected range adds the next line ([commands.rs `extend_line_impl` L2813-2850](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L2813-L2850)).
- `i` flips each range so the cursor sits at `from`; the range is kept. `a` puts the cursor at `to`, first adding a newline at EOF if needed ([commands.rs L3119-3170](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L3119-L3170)). `c` deletes and enters insert. If every range was whole lines, it opens a fresh line above instead ([L2983-3020](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L2983-L3020)).
- `;` collapses each range to its block-cursor position. `Alt-;` flips anchor and head. `Alt-:` forces forward direction ([L3083-3113](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L3083-L3113)).
- Search `n`: in Normal mode it **replaces** the primary range with the next match. In Select mode it **pushes** the match as a new primary range, which is the Kakoune-style way to add cursors on matches ([commands.rs L2322-2329](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L2322-L2329); `keymap.md` "Select / extend mode").

### Registers, yank, paste
- A register holds a **list of values, one per selection**. `yank` writes `selection.fragments()` ([commands.rs `yank_impl` L4842-4860](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L4842-L4860)). `d` and `c` also yank unless you use the `Alt-` variant or register `_` (L2989-3000).
- **Paste** zips register values to ranges. If there are more ranges than values, the last value repeats. If **any** value ends in a line ending, the whole paste is **linewise**: it goes before the first line or after the last line of each range. Otherwise it goes at `from` (`P`) or `to` (`p`). Line endings are normalized to the document's. The pasted text becomes the new selection, and a count repeats the text ([`paste_impl` L4941-5022](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L4941-L5022)).
- Default registers ([registers.md](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/book/src/registers.md)):
  - `"` last yank, `/` last search, `:` last command, `@` last macro.
  - Special: `_` black hole, `#` selection indices, `.` current selection contents, `%` file name.
  - `+` / `*` are the system and primary clipboards. Writing joins the values with newlines. Reading returns them as multiple values only if this session wrote the clipboard ([register.rs L80-103](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-view/src/register.rs#L80-L103)).
- `R` replaces the selections with yanked text. `Space y/p/P/R/Y` are the same commands bound to the `+` register.

### Repeat
- `.` is **"repeat last insert" only**. The editor records the command that entered Insert mode plus the keys typed until it left, and `.` replays both ([ui/editor.rs L956-963, L1029-1075, L1546-1547](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/ui/editor.rs#L1029-L1075)). It does **not** repeat `d`, `>`, `~` and similar, and it does not replay the selection step: after `miwc foo<esc>`, `.` replays `c foo` on whatever is selected now. A count is supported.
- `Alt-.` (`repeat_last_motion`) repeats the last `f/t/F/T`, `mi/ma` textobject, or `[`/`]` motion. These motions are recorded by `editor.apply_motion` ([commands.rs `select_textobject` L6262-6339](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L6262-L6339)).
- Macros: `Q` records into a register (default `@`) and `q` replays it as a key sequence (marked "experimental" in `keymap.md`).
- Counts: digits typed before a command form a count of up to 100,000,000. `0` cannot start a count ([ui/editor.rs L1013-1028](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/ui/editor.rs#L1013-L1028)).

### Textobjects (`mi` / `ma`)
Source: [commands.rs L6303-6334](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L6303-L6334) and [textobjects.md](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/book/src/textobjects.md).

| Key | Object | Needs |
|---|---|---|
| `w` / `W` | word / WORD | none |
| `p` | paragraph | none |
| any non-alphanumeric char, e.g. `(` `"` `[` | that pair | none. Takes `Option<syntax>`: TS is used when present, plaintext search otherwise |
| `m` | closest surrounding pair | TS-preferred (help text says "tree-sitter"); also takes `Option<syntax>` |
| `f` `t` `a` `c` `T` `e` `x` | function, type, argument, comment, test, entry, XML element | **TS** plus a `textobjects.scm` query. Without syntax it does nothing |
| `g` | VCS diff hunk | diff provider (git) |

A count selects outer levels. Surround (`ms` add, `mr` replace, `md` delete) reuses the same pair finder, so it works without TS ([surround.md](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/book/src/surround.md)). `mm` (`match_brackets`) uses TS when available and falls back to `find_matching_bracket_plaintext` ([commands.rs L5895-5914](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L5895-L5914)). `keymap.md` marks `mm` as **TS**, but the code has a plaintext fallback.

---

## 2. Modes

Source: [default.rs](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/keymap/default.rs).

- **Major modes:** `Mode::{Normal, Select, Insert}`. Select is built as `normal.clone()` with motion keys overridden by `extend_*` versions (`hjkl wbe WBE f t F T n N Home End Alt-e Alt-b g{g | e j k w}`); `v` and `Esc` leave it. Any edit command run in Select mode (`d`, `y`, ...) calls `exit_select_mode`.
- **Minor modes** are nested `KeyTrie` nodes in the keymap, not real modes: `g` goto, `m` match, `z` view, `Z` sticky view, `Space`, `Ctrl-w` window, `[` / `]` unimpaired, plus `Space G` debug (sticky). A **sticky** node stays active until `Esc`. Pending nodes show an infobox (`autoinfo`).
- **Command mode** `:` opens a prompt UI for typed commands. It is not a keymap node.

---

## 3. Catalogue table

Columns:
- **Kind**:
  - Sel: changes only the selection.
  - Edit: changes the text.
  - Nav: moves the view or jumps.
  - UI: picker, prompt, or popup.
  - Sys: shell, clipboard, or files.
- **Dep**:
  - `-`: pure, needs only buffer and selection.
  - `TS`: tree-sitter.
  - `LSP`: language server.
  - `VCS`: diff provider.
  - `Prompt`: needs a minibuffer text input, a small UI and not a picker.
  - `Clip`: system clipboard.
  - `Shell`: runs a process.
- **v1?**:
  - **A**: strong v1 candidate.
  - **B**: cheap follow-up.
  - **C**: later or out of scope.
  - This is my suggestion, for the planners to override.

### Normal-mode movement
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `h j k l` / arrows | `move_char_left/right`, `move_visual_line_up/down` | Sel | - (visual line needs soft-wrap layout) | A |
| `w b e` / `W B E` | word / WORD start and end | Sel | - | A |
| `f t F T` + char | find/till char, not limited to the line | Sel | - (reads next key) | A |
| `Alt-.` | `repeat_last_motion` | Sel | - | B |
| `Home End`, `gh gl gs` | line start, end, first non-blank | Sel | - | A |
| `<n>G`, `gg`, `ge`, `g\|` | goto line, file start, last line, column | Sel+jump | - | A |
| `gt gc gb` | window top, centre, bottom | Sel | - (needs viewport) | B |
| `gj gk` | textual (not visual) line down/up | Sel | - | B |
| `Ctrl-b/f`, `PgUp/PgDn`, `Ctrl-u/d` | page and half-page | Nav+Sel | - | A |
| `Ctrl-o Ctrl-i Ctrl-s` | jumplist back, forward, save | Nav | - | B |
| `g.` | last modification | Sel | - (history) | B |
| `gw` | label jump (`goto_word`) | Sel | - (needs label overlay UI) | C |
| `]p [p` | paragraph next/prev | Sel | - | B |
| `]f [f ]t [t ]a [a ]c [c ]e [e ]T [T ]x [x` | function, type, arg, comment, entry, test, XML-element navigation | Sel | **TS** | C |
| `]d [d ]D [D` | diagnostics | Nav | **LSP** | C |
| `]g [g ]G [G` | VCS hunks | Nav | **VCS** | C |

### Mode entry and insert
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `i a I A o O` | insert, append, line start/end, open below/above | Edit | - | A |
| `v`, `Esc` | select mode, normal mode | mode | - | A |
| Insert: `Backspace Del Enter Tab S-Tab` | `delete_char_*`, `insert_newline`, `smart_tab`, `insert_tab` | Edit | - (smart-tab and auto-indent are better with TS indent queries) | A |
| Insert: `Ctrl-w`/`Alt-Bksp`, `Alt-d`, `Ctrl-u`, `Ctrl-k` | delete word back/forward, kill to line start/end | Edit | - | B |
| Insert: `Ctrl-s` | `commit_undo_checkpoint` | Edit | - | B |
| Insert: `Ctrl-r` + reg | `insert_register` | Edit | - | B |
| Insert: `Ctrl-x` | `completion` | UI | **LSP** (or word completion) | C |
| Insert: arrows, Home, End, PgUp, PgDn | movement | Sel | - | A |

### Changes
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `d`, `Alt-d` | delete (yank / no yank) | Edit | - | A |
| `c`, `Alt-c` | change (yank / no yank) | Edit | - | A |
| `y`, `p`, `P` | yank, paste after/before (linewise detection) | Edit | - | A |
| `"` + reg | `select_register` | - | - | B |
| `R` | `replace_with_yanked` | Edit | - | B |
| `r` + char | replace every char in the selections | Edit | - | A |
| `~`, `` ` ``, `` Alt-` `` | switch case, lower, upper | Edit | - | B |
| `>` `<` | indent, unindent | Edit | - | A |
| `J`, `Alt-J` | join lines (select inserted space) | Edit | - | B |
| `u U` | undo, redo | Edit | - | A |
| `Alt-u Alt-U` | earlier, later (history tree) | Edit | - | C |
| `.` | repeat last insert | Edit | - | B |
| `Q q` | record, replay macro | Edit | - | C |
| `Ctrl-a Ctrl-x` | increment/decrement number (also dates and similar) | Edit | - | C |
| `Ctrl-c`, `Space c/C/Alt-c` | toggle comments | Edit | needs language comment tokens (config; TS injection-aware) | B |
| `=` | format selections | Edit | **LSP** | C |
| `\| Alt-\| ! Alt-! $` | pipe, pipe-to, insert/append output, keep-pipe | Edit/Sel | **Shell** + Prompt | C |
| `]Space [Space` | add newline below/above (no mode change) | Edit | - | B |

### Selection manipulation (multicursor core)
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `x`, `X`, `Alt-x` | extend line below, extend to line bounds, shrink to line bounds | Sel | - | A |
| `%` | select all | Sel | - | A |
| `;` | collapse to cursor | Sel | - | A |
| `Alt-;`, `Alt-:` | flip, ensure forward | Sel | - | A / B |
| `,`, `Alt-,` | keep primary, remove primary | Sel | - | A |
| `C`, `Alt-C` | copy selection to next/prev line (add cursor) | Sel | - | A |
| `(` `)` | rotate primary range | Sel | - | A |
| `Alt-(` `Alt-)` | rotate selection *contents* | Edit | - | C |
| `s` | select regex matches within selections | Sel | Prompt + regex engine | A |
| `S` | split selections on regex | Sel | Prompt + regex | A |
| `Alt-s` | split on newlines | Sel | - | A |
| `K`, `Alt-K` | keep/remove selections matching regex | Sel | Prompt + regex | B |
| `Alt-minus`, `Alt-_` | merge all, merge consecutive | Sel | - | B |
| `&` | align selections into columns | Edit | - | C |
| `_` | trim whitespace from selections | Sel | - | B |
| `Alt-o/i/p/n/a/I`, `Alt-up/down/left/right`, `Alt-e/b` | expand/shrink to syntax node, siblings, children, parent start/end | Sel | **TS** | C (high-value once TS lands) |
| `Space h` | select references to symbol | Sel | **LSP** | C |

### Search
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `/ ?` | search, reverse search (regex, incremental) | Sel | Prompt + regex | A |
| `n N` | next/prev match. Normal mode replaces primary; Select mode adds a cursor | Sel | - | A |
| `*`, `Alt-*` | selection becomes search pattern (`*` adds `\b`) | Sel | - | A |
| `Space /` | global search | UI | picker + file walk | C |

### Match mode `m`
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `mm` | match bracket | Sel | - (plaintext fallback; TS better) | A |
| `mi`/`ma` + `w W p` or pair char | textobjects | Sel | - | A |
| `mi`/`ma` + `m` | closest pair | Sel | TS-preferred (`Option<syntax>`) | B |
| `mi`/`ma` + `f t a c T e x` | syntax textobjects | Sel | **TS** + queries | C |
| `mi`/`ma` + `g` | change hunk | Sel | **VCS** | C |
| `ms mr md` | surround add, replace, delete | Edit | - | B |

### View mode `z` / `Z`
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `zz/zc zt zb` | align view centre, top, bottom | Nav | - | A |
| `zm` | align horizontally | Nav | - | C |
| `zj zk`, page keys | scroll without moving the selection | Nav | - | B |
| `Z` | sticky variant | Nav | - | C |
| `z/ z? zn zN` | search from view mode (in default.rs, not in keymap.md) | Sel | Prompt | C |

### Goto mode `g`: buffers, files, LSP
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `ga gm gn gp` | last-accessed, last-modified, next, prev buffer | Nav | - | B |
| `gf` | open file/URL under selection | Sys | - | C |
| `gd gD gy gr gi` | definition, declaration, type definition, references, implementation | Nav/UI | **LSP** (multiple results open a picker) | C |

### Window mode `Ctrl-w` (also `Space w`)
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `w s v q o`, `h j k l` | rotate, hsplit, vsplit, close, only, focus direction | UI layout | - | C (B if splits are wanted early) |
| `t H J K L`, `n s/v`, `f F` | transpose, swap, scratch split, goto file in split | UI layout | - | C |

### Space mode (mostly pickers)
| Keys | Command(s) | Kind | Dep | v1? |
|---|---|---|---|---|
| `Space f F` | file picker (workspace / cwd) | UI | picker + fuzzy matcher + file walk | B (the main way to open files) |
| `Space b` | buffer picker | UI | picker | B |
| `Space j`, `Space '` | jumplist picker, last picker | UI | picker | C |
| `Space e .` | file explorer | UI | picker/tree | C |
| `Space g` | changed-file picker | UI | **VCS** | C |
| `Space s S` | document/workspace symbols | UI | **LSP or TS** | C |
| `Space d D` | diagnostics pickers | UI | **LSP** | C |
| `Space k r a` | hover, rename, code action | UI/Edit | **LSP** | C |
| `Space y Y p P R` | clipboard yank, paste, replace | Sys | **Clip** | A (GUI users expect this) |
| `Space ?` | command palette | UI | picker | B |
| `Space G ...` | debugger (DAP) | UI | DAP | C |

### Other
| Keys | Command | Kind | Dep | v1? |
|---|---|---|---|---|
| `:` | command mode (`:w`, `:q`, `:o`, ...) | UI | Prompt | A (minimum: write, quit, open) |
| `Ctrl-z` | suspend | Sys | terminal-only, n/a for GUI | - |

---

## 4. Takeaways for a v1 cut

1. **Most of the selection model needs neither TS nor LSP.** Range, Selection, normalize, transform, and the regex select/split/keep functions are small pure functions of about 900 lines in `selection.rs`. Combined with word, char, line and paragraph movement and pair textobjects, they give the full multicursor experience on plain text.
2. **Edits are expressed per range and batched.** Multicursor edits produce one `ChangeSet` and one undo step. An Odin port should do the same: build one change list per command, apply it to the piece tree, and map every range through it. `update_positions` is the sorted-merge trick that makes mapping O(N+M).
3. **Undo is per command, plus one step per insert session.** You need a "pending changes" buffer that is committed after each non-insert keypress and on `Esc`. The history tree with `earlier`/`later` is optional; a linear stack with the same commit points is a valid v1.
4. **A cursor is a 1-wide selection.** Every motion and edit assumes block-cursor semantics (`cursor()`, `put_cursor`, `min_width_1`). Pick this convention on day one; retrofitting it is painful.
5. **`.` repeats only the last insert.** It replays the command that entered insert mode plus the typed keys. It is cheap to implement and does not need a general operator-repeat system. Macros are a separate, later feature.
6. **Three UI pieces are needed outside the buffer:**
   - A one-line **prompt**, used by `/ s S K :`. This is A-tier because the regex selection workflow depends on it.
   - A **fuzzy picker**: file, buffer, palette. B-tier.
   - **Popups**: LSP hover and completion. C-tier.
7. **TS-dependent groups** can wait for a later tree-sitter milestone with no loss of the core model:
   - `Alt-o/i/n/p/a/I/e/b` syntax-node selection.
   - `]f`-style navigation.
   - `mi f/t/a/c/T/e/x` textobjects.
   - Symbol pickers.
   - Better `mm`, `mim` and indent.

   **LSP-dependent groups** are entirely separable:
   - `gd gD gy gr gi`.
   - `Space k r a s S d D h`.
   - `]d [d`.
   - `=` and completion.

## Doc vs code discrepancies
- `keymap.md` documents `Ctrl-i` for `jump_forward`; `default.rs` also binds `tab`, with the comment `tab == <C-i>`.
- `keymap.md` marks `mm` as **TS**; the code falls back to plaintext bracket matching.
- `keymap.md` lists `<n>g` as `goto_file_start`. In code, `gg` is `goto_file_start` and takes a count (`<n>gg`) as goto-line.
- View mode in `default.rs` also binds `Backspace`/`Space` (half page) and `/ ? n N` (search). These are not in the `keymap.md` table.
- `keymap.md` lists `[x` as "next" and `]x` as "previous" XML element; `default.rs` binds `[x` to `goto_prev_xml_element` and `]x` to `goto_next_xml_element`. The book table has them swapped.

## Not verified
- Exact behaviour of `copy_selection_on_line` (`C`) across soft-wrapped lines. It uses visual coordinates ([commands.rs L2095](https://github.com/helix-editor/helix/blob/ba40e547426b0f9896c8bdc699a4ab11f2b37dbc/helix-term/src/commands.rs#L2095)), and I did not read it in full.
- Whether `textobject_pair_surround` without syntax handles nested and escaped quotes. The code path exists (it takes `Option<syntax>`), but I did not read `surround.rs`.
- Typable `:` commands (`typed.rs`) were not catalogued; only key bindings were.
