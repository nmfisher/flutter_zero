# Boundaries — engine, `dart:ui`, and the Flutter framework

A map of the three layers and where the seams between them fall. Companion to
`SUMMARY.md` (which details what flutter_zero removed from the engine) — this
doc adds the two halves nobody has written down yet: the *original* anatomy of
`dart:ui` (so a reimplementation knows the full target surface, not just the
delta), and the anatomy of the Flutter framework (so we know which parts of it
could run on a future `dart:ui` package and which can never be satisfied).

```
┌──────────────────────────────────────────────────────────────┐
│  YOUR APP CODE                                               │
├──────────────────────────────────────────────────────────────┤
│  FLUTTER FRAMEWORK          packages/flutter  (NOT HERE —    │
│  widgets → rendering → …     stub in this repo)               │
├──────────────────────────────────────────────────────────────┤
│  dart:ui                     engine/src/flutter/lib/ui        │
│  the API boundary            (gutted to message-passing hub)  │
├──────────────────────────────────────────────────────────────┤
│  FLUTTER ZERO ENGINE         engine/src/flutter/{runtime,     │
│  Dart VM host, channels      shell,fml} + prebuilt binaries   │
├──────────────────────────────────────────────────────────────┤
│  PLATFORM EMBEDDER           macos/Runner, android/… (per app)│
│  owns the process + windows  rewritten headless (see SUMMARY) │
└──────────────────────────────────────────────────────────────┘
```

The direction of knowledge: **each layer only knows the layer below it.**
The framework imports `dart:ui` and nothing else native; `dart:ui` talks to
the engine via natives/FFI; the engine talks to the embedder through the C
embedder API. Anything crossing a seam the other way is a callback
(`onBeginFrame`, platform message handlers, vsync signals).

---

## 1. The engine — what flutter_zero is and isn't

(Keeps/removes detail in `SUMMARY.md`; this is the orientation view.)

**The engine is a Dart VM host plus an embedder contract.** In stock Flutter
it *also* carries the entire rendering stack; flutter_zero deleted that half.
What remains, with disk locations in this checkout (`engine/src/flutter/`):

| Subsystem | Location | Role |
|---|---|---|
| Dart VM glue | `runtime/` (`dart_vm.cc`, `dart_isolate.cc`) | Start the VM, create/run/restart the root isolate, load kernel, snapshots. Hot reload lives here (VM service RPCs → `Dart_IsolateReload`) |
| Platform channels | `lib/ui/window/platform_message*.cc`, `shell/` | Route `SendPort`-style messages between Dart and the embedder |
| Shell | `shell/common/` (`shell.cc`, `platform_view.cc`, `switches.cc`) | Engine lifecycle, embedder C API surface, task runners — minus raster/io threads |
| FML | `fml/` | Foundation: message loops, threads, file I/O, mappings |
| Service isolate | `runtime/dart_service_isolate.cc` | Boots `dart:vmservice_io` — VM service protocol (proves out `flutter run`, hot reload, DevTools) |
| `dart:ui` Dart side | `lib/ui/` | See §2 |
| Assets | `assets/` | `flutter_assets` loading via `ImmutableBuffer` |

**Removed:** rasterizer, compositor, animator/vsync waiter, IO thread,
Impeller and all GPU backends, Skia, `flutter_gpu`, text/layout stack,
image codecs, and the scene/layer machinery. The threading model collapsed to
one effective thread (platform+UI merged; see `SUMMARY.md`).

**In this repo the engine source is reference-only for most work** — apps
consume prebuilt binaries from `bin/cache/artifacts/engine/` (built from
`engine.flutter0.dev`, see `engine/scripts/*.gclient`).

## 2. `dart:ui` — the boundary that was hollowed out

`dart:ui` is the *only* API the Flutter framework can see. In stock Flutter
it lives in the engine (`engine/src/flutter/lib/ui/`), is shipped to pub as
the **`sky_engine`** SDK package, and every framework import of `dart:ui`
resolves there. It is half Dart classes, half thin wrappers over engine C++
(each `Foo` Dart class pairs with a `foo.cc` doing the real work).

### 2.1 Original anatomy (the reimplementation target surface)

| Subsystem | Stock classes | Native counterpart does | Status in flutter_zero |
|---|---|---|---|
| **Geometry & math** | `Offset`, `Size`, `Rect`, `Radius`, `RSTransform` | none (pure Dart) | ✅ kept (`geometry.dart`, `math.dart`) |
| **Platform plumbing** | `PlatformDispatcher`, `Window`, `PlatformMessage*`, channel buffers | message routing, locales, metrics, lifecycle callbacks | ✅ kept — this is now dart:ui's whole job |
| **Hooks & lifecycle** | `hooks.dart` (`scheduleFrame`, engine bootstrap, error hooks) | animator handshake | ⚠️ shell only — `scheduleFrame`/frame callbacks gone |
| **Isolate services** | `IsolateNameServer`, `PluginUtilities`, `CallbackHandle` | native registry | ✅ kept |
| **Painting** | `Canvas`, `Paint`, `Picture`, `PictureRecorder`, `Path`, `Shader` (+ gradients), `Color`, `ColorFilter`, `ImageFilter`, `MaskFilter`, `Vertices`, `Image`, `Codec`, `ImageDescriptor`, `FrameInfo` | display-list recording; decode in Skia/Impeller | ❌ deleted — `painting.dart` is one `_futurize` helper; `painting/` dir holds only `immutable_buffer.cc` |
| **Scene & compositing** | `Scene`, `SceneBuilder`, `EngineLayer`, all layer semantics | compositor, raster thread | ❌ deleted |
| **Text** | `Paragraph`, `ParagraphBuilder`, `TextStyle`, `FontWeight`, `ParagraphStyle`, `FontLoader`, glyph protocols | HarfBuzz + FreeType + ICU shaping, font collection | ❌ deleted |
| **Semantics** | `SemanticsUpdate`, `SemanticsUpdateBuilder` | a11y tree → platform bridges | ❌ deleted |
| **Buffers** | `ImmutableBuffer` | asset bytes without a copy | ✅ kept (sole `painting/` survivor) |

