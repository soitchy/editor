---
id: 004
title: Tree-sitter from Odin
type: wayfinder:research
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Tree-sitter from Odin

## Question

Are there existing Odin tree-sitter bindings? How would grammars be compiled and bundled? What does incremental reparse cost per edit, and can highlighting stay inside a 7ms frame? Can Helix's highlight queries be reused (license: MPL-2.0)?

## Resolution

Findings: branch `research/tree-sitter-from-odin`, file `research/tree-sitter-from-odin.md`. Timings are published figures; a benchmark was written but not run.

- **Bindings:** laytan/odin-tree-sitter (MIT) is maintained (last commit 2026-03-05) and covers the full C API, with runtime v0.26.3 against upstream v0.27.1.
  - **Bug:** its progress callbacks and `Decode_Function` are plain `proc`, not `proc "c"`. The progress callback is the only way left to cancel a parse, so cancelling is undefined behaviour until fixed.
- **Bundling:** compile `lib/src/lib.c` plus each grammar's parser.c/scanner.c into per-OS static libs and `foreign import` them. Windows needs the x64 MSVC toolchain. Pin grammar revisions to match the queries.
- **Piece tree:** the read callback can return a pointer straight into a piece, with no copy. Buffers must not move during a parse. `ts_tree_edit` needs row/column as well as bytes.
- **Cost:**
  - A small-edit reparse is usually under 1ms, with rare ~30ms spikes.
  - Helix parses on the main thread with a 500ms timeout. Zed gives the main thread 1ms, then moves to a background thread.
  - Parse timeouts were removed in 0.26.
- **Helix queries:** MPL-2.0 confirmed, with a few Apache-2.0/MIT files. They use TextMate-style scopes with "last match wins". Predicates (#match?, #eq?, #any-of?, the not- variants, #set!, #is-not? local) must be implemented by us.
- **The researcher suggests:** vendoring laytan's bindings and fixing the callbacks, a synchronous tree edit with a 1–2ms parse deadline then finishing on a worker, querying only the visible range, and reusing Helix's queries with notices kept.

To decide in [Frame loop and threading model](015-frame-loop-threading.md).
