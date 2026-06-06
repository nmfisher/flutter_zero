# UI renderer plan

A focused build plan for the 2D rendering layer that sits under our
`RecordingCanvas` / `DisplayListExecutor` seam. Companion to
`UI_BRAINSTORMING.md` (framework above the canvas) and `RENDERING.md`
(backend survey). Where those documents survey options, this one commits
to a direction and scopes the work.

## TL;DR

**Build a Filament-native UI shader library, not an off-the-shelf 2D
engine.** Game UIs are mostly text + coloured rects + images + small
shaders. Filament already gives us the GPU, command buffer, material
system, and texture management; bolting a CPU 2D engine (Blend2D) next
to it duplicates infrastructure and abandons the GPU we already have.
Bolting a heavyweight GPU 2D engine (Skia) brings ~100 MB of binary
and reproduces what we just stripped out of Flutter.

Realistic scope: **4–6 weeks of focused work** for a useful Latin-script
UI renderer with rounded rects, gradients, AA, drop shadows, text,
images, transforms, clipping. The result is GPU-native, ~zero new
binary footprint beyond `stb_truetype`, no bus factor on a single
external maintainer, and every primitive is a small focused commit.

The honest ceiling is "good game UI" — not Material Design 3 polish,
not arbitrary SVG path rendering, not complex-script text shaping.
Those are deferrable; most aren't needed for a game engine.

## Context: where we stand

- `examples/thermion_ui/` is the working framework today. `FrameScheduler`
  + `RecordingCanvas` + `DisplayList` + `DisplayListExecutor` are wired
  end-to-end, with a real `FilamentDisplayListExecutor` that
  software-rasterizes per frame into an RGBA8 `Uint8List`, uploads to a
  Filament texture, and composites it on top of the 3D scene via a
  second `View` at `renderOrder: 1` (commit `e148b50`).
- The current rasterizer handles `Clear`, `FillRect`, `StrokeRect`,
  `Save`, `Restore`, `Translate`. Output is the raw "Win95" look — no
  AA, no rounded corners, no text, no gradients.
- The 2D backend question — hand-rolled vs Blend2D vs build-our-own —
  was open. This document commits to "build our own."

## The decision space

Three honest options, briefly. Detail in `RENDERING.md`.

### Hand-roll bigger software rasterizer

What we have today, scaled up. Add bitmap font, add SDF rounded-rect
software rasterization, etc.

- **Pros:** zero deps, ships fast, pure Dart.
- **Cons:** every primitive is duplicate work the day we swap; CPU-only;
  visual ceiling is permanently low; no GPU acceleration despite us
  having a GPU.

Rejected as the destination. Useful only as a stepping-stone scaffold
(which it already is).

### Blend2D as the canvas backend

Replace our rasterizer with Blend2D's `BLContext`. Get text, AA,
gradients, paths, drop shadows in one piece.

- **Pros:** turn-key 2D engine, excellent quality, small dep (~1–2 MB),
  clean C API for FFI.
- **Cons:** CPU-only — burns cores while the GPU sits idle. Adds a
  native build per platform. Bus-factor 1 maintainer. sRGB-only
  (no HDR / P3). No WASM story. ~1–2 weeks of FFI integration.

Right answer if we were building a desktop app framework. Wrong shape
for a game engine that already runs Filament on the GPU.

### Build our own Filament-native UI renderer

A small library of Filament materials (rounded rect, gradient, image,
text, shadow) + a batching layer + an `stb_truetype`-backed glyph atlas
+ a transform stack. Each `DrawCommand` translates to a Filament render
submission.

- **Pros:** GPU-native, shares Filament's command buffer, ~0 MB new
  binary, no FFI gymnastics, inherits Filament's HDR / color management,
  every primitive is small and ours to control.
- **Cons:** every new primitive is engineering work; text pipeline is
  fiddly; quality ceiling is "good game UI" not "Apple-grade." 4–6 weeks
  of focused work.

**Picked.** Matches the "lightweight game engine" pitch. Same shape as
how Unity UI Toolkit / Unreal Slate / Bevy UI actually work — they
emit textured quads with bespoke shaders, not Skia.

## What "build our own" means in pieces

Six concrete components, in roughly increasing complexity.

### 1. The matc build pipeline

Filament's material compiler (`matc`) turns `.mat` source into
`.filamat` blobs. Thermion already invokes it via `make materials` for
its built-in materials. We add:

