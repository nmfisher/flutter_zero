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
| `FilamentDisplayListExecutor`: pure-Dart rasterizer → RGBA8 buffer → Filament texture upload → background plane | ✅ |
| Layering: UI texture is on Filament's **background plane** (cube renders in front) | ⚠️ — works, but inverse of desired |
| UI on top of 3D (requires a transparent unlit material, see below) | ❌ — next |
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

Linux x86_64 under Xvfb (Vulkan/llvmpipe). With the real executor:
~390 frames driven by `ThermionFrameScheduler`, ~3120 draw commands
(8 per frame × ~390 frames) software-rasterized into an 800×600 RGBA8
buffer, uploaded to a Filament Texture, and displayed via the viewer's
background plane. Clean shutdown.

```
FilamentDisplayListExecutor: 800x600 RGBA8 UI surface ready (background plane).
Rendering. Press Escape or close the window to quit.
vkCreateSwapchain: 800x600, ...
  frame 60
  frame 120
  ...
Shutting down...
UI executor stats: 391 frames, 3128 draw commands rasterized.
Goodbye!
```

Screenshots:
- `screenshots/linux_xvfb.png` — earlier `StubFilamentExecutor` baseline,
  no UI visible.
- `screenshots/linux_xvfb_real_executor.png` — the current state: pink
  HUD box (wobbling), grey frame outline, blue-tinted box cluster, all
  rasterized into the background, with the 3D cube rendering on top.

## Why the cube draws *over* the UI (and what to do about it)

The current Filament wiring puts our texture on the viewer's
background plane — Filament's stock `TexturedQuad` / image-material
path is **opaque** (its fragment shader pre-blends `image × alpha +
backgroundColor × (1 − alpha)` and outputs `alpha = 1`), so it can't
be used as an overlay surface. Even with `View.BlendMode.transparent`,
the quad's fragment alpha is implicitly 1 so nothing leaks through to
the framebuffer.

Two paths to actual overlay (cube *behind*, UI *on top*):

1. **Custom transparent material** compiled via `matc`. ~30 lines of
   `.mat` source declaring `blending: transparent` and a `sampler2d`
   that gets sampled and emitted directly to `material.baseColor`
   without the pre-multiply step. Drops into `createMaterial(Uint8List)`,
   gets attached to a custom screen-space quad geometry. Hot path
   doesn't change.
2. **Second View + orthographic camera** attached to the same SwapChain
   at `renderOrder: 1`, with our quad in its scene. Filament composites
   the views automatically. More setup, no `matc` dependency.

The seam from the canvas down to the upload doesn't move — we change
*where* Filament displays the texture, not how we produce it.

Also note: the current setup deliberately skips `viewer.setBackgroundColor`
because that creates a Filament Skybox which overdraws the texture
background plane.

## Build cost note

First cold build of this example takes ~2.5 minutes on the container
(clang compiles the Thermion FFI shim per `.dart_tool` even though the
actual Filament `libthermion_dart.so` is shared with `thermion_basic`
via `hooks_runner/shared/`). Subsequent runs are fast.

## Next steps

- **Flip layering to UI-on-top.** Pick path 1 or 2 from "Why the cube
  draws over the UI" above. Path 2 (separate `View`) is probably the
  right answer since it doesn't need `matc` and gives us a clean
  separation for hit-testing later.
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
