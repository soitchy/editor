# Use SDL3 as the platform layer

v1 uses SDL3 for windowing, input, clipboard and present on Windows, macOS and Linux (Wayland). Native per-OS windows are a possible later optimisation, not a v1 goal.

## Why

- SDL3 was 5-9ms behind native on macOS and 17ms (GPU path) to 41ms (CPU path, managed machine) behind on Windows. No option reached the 100ms startup target, so native would not have bought it.
- SDL3 is the only vendored layer that covers Wayland. One small file replaces three hand-written platform layers, which matters for a solo maintainer.

## Consequences

- The editor core must not use `SDL_*` types. It sees a thin platform seam (window, events, clipboard, present), so a native backend can replace SDL3 one file per OS.
- The startup target is "as close to the OS floor as we can get", not "well under 100ms".
- SDL3 ships as a ~2.5-2.8MB shared library.
