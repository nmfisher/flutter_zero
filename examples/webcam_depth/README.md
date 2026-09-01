# webcam_depth

Standalone macOS webcam pass-through — Phase 1 of
`video_editor/docs/compositing/standalone-macos-webcam-depth.md`
(ref `4052f79`). One window, one camera, no depth model yet: capture
with `AVCaptureSession`, upload the newest frame into a Filament
texture every render tick, and draw it full-screen through an unlit
quad. A stats HUD reports per-stage timings so each budget in the
design doc is a measured number rather than an assumption.

Built on the flutter_zero app model: a plain Dart process, SDL3 for
window and input, `thermion_dart` (Filament/Metal) for rendering.

## Supported platforms

- **macOS** — the real target. Metal through SDL's `SDL_Metal_CreateView`,
  capture through the Objective-C shim in `native/src/`.
- **Linux/X11** — window, render loop, stats HUD and telemetry all run,
  fed by a synthetic camera source, so the non-capture half of the app
  stays runnable (and testable) off a Mac. No real camera.

## Requirements

- Flutter Zero's bundled Dart SDK, run through `../../bin/dart`.
- **macOS:** `brew install sdl3`, a camera, and a code signing identity
  for the camera permission prompt.
- **Linux:** SDL3 ≥ 3.2 on the loader path; see
  `../sdl_window/README.md` for the build recipe.

## Run

```sh
cd examples/webcam_depth
../../bin/dart run lib/main.dart
```

- **Escape** quits (or close the window).
- **H** toggles the stats HUD.

On first launch macOS shows the camera permission prompt. Grant it and
the pass-through starts; deny it and the window shows the reason and the
fix instead of a black frame.

## Layout

| Path | What it is |
| --- | --- |
| `lib/main.dart` | App shell: SDL window, native surface, frame loop, key handling, teardown. |
| `lib/src/capture/` | `CameraSource` interface, `CameraController` (permission flow + newest-wins handoff), the FFI bindings, and the `NativeCameraSource` that owns the buffer pool. |
| `lib/src/capture/` · `FakeCameraSource` | Synthetic scrolling-gradient camera used on Linux and in tests. |
| `native/src/webcam_depth_capture.m` | Objective-C capture shim: `AVCaptureSession`, pooled BGRA→RGBA buffers, atomic newest-wins handoff, `os_signpost` intervals. |
| `hook/build.dart` | Native-assets build hook; compiles the shim into `package:flutter_zero_webcam_depth/webcam_depth_capture.dart` (macOS only). |
| `lib/src/render/video_view.dart` | Filament pass-through: RGBA8 texture + unlit full-screen quad on a dedicated view (`renderOrder: 0`). |
| `lib/src/stats/` | `PipelineStats` histograms, the 5×7 bitmap font, and the HUD view (`renderOrder: 1`). |

## Frame path

1. `AVCaptureVideoDataOutput` delivers BGRA frames on a private serial
   queue. The shim copies each into a pooled buffer, swizzling to RGBA,
   or drops it when every buffer is held — frames drop, never queue
   (§2.4). `alwaysDiscardsLateVideoFrames` keeps AVFoundation itself
   from building a backlog.
2. The render loop polls `wc_get_newest_frame` once per tick. Polling
   makes newest-wins fall out for free; a tick with nothing new simply
   re-presents the previous upload.
3. The frame is uploaded with `Texture.setImage` and drawn by the quad.
4. The HUD redraws at most twice a second, so the overlay costs two
   small uploads per second, not one per frame.

The camera is capped at 30 fps, the render loop targets 60 fps.

## Telemetry

The HUD shows render fps, camera fps, frame and drop counts, and
mean/max per stage against the design doc budgets (§5.1): upload ≤ 2 ms,
render ≤ 2 ms, glass-to-glass ≤ 100 ms. Two deliberate phase-1 caveats:

- **Present is not separately measurable.** Thermion's render call is
  synchronous through drawable submission, so the present wait is inside
  the reported render number. The HUD says so on the line where a
  separate present row would sit.
- **Glass-to-glass ends at submit, not at scan-out.** The frame is timed
  from the camera's presentation timestamp to the return of the render
  call, which is the closest point Dart can observe.

Stage timings also land in `os_signpost` (`capture-delivery`,
`buffer-copy`) for Instruments.

## Known deviations from the design doc

- **CPU frame upload instead of `CVMetalTextureCache`.** The doc asks
  for zero CPU pixel access on the live path. Thermion's supported
  per-frame upload is `Texture.setImage`; `setExternalImage` is
  unimplemented in `thermion_dart` develop. One pooled copy per frame is
  therefore made and measured in the HUD. No GPU readback happens
  anywhere. This is the main thing to revisit for Phase 2, where the
  depth model makes readback unavoidable.
- **`viewer.dispose()` / `FilamentApp.destroy()` are skipped on quit.**
  Thermion develop hits a concurrent-modification fault in
  `FilamentApp.destroy` for certain swapchain states; the process ends
  with `Isolate.current.kill()` instead, which the other examples do too.
- **Camera geometry is negotiated by a session preset, not a hand-picked
  device format.** A preset re-applies itself when the session runs and
  would override an `activeFormat` set beforehand. The 1280×720 preset
  expresses the same ≥ 720p @ 30 fps requirement.

## Testing

```sh
../../bin/dart test
```

46 tests cover the pure-Dart side: stats aggregation and budget
fractions, permission-flow state transitions, newest-wins frame handoff
and staleness counting, the bitmap font (including a check that the
error-screen copy only uses glyphs the font can draw), and the HUD
canvas scaling/wrapping. The capture shim and the render path need real
hardware and a Metal device, so they are reviewed but not exercised in
CI.
