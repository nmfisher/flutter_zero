# Rendering — what to actually draw with on top of SDL3

A companion to `UI_BRAINSTORMING.md`. That doc treats SDL3's renderer as
the assumed drawing backend; this one questions whether that's the right
call and surveys the alternatives. Short version: SDL3's built-in
renderer is fine for geometric demos and not enough for a modern UI —
once we want rounded corners, anti-aliasing, gradients, or drop shadows,
something else has to do the drawing.

## TL;DR

- **SDL3's renderer is too primitive for modern UI.** No rounded rects,
  no anti-aliasing, no paths, no gradients, no non-rect clipping, no
  shadows.
- The current `sdl_ui` example uses it because it's convenient and
  validates the rest of the stack (event loop, FrameScheduler, Canvas
  seam). The Canvas seam is where this decision actually lands, and
  everything above it (widget tree, layout, scheduler) is renderer-agnostic.
- Realistic upgrade paths:
  - **[NanoVG](https://github.com/memononen/nanovg)** — ~5k LOC C, GL-based,
    UI-focused. ~1 week of integration. Mature, decent quality.
  - **[Blend2D](https://blend2d.com/)** — pure-CPU, JIT-compiled, no GPU
    deps at all. ~1 week. Tiny binary, high pixel quality.
  - **[Vello](https://github.com/linebender/vello)** — pure-GPU compute-shader
    2D renderer, Rust, targets WebGPU. ~3 weeks of integration. Modern,
    high quality, brings a Rust toolchain and `wgpu-native` along. The
    only modern stack with bundled text shaping (via Parley).
  - **Skia Graphite** — Google's newer Skia backend, modern GPU APIs.
    ~3–6 weeks of integration. Production-grade output, ~100 MB build,
    no first-class C API.
  - **Skia Ganesh** — legacy GL-era backend, same library, well-trodden
    C++ API. Similar shape and cost to Graphite.
  - **Platform-native** (Direct2D / CoreGraphics / Cairo) — zero binary
    bloat, native quality, three backends to write and keep in sync.
- **Three hidden costs the renderer choice forces:**
  - **Text shaping ≠ rendering.** Only Skia (HarfBuzz+FreeType+ICU
    bundled) and Vello (Parley bundled) come with a shaping/line-break
    stack. NanoVG, Blend2D, FemtoVG, Rive all expect us to add
    HarfBuzz + a line breaker — weeks of work, closes the binary-size
    gap.
  - **Power consumption.** Spinning the GPU every frame (NanoVG,
    Vello-on-old-GPUs) drains laptops; Skia and platform-native are
    well power-tuned; Blend2D costs only when busy.
  - **Color management / HDR.** Modern Macs and recent laptops are P3
    or HDR. Skia / Vello / platform-native handle this; NanoVG /
    Blend2D assume sRGB and clip on fancy displays.
- The honest cross-cutting concern: **Skia (either backend) is what
  Flutter uses**, and adding it back via FFI essentially reproduces
  Flutter's architecture. Flutter Zero exists because that coupling was
  felt to be wrong, so picking Skia is also picking to undo the project's
  pitch.
- **Bake the seam right today:** the `Canvas` should be a *recording*
  canvas that produces a Display List of draw commands, not a thin FFI
  passthrough. That single architectural decision is what lets us swap
  backends later and what eventually lets layout and rasterization run
  on different threads.

## Why this matters now

Path 3 in `UI_BRAINSTORMING.md` says "real UI (think Sublime)" — but
Sublime's UI involves rounded buttons, anti-aliased text, drop shadows,
gradients, and translucent panels. None of those are reachable with
SDL3's renderer. The brainstorm under-specified this: it treated drawing
quality as a free variable when it's actually the single biggest visual
gate on what we ship.

The current `examples/sdl_ui` demo is geometric (orbiting solid-color
squares), which hides the issue. The moment we draw a button it will
become obvious.

## What SDL3's renderer actually gives you

The complete primitive set, in roughly the order you'd reach for them:

| API | What it does |
|---|---|
| `SDL_RenderFillRect` / `SDL_RenderRect` | Axis-aligned rectangles only |
| `SDL_RenderPoint`, `SDL_RenderLine` | Single-pixel-wide, no AA |
| `SDL_RenderCopy` / `SDL_RenderTexture` | Blit textures with scale + rotation |
| `SDL_RenderGeometry` | Submit your own triangle meshes |
| `SDL_SetRenderClipRect` | Rectangular clipping only |
| Blend modes | Alpha blend, additive, mod, mul — a handful |

That's the whole API. What it does **not** give you:

- **No rounded-rect primitive.** Every modern UI uses rounded corners
  everywhere. You'd have to tesselate them via `RenderGeometry`,
  pre-render to a texture, or accept hard corners.
- **No anti-aliasing for primitives.** Lines and shape edges are
  pixel-aligned. Diagonals and curves look jaggy.
- **No paths.** No `MoveTo`/`LineTo`/`CurveTo`. No filled or stroked
  paths. No Bezier curves.
- **No gradients.** Solid color or texture-mapped only.
- **No non-rectangular clipping or masking.**
- **No drop shadows, blurs, or filters.**
- **No native text rendering.** SDL_ttf rasterizes glyphs to surfaces;
  layout (kerning, line breaking, sub-pixel positioning) is your problem.
- **No transform stack.** Can't push a rotation/scale matrix and have
  subsequent draws inherit it.

For "geometric demo" content — what `sdl_ui` renders today — this is
fine. For "card with rounded corners, gradient fill, soft shadow,
anti-aliased text" — the table stakes of any modern UI — it isn't close.

## Hidden costs beyond drawing

The renderer choice isn't just about "what shapes can I draw." Three
costs people consistently underestimate when picking a 2D renderer:

### 1. Text shaping ≠ text rendering

These are two different problems and they're often conflated:

- **Rasterization** turns a glyph outline into pixels. SDL_ttf, FreeType,
  stb_truetype, NanoVG's font system, and the text path of every modern
  renderer all do this. It's the easy part.
- **Shaping** turns a Unicode string into a sequence of positioned
  glyphs: which glyph for `"fi"` (a ligature?), how Arabic combining
  marks attach, how Devanagari clusters work, RTL/LTR boundaries,
  kerning between specific glyph pairs, contextual substitutions.
- **Line breaking** decides where lines wrap, given Unicode's actual
  rules (`UAX #14`), language-specific exceptions, hyphenation.

Skia is ~100 MB partly because it bundles **HarfBuzz** (shaping),
**FreeType** (outline parsing), and **ICU** (Unicode break iteration,
collation, locale rules). If we pick a leaner renderer, we still need
those — typically:

- **HarfBuzz** (~1 MB) for shaping
- **FreeType** (~1 MB) or stb_truetype (smaller, weaker)
- **ICU** (~30 MB, painful) or a simpler line breaker for ASCII-only
  scripts

Adding HarfBuzz + FreeType + a line breaker to a NanoVG or Vello stack
is a few extra weeks of work and closes the binary-size gap modestly.
The "Skia is huge" comparison gets less unfair once you count what
you'd have to add alongside the alternatives.

Honest matrix:

| Renderer | Rasterization | Shaping | Line breaking |
|---|---|---|---|
| SDL3 alone | none | none | none |
| SDL3 + SDL_ttf | yes (FreeType under the hood) | none | none |
| NanoVG | yes (stb_truetype) | none | none |
| Vello | yes (via parley + swash) | yes (via parley + swash) | yes (via parley) |
| Skia | yes (FreeType) | yes (HarfBuzz) | yes (ICU) |
| Blend2D | yes (FreeType-style internal) | none — bring your own | none |

Vello bundling Parley is a real differentiator vs Skia — it gets you a
shaping-and-layout stack without a separate HarfBuzz integration.

### 2. Power consumption

The renderer ladder ignores battery, which matters on laptops and
phones. Rough characterization:

- **SDL3 / NanoVG (immediate-mode GL):** spins the GPU on every frame
  even when nothing changes. Bad on battery unless you implement a
  "is anything dirty?" gate and skip frames.
- **Vello (compute-shader-heavy):** compute is power-hungry; on older
  integrated GPUs it can be noticeably worse than tessellation-based
  renderers. On modern GPUs with strong compute it's fine.
- **Skia (Ganesh/Graphite):** very tuned. Aggressive caching, command
  batching, hits the GPU only when content changes. Best power profile
  of the GPU options.
- **Blend2D (CPU):** zero GPU usage; CPU usage scales with workload.
  Idle UIs cost roughly nothing. Heavy animation pegs cores.
- **Platform-native (CoreGraphics / Direct2D / Cairo):** generally well
  power-tuned by the OS vendor. Wins on idle, loses on heavy custom
  effects.

If "lighter than Flutter" is the pitch, battery is a metric to compete
on — and it points at Blend2D + dirty-region tracking, not GPU
compute.

### 3. Color management and HDR

Modern displays — every Mac laptop, every recent iPad, increasing
numbers of Windows laptops — are wide-gamut (P3). Some are HDR. SDL3
handles the *window surface* colorspace, but the renderer has to output
the correct pixel format and respect colorspace tags on inputs.

- **Skia:** deep color management, sRGB/P3/HDR-aware, handles ICC
  profiles.
- **Vello:** linear-space rendering, gamut-correct, modern from the
  start.
- **NanoVG, Blend2D:** assume sRGB. Will clip / desaturate on P3
  displays without manual workarounds.
- **Platform-native:** correct by construction on the platform.

For desktop apps targeting Macs and modern laptops, "wrong colors on
fancy displays" is a real user-visible defect that lower-tier renderers
silently produce.

## The renderer ladder

Roughly ordered by drawing quality. Note that "tier" isn't strictly
linear — Blend2D and platform-native are on different axes (CPU-only,
and per-platform respectively) than the GPU-based GL/wgpu options.

| Tier | Stack | Integration effort | Native deps | Output quality | Text shaping included? | Trade-off |
|---|---|---|---|---|---|---|
| 0 | SDL3 alone | (current) | sdl3 | 90s-era | no | No rounded corners, no AA, no shadows |
| 1 | SDL3 + SDL_ttf + SDL_image | days | + 2 SDL deps | Still primitive, but text and images | no | Rasterizes glyphs only; shaping/line-break on us |
| 2 | SDL3 + NanoVG (via GL context) | ~1 week | NanoVG, OpenGL | Decent — rounded rects, AA, paths, gradients | no | OpenGL-only; sRGB-only; needs HarfBuzz+ICU for real text |
| 2 | SDL3 + Blend2D (CPU) | ~1 week | Blend2D | High AA / gradient quality, CPU-bound | no | Zero GPU bloat; needs HarfBuzz+ICU; not great on 4K + animation |
| 3 | SDL3 + Skia Ganesh | ~3–4 weeks | Skia (~100 MB lib) | Production-grade, GL-era | yes | Old Skia backend; no compute; bundles HarfBuzz/FreeType/ICU |
| 3 | SDL3 + FemtoVG via wgpu | ~2 weeks | FemtoVG (Rust), wgpu-native | NanoVG-quality on modern GPUs | no | Lighter than Vello; same need for HarfBuzz+ICU |
| 4 | SDL3 + Vello via wgpu-native | ~3 weeks | wgpu-native, Vello, Rust toolchain | High quality, modern, P3-aware | yes (via Parley) | Rust deps; two GPU stacks in one process |
| 4 | SDL3 + Rive Renderer | ~2–3 weeks | Rive renderer, GL/Metal | High quality, analytic (no tessellation) | no | Unproven outside Rive's ecosystem; needs HarfBuzz+ICU |
| 5 | SDL3 + Skia Graphite | ~3–6 weeks | Skia (~100 MB lib), Dawn or platform GPU | Production-grade, modern, full color | yes | Same cost as Ganesh + modern API plumbing |
| ↗ | Platform-native (Direct2D / CoreGraphics / Cairo) | weeks per platform × 3 | platform SDKs (zero binary bloat) | OS-native quality | partial (varies per platform) | Three backends; feature parity is a constant battle |
| 6 | Flutter's Impeller (hypothetical) | unknown | Impeller (already in engine?) | Production-grade | yes | Unproven reachability; needs investigation |

Everything above tier 2 starts to feel like "we're rebuilding Flutter."
That's not wrong — at some level a 2026 UI framework that wants Material
Design quality needs roughly what Flutter has. The question is whether
we want to do it differently or more lightly.

## Modern (WebGPU-era) renderers

A specific subset of tier 3+: renderers that target compute-shader-era
GPU APIs (WebGPU, Vulkan 1.3+, Metal 3, D3D12), often using compute
shaders for path rendering rather than CPU-side tesselation.

### Standalone 2D renderers

- **[Vello](https://github.com/linebender/vello)** — Linebender's
  flagship. Pure-Rust 2D vector renderer using compute shaders for path
  rendering. WebGPU (via `wgpu`) is the primary backend. High-quality
  output, designed exactly for UIs. Actively developed under the same
  group building the [Xilem](https://github.com/linebender/xilem) UI
  framework. Pairs with [Parley](https://github.com/linebender/parley)
  for text shaping and line breaking — the only modern stack that
  bundles real typography without dragging in Skia.
- **Skia Graphite** — Google's newer Skia backend (separate from the
  legacy GL-era "Ganesh"). Designed for modern GPU APIs; can target
  [Dawn](https://dawn.googlesource.com/dawn) (Google's C++ WebGPU
  implementation), Metal, Vulkan, D3D12. Production code path in Chrome.
- **[Forma](https://github.com/google/forma)** — Google's experimental
  compute-shader 2D renderer. Smaller and less active than Vello;
  conceptually similar. Status unclear — treat as exploratory.
- **[ThorVG](https://github.com/thorvg/thorvg) WebGPU backend** — added
  to ThorVG's multi-backend setup alongside software and GLES backends.
  Embedded-UI focus.
- **[FemtoVG](https://github.com/femtovg/femtovg)** — Rust port of
  NanoVG that targets `wgpu`. Gets you NanoVG's simplicity and API shape
  with a modern WebGPU backend. Lighter than Vello, but no compute-shader
  cleverness — just a competent modern rewrite of the immediate-mode
  vector approach.
- **[Epaint](https://github.com/emilk/egui/tree/master/crates/epaint)**
  — the rendering crate behind [egui](https://github.com/emilk/egui).
  Does CPU-side tessellation, producing textured triangle meshes; the
  actual rasterization is delegated to any simple 3D API (could be
  driven through `SDL_RenderGeometry` directly without a separate GPU
  context). Extremely fast for immediate-mode UI; text/shadows are
  basic; quality is "good enough for tools," not "Apple-grade."
- **[Rive Renderer](https://github.com/rive-app/rive-renderer)** —
  recently open-sourced by Rive (the animation tool). Uses Pixel Local
  Storage (PLS) on GL/Metal to do analytic vector rendering without
  CPU-side tessellation. Designed for complex overlapping vector paths
  (UI + animation). Different point in the design space from both Skia
  and Vello: bleeding-edge GPU technique, smaller scope than Skia.
  Unproven as a general UI canvas outside Rive's animation ecosystem.

### UI frameworks built on WebGPU/wgpu

Not standalone 2D libs, but worth knowing as reference architecture:

- **[Makepad](https://makepad.dev/)** — Rust UI framework, its own
  renderer, targets `wgpu`, ships to native + WASM.
- **[Iced](https://github.com/iced-rs/iced)** — Rust GUI library, uses
  `wgpu` by default.
- **Bevy UI** — [Bevy](https://bevyengine.org/) game engine's UI module,
  uses `wgpu`.
- **[Xilem](https://github.com/linebender/xilem) / Druid** (Linebender)
  — pair with Vello as the renderer.
- **[Slint](https://slint.dev/)** — multiple backends including software
  and FemtoVG; modern GPU pipeline in progress.

### WebGPU vs SDL_GPU

There's a parallel "modern unified GPU API" path in the SDL3 family:
**`SDL_GPU`**, introduced around SDL 3.2. Same conceptual shape as
WebGPU (Metal/Vulkan/D3D12 underneath, modern command-buffer model).

If we stay in the SDL3 family, `SDL_GPU` is the natural fit — except
**no popular 2D renderer targets it yet**. The renderer ecosystem
standardized on WebGPU because of the browser/standards story, not
because WebGPU is technically superior to `SDL_GPU`. So "WebGPU backend"
is the current modern-GPU lingua franca for renderer libraries, even
when we don't care about the browser.

## CPU-side and platform-native paths

Two categories that don't fit on the GPU-renderer ladder but are real
options worth understanding.

### Blend2D — the high-performance CPU dark horse

[Blend2D](https://blend2d.com/) is a pure-software 2D vector engine in
C++ with a clean C API. The interesting thing about it: it uses a
custom JIT compiler to generate optimized rendering pipelines at
runtime, specialized to the pixel format and blend mode in use.

The pitch:

- **Skips the GPU API problem entirely.** No OpenGL context, no
  `wgpu-native` dependency, no Metal layer plumbing, no per-platform
  swapchain code, no driver bugs. You give it a chunk of memory, it
  fills it with anti-aliased gradients and paths, you upload that
  buffer to a streaming SDL texture (`SDL_UpdateTexture`) and `present`.
- **High output quality.** Path AA, gradients, blending, compositing —
  rendered with care, often beats GL-era renderers on quality at the
  pixel level.
- **Tiny dep.** ~1–2 MB compiled, no GPU stack tagging along.
- **Fast for typical UIs on modern CPUs.** A few hundred draw calls per
  frame is comfortable at 60 Hz on a single core. Multi-core scales
  via tiling.

The trade-off:

- **CPU-bound.** A 4K display with heavy animation across the whole
  screen will eat cores. Battery is workload-dependent — idle UIs are
  basically free, busy ones spin fans.
- **No text shaping built in.** Same situation as NanoVG; bring
  HarfBuzz / line breaker yourself.
- **Different mental model from GPU renderers.** You don't accumulate
  draw commands; you make the call and pixels happen. Plays well with
  display lists since you can defer the actual rendering pass.

Blend2D is the right call if "no GPU stack at all" is appealing, or if
the UI is typically idle and we'd rather burn nothing than burn a
little GPU constantly.

### Platform-native — Direct2D / CoreGraphics / Cairo

The other "drop the cross-platform renderer entirely" path: bind to
each OS's native 2D API.

- **macOS / iOS:** CoreGraphics (Quartz 2D). Highly tuned, color-correct,
  HDR-aware, integrates with the platform compositor.
- **Windows:** Direct2D + DirectWrite. Production-grade, GPU-accelerated,
  modern.
- **Linux:** [Cairo](https://www.cairographics.org/). Mature, used by
  GTK. Software-default, GL backend available.

What you get: 

- **Zero binary bloat.** No 100 MB Skia. No 5 MB Vello + wgpu. The
  rendering code is already in the OS.
- **Native visual quality.** Matches the platform's own apps: correct
  font hinting, correct color, correct subpixel positioning, correct
  HDR handling.
- **OS-level power tuning.** Vendors optimize these for their own
  apps; you inherit that.

What you pay:

- **Three completely different backends.** Different APIs, different
  text models, different color models. You write the same `Canvas`
  three times.
- **Feature parity is a forever battle.** Direct2D handles text clipping
  differently than CoreGraphics. Cairo's gradient model is different
  again. Edge cases will diverge.
- **No headless / CI story by default.** Each backend assumes a real
  display. Testing rendering output cross-platform becomes hard.

This is how lightweight frameworks like [Tauri](https://tauri.app/)
historically kept their binary tiny, and how early React Native
achieved native look. It's also why those projects have small "rendering
team" but constant "platform differences" bugs.

For Flutter Zero, the platform-native path is the most "anti-Flutter"
choice — it goes the opposite direction (delegate everything to the
platform) from Flutter's "draw it ourselves identically everywhere."

## Implementing Skia Graphite in detail

Asked explicitly. The recipe:

```
Dart code
  ↓ FFI
small C wrapper around Skia C++ API (our own, ~hundreds of LOC)
  ↓ C++
Skia + Graphite backend (huge, ~100 MB build)
  ↓ Metal / Vulkan / D3D12 / Dawn(WebGPU)
GPU
  ↑ surface acquired via
SDL3 (window + GPU layer / surface)
```

### 1. Build Skia with Graphite enabled

Skia uses GN + Ninja:

```sh
git clone https://skia.googlesource.com/skia.git
cd skia
python3 tools/git-sync-deps
bin/gn gen out/Release --args='
  is_debug=false
  skia_use_graphite=true
  skia_use_metal=true       # macOS
  skia_use_vulkan=true      # Linux/Windows
  skia_use_dawn=true        # if you want the WebGPU path
  skia_enable_pdf=false
  skia_enable_skshaper=true
'
ninja -C out/Release skia
```

Realistic costs: ~30 min first-time build, ~100 MB static lib per
platform, ~200 MB build artifacts. Repeat per target architecture
(`x86_64-mac`, `arm64-mac`, `linux-x64`, `win-x64`). Building Skia is
the kind of thing you check into CI and forget; bootstrapping it is a
real engineering day.

### 2. Write a C wrapper

This is the load-bearing problem. Skia's public API is C++; Dart FFI
talks C ABI. So we need a translation layer:

```c
typedef struct sk_graphite_context_t sk_graphite_context_t;
typedef struct sk_surface_t sk_surface_t;
typedef struct sk_canvas_t sk_canvas_t;
typedef struct sk_paint_t sk_paint_t;
typedef struct sk_path_t sk_path_t;

sk_graphite_context_t* sk_graphite_create_metal_context(void* mtl_device, void* mtl_queue);
sk_graphite_context_t* sk_graphite_create_vulkan_context(/* ... */);
sk_graphite_context_t* sk_graphite_create_dawn_context(/* WGPUDevice */);

sk_surface_t* sk_graphite_make_surface(sk_graphite_context_t*, void* drawable, int w, int h);
sk_canvas_t* sk_surface_get_canvas(sk_surface_t*);

void sk_canvas_clear(sk_canvas_t*, uint32_t color);
void sk_canvas_draw_rect(sk_canvas_t*, float x, float y, float w, float h, sk_paint_t*);
void sk_canvas_draw_rrect(sk_canvas_t*, float x, float y, float w, float h, float radius, sk_paint_t*);
void sk_canvas_draw_path(sk_canvas_t*, sk_path_t*, sk_paint_t*);
void sk_canvas_draw_text(sk_canvas_t*, const char* utf8, sk_paint_t*, float x, float y);
void sk_canvas_save(sk_canvas_t*);
void sk_canvas_restore(sk_canvas_t*);
void sk_canvas_translate(sk_canvas_t*, float dx, float dy);
void sk_canvas_scale(sk_canvas_t*, float sx, float sy);
// ... many more
```

Skia *does* ship partial C headers in `include/c/` (`sk_canvas.h`,
`sk_paint.h`, etc.) — but they're an old subset, not actively maintained,
and **don't cover Graphite at all**. The Graphite glue is on us.

A useful subset is probably 500–1500 lines of C++. Full Flutter-quality
coverage is more like 5,000 lines.

### 3. SDL3 → Skia surface bridge per backend

- **Metal (macOS):** `SDL_Metal_CreateView(window)` →
  `SDL_Metal_GetLayer(view)` returns a `CAMetalLayer*`. Per-frame,
  `[layer nextDrawable]` gives a `id<CAMetalDrawable>`. Wrap its
  texture in a Graphite `BackendTexture`, make a `Surface` from it.
- **Vulkan (Linux/Windows fallback):** `SDL_Vulkan_CreateSurface(window,
  instance, &surface)`. Then create the Vulkan swapchain, acquire
  images, wrap one as a Graphite `BackendTexture` per frame.
- **D3D12 (Windows):** SDL3 doesn't expose D3D12 directly — use
  `SDL_GetWindowProperties` to get the HWND, create the swapchain
  manually with DXGI.
- **Dawn/WebGPU:** SDL3 has no first-class WebGPU surface helper yet;
  construct the `wgpu::Surface` from the platform-native window handle
  yourself, hand it to both Dawn and Graphite.

Per platform: 1–2 days of plumbing.

### 4. Dart FFI bindings

Use `ffigen` to generate Dart bindings from the C wrapper's header:

```yaml
# ffigen.yaml
output: lib/src/skia/skia_bindings.dart
headers:
  entry-points:
    - 'native/sk_graphite_wrapper.h'
```

`ffigen` produces a Dart class with bindings for every C function. Then
the Dart-side `Canvas` wraps those bindings with a friendly API — the
same shape as Flutter's `dart:ui` `Canvas`, because that's what
`dart:ui` *is*: a Dart wrapper over Skia bindings, just baked into the
engine instead of via FFI.

### 5. Tie it into `sdl_ui`

Replace `Canvas`'s SDL renderer delegate with the Skia binding.
`SdlApp.run` adds one-time Graphite context creation in init, and
per-frame surface acquisition before calling `onFrame`. The widget tree
above doesn't change.

### Honest cost summary

For a useful subset, single-platform:

| Phase | Days |
|---|---|
| Skia + Graphite build pipeline | 2–4 |
| C wrapper (subset) | 5–10 |
| SDL3 surface integration | 2–3 per platform |
| Dart bindings + Canvas | 3–5 |
| Cross-platform testing | ongoing |

**3–6 weeks of focused work for one platform.** More for full
multi-platform. By comparison: NanoVG is ~1 week; Vello via
`wgpu-native` is ~3 weeks.

### Distribution / binary size

- Skia static lib: ~100 MB per platform per arch
- Linking dynamically means shipping a ~40–50 MB `.dylib`/`.so`/`.dll`
- NanoVG: ~10 KB compiled
- Vello-via-wgpu: ~5 MB Rust-compiled lib

For a "lightweight" framework that's a meaningful chunk of the binary
size budget.

## The "we just rebuilt Flutter" problem

Flutter Zero's pitch (from the README): *"`dart:ui` is a monolithic blob
with layers of abstractions and indirections that are not always at the
right place or even necessary."* The project's whole motivation is the
hypothesis that a lighter, more decoupled approach exists.

If we wire Skia (Ganesh or Graphite) back in via FFI + a Dart `Canvas`
binding, we have functionally reproduced what Flutter does — Skia
underneath, Dart `Canvas` on top, just with FFI between the layers
instead of the engine baking them together, and SDL3 swapped for
Flutter's platform embedder.

That might still be the right call if Skia-quality rendering is
non-negotiable and we want a different architecture around it. But it's
worth naming honestly: **Skia means "Flutter rendering, externalized."**
The whole point of Flutter Zero was to question whether that's the
right answer.

The alternatives don't have this issue:
- **NanoVG** is a different lineage (Mikko Mononen's port of Cairo-style
  rendering to GPU, designed for embedded UIs).
- **Vello** is a different lineage too (Linebender, compute-shader-first,
  Rust ecosystem).
- **Building our own on `SDL_RenderGeometry` or `SDL_GPU`** is an
  entirely separate path — slow and ambitious but maximally
  differentiated.

## Impeller as a wildcard

[Impeller](https://github.com/flutter/engine/tree/main/impeller) is
Flutter's newer renderer, intended to eventually replace Skia inside
Flutter. It was designed precisely to be more amenable to alternative
embedding patterns than Skia's monolithic shape. It targets Metal,
Vulkan, and OpenGL ES; uses pre-built pipelines instead of Skia's
runtime shader compilation; aims for lower latency and predictable
frame times.

If Impeller is reachable from Flutter Zero's engine, it might be the
best of both worlds: production-quality rendering with a lighter,
modern API and no Skia build dependency. **Status: unknown.** Flutter
Zero strips out most rendering machinery, and I haven't checked whether
Impeller pieces survive or whether they could be reached via Dart FFI.

Worth investigating before committing to a heavier path. Specific
things to check:
- Is `impeller_dart` or equivalent exposed?
- Are the Impeller `.a`/`.so` build outputs present in
  `engine/src/out/`?
- Are there C ABI entry points or do we need C++ wrappers?
- Can we instantiate an Impeller context from SDL3-provided GPU primitives?

## Architecture: keeping the renderer swappable

The `sdl_ui` Canvas seam is already the right place for this decision —
nothing above it (`FrameScheduler`, `SdlApp`, future widget tree)
references SDL renderer concepts directly. The current `Canvas` in
`examples/sdl_ui/lib/src/canvas.dart` is ~30 lines and delegates to
`SdlxRenderer`. Swapping it for a NanoVG or Skia-backed implementation
is one file change plus per-frame init.

What we should *not* do is leak SDL renderer concepts into widget code.
A `Container(borderRadius: 8)` should compile and behave the same way
regardless of whether `Canvas` is SDL, NanoVG, or Skia underneath. The
visual output will differ (SDL3 will square the corners, NanoVG and
Skia will round them), but the framework doesn't care.

Concretely: the Canvas API should be designed against the
**most-capable** renderer we plan to support, not the least-capable.
Today's `Canvas` should expose `fillRRect`, `strokePath`, `clipPath`,
gradient paints, transforms — even though SDL3 can only no-op or
approximate most of them. When we swap to NanoVG/Skia, the existing
widget code lights up correctly without changes. This is the same
pattern as Flutter's `dart:ui` `Canvas`, which exposes a Skia-shaped
API regardless of the underlying GPU backend.

### Recording canvas / Display Lists — the right shape for the seam

There's a stronger version of "renderer-swappable Canvas": make the
Canvas a **recording** canvas. Instead of every `canvas.fillRRect(...)`
call issuing a synchronous FFI call into the backend, it appends a
`DrawCommand` to an in-memory list:

```dart
sealed class DrawCommand {}
class ClearCommand extends DrawCommand { final Color color; ... }
class FillRRectCommand extends DrawCommand { final Rect rect; ... }
class SaveCommand extends DrawCommand {}
class RestoreCommand extends DrawCommand {}
class TranslateCommand extends DrawCommand { final double dx, dy; }
class DrawPathCommand extends DrawCommand { final Path path; ... }
class DrawTextCommand extends DrawCommand { final TextRun run; ... }
// ...
```

The widget tree's paint pass produces a `DisplayList` (the tree of
`DrawCommand`s). A separate "executor" walks the display list and
invokes the actual backend — SDL renderer, NanoVG, Skia, whatever.

Why this is structurally important, beyond "renderer-swappable":

1. **Decouples the UI thread from the render thread.** Today
   `sdl_ui` runs both on the platform thread because we're merged. If
   we ever go unmerged (or move to approach B with `SDL_AppIterate`),
   the display list is a *serializable* unit of work that ships across
   threads. The UI thread does layout + records; the render thread
   does execute. This is exactly how Flutter hits 120 Hz: the framework
   thread produces a `Scene`, the raster thread consumes it.

2. **Caching and invalidation.** Display lists are cheap to compare. If
   only a small subtree changed, you can paint only that subtree's
   slice and reuse the rest. Without a recording layer, every frame is
   a fresh blast of FFI calls regardless of what changed.

3. **Testing.** A display list is a value. You can assert on it without
   spinning up a GPU context. `expect(canvas.commands, contains(...))`
   is straightforward unit-testing for renderer code; "did the right
   pixels land in the framebuffer?" is much harder.

4. **Replay / debugging.** Capturing a display list per frame lets you
   re-execute frames in a debugger, diff frames against each other,
   replay a UI session as a recording.

5. **Multi-backend at runtime.** A useful corollary: you can dump the
   same display list through different executors to see how the
   renderers diverge. Worth its weight in regression-debugging.

The cost is small — a `DrawCommand` is a tiny Dart object; a tree of a
few hundred per frame is well under a millisecond to build and walk.
The right time to add it is **before** the renderer swap, since adding
a recording layer to a Canvas that's already issuing direct FFI calls
means rewriting the Canvas. Better to ship the seam in this shape from
the start.

Concrete change to `sdl_ui` today: split `Canvas` into a `RecordingCanvas`
that produces a `DisplayList`, and a `SdlDisplayListExecutor` that
walks the list and issues SDL renderer calls. The widget code calls
into `RecordingCanvas`. When NanoVG / Skia ships, it's a new
`NanoVgDisplayListExecutor` and the widget code doesn't move.

This is the same shape as Flutter's `Picture` / `PictureRecorder` /
`SceneBuilder` model — and it's deliberate. Flutter built it that way
because separating "what to paint" from "how to paint it" is the
single highest-leverage architectural decision in a UI framework's
rendering layer.

## Recommendation

Sorted by likely best fit:

- **For "ship a real UI this quarter":** NanoVG via SDL3's GL context,
  or Blend2D via streaming SDL texture. Pick NanoVG if a desktop GPU is
  assumed and battery-on-idle isn't critical; pick Blend2D if "zero GPU
  stack, idle UIs cost nothing" is appealing. Both at ~1 week, both
  needing HarfBuzz + a line breaker added on for real text.

- **For "build the right thing for 2027":** Vello via `wgpu-native`.
  Modern GPU pipeline, P3-correct, the only modern stack with bundled
  text shaping (Parley), ongoing investment, smaller binary than Skia.
  Cost is the Rust toolchain and learning a less-well-known API.

- **For "match Flutter's output":** Skia Graphite. Most expensive both
  in engineering and in binary size, but it's the known-good answer if
  the bar is "indistinguishable from a Flutter app" — and it's the only
  option where text, color, and quality all come boxed together.

- **For "tiny binary, native look, willing to pay platform tax":**
  Direct2D / CoreGraphics / Cairo per platform. Zero rendering bloat,
  perfect platform integration. The trade is owning three rendering
  backends forever.

- **Wildcard worth a day of research:** Impeller. If it's reachable
  from Flutter Zero's engine, it dominates Skia Graphite on every axis
  for our use case.

- **Stay on SDL3 alone:** only if the UI is genuinely geometric (game
  HUDs, dev tools, debugger panels) and rounded corners + AA aren't
  required.

The conservative default for the framework work today is two-fold:

1. **Restructure `Canvas` into a recording canvas that emits a Display
   List** (see Architecture section). Build this now, before any
   renderer swap, while the Canvas is small and there's no widget code
   depending on its shape. This is the load-bearing decision.
2. **Upgrade the Canvas API surface to the most-capable target** —
   `fillRRect`, `strokePath`, `clipPath`, gradient paints, transforms,
   text runs with style — even though SDL3 can only no-op or
   approximate most of them today. When NanoVG / Vello / Skia lands,
   existing widget code lights up without changes.

The renderer swap itself is then a deferrable concern. The right time
to make it is when the visual ceiling actually starts hurting — likely
when we ship a `Button(borderRadius: 8)` and the hard corners look
wrong.
