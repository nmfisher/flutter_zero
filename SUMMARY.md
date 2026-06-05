# Flutter Zero

## What It Is

Flutter Zero is a stripped-down fork of the Flutter engine with **all rendering removed**. It provides a portable Dart runtime that runs on every platform Flutter supports (iOS, Android, macOS, Linux, Windows, Web) but makes no assumptions about the UI layer. There is no Skia, no Impeller, no widget framework, and no drawing surface.

The project is maintained by Matej Knopp ([github.com/knopp](https://github.com/knopp)) and lives at [github.com/knopp/flutter_zero](https://github.com/knopp/flutter_zero).

## Why It Exists

Flutter Zero's stated goals are:

1. **Explore new use cases for Dart** — writing apps with native UI toolkits via Dart interop (e.g., driving SwiftUI, Jetpack Compose, WinUI from Dart), without carrying the overhead of Flutter's rendering pipeline.
2. **Explore `dart:ui` as a separate package** — decoupling the rendering API from the engine itself, so alternative renderers could be plugged in.
3. **Maintain compatibility with existing Flutter tooling** — the `flutter` CLI, IDE plugins, hot reload, and debugging all work as-is.

## How It Works

### Architecture

Standard Flutter has four threads: Platform, UI, Raster, and IO. Flutter Zero collapses this to **one effective thread** — the platform thread — by defaulting `MergedPlatformUIThread::kEnabled`. The rasterizer, compositor, animator, IO thread, and all GPU abstractions are physically deleted from the engine source.

### Threading Model

| | Standard Flutter | Flutter Zero |
|---|---|---|
| Threads | Platform, UI, Raster, IO | Platform + UI (merged) |
| Rasterizer | Own thread, GPU compositing | Deleted |
| IO thread | Asset loading, image decode | Removed |
| Frame scheduler | Vsync waiter, Animator | Removed |

### What the Engine Keeps

- Dart VM initialization and lifecycle
- Root isolate management (create, run, restart)
- Platform message routing (channels between Dart and native code)
- Asset management and deferred library loading
- VM service protocol (for debugging)
- FML (foundation library) — message loop, threading, sync, file I/O
- The embedder C API (`FlutterEngineRun`)
- Hot reload and hot restart

### What the Engine Removes

- Impeller, Skia, and all GPU backends (Metal, Vulkan, OpenGL)
- The rasterizer and compositor
- The animator (frame scheduling, vsync)
- The entire `dart:ui` drawing API: `Canvas`, `PictureRecorder`, `Picture`, `Path`, `Paint`, `Color`, `Shader`, `Image`, `Codec`, `FrameInfo`, `Scene`, `SceneBuilder`
- Text rendering: `Paragraph`, `ParagraphBuilder`, `FontWeight`, `TextStyle`
- Image decoding: `Image`, `ImageDescriptor`, `Codec`
- Layer types: `OffsetLayer`, `TransformLayer`, `ClipRectLayer`, etc.
- Frame callbacks: `scheduleFrame`, `onBeginFrame`, `onDrawFrame`
- `flutter_gpu` (the Dart-side GPU API)

### The `dart:ui` Surface That Remains

The `dart:ui` library is importable but reduced to a message-passing and configuration hub:

| Available | Gone |
|---|---|
| `PlatformDispatcher` (messages, locales, errors) | `Canvas`, `PictureRecorder`, `Picture`, `Path` |
| `registerHotRestartListener` | `Paint`, `Color`, `Shader`, `Gradient` |
| `IsolateNameServer`, `PluginUtilities` | `Image`, `Codec`, `FrameInfo`, `ImageDescriptor` |
| `ImmutableBuffer` (raw asset bytes) | `Scene`, `SceneBuilder` |
| `Offset`, `Size`, `Rect` | `scheduleFrame`, `onBeginFrame`, `onDrawFrame` |
| `CallbackHandle` (isolate callbacks) | `Paragraph`, `ParagraphBuilder`, text APIs |
| Full `dart:io`, `dart:ffi`, `dart:isolate` | All layer types |

### Platform Embedders

Every platform embedder has been rewritten to run the engine headlessly:

- **macOS** — `MainFlutterWindow.swift` deleted. `AppDelegate` creates a bare `FlutterEngine`.
- **Windows** — `FlutterWindow`, `Win32Window` deleted. Creates headless `flutter::FlutterEngine`.
- **Linux** — Uses `fl_engine_new()` directly. No GTK window, no `FlView`.
- **iOS** — No `FlutterViewController`. `AppDelegate` runs a bare `FlutterEngine`.
- **Android** — `MainActivity` is plain `Activity()` (not `FlutterActivity`). Custom `Application` class starts a headless `FlutterEngine`.

### Flutter Tools Patches

Five patches modify the upstream `flutter_tools` to work without rendering:

1. **Redirect storage URLs** — Gradle wrapper and iOS USB artifacts download from Google's servers; Flutter Zero's engine artifacts come from `engine.flutter0.dev`.
2. **No CanvasKit** — Strips CanvasKit from web builds.
3. **No texture registrar (Windows)** — Removes `flutter_texture_registrar.h`.
4. **No `flutter_gpu`** — Removes `flutter_gpu` from SDK artifact downloads.
5. **Rewrite app templates** — Converts every platform template from "GUI app with Flutter view" to "headless engine." The `main.dart` template becomes an empty `void main() {}`.

### Engine Build

The engine is built via GN/Ninja (same as upstream Flutter). Prebuilt artifacts are hosted at `engine.flutter0.dev` (R2 storage). CI builds for macOS, Linux, and Windows via GitHub Actions using a content-aware hash to skip builds when the engine source hasn't changed.

## Capabilities as of Today

### Can Do

- Run Dart code on iOS, Android, macOS, Linux, Windows, and Web
- Use `dart:io` for filesystem and networking (unrestricted, unlike standard Flutter)
- Use `dart:ffi` for native C interop on every platform
- Use platform channels to communicate between Dart and native code
- Hot reload and hot restart via standard Flutter debugging workflow
- Load assets via `ImmutableBuffer`
- All standard Dart SDK libraries: `dart:async`, `dart:isolate`, `dart:convert`, `dart:math`, `dart:typed_data`, `dart:collection`, `dart:developer`
- VM service protocol for debugging and profiling

### Cannot Do

- Draw anything — no canvas, no scene, no pixels
- Display text — no paragraph/layout engine
- Decode or display images — no codec, no frame info
- Schedule frames — no vsync, no frame callbacks
- Run the Flutter widget framework — `package:flutter` is an empty file
- Use Material or Cupertino widgets
- Use any GPU rendering API through the Flutter engine

## Potential Future Directions

Based on the project's stated goals and architecture:

- **Pluggable `dart:ui`** — Reintroduce rendering as a separate package rather than baked into the engine. Alternative renderers (Skia, Impeller, custom) could be swapped in.
- **Native UI toolkit bindings** — Write Dart FFI bindings for SwiftUI, Jetpack Compose, WinUI, GTK, etc., and drive native UIs from Dart.
- **Custom rendering backends** — Use SDL, GLFW, or similar for windowing and Vulkan/Metal/OpenGL for rendering, all driven from Dart via FFI.
- **Game development** — Use Dart as a game scripting language with SDL/GLFW for windowing and a custom rendering pipeline.
- **Server-side / embedded Dart** — Run Dart on mobile/desktop with full `dart:io` access, without needing a UI at all.
- **Lightweight Dart runtime** — A smaller, leaner engine binary for use cases that don't need Flutter's rendering stack.

## Getting Started

```bash
# Run the example app (engine artifacts download automatically)
./bin/flutter run -d macos

# Or use dev mode (runs tool from source)
./bin/flutter-dev run -d macos
```

The example at `examples/hello_world/` prints to the console and registers a hot-restart listener.

## Repository Structure

```
flutter_zero/
├── bin/                    # CLI entry points (flutter, flutter-dev, dart)
│   └── internal/           # Bootstrap logic, SDK downloads, version pins
├── engine/                 # Custom Flutter engine source
│   ├── scripts/            # gclient configs for engine checkout
│   └── src/flutter/        # Engine code (shell, runtime, lib/ui, fml)
├── examples/
│   └── hello_world/        # Minimal headless example
├── packages/
│   ├── flutter/            # Empty (lib/flutter.dart = "// Crickets")
│   ├── flutter_tools/      # Patched upstream flutter CLI tool
│   └── flutter_tools_patches/  # 5 patches applied to upstream
├── pubspec.yaml            # Dart workspace root
└── .github/workflows/      # CI: build + upload engine artifacts
```
