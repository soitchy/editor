---
id: 001
title: "Benchmark startup and file load: native Win32 vs SDL3"
type: wayfinder:task
status: open
assignee:
blocked_by: []
parent: map.md
---

# Benchmark startup and file load: native Win32 vs SDL3

## Question

Build minimal Odin spikes (native Win32, SDL3) that open a window and render a first frame of text, then load and display a large file (~100MB). Measure on Windows: cold start → first frame with text, and file load → first frame of its content. Record numbers, method, and rough code size/maintenance burden of each spike so the platform choice can weigh startup against ease of maintenance.

## Context

sokol was dropped from this benchmark: [IMGUI and text rendering options in Odin](002-imgui-text-rendering.md) found its Linux window layer is X11-only, which conflicts with the Wayland-only Linux target.
