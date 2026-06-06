# thermion_ui

`examples/sdl_ui`'s framework abstractions (`FrameScheduler`,
`RecordingCanvas`, `DisplayList`, `DisplayListExecutor`) wired against
Thermion. Same lit cube as `examples/thermion_basic` for visual
confirmation, but the per-frame work runs *through* the framework seams
instead of bypassing them — proving the seams are real and that the
sdl_ui design carries over to a Thermion backend without changes above
the executor.

## Architecture

```
ThermionFrameScheduler                 ← wraps FrameScheduler_startWithPort
       │
       │ onFrame(timestamp)            ← Dart-thread, port-driven, vsync-ish
       ↓
SDL3 event drain                       ← claim quit / escape
       │
       ↓
RecordingCanvas ─► DisplayList         ← clear + fillRect + strokeRect each frame
       │
       ↓
StubFilamentExecutor                   ← counts; real impl is the next step
       │
       ↓
camera.lookAt(orbit)
FilamentApp.instance!.render()         ← Filament submits to GPU
```

The 3D scene (cube + two lights + orbiting camera) still goes through
the `ThermionViewer` API directly. The `RecordingCanvas` is exercised
every frame purely to demonstrate the abstraction works: when the real
Filament executor lands (turning each `DrawCommand` into a Filament
textured quad on a UI `View` attached at `renderOrder: 1`), the
consumer code below the canvas doesn't change.

## What's wired here vs what isn't

| Component | State |
| --- | --- |
| `FrameScheduler` interface (same shape as sdl_ui) | ✅ |
| `ThermionFrameScheduler` impl (port-based, real vsync-ish) | ✅ |
| `RecordingCanvas` + `DisplayList` + `DrawCommand` types | ✅ |
| `DisplayListExecutor` interface | ✅ |
| `StubFilamentExecutor` (counts commands, draws nothing) | ✅ |
| Real Filament executor (textured-quad emission, UI View setup) | ❌ — next |
| Widget tree / layout above the Canvas | ❌ |
| Hit-testing through the widget tree | ❌ |
| Text rendering via glyph atlas | ❌ |

The stub executor is intentional. The Canvas API is the seam; the
executor swap is the upgrade. Building the real executor (UI View at
`renderOrder: 1`, dynamic per-frame `Geometry`, unlit material, glyph
atlas for text) is a chunk of work that deserves its own commit.

## Run

Same recipe as `examples/thermion_basic`:

```sh
cd examples/thermion_ui
../../bin/dart pub get
../../bin/dart run lib/main.dart
```

Headless (Linux):

```sh
xvfb-run -s "-screen 0 800x600x24" ../../bin/dart run lib/main.dart
```

Expected: window opens, lit cube orbits, prints `frame 60 (display list:
3 cmds)`, `frame 120 (display list: 3 cmds)`, … at 60Hz. Escape, window
close, or SIGTERM triggers shutdown — prints `UI executor stats: N
frames, 3N draw commands recorded.` then `Goodbye!`.

## Verified

Linux x86_64 under Xvfb (Vulkan/llvmpipe). 325 frames driven by
`ThermionFrameScheduler`, 975 draw commands recorded into display
lists, clean shutdown. Screenshot at `screenshots/linux_xvfb.png` shows
the lit cube (identical to `thermion_basic` — the UI overlay's empty
because the executor is a stub).

```
FilamentApp ready.
Rendering. Press Escape or close the window to quit.
vkCreateSwapchain: 800x600, ...
  frame 60  (display list: 3 cmds)
  frame 120  (display list: 3 cmds)
  ...
Shutting down...
UI executor stats: 325 frames, 975 draw commands recorded.
Goodbye!
```

## Build cost note

First cold build of this example takes ~2.5 minutes on the container
(clang compiles the Thermion FFI shim per `.dart_tool` even though the
actual Filament `libthermion_dart.so` is shared with `thermion_basic`
via `hooks_runner/shared/`). Subsequent runs are fast.

## Next steps

- **Real `FilamentDisplayListExecutor`.** Create a second Filament
  `View` with an orthographic camera + its own `Scene`, attach to the
  same `SwapChain` at `renderOrder: 1`. Per frame: clear the UI scene,
  walk the `DisplayList`, build a single `Geometry` containing all UI
  quads (vertex colors, indices), submit via `createGeometry` with an
  unlit material instance, add to the UI scene. That replaces
  `StubFilamentExecutor` with no other changes.
- **Glyph atlas + `DrawTextCommand`.** stb_truetype-rasterized glyphs
  into a `R8` Filament texture, `DrawText` translates to a run of
  textured quads sampling the atlas.
- **Widget tree.** Stateless first, build → layout → paint → walk into
  the canvas. Same shape as Flutter, smaller.
- **Hit testing.** Wire into Thermion's `InputHandler` chain so UI
  events get claimed before reaching the 3D scene logic.
