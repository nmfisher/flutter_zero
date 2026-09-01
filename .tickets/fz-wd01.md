---
id: fz-wd01
status: closed
deps: []
links: []
created: 2026-09-01T00:00:00Z
closed: 2026-09-01T00:00:00Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [webcam-depth, macos, thermion, phase-1]
---

# Standalone macOS webcam depth app — Phase 1 (capture + render skeleton)

Implements Phase 1 of
`video_editor/docs/compositing/standalone-macos-webcam-depth.md`
(ref 4052f79): a standalone macOS app that captures the webcam with
AVFoundation and renders a Metal pass-through, with per-stage
instrumentation. No depth model — that is Phase 2.

Hosted in flutter_zero as `examples/webcam_depth`, using the framework
app model: a plain Dart process, SDL3 for window/input, `thermion_dart`
(Filament/Metal) for rendering.

## Scope

- App shell: one window, quit on Escape/close.
- Camera permission: `NSCameraUsageDescription`, request on launch, clear
  error screen when denied.
- `AVCaptureSession` + `AVCaptureVideoDataOutput`, >= 720p @ 30 fps,
  built-in camera first then external/UVC.
- Full-screen video pass-through at 30-60 fps.
- Stats HUD: fps, per-stage ms, drop count, glass-to-glass ms; toggled
  with a key.
- `os_signpost` intervals per stage.

## Exit criteria (from the design doc)

Stable pass-through, zero dropped frames over a 10-minute run.

## Deviations from the design doc

- **Frame upload is CPU-side, not `CVMetalTextureCache`.** The doc asks
  for zero CPU pixel access on the live path. Thermion's supported
  per-frame upload API is `Texture.setImage`; its `setExternalImage`
  binding is `UnimplementedError`, and the working
  `FFIFilamentApp.setExternalImage` needs a prebuilt C++
  `Platform::ExternalImage` that a Swift capture shim cannot construct
  without Filament's C++ headers. Phase 1 therefore does one pooled
  BGRA copy per frame and measures it in the HUD. No GPU readback
  happens anywhere — nothing is read back, only uploaded. Revisit when
  the model lands (Phase 2), which is where readback actually bites.

## Notes

- `tk` is not installed in the build container (checked PATH, filesystem,
  and every accessible repo). This ticket file follows the `.tickets/`
  convention manually instead of `tk start` / `tk close`.
- macOS-only work; written on a Linux container, so the Swift/Obj-C
  capture shim is reviewed but not compiled here.

## Outcome

Implemented in `examples/webcam_depth`. `dart analyze` clean,
`dart test` 46/46 on Linux.

- App shell: SDL3 window, Metal layer via raw FFI (`sdl3`'s bindings for
  `SDL_Metal_CreateView`/`GetLayer` have broken signatures), port-based
  `FrameScheduler` at 60 fps, Escape/H keys.
- Capture: Objective-C shim + native-assets hook; pooled buffers owned
  by Dart, atomic newest-wins handoff, drop-never-queue; permission
  through a callback so the window keeps drawing during the dialog;
  clear error screen on denial.
- Render: RGBA8 texture + unlit full-screen quad on view 0; HUD on view
  1, blended over the video, redrawn at most twice a second.
- Telemetry: per-stage mean/max histograms vs the §5.1 budgets,
  drop/staleness counts, glass-to-glass distribution,
  `os_signpost` intervals, 5x7 bitmap-font HUD (no text renderer in
  thermion).

Deferred to first macOS run (hardware + camera required here):

- The exit criterion (stable pass-through, zero drops over 10 minutes)
  is unverified on this container: no macOS, no camera, no Metal device.
- The shim and build hook are reviewed but not compiled here.
- Signing entitlement for the camera prompt is untested.
