---
id: 003
title: Piece tree and undo prior art
type: wayfinder:research
status: open
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Piece tree and undo prior art

## Question

How do VS Code's piece tree and Helix's rope (ropey) work, and what do they cost at 100MB? How is the line index maintained, and how are undo/redo implemented (snapshots of immutable trees, operation logs, transactions as Helix does)? What fits an arena-heavy, low-allocation Odin design?
