# Platform benchmark spikes

Throwaway spikes for [Benchmark startup and file load: native Win32 vs SDL3](../../.wayfinder/tickets/001-bench-platform-startup.md). Not editor code.

Every spike runs the same steps: open a 1280×800 window at native pixel density, bake Menlo/Consolas with stb_truetype, draw a screen of text on the CPU, present, then read a 100MB file, draw its first screen, present, and count its lines. Only the window and present path changes between spikes (`common/` is shared).

| Spike | Window | Present |
|---|---|---|
| `native_macos` | AppKit `NSWindow` | `CAMetalLayer`, canvas copied into the drawable (no shaders), wait until done |
| `native_win32` | Win32 `CreateWindowExW` | GDI `StretchDIBits` + `DwmFlush`; `--gpu`: D3D11 flip swapchain + `UpdateSubresource` + `DwmFlush` |
| `sdl3` | `SDL_CreateWindow` | window surface; `--gpu`: `SDL_Renderer` streaming texture (Metal / D3D11) |

## Method

`harness run` takes the wall-clock time, spawns the spike, and reads the `MARK <stage> <unix_ns>` lines it prints. Every number is **ms since spawn**, so it includes exec and dynamic linking. A frame is counted as "visible" once present returns (macOS: Metal command buffer completed; Windows: `DwmFlush` returned; SDL: `RenderPresent`/`UpdateWindowSurface` returned). That's an approximation: the compositor can still take up to one more vsync to show it.

- `first` is run 1 and `median`/`min`/`max` cover all runs. Runs are 200ms apart.
- The file is read while it's still in the OS page cache. A cold disk read was **not** measured (on macOS that needs `sudo purge`).
- `harness gen` writes a source-shaped file of 100MB / 2.53M lines.

## Results: macOS

Apple M5, macOS 26.6.2, Odin dev-2026-03, SDL 3.4.20 (Homebrew), 20 runs. Full output: `build/results-macos.txt` (not committed).

Medians, in ms since spawn:

| Stage | native (AppKit+Metal) | SDL3 surface | SDL3 `--gpu` (Metal) |
|---|---:|---:|---:|
| `main` reached | 10.6 | 14.3 | 14.2 |
| platform init done (`window`) | 125.3 | 131.2 | 131.0 |
| **first frame with text** | **131.1** | **139.9** | **135.7** |
| 100MB file read | +12.8 | +10.3 | +10.6 |
| **first frame of file** | **147.9** (+16.8 after first frame) | **154.2** (+14.3) | **149.9** (+14.2) |
| line count over the whole file | +13.1 | +13.9 | +13.6 |

Where the native time goes (medians): exec→`main` 11, `NSApplication` + `finishLaunching` 62, `NSWindow` init 31, Metal device + queue 0.6, order front 3, first event pump 18, font bake 0.7, draw + present 5.

- **On macOS the platform layer hardly matters.** SDL3 costs 5–9ms more than native at the median, almost all inside `SDL_Init`. AppKit itself takes ~90ms before anything is drawn, whichever layer is used.
- **The "well under 100ms" startup target is missed on macOS by every option** (~130ms). The cost is AppKit startup, not our code.
- **The first launch after a rebuild costs ~250ms more** (seen on both spikes): macOS checks a newly built binary. Users would see this once per install or update.
- **File load is not a platform question.** Reading 100MB from cache takes ~11ms, the first screen ~4ms, and a full newline scan ~13ms, the same on every layer.
- Size: each binary is ~250KB. SDL3 adds a 2.5MB dylib (2.8MB DLL on Windows) to ship. Spike code: native macOS 92 lines, Win32 146, SDL3 94, plus 177 shared. SDL3's one file covers every OS; native needs one file per OS (Wayland not written).

## Results: Windows

Not measured yet. To run them, follow the checklist below.

## Running

macOS (needs `brew install sdl3`):

```bash
odin build harness -o:speed -out:build/harness
odin build native_macos -o:speed -out:build/native_macos
odin build sdl3 -o:speed -out:build/sdl3 -extra-linker-flags:"-L/opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib"
./build/harness gen build/big.txt 100
./build/harness run --runs 20 -- ./build/native_macos --file build/big.txt
```

### Windows checklist

1. Make sure `<odin>/vendor/sdl3/SDL3.dll` and `SDL3.lib` are real binaries (~2.8MB) and not Git LFS pointer files. Run `git lfs pull` in the Odin checkout, or use a release zip.
2. From `spikes\platform-bench`:
   ```
   mkdir build
   odin build harness -o:speed -out:build\harness.exe
   odin build native_win32 -o:speed -out:build\native_win32.exe
   odin build sdl3 -o:speed -out:build\sdl3.exe
   copy <odin>\vendor\sdl3\SDL3.dll build\
   build\harness.exe gen build\big.txt 100
   ```
3. Run each one 20 times and save the output:
   ```
   build\harness.exe run --runs 20 -- build\native_win32.exe --file build\big.txt
   build\harness.exe run --runs 20 -- build\native_win32.exe --gpu --file build\big.txt
   build\harness.exe run --runs 20 -- build\sdl3.exe --file build\big.txt
   build\harness.exe run --runs 20 -- build\sdl3.exe --gpu --file build\big.txt
   ```
4. Check one frame by eye: `build\native_win32.exe --gpu --file build\big.txt --stay` should show the file as text. The Win32 spike was only type-checked from macOS (`odin check native_win32 -target:windows_amd64`) and has never run.
5. Record the machine (CPU, GPU, Windows build) and the four outputs on the Windows ticket.
