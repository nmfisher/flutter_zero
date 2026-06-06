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
| `FilamentDisplayListExecutor`: pure-Dart rasterizer → RGBA8 buffer → Filament texture upload | ✅ |
| UI rendered on a separate Filament `View` at `renderOrder: 1`, composited on top of the 3D scene | ✅ |
| Alpha blending against 3D output (transparent clear, translucent panels) | ✅ |
| Widget tree / layout above the Canvas | ❌ — next |
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

Linux x86_64 under Xvfb (Vulkan/llvmpipe). ~390 frames driven by
`ThermionFrameScheduler`, ~1520 draw commands (4 per frame ×
~390 frames) software-rasterized into an 800×600 RGBA8 buffer,
uploaded to a Filament Texture, and composited on top of the 3D scene
via a separate UI View at `renderOrder: 1`.

```
FilamentDisplayListExecutor: 800x600 RGBA8 UI on a transparent overlay View (renderOrder: 1).
Rendering. Press Escape or close the window to quit.
vkCreateSwapchain: 800x600, ...
  frame 60  (display list: 4 cmds)
  frame 120  (display list: 4 cmds)
  ...
Shutting down...
UI executor stats: 382 frames, 1528 draw commands rasterized.
Goodbye!
```

Screenshots:
- `screenshots/linux_xvfb.png` — `StubFilamentExecutor` baseline, no UI
  visible (predates the real executor).
- `screenshots/linux_xvfb_real_executor.png` — earlier
  background-plane iteration (UI behind cube).
- `screenshots/linux_xvfb_overlay.png` — **current state**: pink HUD
  box and grey frame outline drawn *over* the cube; translucent dark
  panel at bottom-right reveals the cube through it.

## How the overlay is wired

Per the user's call — Filament does 3D rendering only, our software
rasterizer does 2D, and we hand Filament a texture to composite. The
on-Filament-side shape:

1. **A Filament `Texture`** (RGBA8, viewport-sized, `SAMPLEABLE | UPLOADABLE`).
   The executor updates it every frame via `Texture.setImage(0, ...)`.
2. **An unlit ubershader `MaterialInstance`** with
   `hasBaseColorTexture: true`, `alphaMode: AlphaMode.BLEND`,
   `doubleSided: true`. The texture is bound as `baseColorMap`.
3. **A fullscreen quad geometry** in NDC: vertices `[-1,-1,0]`..`[1,1,0]`,
   normals `(0, 0, 1)`, UVs flipped on V so row 0 of the buffer maps
   to the top of the screen.
4. **A new `Scene`** containing only that quad, with the material
   instance applied.
5. **A new `Camera`** with `Projection.Orthographic` set to
   `[-1, 1] × [-1, 1]`, near 0.1, far 10, positioned at `(0, 0, 1)`
   looking at origin.
6. **A new `View`** with that scene + camera, viewport
   `width × height`, `BlendMode.transparent`, post-processing off,
   frustum culling off.
7. **`renderManager.attach(uiView, swapChain, renderOrder: 1)`** so
   Filament composites the UI view *after* the 3D view, alpha-blending
   against the existing framebuffer content.

## Gotcha that ate hours during bring-up

The ubershader fragment shader computes
`color = baseColorTexture × baseColorFactor`. `baseColorFactor`
defaults to `(0, 0, 0, 0)`. So unless you explicitly call
`setBaseColorFactor(1.0, 1.0, 1.0, 1.0)` after `setBaseColorTexture`,
your texture sample multiplies to zero and every UI pixel is fully
transparent black. The view renders, the texture is correctly
uploaded — nothing visible. Worth either documenting upstream in
Thermion or defaulting the factor to white when `hasBaseColorTexture`
is true.

## Build cost note

First cold build of this example takes ~2.5 minutes on the container
(clang compiles the Thermion FFI shim per `.dart_tool` even though the
actual Filament `libthermion_dart.so` is shared with `thermion_basic`
via `hooks_runner/shared/`). Subsequent runs are fast.

## Next steps

- **Glyph atlas + `DrawTextCommand`.** stb_truetype-rasterized glyphs
  blended directly into the same RGBA8 buffer the executor already
  manages. No new infrastructure on the Filament side.
- **Anti-aliasing.** The current `_fillRect`/`_strokeRect` are
  pixel-grid only. AA over diagonals would benefit from supersampling
  or moving to Blend2D.
- **Dirty-region tracking.** Right now we re-upload the whole 800×600
  RGBA8 buffer (~1.9 MB) every frame. Acceptable at this scale, but a
  damage-list pass + `setSubImage` reduces bandwidth a lot when the UI
  is mostly static.
- **Widget tree.** Stateless first, build → layout → paint → walk into
  the canvas. Same shape as Flutter, smaller.
- **Hit testing.** Wire into Thermion's `InputHandler` chain so UI
  events get claimed before reaching the 3D scene logic.
