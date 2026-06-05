# sdl_window

A Flutter Zero example that uses the [`sdl3`](https://pub.dev/packages/sdl3)
Dart package to open a native SDL3 window, run an event loop, and render an
animated scene — all driven from the headless Dart runtime via `dart:ffi`.

The Flutter engine is not on the hot path: `lib/main.dart` is pure Dart +
FFI. The platform scaffolding (`android/`, `ios/`, `macos/`, `linux/`,
`windows/`, `web/`) is only used when packaging as a Flutter app.

## Requirements

**SDL3 (≥ 3.2) must be installed on the host.** The `sdl3` Dart package
loads `libSDL3` via `dart:ffi` at runtime — there is no fallback. The
example will fail to create a window with `Failed to create window: ...`
if the library can't be found.

## Running

### macOS

```sh
brew install sdl3
cd examples/sdl_window
../../bin/dart run lib/main.dart
```

Homebrew installs `libSDL3.dylib` to `/opt/homebrew/lib` (Apple Silicon)
or `/usr/local/lib` (Intel). The `sdl3` package finds it automatically.
If it doesn't, load it explicitly before `sdlInit`:

```dart
SdlDynamicLibraryService().set('SDL3', '/opt/homebrew/lib/libSDL3.dylib');
```

### Linux

Ubuntu 24.04 ships SDL2 only. Build SDL3 from source:

```sh
curl -L https://github.com/libsdl-org/SDL/releases/download/release-3.2.10/SDL3-3.2.10.tar.gz | tar xz
cd SDL3-3.2.10 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build && sudo cmake --install build && sudo ldconfig
```

Then:

```sh
cd examples/sdl_window
../../bin/dart run lib/main.dart
```

Headless / CI works under Xvfb:

```sh
xvfb-run -s "-screen 0 800x600x24" ../../bin/dart run lib/main.dart
```

### Windows

Download `SDL3.dll` from a build of [libsdl-org/SDL](https://github.com/libsdl-org/SDL/releases)
and place it next to the Dart executable or somewhere on `%PATH%`. Then:

```sh
cd examples\sdl_window
..\..\bin\dart run lib\main.dart
```

## Controls

- **Escape** or close the window — exit
- **1–4** — cycle background color (Catppuccin palette)
- **Mouse motion** — moves the pink cursor indicator

## What you'll see

An 800×600 window titled "Flutter Zero + SDL3" with:

- An outer ring of 6 color-cycling rectangles orbiting the centre
- An inner ring of 12 small dots counter-rotating
- A pink target box that tracks the mouse pointer
