---
title: Daily-driver v1 spec
labels: [wayfinder:map]
status: open
---

# Daily-driver v1 spec

## Destination

A build-ready spec for a daily-driver v1: a Helix-inspired modal editor in Odin plus a diffity-style review loop (diff view, comment threads, an agent that addresses them). Done when nothing is left to decide before building starts.

## Notes

- Domain: native GUI text editor. See `MISSION.txt`. References: [Helix](https://github.com/helix-editor/helix), [diffity](https://github.com/nilbuild/diffity).
- Odin. GUI only. Windows-first dev; macOS and Linux (Wayland only) must be proven by a spike each.
- Helix-*inspired*: Helix keymap and selection model as baseline, free to diverge.
- No config file in v1: keymap/theme/fonts live in Odin source, change by recompiling.
- Perf targets: 144Hz (~7ms frame budget); cold start → first frame with text well under 100ms; 100MB files edit smoothly; zero idle CPU (redraw on events only).
- Git: shell out to the `git` CLI for refs/blobs; live diffs computed in Odin.
- Agent: Claude Code is the reference agent; support both passive ("address my review") and active ("send to Claude") directions.
- Every grilling ticket: also consult the `domain-modeling` skill; record terms in `GLOSSARY.md`, hard-to-reverse choices in `docs/adr/`.
- Tracker: local markdown. Tickets live in `.wayfinder/tickets/`; frontmatter carries `type`, `status`, `assignee` (the claim), `blocked_by`. Frontier = `status: open`, no assignee, every `blocked_by` closed.

## Decisions so far

<!-- one line per closed ticket -->

- [Helix keymap and selection model](tickets/007-helix-keymap-model.md): the core selection model and multicursor need no tree-sitter or LSP; command groups tiered A/B/C for picking the v1 subset.
- [Piece tree and undo prior art](tickets/003-piece-tree-prior-art.md): piece table + B-tree index and Helix-style ChangeSet/undo tree fit; 100MB load cannot fit in one frame, so it goes off-thread.
- [IMGUI and text rendering options in Odin](tickets/002-imgui-text-rendering.md): SDL3 is the only vendored layer covering Wayland (sokol is X11-only); kb_text_shape and microui are vendored; LCD text needs shader-side blending.
- [How agents connect to an editor](tickets/006-agent-transport.md): diffity uses a stdio MCP relay to the app over a local socket, plus Node-based ACP for the active direction; a stdio MCP mode in the editor exe plus `claude -p` stream-json avoids Node.
- [How review comments are stored and re-anchored](tickets/005-review-comment-anchoring.md): every system keeps a fixed original anchor and works out the current position on read; diffity uses SQLite in app data, which agents cannot read offline.
- [Tree-sitter from Odin](tickets/004-tree-sitter-from-odin.md): laytan/odin-tree-sitter is usable once three callbacks are fixed; small reparses are usually under 1ms with rare spikes, so a short main-thread deadline then a worker fits; Helix queries are reusable (MPL-2.0).
- [Benchmark startup and file load: native Win32 vs SDL3](tickets/001-bench-platform-startup.md): on macOS, SDL3 was only 5–9ms behind native (~130ms to first frame either way, AppKit setup ~90ms of it), so startup misses the "well under 100ms" target; 100MB load is about the same on every layer. Windows not measured yet.

## Not yet specified

- **File picker & search**: fuzzy matcher, file walking, project-wide search.
- **Buffer/project model**: how open buffers relate to a workspace root; multiple files open.
- **Tree-sitter textobjects**: syntax-aware selection commands.
- **Input edge cases**: clipboard, IME, dead keys.
- **Beyond 100MB**: what degrades and how for very large files.
- **Theme**: colours, fonts, the look.
- **Config file**: a later replacement for config-as-source.
- **Split diff view**: side-by-side alongside the unified review view.
- **GitHub PR round-trip**: check out a PR, review, post back.
- **LSP**: wanted, but not needed until the core is figured out; the core should not preclude it.
- **Wayland startup numbers**: run the SDL3 spike on Wayland, plus a native Wayland spike if the platform choice leans native.
- **Spec assembly**: pulling resolved decisions into the final spec document.

## Out of scope

- Terminal UI: GUI only, per the mission.
- Plugin system.