- A `materials/` directory under `examples/thermion_ui/` (or wherever
  the framework lands).
- A Makefile rule that runs `matc` per `.mat` file, outputs `.filamat`
  blobs into the example's asset directory.
- A small Dart loader that reads bundled blobs and calls
  `FilamentApp.instance!.createMaterial(blob)` at startup.

**Effort: 1–2 days.** Tooling.

### 2. The UI material library

One `.mat` file per primitive. Realistic v1 set:

| Material | Lines (estimate) | Notes |
|---|---|---|
| `solid.mat` | ~20 | Per-instance colour; opaque or BLEND alpha mode |
| `rounded_rect.mat` | ~50 | SDF-based AA; params: corner radius + size |
| `gradient.mat` | ~40 | Linear + radial; vertex-colour interpolation + fragment math |
| `image.mat` | ~30 | Textured unlit BLEND |
| `text.mat` | ~30 | Samples R8 glyph atlas; tints output by colour |
| `shadow.mat` | ~50 | Gaussian blur of a rounded-rect SDF, or pre-baked blob texture |

Each is small, focused, single-purpose. Compiled offline by `matc`.

**Effort: ~1 day per material. ~1 week for the v1 set.**

### 3. The batching / submission layer

Today's executor builds one `Geometry` per frame (the fullscreen quad).
Real UI submits hundreds of primitives per frame. We need batching.

Two approaches:

**(a) Per-frame mesh build.** Walk the DisplayList; append
vertices/indices/UVs/colours into growing buffers; emit one
`createGeometry` per material change. Standard immediate-mode pattern.
Simpler. Memory churn is the cost (Filament will let us reuse vertex
buffers but the wiring is non-trivial).

**(b) Instanced rendering.** Pre-create a single quad geometry, fill
an instance buffer with per-instance parameters (position, size,
colour, radius, etc.), draw N instances per material. More modern,
faster on real workloads. Filament's `MaterialInstance` story makes
per-instance attributes fiddly — needs investigation.

**Pick (a) first, swap to (b) when frame budget bites.**

**Effort: 3–5 days for (a). Multiple days more for (b).**

### 4. Coordinate space + transform stack

- Pixel-space `Canvas` coordinates (origin top-left, x right, y down).
- Orthographic camera maps that to NDC. Mostly handled today; the
  existing `Camera.setProjection(Orthographic, -1, 1, -1, 1, ...)` just
  needs widening to `(0, width, 0, height)`.
- A transform stack: `save()` pushes the current `Matrix4`, `restore()`
  pops, `translate/scale/rotate/transform` mutate the top. Vertex
  positions get pre-multiplied by the top matrix before submission.
- Clipping:
  - **Rectangular clip** via Filament's scissor rect (cheap, only
    axis-aligned).
  - **Rounded / arbitrary clip** via the stencil buffer (Filament has
    stencil ops; needs a sentinel material that writes to stencil).

**Effort: 2–3 days.**

### 5. The text pipeline (the biggest single piece)

Components, in order:

- **Font loading.** Vendor `stb_truetype.h` (single header, ~4k LOC C).
  Compile via the existing native-assets hook alongside Thermion's
  build. `ffigen` bindings for the half-dozen entry points we actually
  use. ~2 days.
- **Glyph rasterization.** `stbtt_GetCodepointBitmap` per `(font, size,
  codepoint)` produces a coverage bitmap. Rasterize once per glyph
  variant. ~0.5 days.
- **Glyph atlas.** A single R8 Filament texture (typically 1024×1024).
  Pack glyphs as requested using a skyline packer (~100 LOC Dart).
  Grow / re-pack on overflow (or shed cold glyphs LRU-style). ~1 day.
- **Glyph cache.** `Map<(int fontId, double size, int codepoint),
  AtlasRect>`. LRU eviction when the atlas fills. ~0.5 days.
- **Layout (v1, Latin only).** Cursor advance using stb_truetype's
  kerning tables. Line breaks on `\n` only — no word wrap, no UAX #14
  break iteration. ~1 day.
- **`DrawTextCommand` + text material wiring.** Walk a text run, look
  up each glyph in the atlas, emit a textured quad with atlas UV coords
  + per-vertex colour. ~0.5 days.

**Deliberately not in v1:**

- HarfBuzz shaping (Arabic, Indic, complex CJK ligatures). Add when we
  ship non-Latin UI.
