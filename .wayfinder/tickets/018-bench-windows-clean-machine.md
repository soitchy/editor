---
id: 018
title: Re-measure Windows startup without endpoint security
type: wayfinder:task
status: open
assignee:
blocked_by: []
parent: map.md
---

# Re-measure Windows startup without endpoint security

## Question

What do the four Windows spikes measure on a machine without endpoint security hooks (a personal PC or VM, or the dev machine with exclusions for the build folder if policy allows)? Follow the Windows checklist in [`spikes/platform-bench/README.md`](../../spikes/platform-bench/README.md) and record the machine and the four outputs. If the D3D11 paths stay above ~150ms, also try picking the adapter explicitly.

## Context

[Run the platform benchmark on Windows](016-bench-platform-windows.md) saw ~58ms before `main` (macOS ~11ms) and 38-52ms to read 100MB from cache (macOS ~11ms), probably the managed machine's security software. It does not block [Choose the platform layer](009-choose-platform-layer.md); it tells us whether the 100ms target is realistic on Windows.
