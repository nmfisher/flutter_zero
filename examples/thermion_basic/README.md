# thermion_basic

Vanilla Thermion bootstrap on top of the Flutter Zero Dart runtime — no UI
layer, no animation. Renders a magenta background to a BMP file.

This is the smallest possible "Thermion runs inside Flutter Zero" demo,
modeled after Thermion's own `examples/dart/cli_headless`. It confirms:

1. `FFIFilamentApp.create()` succeeds under the Flutter Zero bundled Dart
   SDK
2. The native-assets hook for `thermion_dart` builds and links
3. A headless swapchain + view round-trips one frame's pixels back to Dart

It does **not** integrate with the workspace pubspec — the workspace's
pinned `archive` / `code_assets` / `hooks` versions conflict with
`thermion_dart`'s requirements, so this example resolves its own deps via
its own `pubspec.yaml`. Future Thermion work lives alongside, not inside,
the existing `_flutter_packages` workspace.

## Requirements

- The Flutter Zero bundled Dart SDK (or any Dart `>= 3.11.0`).
  Native-assets is on by default — no experiment flag needed on Dart
  3.5+.
- A C/C++ toolchain (Thermion's build hook compiles FFI glue locally
  and links against a precompiled Filament archive it downloads from
  Cloudflare R2).

## Platform / build-mode matrix

Thermion ships precompiled Filament binaries; not every (platform, mode)
combo is published. As of `thermion_dart 0.3.4+1` / Filament v1.58.0:

| Platform        | Debug | Release |
| --------------- | :---: | :-----: |
| macOS (arm64)   | ✓     | ✓       |
| Linux (x86_64)  | ✗     | ✓       |
| Windows (x86_64)| ✗     | ✗       |

This example pins `mode: release` in `pubspec.yaml` so it works on both
macOS and Linux. Flip to `mode: debug` in `hooks.user_defines.thermion_dart`
if you want debug symbols and you're on a supported platform.

## Running

```sh
cd examples/thermion_basic
../../bin/dart pub get
../../bin/dart run lib/main.dart
```

This example is **not** a workspace member (Thermion's `archive` /
`code_assets` / `hooks` requirements diverge from the Flutter Zero
workspace pins), so use plain `dart pub get` and run from the example
directory.

Output lands in `examples/thermion_basic/output/render.bmp` — a 500×500
magenta bitmap.

## Verified on this branch

Bootstrap output on Linux x86_64 (Ubuntu 24.04 inside a container,
software Vulkan):

```
FEngine (64 bits) created at 0x... (threading is enabled)
FEngine resolved backend: Vulkan
Vulkan device driver: llvmpipe Mesa 25.2.8-0ubuntu0.24.04.1 (LLVM 20.1.2)
Selected physical device 'llvmpipe (LLVM 20.1.2, 128 bits)' ...
Backend feature level: 3
FEngine feature level: 1
No material provider specified, using default ubershader provider
FilamentApp ready.
Viewer ready.
Capturing one frame...
Wrote output/render.bmp (750054 bytes).
Destroying RenderThread (0 tasks remaining)
```

Filament's render thread is created (confirms our audit's "Thermion has
its own native render thread" finding) and tears down cleanly via
`Isolate.kill`.

## Next steps

- Continuous rendering via `viewer.setRendering(true)`
- A native window swapchain (instead of headless) — needs platform
  native-handle plumbing
- Register a `requestFrameHook` to validate the integration point for
  our future UI scheduler
- Load a glTF asset so the scene has actual 3D content
