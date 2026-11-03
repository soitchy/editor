---
id: 001
title: Benchmark startup and file load: native Win32 vs SDL3 vs sokol
type: wayfinder:task
status: open
assignee:
blocked_by: []
parent: map.md
---

# Benchmark startup and file load: native Win32 vs SDL3 vs sokol

## Question

Build minimal Odin spikes (native Win32, SDL3, sokol) that open a window and render a first frame of text, then load and display a large file (~100MB). Measure on Windows: cold start → first frame with text, and file load → first frame of its content. Record numbers, method, and rough code size/maintenance burden of each spike so the platform choice can weigh startup against ease of maintenance.
