# Prior art: VS Code piece tree vs Helix/ropey rope

Research ticket: how VS Code's piece tree and Helix's rope (ropey) work, what they cost at
100 MB, how they keep a line index, how undo/redo and multicursor edits map onto them, and
what fits an arena-heavy, low-allocation Odin design (see `MISSION.txt`).

Sources are primary: the VS Code source and its 2018 engineering blog post, ropey's source,
README and design doc, and Helix source. Numbers marked **[measured]** come from a benchmark
run for this ticket (details in [Measurements](#measurements-ropey-at-100-mb)); everything else
is cited.

---

## TL;DR

- **VS Code piece tree** = piece table (read-only original buffers + one append-only change
  buffer) indexed by a **red-black tree** whose nodes cache `size_left` and `lf_left` (length
  and line-feed count of the left subtree). Line starts are precomputed **per buffer**, not per
  node, so they never need splitting. Load memory is "very close to the original file size".
  Undo is **not** structural: `applyEdits` returns reverse edits (old text + inverse range),
  which an edit stack compresses and serialises into a byte buffer.
- **ropey** = B-tree rope with **1024-byte nodes** (leaf text ~980 B), each internal node
  storing per-child `TextInfo {bytes, chars, utf16_surrogates, line_breaks}`. Nodes are `Arc`
  with copy-on-write, so `clone()` is O(1) and gives persistent snapshots. ~10% memory
  overhead on load; at 100 MB: ~100-160 ms build, ~1.1 µs insert, ~0.7 µs remove **[measured]**.
- **Helix undo** = **revision tree** in a flat `Vec<Revision>`, each storing a forward
  `Transaction` and its precomputed inversion. **No rope snapshots** are stored. A
  `ChangeSet` is a `Retain/Delete/Insert` operation list spanning the whole document, so **one
  ChangeSet encodes the edit at every cursor**; `map_pos`/`update_positions` remap selections,
  diagnostics and other views through it.
- **Recommendation for Odin:** piece tree (VS Code's buffer + line-start design) stored in
  pooled fixed-size nodes, with Helix's ChangeSet/Transaction model as the edit and undo
  currency and Helix's index-based revision tree for history. Append-only buffers mean undo
  records can reference **spans** instead of owning copies of deleted text. Details in
  [What fits an Odin, arena-heavy design](#what-fits-an-odin-arena-heavy-design).

---

## 1. VS Code piece tree

Primary sources:
- Blog: [Text Buffer Reimplementation (VS Code, 2018-03-23)](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation)
- [`pieceTreeBase.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts)
- [`pieceTreeTextBuffer.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.ts)
- [`editStack.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/editStack.ts)
- Standalone package: [microsoft/vscode-textbuffer](https://github.com/microsoft/vscode-textbuffer) (no benchmark numbers in its README)

### Why they replaced the line array
The old model was an array of line objects. A 35 MB file with 13.7M lines crashed out of
memory: each `ModelLine` cost ~40-60 bytes, so the array alone was ~600 MB, about 20x the file
size. Splitting the file into one string per line also made opening slow. ([blog](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation))

### Structure
- **Buffers.** `StringBuffer { buffer: string, lineStarts: Uint32Array | Uint16Array | number[] }`.
  Buffer 0 is the append-only **change buffer**; the others are read-only **original buffers**.
  Loaded text is kept as the 64 KB chunks Node's file reader delivers. Concatenating them hit
  V8's 256 MB maximum string length on a 500 MB file. `AverageBufferSize = 65535`, and larger
  inserted text is split into multiple pieces. ([blog](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation), [`pieceTreeBase.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts))
- **Piece.** `{ bufferIndex, start: BufferCursor{line, column}, end: BufferCursor, length, lineFeedCnt }`.
  Positions inside a buffer are expressed as *(index into that buffer's lineStarts, column)*,
  so a piece knows its line-feed count without scanning text. ([`pieceTreeBase.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts))
- **Tree.** Red-black tree of pieces, in document order. Each node caches `size_left` and
  `lf_left`, the length and line-feed count of its **left subtree** only, since the right side
  can be derived. Offset→node and line→node lookups descend from the root in O(log n). An edit
  only updates metadata on the path to the root. The blog author chose a red-black tree as
  "more 'editing' friendly". ([blog](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation))

### Line index maintenance
- Line starts are computed **once per buffer** when it is created. Because original buffers are
  immutable and the change buffer is append-only, those offsets never move. Nodes just
  reference them. The blog reports that moving line starts from per-node to per-buffer storage
  made operations about 3x faster, because no array splitting is needed. ([blog](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation))
- On append to the change buffer, the new text's line starts are offset by the old buffer length
  and concatenated (dropping the leading 0). A special case handles a trailing `\r` already in
  the buffer meeting a leading `\n` in the new text. ([`pieceTreeBase.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts) `createNewPieces`, `appendToNode`)
- **CRLF** is the main source of complexity. Every edit checks whether it splits or creates a
  `\r\n` across pieces (`validateCRLFWithPrevNode`/`NextNode`, `fixCRLF`,
  `adjustCarriageReturnFromNext`). These checks are skipped when the buffer is normalised to `\n`
  (`shouldCheckCRLF`). The blog calls this "a programmer's nightmare".

### Insert fast path and caches
- **Typing fast path:** if the insert lands at the end of a piece that ends exactly at
  `_lastChangeBufferPos` (the end of the change buffer), `appendToNode` **extends the existing
  piece** instead of creating a node. Sequential typing therefore adds no nodes. ([`pieceTreeBase.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts))
- `PieceTreeSearchCache(1)` remembers the last node found for an offset or line. `insert` and
  `delete` invalidate it.
- `_lastVisitedLine` caches the most recent `getLineContent` result.

### Snapshots
`createSnapshot()` collects references to every piece in order. It does not copy text, but it is
O(pieces). It stays valid after later edits because buffers are append-only and the snapshot
holds the piece values themselves. It is **not** an O(1) persistent clone. ([`pieceTreeBase.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts))

### Multicursor edits (`applyEdits`)
1. Each operation is normalised: offsets computed, EOLs in inserted text rewritten to the
   buffer's EOL. Each op is tagged with a `sortIndex`.
2. Ops are sorted ascending. **Overlapping ranges throw** ("Overlapping ranges are not
   allowed!"). Touching ranges are allowed.
3. With ≥1000 untracked ops, they are **reduced to one big edit** (`_reduceOperations` →
   `_toSingleEditOperation`), which interleaves the untouched text with the new text.
4. Reverse operations are built **before** mutation: old text via `getValueInRange`, plus the
   range each insert will occupy afterwards (`_getInverseEditRanges`).
5. Ops are applied **end-to-start** (`_sortOpsDescending`), so earlier offsets stay valid
   without adjustment.
6. Returns `ApplyEditsResult(reverseOperations, contentChanges, trimAutoWhitespaceLineNumbers)`.

([`pieceTreeTextBuffer.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.ts))

### Undo / redo
Undo is an **operation log of inverse edits**, kept outside the buffer:
- `SingleModelEditStackElement` stores before/after version ids, EOL, cursor selections, and a
  list of `TextChange`s. Consecutive changes are merged with `compressConsecutiveTextChanges`,
  so typing does not create one record per keystroke.
- A closed element is **serialised into a single `Uint8Array`**. `heapSize()` reports
  `byteLength + 168`. Undo deserialises it and calls `model._applyUndo(changes, ...)`.
- `pushStackElement()` closes the current group. `MultiModelEditStackElement` groups edits
  across files.
- Deleted text is **copied** into the undo record, even though the piece tree's buffers still
  hold it.

([`editStack.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/editStack.ts))

### Cost at large sizes (from the blog)
- Memory right after load: "very close to the original file size". The blog shows this only as
  a chart, without exact figures.
- Load: much faster than the line array, because line breaks are cached instead of splitting
  the file into strings. Test files went up to 184 MB / 3M lines. No exact timings are given.
- Edits: stable across file sizes. The line array choked beyond ~100k lines.
- Weakness: full-file line reads after many edits are O(log n) per line instead of O(1). The
  blog argues `getLineContent` takes microseconds and is under 1% of viewport render/tokenize
  time.

For this design, a piece tree's load memory is roughly *file bytes + 4 bytes per line* for
`Uint32Array` line starts. That is ~5.4 MB for the 1.4M-line 100 MB test file **[measured]**,
plus a small node count (~1,600 pieces at 64 KB). This is an inference from the structure, not
a published VS Code figure. JS string encoding also affects the real VS Code footprint.

---

## 2. ropey (Helix's rope)

Primary sources:
- [ropey docs.rs (1.6.1)](https://docs.rs/ropey/latest/ropey/)
- [README](https://github.com/cessen/ropey/blob/master/README.md)
- [design/design.md](https://github.com/cessen/ropey/blob/master/design/design.md)
- [`src/tree/mod.rs`](https://github.com/cessen/ropey/blob/master/src/tree/mod.rs), [`src/tree/text_info.rs`](https://github.com/cessen/ropey/blob/master/src/tree/text_info.rs)

### Structure
- **B-tree.** All leaves sit at the same depth. Internal nodes have `MIN_CHILDREN..MAX_CHILDREN`
  children, and leaves hold `MIN_BYTES..MAX_BYTES` of UTF-8 text. ([design.md](https://github.com/cessen/ropey/blob/master/design/design.md))
- **Node size is fixed at 1024 bytes**, including the Arc counters: `TARGET_TOTAL_SIZE = 1024`,
  enforced by a compile-time assertion. The goal is power-of-two allocations to reduce allocator
  fragmentation. `MAX_BYTES = 1024 - START_OFFSET - smallvec_overhead`,
  `MIN_BYTES = MAX_BYTES/2 - MAX_BYTES/32`, `MIN_CHILDREN = MAX_CHILDREN/2`. ([`mod.rs`](https://github.com/cessen/ropey/blob/master/src/tree/mod.rs))
- **Internal nodes** keep a contiguous array of child metadata, then child `Arc` pointers, so
  choosing a child is a linear scan over one cache-friendly array. Per-child metadata is
  `TextInfo { bytes, chars, utf16_surrogates, line_breaks }`. ([`text_info.rs`](https://github.com/cessen/ropey/blob/master/src/tree/text_info.rs), [design.md](https://github.com/cessen/ropey/blob/master/design/design.md))
- **Line index:** the line-break count is aggregated in `TextInfo` up the tree, so
  `line_to_char`/`char_to_line` descend by summing counts. No separate line array exists. Within
  a leaf, line breaks are counted with SIMD-accelerated scanning (`str_indices`; `simd` feature
  on by default). LF and CRLF are always recognised, plus CR and Unicode separators under the
  default `unicode_lines` feature. ([docs.rs](https://docs.rs/ropey/latest/ropey/))
- **CRLF invariant:** a CRLF pair must never be split by a leaf boundary. A leaf may exceed
  `MAX_BYTES` to honour this. ([design.md](https://github.com/cessen/ropey/blob/master/design/design.md))
- **Persistence:** nodes are `Arc`. Mutation goes through `Arc::make_mut`, which edits in place
  when the node is uniquely owned and copies it when shared. A clone is 8 bytes, and clones
  share memory until they diverge. Clones are thread-safe for both reading and writing. ([design.md](https://github.com/cessen/ropey/blob/master/design/design.md), [README](https://github.com/cessen/ropey/blob/master/README.md))
- **Indexing unit:** char (Unicode scalar) indices, so invalid UTF-8 slices cannot be created.

### Published performance claims ([README](https://github.com/cessen/ropey/blob/master/README.md))
- More than 1.8M small incoherent insertions/s while building a ~100 MB text. More than 3.3M/s
  for coherent insertions.
- Edits take "single-digit microseconds" on multi-gigabyte texts.
- About 10% memory overhead on fresh load: a 100 MB file occupies ~110 MB.
- Caveats: kilobyte-chunk allocation bloats tiny texts, it is in-memory only, and it uses
  `unsafe`.

### Measurements: ropey at 100 MB
**[measured]** ropey 1.6.1, `--release`, Windows 11, Intel i9-10900 @ 2.8 GHz. Synthetic 100 MB
file with 1,416,995 lines of ~74 bytes each, ASCII. Two runs; the range is shown. Source:
throwaway bench in the session scratchpad (not committed).

| Operation | Result |
|---|---|
| `Rope::from_reader` (file → rope) | 161-241 ms |
| `read_to_string` (incl. UTF-8 validation) | 58-80 ms |
| `Rope::from_str` from an in-memory string | ~99 ms |
| Scalar `\n` scan building a `u32` line-start array (piece-table style), same data | 45 ms, 5.4 MB |
| Leaf chunks after load | 106,563 leaves, avg 983 B → ~104 MB leaves + internal nodes ≈ README's ~110 MB |
| Random 2-char insert | 1.1-1.7 µs/op |
| Random 2-char remove | ~0.7 µs/op |
| `line_to_char` + `char_to_line` pair | ~1.2 µs |
| `clone()` (snapshot) | 0.1-0.3 µs |
| First insert after clone (path copy, ~4 levels of 1 KB nodes) | ~7.8 µs |
| 1000-cursor insert (1000 × `line_to_char` + `insert`, back-to-front) | 2.9-4.0 ms |
| Read 100 viewport lines via chunks | ~60 µs |

Takeaways for a 7 ms frame:
- **Load never fits in a frame** with either structure. It must be off-thread or progressive.
- A single edit or lookup is about 1 µs.
- **1000 cursors costs about half a frame** when every cursor does an independent O(log n)
  tree edit. Batched application is worth designing for (see §5).

---

## 3. Helix: Transaction / ChangeSet

Primary source: [`helix-core/src/transaction.rs`](https://github.com/helix-editor/helix/blob/master/helix-core/src/transaction.rs)

- `enum Operation { Retain(usize), Delete(usize), Insert(Tendril) }`, counted in chars.
- `struct ChangeSet { changes: Vec<Operation>, len: usize, len_after: usize }`. A ChangeSet
  spans the **whole document**: Retains cover the untouched gaps, so its size scales with the
  number of edits, not the document size. The builder merges adjacent operations of the same
  kind.
- `apply(&self, &mut Rope) -> bool` checks that the rope's length equals `len`, then walks the
  ops front-to-back with a cursor: Retain advances, Delete removes, Insert inserts and advances.
- `compose(self, other)` fuses A (doc1→doc2) and B (doc2→doc3) into one doc1→doc3 ChangeSet.
  For example, five single-character inserts collapse into `Insert("hello")`.
- `invert(&self, original_doc)` builds the undo: `Delete(n)` becomes `Insert(text read from the
  original doc)`, and `Insert(s)` becomes `Delete(len(s))`. Deleted text is therefore
  materialised (copied) into the inversion.
- `map_pos(pos, Assoc)` and `update_positions` (batched, roughly O(N+M) for sorted input) remap
  positions through a change. `Assoc` controls stickiness: `Before`/`After`, `BeforeWord`/
  `AfterWord`, `BeforeSticky`/`AfterSticky`. Operational-transform `map` is declared but
  `unimplemented!()`.
- `struct Transaction { changes: ChangeSet, selection: Option<Selection> }`.

### Multicursor
`Transaction::change_by_selection(doc, &selection, |range| (from, to, Option<Tendril>))` calls
the closure once per selection range. `ChangeSet::from_changes` then stitches the results into
**one** ChangeSet: retain the gap, insert, delete, and finally retain the tail. Changes must be
sorted and non-overlapping (`debug_assert!`). The `*_ignore_overlapping` variants drop
overlaps, and `delete` clamps overlapping deletions. `insert(doc, selection, text)` is a
zero-width change at every range head. So **an N-cursor edit is one ChangeSet, one undo step,
and one `apply`**. ([`transaction.rs`](https://github.com/helix-editor/helix/blob/master/helix-core/src/transaction.rs))

### Document integration
Source: [`helix-view/src/document.rs`](https://github.com/helix-editor/helix/blob/master/helix-view/src/document.rs)

- Uncommitted edits accumulate in `changes: ChangeSet`, composed transaction by transaction.
  `old_state` holds the pre-edit state. `append_changes_to_history` wraps the accumulated
  ChangeSet in a Transaction and calls `history.commit_revision`. A whole insert-mode session
  can therefore become one revision. Commits are also triggered before undo/redo,
  earlier/later and reload; the insert-mode-exit call site lives in `helix-term`.
- After each apply, **every view's selection** is mapped through the ChangeSet and
  `ensure_invariants` is run. Diagnostics, inlay hints and view anchors are remapped with
  `update_positions` / `map_pos`.
- Tree-sitter is updated incrementally: `syntax.update(old_text, new_text, changeset)`. The
  rope `clone()` is what makes "old text" free to keep.
- `SavePoint` stores a **revert Transaction**, not a rope clone. Each later transaction's
  inversion is composed into every live savepoint.

## 4. Helix history (undo tree)

Primary source: [`helix-core/src/history.rs`](https://github.com/helix-editor/helix/blob/master/helix-core/src/history.rs)

- `History { revisions: Vec<Revision>, current: usize }`. Index 0 is an empty root.
- `Revision { parent: usize, last_child: Option<NonZeroUsize>, transaction, inversion, timestamp }`.
  The parent and child links are **indices into the flat vector**, not pointers.
- The `inversion` is precomputed at commit time from the pre-edit document ("We need an
  inversion for undos because delete transactions don't store the deleted text"), so commit
  must happen **before** apply.
- Committing never discards a branch: undo followed by a new edit creates a sibling. `redo`
  follows `last_child`, the most recently used branch.
- `earlier`/`later` move by steps or by duration (`UndoKind::TimePeriod`, a binary search on
  timestamps). `jump_to` goes up to the lowest common ancestor applying inversions, then down
  applying transactions. `changes_since(rev)` composes that path into a single transaction.
- **No rope snapshots are stored.** History is pure operation log.
- Stated limitations: the vector is unbounded, so memory grows over long sessions. Each revision
  holds both directions, roughly doubling storage per edit.

---

## 5. Comparison

| | VS Code piece tree | ropey (Helix) |
|---|---|---|
| Text storage | original buffers (as loaded) + one append-only add buffer; text never moves or is freed | text copied into ~1 KB leaves; edits rewrite leaves |
| Load at 100 MB | read + line-start scan (scalar scan 45 ms **[measured]**, on top of read) | read + build tree, 160-240 ms **[measured]** |
| Memory at load | ≈ file + 4 B/line (+ few nodes) | ≈ 1.1× file ([README](https://github.com/cessen/ropey/blob/master/README.md)) |
| Memory growth | add buffer grows by inserted bytes; pieces grow with edit count (fragmentation) | partially filled leaves after edits; COW copies while snapshots live |
| Line index | per-buffer `lineStarts` + `lf_left` subtree sums | `line_breaks` in per-child `TextInfo` sums |
| Edit cost | O(log pieces) + CRLF fix-ups | O(log n), ~1 µs **[measured]** |
| Snapshot | O(pieces) piece-ref copy | O(1) `Arc` clone |
| Undo (as used) | reverse-edit log with copied old text, serialised to bytes | Helix: revision tree of Transaction + inversion (copied text) |
| Multicursor | sorted batch, overlap = error, applied end-to-start, ≥1000 ops reduced to one edit | one ChangeSet over all selections, applied front-to-back |
| Allocation pattern | few large buffers + small RB nodes (GC'd in JS) | many 1 KB nodes via malloc + atomic refcounts |

---

## What fits an Odin, arena-heavy design

The following is inference from the evidence above, not a published benchmark.

1. **Text storage: piece table, not rope.** The piece table's defining property, immutable
   original and append-only add buffer, is exactly an arena.
   - Load the file into one allocation (or mmap it). No per-chunk copy is needed, unlike ropey's
     ~100 ms `from_str`.
   - Build `lineStarts: []u32` in one pass. The 45 ms scalar scan here is a ceiling, since SIMD
     should do much better. Run it off-thread or progressively, since load cannot fit a 7 ms
     frame with either design.
   - The add buffer can be a reserved-virtual-memory growing arena with stable addresses, so
     pieces can hold raw offsets forever and nothing is ever freed during editing.
   - Adopt VS Code's per-buffer line starts and the typing fast path (extend the last piece when
     appending at the add buffer's end).
   - Normalising EOLs on load, which VS Code supports via `_EOLNormalized`, deletes the whole
     CRLF fix-up class of bugs. Re-emit CRLF on save.
2. **Tree shape: B-tree of pieces in a node pool, not a pointer RB tree.** ropey shows that
   fixed-size (1 KB), cache-line-friendly nodes with a contiguous per-child metadata array work
   well. In Odin that becomes `[dynamic]Node` / a pool indexed by `u32`, with a free list. That
   means no per-node malloc and no refcounts. Per-child metadata would be
   `{bytes, line_breaks}` plus optional UTF-16/char counts if LSP needs them.
3. **Snapshots:** needed for background tree-sitter parsing, async save, and search. Two options:
   - (a) Copy the piece list. VS Code's approach is O(pieces), and cheap while pieces number in
     the thousands.
   - (b) Path-copying with index-based nodes, giving O(log n) new nodes per edit as ropey's
     `make_mut` does, reclaimed by generation or epoch (free when no snapshot older than *g* is
     alive) instead of atomic refcounts.

   Start with (a). Move to (b) only if piece counts or snapshot frequency make it measurable.
4. **Edits and multicursor: adopt Helix's ChangeSet/Transaction as the editing currency.**
   - It is buffer-agnostic (offset operations).
   - One ChangeSet expresses all cursors, giving one undo step.
   - `compose` gives free grouping of an insert session.
   - `map_pos`/`update_positions` with `Assoc` remap selections, other views, diagnostics and
     tree-sitter edit ranges in one sorted pass.
   - Store `Operation`s in a temp/frame arena while building. Only the committed form is copied
     into the history arena.
   - Apply in one sweep over the tree (or end-to-start, like VS Code) rather than N independent
     root-to-leaf descents. The measured 1000-cursor naive case is ~3-4 ms, about half a frame.
     For very large op counts, VS Code's "reduce to one edit" trick is a fallback.
5. **Undo: Helix's revision tree with index links, storing spans instead of strings.** Because
   piece-table buffers are append-only, an inversion's `Insert` never needs to own text. It can
   be `Insert{buffer, start, len}` pointing at bytes that already exist (the original or add
   buffer). Forward inserts already live in the add buffer too. History then costs a few words
   per operation, regardless of how much text was deleted. That beats both VS Code (copies old
   text, then serialises) and Helix (inversion owns the deleted text). Revisions go in a
   `[dynamic]Revision` with `parent`/`last_child` as `u32`. Unbounded growth, Helix's stated
   limitation, is small here, and history can be pruned by dropping the oldest subtree.
6. **Indexing unit:** use byte offsets internally, since tree-sitter and the piece table both
   work in bytes. Keep char/UTF-16 counts as optional aggregates for LSP rather than making
   chars the primary unit, as ropey does.

### Open questions for follow-up tickets
- SIMD line-start scan throughput in Odin (`core:simd`) on 100 MB. It decides whether load can be
  "visible within a frame or two" via a progressive scan.
- How badly does piece fragmentation grow under heavy multicursor editing, and when should
  adjacent add-buffer pieces be coalesced or the tree rebuilt?
- Snapshot strategy (copy the piece list vs path-copy with epochs) once background tree-sitter
  parsing is designed.
