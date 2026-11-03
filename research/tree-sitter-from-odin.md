# Tree-sitter from Odin

Research ticket: using tree-sitter from Odin in a native GUI editor (piece-tree buffer, IMGUI, 144 Hz / ~7 ms frame budget, Windows first, then macOS and Wayland Linux).

Researched 2026-11-03. Every claim cites a primary source: upstream source code, official docs, or repo metadata from the GitHub API. Anything that is my own inference is labelled **(inference)**.

## TL;DR

- **Bindings exist and are maintained.** [laytan/odin-tree-sitter](https://github.com/laytan/odin-tree-sitter) (MIT) covers the whole C API and ships an Odin build script that compiles the runtime and grammars into static libs. Its last commit was 2026-03-05. Its default runtime is v0.26.3, while upstream has reached v0.27.1. I found **two calling-convention bugs** in it (see below). Patch them or vendor your own bindings.
- **Bundling** means compiling `lib/src/lib.c` (one file) plus each grammar's `parser.c` (and `scanner.c`, if present) into static libraries for each OS, then using `foreign import` under `when ODIN_OS == ...`.
- **Piece tree support is first-class.** `TSInput.read` returns a borrowed pointer to a chunk at any byte offset, so the read callback can hand back a pointer straight into a piece's backing buffer with no copy. You do have to give `ts_tree_edit` row/column points as well as byte offsets.
- **Cost:** upstream says incremental reparse is "generally less than a millisecond". Emacs's tree-sitter notes say "usually less than 0.1ms" for small edits. Pathological cases (around 30 ms) do happen. Helix parses on the main thread with a 500 ms timeout. Zed gives a synchronous parse **1 ms** and moves it to a background thread if that runs out.
- **Recommendation:** call `ts_tree_edit` synchronously, try the parse with a deadline of about 1–2 ms (progress callback), and if it misses, finish on a worker thread using a piece-tree snapshot. Run highlight queries only over the viewport byte range. Timeouts are **gone** in 0.26; cancellation is done only through the progress callback.
- **Helix queries can be reused.** Helix is MPL-2.0 (verified). Its queries use Helix's own TextMate/Sublime-style scope names (`keyword.control.conditional`, `variable.other.member`) and a "last match wins" precedence rule. The C library evaluates **no** predicates, so we must implement `#match?`, `#eq?`, `#any-of?`, the `not-` variants, `#set!` and `#is-not? local` ourselves. A few query files carry their own Apache-2.0 or MIT headers.

---

## 1. Existing Odin bindings

| Repo | Status | Notes |
|---|---|---|
| [laytan/odin-tree-sitter](https://github.com/laytan/odin-tree-sitter) | Active. MIT, 31 stars, last push 2026-03-05 ("fix: os2 migration"). Commits through Jan 2026 fixed the Windows build. | Full bindings in `bindings.odin`, idiomatic wrappers, helpers, an example, and a `build` package that clones, compiles and archives the runtime and grammars and generates per-grammar Odin bindings with `#load`ed query files ([README](https://github.com/laytan/odin-tree-sitter/blob/main/README.md)). Docs are at [odin-tree-sitter.laytan.dev](https://odin-tree-sitter.laytan.dev/). |
| [Platin21/odin-treesitter](https://github.com/Platin21/odin-treesitter) | Dead. Last commit 2020-01-29, no license. | Ignore it. |
| Ad-hoc bindings inside other projects | n/a | GitHub code search for `ts_parser_parse language:odin` finds private copies in projects such as `Pingar5/bred`, `insanai/guidedog_odin`, `tagumasa/aubade`, `McFalljb/pi-desk` and `RainerXE/odintooling`. This shows hand-rolling bindings is common and practical: the API is about 200 C functions. |

### Details of laytan/odin-tree-sitter (read from source)

- **Linking.** It uses `foreign import ts "tree-sitter/libtree-sitter.lib"` on Windows and `libtree-sitter.a` everywhere else ([bindings.odin](https://github.com/laytan/odin-tree-sitter/blob/main/bindings.odin)).
- **ABI.** The constants are `LANGUAGE_VERSION :: 15` and `MIN_COMPATIBLE_LANGUAGE_VERSION :: 13`. These match upstream's `TREE_SITTER_LANGUAGE_VERSION 15` ([api.h](https://github.com/tree-sitter/tree-sitter/blob/master/lib/include/tree_sitter/api.h)).
- **Default runtime version.** The build script defaults to `-branch v0.26.3`. Upstream releases have reached **v0.27.1** (2026-10-08), according to the GitHub releases API. You can pass `-branch` to choose another version.
- **Calling-convention bugs (inference from reading the source).** `Input.read` and `Logger.log` are correctly declared `proc "c"`. However, `Parse_Options.progress_callback`, `Query_Cursor_Options.progress_callback` and `Decode_Function` are declared as plain `proc(...)`, which uses the Odin calling convention with an implicit `context` parameter. The C runtime calls all three through C function pointers (`bool (*progress_callback)(TSParseState *state)` in api.h). They should be `proc "c"`. As written, using the progress callback (the only cancellation mechanism, see section 4) would be undefined behaviour. This needs a one-line fix per field, which we can upstream or patch locally.
- **Allocator hook.** `set_odin_allocator` wraps `ts_set_allocator` so tree-sitter allocates through an Odin allocator. It warns that tree-sitter's `realloc` gives no `old_size`, so you need `mem.Compat_Allocator` ([helpers.odin](https://github.com/laytan/odin-tree-sitter/blob/main/helpers.odin)). This setting is global to the process. **(Inference)** Do not point it at a per-frame arena, because trees live across frames.
- **Predicates.** There is only an iterator over predicate steps (`predicates_iter`). The bindings do not evaluate predicates.
- **Open issue #6 (2026-10-14).** It reports unresolved symbols when the lib is built from an x86 developer prompt; it is fine from the "x64 Native Tools" prompt. The issue also notes that Odin `dev-2026-10` switched to the `radlink` linker, which no longer prints a helpful architecture-mismatch hint ([issue](https://github.com/laytan/odin-tree-sitter/issues/6)). This is worth knowing for a Windows-first build.

**Verdict.** Use laytan's bindings as the base: vendor them, fix the three `proc "c"` declarations, and bump the runtime to the current release. The binding layer is thin, so owning a vendored copy is cheap and avoids being blocked on an upstream fix.

## 2. Compiling and bundling the runtime and grammars

The **runtime** is a single amalgamated C file. Upstream says you can "incorporate the library in a larger project's build system by adding one source file", `lib/src/lib.c`, with `lib/src` and `lib/include` on the include path ([Getting started](https://tree-sitter.github.io/tree-sitter/using-parsers/1-getting-started.html)). laytan's build script does exactly that: `cl /Ox /c` or `cc -O3 -c` on `lib.c`, then `lib /OUT:libtree-sitter.lib` or `ar cr libtree-sitter.a` ([build_impl.odin](https://github.com/laytan/odin-tree-sitter/blob/main/build/build_impl.odin)).

Each **grammar** ships a generated `src/parser.c` and sometimes a hand-written `src/scanner.c`. These are compiled with `-I src` into `parser.lib` or `parser.a`, and the grammar exports one entry point, `const TSLanguage *tree_sitter_<lang>(void)` (same build script; the upstream getting-started example declares `tree_sitter_json`). External scanner functions are namespaced `tree_sitter_<lang>_external_scanner_*` ([External scanners](https://tree-sitter.github.io/tree-sitter/creating-parsers/4-external-scanners.html)). Many grammars can therefore be statically linked into one binary without symbol clashes.

**Proposed cross-platform layout (inference):**

```
vendor/tree_sitter/
  lib/{windows_amd64,darwin_arm64,darwin_amd64,linux_amd64}/libtree-sitter.{lib,a}
  grammars/<lang>/{parser.lib|parser.a per target}, queries/*.scm, LICENSE
```

```odin
when ODIN_OS == .Windows { foreign import ts_c "grammars/c/windows_amd64/parser.lib" }
else when ODIN_OS == .Darwin { foreign import ts_c "grammars/c/darwin_arm64/parser.a" }
else { foreign import ts_c "grammars/c/linux_amd64/parser.a" }
foreign ts_c { tree_sitter_c :: proc "c" () -> ts.Language --- }
```

Practical notes:
- **Windows.** Build with the x64 MSVC toolchain. laytan dropped MinGW and clang attempts on Windows and requires `vcvars` (commits from 2026-01-22). Linking an x86 lib produces `_`-prefixed symbols that fail to resolve (issue #6).
- **macOS.** laytan passes `-mmacosx-version-min` (default 12.0.0). **(Inference)** For a universal binary, build both architectures and `lipo` them together, or ship one lib per architecture.
- **Linux/Wayland.** Nothing special: these are plain static `.a` archives with no system dependencies. tree-sitter dropped its `time.h` dependency once timeouts were removed (see section 4).
- **Prebuilt or built from source.** You can commit prebuilt libs (fast builds, no C toolchain needed at Odin build time) or run an Odin `build` package step like laytan's. **(Inference)** Commit prebuilt libs, pinned per grammar commit, and keep a script to regenerate them.
- **Pin grammar revisions** to match whatever query files you use. Helix pins every grammar to a commit in `languages.toml`. For example, Odin uses `tree-sitter-grammars/tree-sitter-odin` at rev `6c6b07e3…` ([languages.toml](https://github.com/helix-editor/helix/blob/master/languages.toml)). Queries break when node names change.
- **ABI window.** The runtime accepts grammars generated with ABI 13 to 15 (api.h constants above). A grammar generated by a newer CLI than the runtime is rejected by `ts_parser_set_language`.

## 3. Reading from a non-contiguous buffer (piece tree)

Upstream API ([api.h](https://github.com/tree-sitter/tree-sitter/blob/master/lib/include/tree_sitter/api.h), [Basic parsing → custom data structures](https://tree-sitter.github.io/tree-sitter/using-parsers/2-basic-parsing.html)):

```c
typedef struct TSInput {
  void *payload;
  const char *(*read)(void *payload, uint32_t byte_index, TSPoint position, uint32_t *bytes_read);
  TSInputEncoding encoding;   // UTF8, UTF16LE, UTF16BE, Custom
  TSDecodeFunction decode;    // only used with TSInputEncodingCustom
} TSInput;
```

How the contract works:
- `read` returns a pointer to text starting at `byte_index` and writes the chunk length to `bytes_read`. Writing 0 signals end of document.
- The parser "does not take ownership of this buffer; it just borrows it until it has finished reading it" (api.h comment on `ts_parser_parse`).
- Chunks can be any length. The parser calls `read` again when it runs past the end of a chunk.

**Mapping this onto a piece tree (inference):**
- `read(byte_index)` finds the piece containing `byte_index`, which is an O(log n) descent. It returns `piece.buffer + piece.start + (byte_index - piece_offset)` with length `piece.len - (byte_index - piece_offset)`. This is zero-copy.
- **Access is mostly sequential.** Helix's rope adapter caches a cursor and only re-seeks when the parser jumps backwards or more than 4 KiB forwards: "this cursor is optimized for contiguous reads which are by far the most common during parsing" ([tree-house ropey.rs](https://github.com/helix-editor/tree-house/blob/master/bindings/src/ropey.rs)). Keep a "last piece" cursor in the payload so most calls are O(1).
- **Pointer stability matters.** Returned pointers must stay valid while the parse runs. If parsing happens on a worker thread (section 4), the original and add buffers must **never move**. Use append-only, chunked add buffers (never `realloc` them), and parse an immutable piece-tree snapshot.
- **`TSPoint position`** is supplied by the parser and can be ignored by `read`.

**Edits.** Before reparsing, call `ts_tree_edit(tree, &TSInputEdit{start_byte, old_end_byte, new_end_byte, start_point, old_end_point, new_end_point})`. The docs say: "You must describe the edit both in terms of byte offsets and in terms of (row, column) coordinates" (api.h). Then pass the edited old tree to `ts_parser_parse`. The edit must "exactly match the source code changes".
- **Implication (inference):** the piece tree must provide byte offset → (row, byte-column) conversion cheaply. Store line-break counts in the tree's node metadata, which you want for line indexing anyway.
- **Multi-cursor edits:** call `ts_tree_edit` once per edit, applied in order, with each edit's coordinates expressed against the text left by the previous edit. Then reparse once. (Inference from the edit contract.)
- **Columns** are byte-based for UTF-8 input.

After reparsing, `ts_tree_get_changed_ranges(old, new, &n)` returns the ranges "whose syntactic structure has changed". Use them to invalidate cached highlight spans. The returned array is `malloc`'d and must be `free`d by the caller (api.h).

## 4. Cost per edit, the 7 ms frame, threading and cancellation

**Published numbers (primary or first-party sources):**
- tree-sitter-rust README: "tree-sitter can generally update the previous existing syntax tree to reflect your edit in less than a millisecond". The same README shows a full parse of a 2,157-line `ast.rs` taking **6.48 ms** (about 9.9 KB/ms) ([tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust)).
- Emacs maintainers' tree-sitter notes: "Incremental parsing of a few characters worth of edit usually takes less than 0.1ms. If it takes longer than that, something is wrong." The same notes report one case where tree-sitter-c took **around 30 ms** to reparse incrementally, fixed by updating the grammar ([emacs admin/notes/tree-sitter/performance](https://sources.debian.org/src/emacs/1%3A30.1%2B1-6~bpo12%2B1/admin/notes/tree-sitter/performance)).

**What real editors do:**
- **Helix** parses synchronously on edit, with `const PARSE_TIMEOUT: Duration = Duration::from_millis(500); // half a second is pretty generous` ([helix-core/src/syntax.rs](https://github.com/helix-editor/helix/blob/master/helix-core/src/syntax.rs)). Its `tree-house` crate implements the timeout as a deadline check inside the progress callback (`parse_with_timeout` in [tree-house parser.rs](https://github.com/helix-editor/tree-house/blob/master/bindings/src/parser.rs)).
- **Zed** sets `sync_parse_timeout` to `Duration::from_millis(1)`. In `reparse()` it tries the parse on the main thread for up to 1 ms. On timeout, it spawns a background parse, keeps showing the "interpolated" old tree (the edited, not yet reparsed tree) in the foreground, swaps the result in when it arrives, and re-parses again if the buffer changed in the meantime ([crates/language/src/buffer.rs](https://github.com/zed-industries/zed/blob/main/crates/language/src/buffer.rs)).

**Cancellation and timeout APIs (current upstream):**
- `ts_parser_parse_with_options(parser, old_tree, input, TSParseOptions{payload, progress_callback})`. The callback gets `TSParseState{payload, current_byte_offset, has_error}`; returning `true` cancels, and the parse returns NULL (api.h).
- `ts_query_cursor_exec_with_options` takes the equivalent query-side progress callback (api.h).
- **Timeouts and cancellation flags are removed.** The v0.25.0 release notes say: "Parsing and Querying should be cancelled using the 'progress callback', rather than setting a timeout or a cancellation flag, which are now deprecated … in the next release the old way of timing out parsing will be removed" ([v0.25.0 release](https://github.com/tree-sitter/tree-sitter/releases/tag/v0.25.0)). The current api.h has no `ts_parser_set_timeout_micros`.
- **Resuming.** After a cancelled parse, calling `ts_parser_parse` again with the same parser resumes where it stopped, unless you call `ts_parser_reset` first (api.h).
- **Threads.** "Individual `TSTree` instances are not thread safe". `ts_tree_copy` is "very fast" (a shallow, refcounted copy), so copy the tree to hand it to another thread ([Advanced parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html), api.h). **(Inference)** Use one `TSParser` per thread.
- **Viewport-limited queries.** `ts_query_cursor_set_byte_range` and `ts_query_cursor_set_point_range` limit query work to the viewport. `ts_query_cursor_set_match_limit` caps in-progress matches (api.h).

**Answer.** Typical keystrokes reparse in well under 1 ms, so highlighting fits inside a 7 ms frame **most of the time**. Pathological edits (grammar bugs, edits that reflow huge regions such as opening an unterminated block comment, initial parse of a large file) can take tens of milliseconds or more. Do not count on parsing on the UI thread unconditionally.

**Recommended design (inference, modelled on Zed):**
1. On edit: apply the edit to the piece tree, then call `ts_tree_edit` on the current tree. This is cheap. The edited tree keeps existing highlight spans in place, already shifted.
2. Try `parse_with_options` on the UI thread with a progress callback that cancels after about 1–2 ms (use a QPC/`time.tick` deadline).
3. If it is cancelled, hand an immutable piece-tree snapshot and a `ts_tree_copy` to a worker that has its own parser. Keep rendering with the interpolated tree. When the worker finishes, swap the tree in, compute `get_changed_ranges`, and invalidate those cached spans. If newer edits have arrived, reparse again (coalesce; never run more than one in-flight parse per buffer).
4. Each frame, run the highlight query only over the visible byte range, caching per-line spans keyed by tree version.
5. For files above a size threshold, do the initial parse on the worker thread from the start.

**Not measured here.** I wrote a C micro-benchmark that does a chunked `TSInput` read, 200 random single-character edits, `ts_tree_edit` plus reparse, changed ranges and a 60-line viewport query, using the tree-sitter v0.26.3 runtime and tree-sitter-c. Compiling and running downloaded C code was not permitted in this session, so there are **no local numbers**. That benchmark is the obvious next step: it would replace the published figures above with numbers for our own hardware and grammars.

## 5. Reusing Helix's `runtime/queries`

**License.** Helix's root `LICENSE` is "Mozilla Public License Version 2.0", and the GitHub API reports `MPL-2.0` ([LICENSE](https://github.com/helix-editor/helix/blob/master/LICENSE)). `tree-house`, Helix's tree-sitter integration crate, is also MPL-2.0 (GitHub API). There is no separate license file for `runtime/queries` as a whole, with one exception: `runtime/queries/snakemake/LICENSE` (MIT). Several files carry their own headers:
- Apache-2.0: `elixir/highlights.scm`, `gn/*`, `pkl/*`, `yaml/injections.scm`
- MIT: `d/highlights.scm`
- "From nvim-treesitter" credits: `jq`, `markdown`, and others

(This comes from a grep of the master tarball on 2026-11-03.)

**What MPL-2.0 means here (inference; see [MPL 2.0 text](https://www.mozilla.org/en-US/MPL/2.0/) §3.2–3.3 and the [MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)):**
- MPL is file-level copyleft. Our own Odin code can stay under any license (the "Larger Work" clause, §3.3).
- Copied or modified `.scm` files must stay MPL-2.0 and keep their notices. Because a `.scm` file is its own source form, shipping the files themselves satisfies the source-availability requirement.
- Keep the per-file Apache-2.0 and MIT headers, and add a third-party notices file.

**Capture names Helix uses (Helix-specific scheme).** Helix uses "a similar set of scopes as Sublime Text" and TextMate ([book/src/themes.md](https://github.com/helix-editor/helix/blob/master/book/src/themes.md#scopes)). The most frequent captures across all `highlights.scm` files (my count from master) are:
- `@keyword`, `@type`, `@function`, `@operator`, `@string`, `@punctuation.bracket|delimiter|special`
- `@variable`, `@variable.parameter`, `@variable.other.member`, `@variable.builtin`
- `@constant`, `@constant.builtin(.boolean)`, `@constant.numeric(.integer|.float)`, `@constant.character.escape`
- `@namespace`, `@attribute`, `@constructor`, `@label`, `@tag`
- `@function.builtin|method|macro`
- `@keyword.control(.conditional|.repeat|.import|.return|.exception)`, `@keyword.operator|directive|function|storage(.type|.modifier)`
- `@type.builtin|enum(.variant)|parameter|definition`
- `@comment(.line|.block)(.documentation)`, `@comment.unused`
- `@markup.*`, `@special`, `@embedded`, `@none`, `@error`

These differ from nvim-treesitter's names (for example nvim's `@keyword.conditional` and `@variable.member`). A theme layer therefore has to target Helix's dotted hierarchy, with longest-prefix fallback (for example `keyword.control.conditional` → `keyword.control` → `keyword`). The fallback design is an inference from how the scopes are named.

**Helix precedence semantics.** These differ from tree-sitter-highlight's historical "first match wins". Helix's rules are: "Same span: last match wins … Nested nodes: innermost wins" ([book/src/guides/highlights.md](https://github.com/helix-editor/helix/blob/master/book/src/guides/highlights.md)). A highlighter written to consume Helix queries must follow these rules or the colours come out wrong.

**`; inherits: <lang>`** on the first line pulls in another language's query file, and the inherited query is compiled against each inheriting grammar (same doc). 39 `highlights.scm` files use it, so our loader must support it.

**Predicates and directives.** The core library evaluates none of these: "Predicates and directives are not handled directly by the Tree-sitter C library" ([Predicates and directives](https://tree-sitter.github.io/tree-sitter/using-parsers/queries/3-predicates-and-directives.html)). We must implement every one we use.

Usage counts in `highlights.scm`, `injections.scm` and `locals.scm` on Helix master:

| Predicate / directive | Count | Origin |
|---|---|---|
| `#set!` (keys: `injection.language`, `injection.combined`, `injection.include-children`, `injection.include-unnamed-children`) | 663 | Standard. `include-unnamed-children` is a Helix extension. |
| `#match?` / `#not-match?` (regex) | 439 / 24 | Standard |
| `#any-of?` / `#not-any-of?` | 263 / 3 | Standard |
| `#eq?` / `#not-eq?` | 247 / 2 | Standard |
| `#is-not? local` | 13 | Ties into `locals.scm` resolution. tree-house parses `is?` and `is-not?` as property predicates. |

The full list of predicates tree-house accepts is in [predicate.rs](https://github.com/helix-editor/tree-house/blob/master/bindings/src/query/predicate.rs): `eq?`, `not-eq?`, `any-eq?`, `any-not-eq?`, `match?`, `not-match?`, `any-match?`, `any-not-match?`, `any-of?`, `not-any-of?`, `set!`, `is?`, `is-not?`, with any other predicate passed to a custom hook.

Other files use further Helix-only predicates: `#not-kind-eq?` (64), `#same-line?` and `#not-same-line?`, `#not-one-line?`, `#make-range!`, `#select-adjacent!`, `#strip!`, `#offset!`, `#trim!`. These appear mainly in `textobjects.scm` and `indents.scm`, so they are not needed for highlighting.

**Helix-specific injection captures** are `@injection.filename` and `@injection.shebang`, alongside the standard `@injection.language` and `@injection.content` ([book/src/guides/injection.md](https://github.com/helix-editor/helix/blob/master/book/src/guides/injection.md)).

**Locals.** Locals use `@local.scope`, `@local.definition.<scope>` and `@local.reference`. A resolved reference inherits its definition's scope, and any other capture in `locals.scm` acts as a "discard" ([book/src/guides/locals.md](https://github.com/helix-editor/helix/blob/master/book/src/guides/locals.md)). This is optional for v1: without locals support, the `#is-not? local` patterns can be treated as always true.

**Regex for `#match?` (inference).** Odin ships `core:text/regex` (present in the local Odin `dev-2026-06` install). Captured node text is short. When a node spans pieces, copy it into `context.temp_allocator` before matching. Compile the regexes once, when the query is loaded. Note that Helix's regexes are Rust-regex syntax, so some patterns may need checking against Odin's regex dialect.

**Practical reuse plan (inference):**
- Vendor the `runtime/queries/<lang>/{highlights,injections,locals}.scm` files for our target languages. Keep MPL and per-file notices, and record the Helix commit.
- Pin each grammar to the revision Helix's `languages.toml` uses, so queries and grammar stay in sync.
- Implement the standard text predicates plus `#set!`, and treat `#is-not? local` as true until locals are supported.
- Build the theme on Helix scope names, so Helix themes (also MPL) could later be ported.

## Open questions / next steps

- Run the micro-benchmark described in section 4 on target hardware with tree-sitter-c, -odin and -rust, including a worst case (inserting `/*` at the top of a 10k-line file).
- Decide whether to upstream the three `proc "c"` fixes to laytan/odin-tree-sitter or keep a vendored fork.
- Check that Helix's Rust-flavoured `#match?` regexes compile with Odin's `core:text/regex`. Patterns to watch: lookaround, `\p{..}` classes, and the `(?i)` flag.