On-disk proof: `engine/src/flutter/lib/ui/ui.dart` still `part`s only
`annotations, channel_buffers, geometry, hooks, isolate_name_server, lerp,
math, natives, painting (≈empty), platform_dispatcher, plugins`.

**Reading the table as a reimplementation spec:** pure-Dart rows are free;
the `PlatformMessage` row already works; everything from "Painting" down is
the project — and matches the survey in `RENDERING.md` and the committed
direction in `UI_RENDERER_PLAN.md`.

### 2.2 The boundary rule

An app (or framework) may import `dart:ui` and is *supposed* to touch
nothing beneath it. In practice the stock framework also relies on
undocumented natives — which is why §3 matters: a `dart:ui` package
replacement must satisfy the *framework's actual call graph*, not just the
published API.

## 3. The Flutter framework — `packages/flutter` (absent here; a stub)

Not in this checkout (`packages/flutter/lib/flutter.dart` is `// Crickets`).
In stock Flutter it is a layered pub package, ~strictly one-directional:

```
widgets          ← what apps import (StatelessWidget, BuildContext…)
  ↑
rendering        ← RenderObject tree, layout/paint/compositing
  ↑               (THE layer that consumes dart:ui painting + scenes)
gestures, services, painting, animation, semantics
  ↑
scheduler        ← frame phases, vsync (SchedulerBinding)
  ↑
foundation       ← ChangeNotifier, bindings machinery, diagnostics
```

Per-layer dependence on `dart:ui` — this is the actual compatibility ladder
for ever running the framework on flutter_zero + a future dart:ui package:

| Framework layer | Consumes from `dart:ui` | Runs without the graphics half? |
|---|---|---|
| `foundation` | almost nothing (errors, platform affinity) | ✅ trivially |
| `scheduler` | `scheduleFrame`/`onBeginFrame`/`onDrawFrame`, `FrameTiming` | ⚠️ needs *a* frame clock — exactly what `FrameScheduler` in `examples/sdl_ui` prototypes |
| `services` | platform messages, `ImmutableBuffer` | ✅ mostly (channels already work) |
| `animation` | `lerp` helpers (pure Dart) | ✅ (driven by scheduler ticks) |
| `gestures` | `PointerDataPacket`/pointer router | ⚠️ needs a pointer-event source (SDL events could feed it) |
| `painting` | `Image`, `Codec`, `Shader`, `ColorFilter`, text (`TextPainter` → `Paragraph`) | ❌ the heavy consumer |
| `semantics` | `SemanticsUpdateBuilder` | ❌ (deferred per `UI_RENDERER_PLAN.md`) |
| `rendering` | `Canvas`, `PictureRecorder`, `SceneBuilder`, `EngineLayer`, `Path` — every frame | ❌ the make-or-break client |
| `widgets` | almost nothing directly — pure composition over the above | ✅ iff everything below it works |

**Implication:** the framework was designed so that only the bottom three
rows touch native rendering. If a `dart:ui` package implements painting +
scenes + text faithfully, `packages/flutter` could in principle be dropped in
unmodified. The whole question is fidelity of that one seam — see
`RENDERING.md` (backend options and hidden costs) and `UI_RENDERER_PLAN.md`
(committed scope, and its explicit "good game UI, not MD3" ceiling).

## 4. The seams, mechanically

| Seam | Mechanism | Where it's visible today |
|---|---|---|
| App ↔ framework | normal Dart imports | any Flutter app |
| Framework ↔ `dart:ui` | Dart import of the `sky_engine` SDK package | framework source; swap point for a reimplementation |
| `dart:ui` ↔ engine | `@Native`/natives + FFI (`natives.dart`, `dart_ui.cc`) | `engine/src/flutter/lib/ui/` |
| Engine ↔ embedder | C embedder API (`FlutterEngineRun` etc.), callbacks, platform messages | `examples/*/macos/Runner/AppDelegate.swift` |
| Anything ↔ tooling | VM service protocol | hot reload, DevTools (both verified working on flutter_zero) |

## 5. Doc map

- `SUMMARY.md` — engine keeps/removes, embedders, tooling patches (layer 1 detail)
- `RENDERING.md` — 2D backend survey for the painting half of layer 2
- `UI_RENDERER_PLAN.md` — committed direction: Filament-native UI shaders
- `UI_BRAINSTORMING.md` — widget-tree-above-Canvas exploration (a parallel,
  framework-independent path instead of reusing `packages/flutter`)
- This doc — the boundary map between all of the above
