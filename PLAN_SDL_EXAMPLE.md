# Plan: SDL3 Window Example for Flutter Zero

## Goal

Create a working example app at `examples/sdl_window/` that uses the [`sdl3`](https://pub.dev/packages/sdl3) Dart package to create a native window, render graphics, and handle input — all driven from Flutter Zero's headless Dart runtime.

This demonstrates the core Flutter Zero use case: using Dart as a portable runtime while driving a native UI/rendering stack via FFI.

## What the Example Will Do

- Initialize SDL3 and create an 800×600 window
- Create a hardware-accelerated renderer
- Run an event loop that:
  - Handles quit (window close, Escape key)
  - Responds to keyboard input (change background color)
  - Responds to mouse input (track position, draw cursor indicator)
- Render animated colored shapes each frame
- Clean up SDL resources on exit

## Prerequisites

### SDL3 Native Library

The `sdl3` Dart package uses `dart:ffi` and requires the SDL3 native shared library:

| Platform | Install |
|---|---|
| **macOS** | `brew install sdl3` |
| **Linux** | Build from source or install `libsdl3-dev` if available |
| **Windows** | Download `SDL3.dll` from [github.com/sansuido/build-sdl3](https://github.com/sansuido/build-sdl3) |

The library must be discoverable at runtime (on the system library path, or loaded explicitly via `SdlDynamicLibraryService()`).

### Dart SDK

Workspace members in this repo pin a dev-channel Dart SDK (`^3.11.0-169.0.dev`), which is compatible with `sdl3`'s `>=3.11` requirement.

> **Heads up:** the *root* `pubspec.yaml` currently pins `sdk: ^3.9.0-0`. If you add `sdl3` to the root `dependencies:` block (see Step 4), you'll also need to raise the root SDK constraint to `^3.11.0-0` (or similar), otherwise `pub get` will fail at the root level.

## Implementation Steps

### Step 1: Scaffold the Example

Copy the existing `examples/hello_world/` as a starting point:

```bash
cp -r examples/hello_world examples/sdl_window
```

The hello_world example already has the correct Flutter Zero platform scaffolding (headless engine on every platform). The platform embedders start a bare `FlutterEngine` and call `main()` — which is exactly what we need.

### Step 2: Rename References

Update all platform build files from `hello_world` to `sdl_window`. The files in `examples/hello_world/` that actually contain `hello_world` references (verified):

| Platform | Files |
|---|---|
| **Root** | `pubspec.yaml` (`name:` field), `README.md` |
| **Android** | `android/app/build.gradle.kts` (`namespace`, `applicationId`), and rename the kotlin package directory `android/app/src/main/kotlin/com/example/hello_world/` → `.../sdl_window/` |
| **iOS** | `ios/Runner.xcodeproj/project.pbxproj`, `ios/Runner/Info.plist` (`CFBundleName`) |
| **macOS** | `macos/Runner.xcodeproj/project.pbxproj`, `macos/Runner/Configs/AppInfo.xcconfig` (`PRODUCT_NAME`) |
| **Linux** | `linux/CMakeLists.txt` (`project()` and `BINARY_NAME`, `APPLICATION_ID`) |
| **Windows** | `windows/CMakeLists.txt` (`project()` and `BINARY_NAME`) |
| **Web** | `web/index.html` (`<title>` and `apple-mobile-web-app-title`), `web/manifest.json` (`name`, `short_name`) |

> Files sometimes assumed to need renaming that actually do **not** contain `hello_world` references in this repo: `AndroidManifest.xml`, `windows/runner/main.cpp`, `linux/runner/my_application.cc`, `.metadata`. Skip them.

> **Note:** Alternatively, run `./bin/flutter create examples/sdl_window` which would scaffold everything correctly using the Flutter Zero templates, avoiding manual renames.

### Step 3: Update `pubspec.yaml`

Replace `examples/sdl_window/pubspec.yaml`:

```yaml
name: sdl_window
description: "Flutter Zero example: SDL3 window with rendering and input."
publish_to: 'none'
version: 0.1.0

resolution: workspace

environment:
  sdk: ^3.11.0-169.0.dev

dependencies:
  flutter:
    sdk: flutter
  sdl3: ^2.8.5

dev_dependencies:
  flutter_lints: ^6.0.0
```

### Step 4: Register as Workspace Member

Add `sdl_window` to the workspace list in the root `pubspec.yaml`:

```yaml
workspace:
  - examples/hello_world
  - examples/sdl_window    # add this
```

Also add `sdl3: ^2.8.5` to the root `dependencies:` block so workspace resolution can find it.

Then run `dart pub get` from the repo root.

### Step 5: Write `main.dart`

Create `examples/sdl_window/lib/main.dart` with the SDL3 application logic.

> **API caveat:** the draft below uses the `sdlx*` ergonomic wrappers (`SdlWindowEx.create`, `sdlxPollEvent`, `SdlxQuitEvent`/`SdlxKeyboardEvent`/`SdlxMouseMotionEvent`, `SdlxColor`, `SdlxFRect`, `SdlkScancode`, renderer extension methods). These symbols are illustrative — only `SdlDynamicLibraryService`, `sdlInit`, and the `SDL_INIT_VIDEO`/`SDL_HINT_RENDER_VSYNC`/`SDL_WINDOW_RESIZABLE` constants are confirmed from the package README. Before writing real code, verify each `sdlx*` symbol against the actual `sdl3` package source (or its API docs) and adjust. If the wrappers don't exist as written, fall back to the raw `sdlCreateWindow` / `sdlPollEvent` / `sdlSetRenderDrawColor` style FFI calls.

#### Structure of the code:

```
1. Initialize SDL (video subsystem)
2. Create window (800×600, centered, resizable)
3. Create renderer (hardware-accelerated, vsync)
4. Main loop:
   a. Poll events (quit, keyboard, mouse, window resize)
   b. Update state (color cycling, mouse tracking)
   c. Render frame:
      - Clear to current background color
      - Draw animated shapes
      - Draw mouse cursor indicator
      - Present
5. Cleanup (destroy renderer → destroy window → quit SDL)
```

#### Key APIs used:

| API | Purpose |
|---|---|
| `sdlInit(SDL_INIT_VIDEO)` | Initialize SDL video subsystem |
| `SdlWindowEx.create()` | Create a window (extension method) |
| `window.createRenderer()` | Create hardware renderer |
| `sdlxPollEvent()` | Poll events (returns typed `SdlxEvent` subclasses) |
| `renderer.setDrawColor(SdlxColor(r,g,b))` | Set draw color |
| `renderer.clear()` | Clear to draw color |
| `renderer.fillRect(SdlxFRect(...))` | Fill a rectangle |
| `renderer.present()` | Flip backbuffer |
| `renderer.destroy()` / `window.destroy()` | Cleanup |

#### Draft code:

```dart
import 'dart:math';
import 'package:sdl3/sdl3.dart';

void main() {
  // 1. Initialize SDL
  if (!sdlInit(SDL_INIT_VIDEO)) {
    print('Failed to initialize SDL: ${sdlGetError()}');
    return;
  }
  sdlSetHint(SDL_HINT_RENDER_VSYNC, '1');

  // 2. Create window
  final window = SdlWindowEx.create(
    title: 'Flutter Zero + SDL3',
    w: 800,
    h: 600,
    flags: SDL_WINDOW_RESIZABLE,
  );
  if (window == nullptr) {
    print('Failed to create window: ${sdlGetError()}');
    sdlQuit();
    return;
  }

  // 3. Create renderer
  final renderer = window.createRenderer();
  if (renderer == nullptr) {
    print('Failed to create renderer: ${sdlGetError()}');
    window.destroy();
    sdlQuit();
    return;
  }

  print('SDL3 window created! Press Escape or close the window to exit.');
  print('Press 1-4 to change background color. Move the mouse around.');

  // State
  var running = true;
  var mouseX = 0.0;
  var mouseY = 0.0;
  var bgIndex = 0;
  var frameCount = 0;

  final bgColors = [
    SdlxColor(30, 30, 46),    // dark catppuccin
    SdlxColor(24, 24, 37),    // darker
    SdlxColor(17, 17, 27),    // near-black
    SdlxColor(49, 50, 68),    // lighter
  ];

  // 4. Main loop
  while (running) {
    // Poll events
    SdlxEvent? event;
    while ((event = sdlxPollEvent()) != null) {
      if (event is SdlxQuitEvent) {
        running = false;
      } else if (event is SdlxKeyboardEvent && event.down) {
        if (event.scancode == SdlkScancode.escape) {
          running = false;
        } else if (event.scancode == SdlkScancode.num1) {
          bgIndex = 0;
        } else if (event.scancode == SdlkScancode.num2) {
          bgIndex = 1;
        } else if (event.scancode == SdlkScancode.num3) {
          bgIndex = 2;
        } else if (event.scancode == SdlkScancode.num4) {
          bgIndex = 3;
        }
      } else if (event is SdlxMouseMotionEvent) {
        mouseX = event.x;
        mouseY = event.y;
      }
    }

    frameCount++;

    // Get window size for responsive rendering
    var w = 0, h = 0;
    sdlGetWindowSize(window, [w], [h]); // may need pointer approach
    final cx = 400.0;
    final cy = 300.0;

    // Render
    renderer
      ..setDrawColor(bgColors[bgIndex])
      ..clear();

    // Animated spinning rectangles
    final time = frameCount * 0.02;
    for (var i = 0; i < 6; i++) {
      final angle = time + i * (pi * 2 / 6);
      final radius = 120.0;
      final rx = cx + cos(angle) * radius;
      final ry = cy + sin(angle) * radius;
      final size = 30.0 + sin(time * 2 + i) * 10;

      // Color cycling
      final r = (127 + sin(angle + time) * 127).toInt();
      final g = (127 + sin(angle + time + 2) * 127).toInt();
      final b = (127 + sin(angle + time + 4) * 127).toInt();

      renderer
        ..setDrawColor(SdlxColor(r, g, b))
        ..fillRect(SdlxFRect(
          x: rx - size / 2,
          y: ry - size / 2,
          w: size,
          h: size,
        ));
    }

    // Center circle approximation (small rotating squares)
    for (var i = 0; i < 12; i++) {
      final angle = -time * 1.5 + i * (pi * 2 / 12);
      final radius = 40.0;
      final rx = cx + cos(angle) * radius;
      final ry = cy + sin(angle) * radius;

      renderer
        ..setDrawColor(SdlxColor(205, 214, 244))  // light
        ..fillRect(SdlxFRect(x: rx - 3, y: ry - 3, w: 6, h: 6));
    }

    // Mouse cursor indicator
    renderer
      ..setDrawColor(SdlxColor(243, 139, 168))  // pink
      ..fillRect(SdlxFRect(x: mouseX - 5, y: mouseY - 5, w: 10, h: 10))
      ..rect(SdlxFRect(x: mouseX - 12, y: mouseY - 12, w: 24, h: 24));

    renderer.present();
  }

  // 5. Cleanup
  renderer.destroy();
  window.destroy();
  sdlQuit();

  print('SDL3 cleaned up. Goodbye!');
}
```

> **Caveat:** The `sdlGetWindowSize` call above is pseudocode for illustration. The actual sdl3 Dart API may use a different calling convention (e.g., returning a `SdlxSize` or requiring `calloc<Int>` pointers). Check the [sdl3 package API docs](https://pub.dev/packages/sdl3) for the exact signature and adjust accordingly.

### Step 6: Verify It Works

```bash
# From the repo root
dart pub get

# Then run from inside the example directory (the flutter CLI
# expects to be invoked from a Flutter project root):
cd examples/sdl_window

# macOS (requires SDL3 installed via brew)
../../bin/flutter run -d macos

# Linux
../../bin/flutter run -d linux

# Windows
../../bin/flutter run -d windows
```

## Platform Notes

### macOS
- Install SDL3: `brew install sdl3`
- The library should be auto-discovered at `/opt/homebrew/lib/libSDL3.dylib` or `/usr/local/lib/libSDL3.dylib`
- If not found, load explicitly before `sdlInit()`:
  ```dart
  SdlDynamicLibraryService().add('SDL3', DynamicLibrary.open('/opt/homebrew/lib/libSDL3.dylib'));
  ```

### Linux
- Install SDL3: build from [libsdl.org](https://www.libsdl.org/) or use `sudo apt install libsdl3-dev` if available for your distro
- Ensure `libSDL3.so.0` is on the library path

### Windows
- Download `SDL3.dll` from [github.com/sansuido/build-sdl3](https://github.com/sansuido/build-sdl3)
- Place it next to the executable or on the PATH

### Mobile (Android/iOS) and Web
- SDL3 on mobile takes over the app lifecycle and requires a different setup (the SDL3 Android/iOS main loop). This example targets desktop only for now.
- SDL3 on Web uses Emscripten and requires a different build pipeline. Not covered here.

## Known Challenges

1. **Event loop blocking** — The SDL event loop is a blocking `while` loop. Since Flutter Zero runs Dart on the platform thread, this works fine on desktop but means Dart async/microtasks won't be processed during the loop. For simple examples this is acceptable; for more complex apps you'd want to integrate SDL event polling with Dart's event loop.

2. **Dynamic library discovery** — The `sdl3` package needs to find the native SDL3 library at runtime. On macOS with Homebrew this typically just works; on other platforms you may need explicit loading.

3. **Window size queries** — The exact Dart API for `sdlGetWindowSize` needs verification against the package source. The draft code above uses illustrative syntax.

4. **Workspace dependency resolution** — Adding `sdl3` to the root workspace pubspec may trigger dependency resolution that updates the lock file. This is expected but should be committed alongside the example.

## Future Enhancements

- **OpenGL/Vulkan rendering** — Use SDL3 to create a GL/Vulkan context and render 3D graphics from Dart via FFI
- **Text rendering** — Use `sdl3_ttf` (bundled with the `sdl3` package) to render text in the SDL window
- **Audio** — Use `sdl3_mixer` for audio playback
- **Image loading** — Use `sdl3_image` to load and display images
- **Game controller support** — Use the `sdl_gamepad` package (built on `sdl3`)