- Bidi (mixed RTL/LTR). Same.
- Full Unicode line-break (UAX #14). Add when wrapping bites.
- Subpixel text positioning. Add when small-size readability bites.

**Effort: 5–6 days for a useful Latin-script v1.**

### 6. Image / texture management

- Image decode: Filament's `decodeImage(Uint8List)` already exists for
  PNG/JPG/etc.
- Upload as Filament textures, manage handles.
- An `Image` Dart type holding a `Texture` reference, an `ImageCache`
  with reference counting + LRU eviction, lifecycle (`destroy` on
  release).
- `DrawImageCommand` + the image material wiring.

**Effort: 2–3 days.**

## What we already have

| Component | State |
|---|---|
| `RecordingCanvas` / `DisplayList` / `DrawCommand` | ✅ |
| `DisplayListExecutor` interface | ✅ |
| `ThermionFrameScheduler` (port-based, vsync-ish) | ✅ |
| UI `View` + orthographic camera + textured quad | ✅ |
| `View` compositing at `renderOrder: 1` over 3D | ✅ |
| RGBA8 texture upload pipeline (`setImage` per frame) | ✅ |
| Software rasterizer for `FillRect` / `StrokeRect` / `Clear` / `Save` / `Restore` / `Translate` | ✅ (placeholder) |

That's the foundation. Everything in §1–§6 builds on top of it; nothing
on the foundation needs to move.

## What's deliberately not in scope

- **Arbitrary 2D paths** (Bezier curves, complex stroke shapes). Most
  game UIs don't need them. Tessellation (Lyon, libtess) or runtime
  path rasterization (re-inventing what Vello does) is a separate
  multi-week project.
- **Filter effects** beyond drop shadow (background blur, glassmorphism,
  color matrix). Each is its own shader; add when wanted.
- **Animation primitives** (interpolation, easing curves, ticker).
  That's *framework* above the canvas, not renderer.
- **Subpixel-positioned text.** v1 pixel-aligned only.
- **Print / PDF output.** N/A for a game engine.
- **HDR / wide-gamut color authoring.** We inherit whatever Filament's
  configured to do; we don't add UI-side color management.

## Effort summary

| Piece | Days |
|---|---|
| matc build pipeline | 1–2 |
| 6 UI materials (full set) | 5–7 |
| Batching layer (a) | 3–5 |
| Transform stack + clipping | 2–3 |
| Text pipeline (Latin-only v1) | 5–6 |
| Image management | 2–3 |
| Wiring + Canvas API surface | 2–3 |
| Cross-platform testing (macOS/Linux/Windows) | ongoing |

**Realistic total: 4–6 weeks of focused work** for a single-platform
usable UI renderer.

For comparison (from `RENDERING.md`):

| Path | Effort | Quality ceiling | Binary cost |
|---|---|---|---|
| Hand-rolled rasterizer (current) | 0 (have) | Win95 | ~0 |
| Build-our-own Filament UI renderer | 4–6 weeks | Good game UI | ~stb_truetype only |
| Blend2D | 1–2 weeks | High desktop quality | ~1–2 MB |
| NanoVG via wgpu | 3 weeks | Decent | ~5 MB + wgpu |
| Skia Graphite | 3–6 weeks | Production | ~50–100 MB |

## Quality ceiling

Honest assessment of where we'd top out at v1 + a few iterations:

- **Anti-aliasing:** Good for SDF shapes (rounded rect, glyphs from
  `stb_truetype` AA bitmaps), MSAA-good for everything else if the
  Filament View has it enabled. Comparable to NanoVG-on-GL.
- **Text:** Good for Latin scripts at sane sizes. Weak for very small
  sizes (no subpixel positioning). No complex-script support (no
  HarfBuzz). Better than ImGui, worse than Skia.
- **Effects:** Whatever shaders we write. Drop shadows yes, blurs yes,
  gradients yes, gauzy glassmorphism if we author the shader.
- **Vector graphics:** No. Arbitrary paths would need tessellation work
  we explicitly deferred.
- **Color management:** Inherits from Filament. Probably correct on
  modern platforms but we haven't proven it.

For game UI specifically — HUDs, menus, debug overlays, settings
panels — this is fine. For app-quality polish — Material Design 3,
elaborate animations, complex layouts — we'd hit the ceiling.

## Sequencing — phased commit plan

Each phase ships something visible.

### Phase 1: matc + solid rect via material (1 commit, ~3 days)

- matc build pipeline (§1)
- `solid.mat` material (§2.1)
- Replace the current per-rect software rasterizer for `FillRect` with
  a Filament-submitted batched quad using the new material
- Keep `_strokeRect` as a fallback path through `FillRect`

Outcome: GPU-native solid coloured rects, same demo as today but no
software rasterization.

### Phase 2: rounded rect + AA (1 commit, ~2 days)

- `rounded_rect.mat` with SDF AA (§2.2)
- `RRectCommand` added to the canvas DrawCommand sealed hierarchy
- Demo updated: replace the current sharp pink HUD box with a rounded
  AA'd one

Outcome: rounded buttons look like real UI for the first time.

### Phase 3: image rendering upgraded (1 commit, ~1.5 days)

- `image.mat` (§2.4)
- `Image` type, image cache, `DrawImageCommand`
- Demo: load an asset, draw it as an icon next to the HUD

Outcome: icons, photos, sprites in UI.

### Phase 4: text (multiple commits, ~6 days total)

- Vendor `stb_truetype.h`, ffigen bindings (§5 step 1) — 1 commit
- Glyph atlas + cache (§5 steps 2–4) — 1 commit
- `text.mat` + `DrawTextCommand` + v1 Latin layout (§5 steps 5–6) — 1 commit
- Demo: render "frame: 60" in the top-left corner

Outcome: game HUDs become buildable.

### Phase 5: transforms + clipping (1 commit, ~3 days)

- Transform stack (§4)
- Scissor-rect clipping (§4)
- Demo: a scrollable panel showing more content than fits

Outcome: composite UI structures (scrollable lists, transformed
widgets, modals).

### Phase 6: gradient + shadow (2 commits, ~3 days total)

- `gradient.mat` (§2.3) — 1 commit
- `shadow.mat` (§2.6) — 1 commit
- Demo: card with rounded corners, gradient fill, soft drop shadow

Outcome: polished card-style UI.

### Phase 7: batching upgrade — instanced rendering (later, ~5 days)

- Move from per-frame mesh build (§3a) to instanced rendering (§3b)
- Only when frame budget bites. May never be needed for game-UI scale.

Outcome: scales to thousands of UI elements per frame.

### Phase 8: stencil clipping (later)

- Rounded-rect clipping via Filament's stencil ops (§4)
- Only when scissor rect's "axis-aligned only" limit bites.

## Open decisions

Items where we have a default but should pause to confirm.

1. **Where the framework lives.** Currently in `examples/thermion_ui/lib/src/`. As §1–§6 land, it grows beyond example-sized. Right time to extract into a real package (`packages/flutter_zero_ui/` or similar)? Probably yes around phase 4.
2. **`matc` shipping.** Filament ships `matc` for the host toolchain only. Do we vendor a host build into the repo, or require the developer install Filament SDK? Probably vendor — keeps "clone and build" working.
3. **Materials directory layout.** Per-platform `.filamat` blobs or one universal blob? Filament outputs different blobs per backend (Metal, Vulkan, GLES); we likely need per-platform bundling.
4. **`stb_truetype` ABI.** Static link into our `.so/.dylib`, or runtime FFI to a shared lib? Static is cleaner; the binary cost is negligible (~4k LOC compiled).
5. **Font management.** Single bundled default font, or expose font-loading API from day one? Bundle a default monospace + sans pair for v1; expose loading later.
6. **Glyph atlas size policy.** Single fixed 1024×1024, grow-as-needed, or multi-atlas pool? Fixed is simplest; revisit if it overflows in practice.
7. **Texture sub-image updates for glyph additions.** Audit confirmed `Texture.setImage(...)` exists; `setSubImage` should also be exposed but worth verifying before we depend on it. If it isn't exposed, that's a small Thermion patch.

## Cross-references

- `UI_BRAINSTORMING.md` — framework above the canvas (widget tree,
  scheduler, hit-testing).
- `RENDERING.md` — broader survey of 2D backends and the architecture
  seams.
- `examples/thermion_ui/README.md` — current implementation state.
- `examples/thermion_basic/README.md` — vanilla Thermion bootstrap this
  builds on.

## Updating this plan

As phases land, mark them off in the sequencing section and update the
effort summary with actuals. Pin actual screenshots after phase 2
(first one where the visual diff over the current state is obvious).
If we end up swapping the approach mid-way — e.g. picking up Blend2D
after all because the text pipeline is too painful — note the decision
and why here.
