# sdl_ui

Foundation for a UI framework on top of Flutter Zero + SDL3. The current
scope is intentionally tiny:

- `src/scheduler.dart` — `FrameScheduler` abstraction with a
  `YieldFrameScheduler` implementation. This is approach (A) from
  `../../UI_BRAINSTORMING.md`: a `while (running) { onFrame(); await
  Future.delayed(Duration.zero); }` loop that lets the embedder message
  loop pump between frames so `async`/`Future`/`dart:io`/isolate messages
  actually work. Approach (B) (real vsync alignment via SDL3 main-callbacks)
  will land as an alternate `FrameScheduler` implementation later, with no
  changes above this seam.
- `src/canvas.dart` — `Canvas` wraps `SdlxRenderer` with framework-side
  types (`Color`, `Rect`). All calls run on the SDL main thread.
- `src/app.dart` — `SdlApp.run(...)` does SDL init, window/renderer
  creation, dlopen path probing for Apple Silicon Homebrew, event
  pumping, and drives the loop via the scheduler.
- `lib/main.dart` — small demo: six color-cycling squares orbiting a
  centre marker, switchable backgrounds (`1`–`4`), `Escape` to quit.

This is a Dart-only example (no Flutter platform scaffolding). Run with
`dart` directly; for macOS .app-bundle context use the same recipe as
`../sdl_window/README.md` if/when we add platform dirs here.

## Running

```sh
# Linux — SDL3 from source per the sdl_window README
cd examples/sdl_ui
../../bin/flutter pub get
../../bin/dart lib/main.dart
```

```sh
# Headless / CI
xvfb-run -s "-screen 0 800x600x24" ../../bin/dart lib/main.dart
```

If `flutter pub get` complains about `0.0.0-unknown`, patch the version
stamp once per cache (see `../sdl_window/README.md`).

## Where this is going

Next layers (in order of intended addition, see `UI_BRAINSTORMING.md`):

1. SDL_ttf bindings + a glyph atlas for text rendering.
2. A minimal widget tree (`Widget`, `Element`, `StatelessWidget`,
   `StatefulWidget`) above the Canvas.
3. Yoga FFI for flexbox layout.
4. Worker isolate image decoding.
5. Swap `YieldFrameScheduler` for an `SDL_AppIterate`-backed scheduler so
   frames are phase-locked to the display's vsync.
