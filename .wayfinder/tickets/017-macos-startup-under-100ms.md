---
id: 017
title: Can macOS startup get under 100ms?
type: wayfinder:task
status: open
assignee:
blocked_by: []
parent: map.md
---

# Can macOS startup get under 100ms?

## Question

Can cold start → first frame with text on macOS get well under 100ms? The `native_macos` spike takes ~130ms, ~90ms of it in `NSApplication` setup and `NSWindow` creation. Try cheap changes in the spike (a real `.app` bundle with Info.plist, launching through LaunchServices/`open`, skipping or deferring `finishLaunching`/activation, creating the window before other setup) and measure each one with the harness. If nothing gets there, record the floor so the macOS target can be restated.

## Context

From [Benchmark startup and file load: native Win32 vs SDL3](001-bench-platform-startup.md). The floor applies to native and SDL3 alike, so this does not block [Choose the platform layer](009-choose-platform-layer.md).
