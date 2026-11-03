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
- **Spec assembly**: pulling resolved decisions into the final spec document.

## Out of scope

- Terminal UI: GUI only, per the mission.
- Plugin system.
