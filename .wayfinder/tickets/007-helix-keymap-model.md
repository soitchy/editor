---
id: 007
title: Helix keymap and selection model
type: wayfinder:research
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# Helix keymap and selection model

## Question

Catalogue Helix's default keymap and selection model (selections, anchors/heads, multicursor, modes, minor modes, register/yank behaviour, textobjects) so a v1 subset can be chosen. Note what depends on tree-sitter or LSP.

## Resolution

Findings: branch `research/helix-keymap-model`, file `research/helix-keymap-model.md` (sources pinned to Helix commit ba40e54; code wins over the book where they disagree).

- Selection model is plain-text: a Range is anchor+head, half-open; a cursor is a 1-wide block; a selection is never empty, sorted, merged, with one primary.
- Regex select/split/keep, word/line/paragraph motions, `w`/`p`/pair textobjects, surround and `mm` all work with no tree-sitter or LSP. That covers the full multicursor experience.
- Undo is one step per normal-mode command or per insert session; history is a tree, but a linear stack with the same commit points would do for v1.
- `.` repeats the last insert only; registers hold one value per selection.
- Tree-sitter-only: syntax-node selection, `]f`-style navigation, most `mi`/`ma` objects. LSP-only: `g d/D/y/r/i`, most of Space mode, `=`, completion. A one-line prompt is needed early; fuzzy pickers can come later.
- The file tags each command group A (core) / B (cheap follow-up) / C (later). The tiers are the researcher's suggestion, to be decided in [Commands and keymap for v1](013-v1-commands-keymap.md).
