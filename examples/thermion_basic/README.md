# thermion_basic

Vanilla Thermion bootstrap into an SDL3 window — no UI layer yet. Opens
an 800×600 window, hands the backing `CAMetalLayer` to Filament, renders
a Catppuccin-flavoured background continuously. Escape or closing the
window quits.

This validates three things:

1. The Filament Metal backend bootstraps against an externally-owned
   `CAMetalLayer` (SDL3 owns the layer, Filament owns the swapchain).
2. `registerRequestFrameHook` actually fires per frame on the Dart
   thread.
3. SDL3 event polling coexists with Filament's render thread (Thermion
   spawns its own native render thread; our SDL polling runs on the
   Dart main thread inside the frame hook).

It's the windowed peer of Thermion's own `examples/dart/cli_headless` —
the latter writes a frame to a BMP file, this one shows it in a window.

## macOS only for now

This example targets macOS. Filament's other backends (Vulkan on
Linux/Windows, OpenGL on web) need different surface-acquisition glue
than `CAMetalLayer`. Cross-platform support is a follow-up.

## Requirements

- macOS (arm64 or x86_64)
- Flutter Zero's bundled Dart SDK (Dart 3.13.0-beta).
- SDL3 installed via Homebrew:
  ```sh
  brew install sdl3
  ```

## Dependencies

This example sits outside the Flutter Zero workspace because Thermion's
`archive` / `code_assets` / `hooks` requirements conflict with the
workspace's pinned versions. It resolves its own deps via its own
`pubspec.yaml`:

- `thermion_dart` from the `develop` branch of
  [nmfisher/thermion](https://github.com/nmfisher/thermion). Pub.dev
  currently has 0.3.4+1, but the windowed-swapchain API surface this
  example uses lives on develop / 0.4.0.
- `sdl3 ^2.8.5` for window and event handling.

The `pubspec.yaml` pins `hooks.user_defines.thermion_dart.mode: debug`,
which matches the precompiled Filament binaries Thermion downloads from
its CDN for macOS.

## Running

```sh
cd examples/thermion_basic
../../bin/dart pub get
../../bin/dart run lib/main.dart
```

Expected behaviour: an 800×600 window opens, draws a dark
Catppuccin-Mocha background, prints `frame 60`, `frame 120`, … every
~1s. Escape or closing the window prints `Shutting down...` and exits.

## Implementation notes

- **Metal layer plumbing.** The `sdl3 2.8.5` package's Dart bindings for
  `SDL_Metal_CreateView` / `SDL_Metal_GetLayer` have broken signatures
  (return `Void`, drop their `view` argument). We work around this by
  looking up both symbols directly via `DynamicLibrary.open(...)` and
  calling them with the correct C signatures. Worth filing upstream.
- **Frame hook.** We register an async callback via
  `FilamentApp.instance!.registerRequestFrameHook(...)`. Thermion's
  render thread calls into it on the Dart main thread once per frame,
  before the GPU submission. We use it to drain SDL events.
- **Quit.** A `Completer<void>` gets completed when SDL surfaces a
  quit event or Escape, the outer `await` returns, and the cleanup
  path runs in order: stop rendering → unregister hook → dispose
  viewer → destroy FilamentApp → destroy SDL view + window → quit SDL.
- **No UI layer.** Intentionally. The `FrameScheduler` /
  `RecordingCanvas` / widget-tree work from `UI_BRAINSTORMING.md` and
  `RENDERING.md` will plug in above this baseline once the bootstrap
  is solid.

## Next steps

- Drop a glTF asset into the scene to confirm the full render pipeline
  works (load with `viewer.loadGltf(...)`).
- Implement a `ThermionFrameScheduler` that satisfies our framework's
  `FrameScheduler` interface and wraps `registerRequestFrameHook`.
- A second `View` attached to the same SwapChain at `renderOrder: 1`
  for UI overlay.
- Linux (Vulkan via `wl_egl_window`/`xlib`) and Windows (D3D12) variants
  once the macOS path is solid.
