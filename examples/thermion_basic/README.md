# thermion_basic

Vanilla Thermion bootstrap into an SDL3 window. Opens an 800×600 window,
hands the backing native surface to Filament, renders a lit cube orbiting
under a perspective camera at 60Hz. Escape or closing the window quits.

This validates four things:

1. The Filament backend bootstraps against an externally-owned native
   surface (CAMetalLayer on macOS, X11 Window on Linux/X11).
2. Thermion's port-based `FrameScheduler` drives continuous rendering on
   the Dart event loop — `setRendering(true)` is a no-op on native, so
   the actual loop comes from `FrameScheduler_startWithPort`.
3. SDL3 event polling coexists with Filament's render thread (events
   pumped inside the frame listener; render happens on Thermion's render
   thread, dispatched per `FilamentApp.instance!.render()`).
4. The basic teardown path (with one known workaround — see below).

It's the windowed peer of Thermion's own `examples/dart/cli_headless`.

## Supported platforms

- **macOS** (arm64 or x86_64) — Metal via SDL3's `SDL_Metal_CreateView`.
- **Linux/X11** (verified under Xvfb with llvmpipe) — Vulkan via the
  X11 Window XID.

Other platforms TBD.

## Requirements

- Flutter Zero's bundled Dart SDK (3.13.0-beta or compatible). Native
  assets are on by default — no experiment flag needed.
- A C/C++ toolchain (Thermion compiles FFI glue locally and links
  against a precompiled Filament archive it downloads from Cloudflare).
- **macOS:** `brew install sdl3`
- **Linux:** SDL3 ≥ 3.2 built from source (Ubuntu's repos still ship
  SDL2 only); see `../sdl_window/README.md` for the build recipe. A
  Vulkan loader needs to be available — `libvulkan1` from the distro,
  plus llvmpipe (Mesa) for headless / xvfb work.

## Dependencies

This example sits outside the Flutter Zero workspace because Thermion's
`archive` / `code_assets` / `hooks` requirements conflict with the
workspace's pinned versions. It resolves its own deps via its own
`pubspec.yaml`:

- `thermion_dart` from the `develop` branch of
  [nmfisher/thermion](https://github.com/nmfisher/thermion). Pub.dev
  currently has 0.3.4+1, but the windowed-swapchain API surface we
  use here lives on `develop` / 0.4.0 (e.g.
  `RenderManager.attach(view, swapChain)` instead of the older
  `FilamentApp.register`, and the port-based `FrameScheduler`).
- `sdl3 ^2.8.5` for window and event handling.

The `pubspec.yaml` pins `hooks.user_defines.thermion_dart.mode: release`
because Thermion only publishes Linux precompiled binaries in release
mode (macOS has both).

## Running

```sh
cd examples/thermion_basic
../../bin/dart pub get
../../bin/dart run lib/main.dart
```

Headless under Xvfb (Linux):

```sh
xvfb-run -s "-screen 0 800x600x24" ../../bin/dart run lib/main.dart
```

Expected behaviour: window opens, dark background, prints `frame 60`,
`frame 120`, … once a second. Escape, closing the window, or SIGTERM
(SDL3 catches it and posts an `SDL_QUIT` to the event queue) triggers
shutdown with `Shutting down...` then `Goodbye!`.

## Implementation notes

- **Frame loop.** On native targets Thermion's `setRendering(true)` is
  a no-op (it only attaches the view to the swapchain; the
  RenderManager-attached-to-render-thread path is web-only). The actual
  per-frame driver is `FrameScheduler_startWithPort(nativePort,
  targetFps)`, which spawns a native scheduler thread that posts an
  int via `Dart_PostCObject_DL` per frame. A Dart `ReceivePort`
  listener wakes up, drains SDL events, and calls
  `FilamentApp.instance!.render()`. This is the same pattern as
  Thermion's `examples/dart/cli_windows`.
- **macOS metal layer plumbing.** The `sdl3 2.8.5` package's Dart
  bindings for `SDL_Metal_CreateView` / `SDL_Metal_GetLayer` have
  broken C signatures (declare `Void` returns and drop the `view`
  argument). We work around this by looking up both symbols directly
  via `DynamicLibrary.open(...)` and calling with the correct C
  signatures. Worth filing upstream against `sdl3`.
- **Linux X11 plumbing.** Filament's stock `VulkanPlatform` on Linux
  interprets the swapchain handle as an X11 `Window` XID (see
  `filament/SwapChain.h`). SDL3 exposes this via
  `SDL_PROP_WINDOW_X11_WINDOW_NUMBER`, so the Linux path is just
  `sdlGetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)`
  cast to a `Pointer` and handed to `createSwapChain`. Wayland and
  Windows would need their own glue.
- **Shutdown bug workaround.** `viewer.dispose()` followed by
  `FilamentApp.destroy()` currently throws "Concurrent modification
  during iteration" in Thermion 0.4.0/develop's
  `FFIFilamentApp.destroy` (an iteration over the swapchain list while
  the list is being mutated). The cli_windows example sidesteps this
  by just calling `FrameScheduler_stop()` and killing the isolate, so
  we do the same. Worth filing upstream against Thermion.

## Verified on this branch

Linux x86_64 under Xvfb (Ubuntu 24.04 container, software Vulkan via
llvmpipe):

```
SDL3 window created. Native surface @ 0x20002e
Bootstrapping FFIFilamentApp...
FEngine (64 bits) created at 0x... (threading is enabled)
FEngine resolved backend: Vulkan
Vulkan device driver: llvmpipe Mesa 25.2.8-0ubuntu0.24.04.1 (LLVM 20.1.2)
Selected physical device 'llvmpipe (LLVM 20.1.2, 128 bits)' ...
Backend feature level: 3
FEngine feature level: 1
FilamentApp ready.
Rendering. Press Escape or close the window to quit.
vkCreateSwapchain: 800x600, 44, 0, swapchain-size=4, ...
  frame 60
  frame 120
Shutting down...
Goodbye!
```

`scrot` of the Xvfb framebuffer (`screenshots/linux_xvfb_lit_cube.png`)
confirms a lit cube on a muted-purple background. The background color
doesn't exactly match what we passed to `setBackgroundColor` because
Filament treats it as linear and runs ACES tone-mapping over it — that's
expected, not a bug. Earlier "clear-only" screenshot (no scene content)
is at `screenshots/linux_xvfb.png` for comparison.

## Next steps

- Drop a glTF asset into the scene to validate the full render pipeline
  (`viewer.loadGltf(...)`).
- Implement a `ThermionFrameScheduler` that satisfies our framework's
  `FrameScheduler` interface (`examples/sdl_ui/lib/src/scheduler.dart`)
  and wraps `FrameScheduler_startWithPort`. This becomes the
  approach-(B) implementation for our UI work.
- A second `View` attached to the same SwapChain at `renderOrder: 1`
  for UI overlay.
- Windows (D3D12 via `SDL_PROP_WINDOW_WIN32_HWND_POINTER`).
- File the two upstream issues observed during this work: broken
  `SDL_Metal_*` bindings in `sdl3 2.8.5`, and the swapchain-list
  concurrent-modification bug in `FFIFilamentApp.destroy`.
