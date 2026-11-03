---
id: 003
title: Piece tree and undo prior art
type: wayfinder:research
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Piece tree and undo prior art

## Question

How do VS Code's piece tree and Helix's rope (ropey) work, and what do they cost at 100MB? How is the line index maintained, and how are undo/redo implemented (snapshots of immutable trees, operation logs, transactions as Helix does)? What fits an arena-heavy, low-allocation Odin design?

## Resolution

Findings: branch `research/piece-tree-prior-art`, file `research/piece-tree-prior-art.md`. Sources are VS Code's source and 2018 blog post, ropey's source and design doc, and Helix's source. Includes a ropey 1.6.1 benchmark at 100MB.

- **VS Code piece tree:** read-only original buffer plus an append-only add buffer, indexed by a red-black tree.
  - Line starts are computed once per buffer, and each node caches its left subtree's length and line count.
  - Memory is about the file size. Undo is a separate log that copies deleted text.
- **ropey:** a copy-on-write B-tree of 1KB nodes, so snapshots are cheap. Measured at 100MB:
  - Load 160–240ms, memory about 110MB.
  - Insert about 1.1µs, line lookup about 1.2µs.
  - A naive 1000-cursor edit takes 3–4ms, about half the frame budget.
- **Helix:** a ChangeSet (Retain/Delete/Insert list) means an N-cursor edit is one transaction and one undo step. History is an index-linked revision tree storing each edit and its inverse; no rope snapshots are kept.
- **Load can't fit in one frame** with either design, so it must run off-thread or progressively.
- **The researcher suggests:**
  - A piece table with per-buffer line starts, normalising line endings on load.
  - The tree stored as a B-tree in a pooled, index-based node array.
  - Helix's ChangeSet and undo tree for edits and history.
  - Undo records that point into the append-only buffers instead of copying text.
  
  To decide in [Buffer and undo design](010-buffer-undo-design.md).
