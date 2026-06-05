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

## First-time setup: patch the Flutter SDK version stamp

The Flutter Zero repo isn't tagged, so on a fresh clone `git describe`
returns nothing and the bundled SDK reports its framework version as
`0.0.0-unknown`. `pub` rejects that when resolving any workspace package
with a Flutter SDK constraint (e.g. `scoped_model`), producing:

```
The current Flutter SDK version is 0.0.0-unknown.
Because _flutter_packages depends on scoped_model 2.0.0 which requires
Flutter SDK version >=1.24.0-1.0.pre, version solving failed.
```

Trigger the bootstrap once so `bin/cache/flutter.version.json` exists,
then patch the version string to something `pub` will accept:

```sh
# trigger SDK bootstrap (downloads Dart + engine artifacts the first time)
../../bin/flutter --version >/dev/null 2>&1
```

Then, depending on your shell:

```sh
# macOS
sed -i '' 's/0\.0\.0-unknown/3.99.0/g' ../../bin/cache/flutter.version.json

# Linux
sed -i 's/0\.0\.0-unknown/3.99.0/g' ../../bin/cache/flutter.version.json
```

```powershell
# Windows (PowerShell)
(Get-Content ..\..\bin\cache\flutter.version.json) `
  -replace '0\.0\.0-unknown', '3.99.0' `
  | Set-Content ..\..\bin\cache\flutter.version.json
```

`bin/cache/` is gitignored, so the edit stays purely local — it won't
show up in `git status`. Redo this if anything invalidates the cache
(e.g. after `flutter upgrade` against this repo).

## Running

### macOS

```sh
brew install sdl3
cd examples/sdl_window
../../bin/flutter pub get        # resolve workspace deps (uses the bundled SDK)
../../bin/dart lib/main.dart
```

Homebrew installs `libSDL3.dylib` to `/opt/homebrew/lib` (Apple Silicon)
or `/usr/local/lib` (Intel). `dlopen`'s default search path on macOS
includes the Intel location but **not** `/opt/homebrew/lib` — and inside
a Flutter `.app` bundle `DYLD_LIBRARY_PATH` is usually stripped by SIP,
so env-var workarounds don't help. `main()` calls a small
`_registerSdlLibrary()` helper that probes both Homebrew paths and pins
the absolute path on `SdlDynamicLibraryService` before `sdlInit`.

If you install SDL3 somewhere unusual, extend that helper or pass your
path directly:

```dart
SdlDynamicLibraryService().set('sdl', '/your/path/libSDL3.dylib');
```

(Note the key is `'sdl'` lowercase — that's the entry the `sdl3` package
uses internally, not the file basename `SDL3`.)

### Linux

Ubuntu 24.04 ships SDL2 only. Build SDL3 from source:

```sh
curl -L https://github.com/libsdl-org/SDL/releases/download/release-3.2.10/SDL3-3.2.10.tar.gz | tar xz
cd SDL3-3.2.10 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build && sudo cmake --install build && sudo ldconfig
```

Then:

```sh
cd examples/sdl_window
../../bin/flutter pub get
../../bin/dart lib/main.dart
```

Headless / CI works under Xvfb:

```sh
xvfb-run -s "-screen 0 800x600x24" ../../bin/dart lib/main.dart
```

### Windows

Download `SDL3.dll` from a build of [libsdl-org/SDL](https://github.com/libsdl-org/SDL/releases)
and place it next to the Dart executable or somewhere on `%PATH%`. Then:

```sh
cd examples\sdl_window
..\..\bin\flutter pub get
..\..\bin\dart lib\main.dart
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
