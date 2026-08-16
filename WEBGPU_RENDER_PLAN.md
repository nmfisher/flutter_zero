# WebGPU rendering plan — one standalone component

A proposal for **one standalone component**: a WebGPU (Dawn) rendering
backend for **Blitz**, with a **Dart** frontend. The component renders an
HTML/CSS UI into either (1) a swapchain — direct presentation to a window
surface — or (2) a view/texture render target that a host renderer can
composite — composited into something like thermion (or any other
renderer).

Companion to `RENDERING.md` (backend survey) and `UI_BRAINSTORMING.md`
(threading model). Those documents survey and ask; this one specifies one
component and prices it.

This is a proposal only. No code has been changed.

## TL;DR

- The component has three parts: **Blitz headless inside a Rust cdylib**
  (HTML/CSS → CPU RGBA8 buffer), a **Dart frontend** that owns the app and
  drives it over FFI, and **our own small Dawn compositor** that draws
  Blitz's output into a target.
- **Two target modes** (§1.2). **Swapchain mode**: Dawn presents the UI
  directly to a window surface — an SDL3 window via its native handle, or
  a window the component owns. **Render-target mode**: Dawn renders into
  an offscreen view/texture, and a host renderer composites it — into
  something like thermion (or any other renderer).
- **The Dawn reality (verified, §6.2):** Blitz's GPU renderer is Vello on
  wgpu; there is no Vello/Dawn path, and wgpu has no Dawn backend. So
  "Dawn backend" means **our Dawn-side compositor over Blitz's CPU
  output**. That keeps Dawn the only GPU implementation in the process.
- **Render-target mode is the recommended first target** (§6.3 option A):
  it works with any host, needs no surface plumbing, and its interop story
  is plain — same-device sharing if the host exposes a Dawn device,
  otherwise one CPU readback → host upload.
- **Milestones B1–B5** (§6.6): cdylib + Dart FFI spike → render-target
  mode with a trivial host composite → swapchain mode on the SDL3 window
  → perf/dirty-region → hardening. Each produces a runnable thing. No
  external project is a prerequisite.
- Known costs: Blitz is beta (0.3.0-beta.1); CSS + layout + paint run on
  the calling thread; render-target mode pays one CPU copy per frame; a
  Rust cdylib plus Dawn is a real build surface (§6.7).

## 1. The component

One standalone component. It does not depend on any particular 3D engine
or host renderer. Three parts, two target modes.

### 1.1 The three parts

1. **Blitz headless, inside a Rust cdylib.** Blitz renders HTML/CSS on
   the CPU with no window: `HtmlDocument::from_html` → `resolve(t)` →
   `paint_scene` → `render_to_buffer` → an RGBA8 buffer **[verified,
   §6.1]**. The cdylib wraps this and exposes a small C ABI (§2.1).
2. **A Dart frontend.** Dart owns the app: it creates the engine, loads
   HTML/CSS, dispatches input, requests frames, and receives the output.
   The bindings are plain FFI over ~six functions (§2.2).
3. **Our Dawn compositor.** A small renderer written against Dawn's
   `webgpu.h` C API. One job: draw Blitz's RGBA8 buffer as a textured
   quad with alpha blending (plus clip/scissor) into the chosen target —
   a window surface, or an offscreen view/texture. A quad, a blend state,
   and a scissor; no more **[inferred: our code to write; the primitives
   are standard WebGPU]**.

### 1.2 The two target modes

```
                    ┌────────────────────────────────────────────────┐
                    │   the component (one cdylib + Dart bindings)   │
                    │                                                │
 window events ───► │  Dart frontend (owns the app)                  │
 (same thread)      │    │ FFI: create / load_html / dispatch /
                    │    │        render / get_output
                    │    ▼
                    │  Blitz headless (HTML/CSS → DOM → layout)
                    │    │ resolve(t) → paint_scene
                    │    ▼
                    │  RGBA8 buffer (CPU; no wgpu anywhere)
                    │    │
                    │    ▼
                    │  Dawn compositor (our code, webgpu.h):
                    │  textured quad, alpha blend, clip/scissor
                    └──────────────┬──────────────────┬──────────────┘
                                   │                  │
                 MODE a: SWAPCHAIN │                  │ MODE b: RENDER TARGET
                                   ▼                  ▼
                   Dawn presents to the window    Dawn renders into an
                   surface (SDL3 window native   offscreen view/texture
                   handle, or our own window)        │
                                   │                 ▼
                                   │          a host renderer samples /
                                   ▼          composites it (something
                     one present; Dawn is     like thermion, or any
                     the only GPU stack       other renderer); or Dart
                     in the process           reads pixels back
```

- **Mode a — swapchain.** The compositor creates a Dawn surface from the
  window's native handle — an SDL3 window, or a window the component owns
  — and presents. The UI *is* the window content. Options B and C in
  §6.3.
- **Mode b — render target.** The compositor renders into an offscreen
  view/texture. A host renderer composites that texture into its own
  frame — composited into something like thermion (or any other
  renderer). Interop reality in brief: if the host exposes its Dawn
  device, the compositor renders on the **same device** and hands over a
  texture (no copies); if not, the compositor renders on its own device
  and the pixels cross once through the CPU (readback → host upload)
  **[inferred: both are standard patterns; neither is built yet]**. And
  in the minimal version the host can simply take the RGBA8 bytes and
  upload them itself — no Dawn compositor needed at all (option A,
  §6.3). Recommended first target.

### 1.3 The Dawn reality, stated plainly

- Blitz's GPU renderer is **Vello on wgpu**. There is no Vello/Dawn path,
  and wgpu has no Dawn backend **[verified, §6.2]**.
- So a "Dawn backend" for Blitz cannot mean putting Blitz itself onto
  Dawn. It means: **Blitz renders on the CPU; our Dawn compositor draws
  the result.** Blitz's CPU renderer is proven headless **[verified,
  §6.1]**.
- This keeps **Dawn the only GPU implementation in the process** — no
  wgpu, no second WebGPU stack. §4 explains why two WebGPU
  implementations in one process cannot share devices.
- If GPU-quality Blitz rendering is ever needed, that is Blitz's wgpu
  renderer (Vello) — a different trade, second GPU stack and all (§6.2,
  §6.7).

Related work, context only: Dawn desktop build scaffolding (macOS/Linux
CI, static-library linking rules) has already been worked out in another
project (thermion's `asb/webgpu` branch) **[verified]**. Useful prior art
for §2.3's build questions; not a dependency, and nothing below requires
it.

## 2. What we build

### 2.1 The Rust cdylib — Blitz engine + C ABI

Blitz has no C API **[verified, §6.1]**, so the cdylib is the boundary.
Sketch of the whole ABI (~300–600 lines of Rust **[inferred]**):

```c
typedef struct fz_blitz_t fz_blitz_t;

fz_blitz_t*    fz_blitz_create(int width, int height, float hidpi_scale);
void           fz_blitz_load_html(fz_blitz_t*, const char* html,
                                  const char* base_url);
void           fz_blitz_set_viewport(fz_blitz_t*, int width, int height,
                                     float hidpi_scale);
void           fz_blitz_dispatch(fz_blitz_t*, const fz_blitz_event_t* events,
                                 int count);
const uint8_t* fz_blitz_render(fz_blitz_t*, double time_ms,
                               int* out_w, int* out_h);   /* borrowed */
void           fz_blitz_destroy(fz_blitz_t*);
```

- **Threading is trivial.** Everything is called from one thread — the
  Dart platform thread — like every other FFI call the app makes. No
  winit, no event loop inside the cdylib: input arrives as data
  (`fz_blitz_event_t` → Blitz's `UiEvent`, a boring translation table)
  **[verified: `UiEvent` is Blitz's input boundary, §6.1]**.
- **Frame gating.** Re-render only when something changed — an event
  arrived, or an animation is running. Blitz's own shell does exactly
  this (`is_animating()` gate) **[verified, §6.1]**.
- **Sizing.** `fz_blitz_set_viewport` on window resize; the buffer size
  follows the window.

### 2.2 The Dart frontend

- Six functions: hand-written FFI lookups are fine; `ffigen` optional.
  Days of work **[inferred]**.
- Dart owns the app and the frame loop: poll window events →
  `fz_blitz_dispatch` → `fz_blitz_render` → hand the bytes or texture to
  the target (mode a: compositor; mode b: host).
- **Input routing.** Window events become `fz_blitz_event_t` values.
  Hit-testing and hover are Blitz's job — DOM-aware, it knows which
  element is under the cursor **[verified, §6.4]**. The routing policy —
  the UI owns the pointer over interactive elements, events fall through
  to the host scene elsewhere — is Dart's choice **[inferred]**.

### 2.3 The Dawn compositor

- Written against Dawn's `webgpu.h` C API — Dawn is the reference
  implementation of that standard header **[verified, §4]**. One
  pipeline: a textured quad with per-fragment
  alpha, a clip/scissor rect, a WGSL shader of tens of lines
  **[inferred]**. It can live in the same cdylib (Rust calling Dawn's C
  API) or in a small C++ library beside it — a build-time choice, not an
  architectural one **[inferred]**.
- **Mode a plumbing:** create the surface from the window's native handle
  — on macOS the handle SDL3 exposes (`SDL_Metal_GetLayer`), on Linux the
  X11 window + display, on Windows the HWND **[verified SDL3 exposes
  these handles; whether Dawn consumes the layer or wants the NSView
  needs a one-day spike — inferred]**. Present in `Fifo` mode so frames
  pace to vsync **[inferred]**.
- **Mode b plumbing:** an offscreen `RGBA8_UNORM` texture with
  `RENDER_ATTACHMENT` (and `COPY_SRC` when a readback path is wanted).
- **Resize:** recreate surface or texture, call `fz_blitz_set_viewport`.
- **Build cost:** linking Dawn brings its static libraries and their
  C++ toolchain quirks; expect the linked output to grow by tens of MB.
  Measure in milestone B3 **[inferred]**.

### 2.4 What the component does not do

- It does not render 3D. A host does (mode b), or nothing does (mode a).
- It does not own a window unless asked (mode a with its own window —
  §6.3 option C).
- It does not require a specific host. Mode b's consumer is "anything
  that can take a GPU texture or an RGBA8 buffer."

## 3. Component-level alternatives

Why this shape and not another? All priced from verified facts in
§4–§6:

| Strategy | GPU stacks in process | UI quality | Build cost | Verdict |
|---|---|---|---|---|
| **Blitz CPU + our Dawn compositor** (this plan) | 1 (Dawn) | browser-grade CSS: stylo + taffy + parley **[verified §6.1]** | Rust cdylib + small Dawn renderer | **chosen** — one GPU stack, any host, headless path proven |
| Blitz GPU renderer (Vello on wgpu) | 2 (wgpu + host's), or 1 with no host | same CSS, GPU-quality AA | cdylib + wgpu | second WebGPU stack, still a CPU copy to reach a host **[verified §6.2]** |
| Skia Graphite on Dawn | 1 (Dawn) | full (HarfBuzz/ICU bundled) **[verified §4]** | ~100 MB build, 500–1500-line C wrapper **[verified §4]** | escape hatch only — "Flutter rendering, externalized" |
| Dear ImGui on Dawn | 1 (Dawn) | rasterized glyphs, no shaping **[verified §5]** | small: cimgui + ~50-line shim **[verified §5]** | the cheap Dawn alternative; immediate mode, no HTML/CSS |
| Hand-rolled WGSL UI renderer | 1 | ours to build (no CSS, no shaper) | 4–6 weeks | rebuilds what Blitz gives for free |

The choice follows the requirements: HTML/CSS authoring, retained mode,
Dawn as the only GPU implementation, Dart owns the app, small-ish and
permissively licensed (Blitz is Apache-2.0 OR MIT **[verified, §6.1]**).
Only the first row satisfies all five.

## 4. UI framework WebGPU backend research

Nick asked: of the frameworks listed in `RENDERING.md`, which ones really
support WebGPU, and could one of them be *the* unified WebGPU UI stack for
Flutter Zero, sitting beside a host 3D renderer? Each candidate was checked
against its upstream README, docs, or source on 2026-08-15. Facts below
are **[verified]** (read from the project's own repo/docs this round) or
**[inferred]** (our judgment, flagged as such).

### The key constraint first: two WebGPU implementations exist

- **Dawn** — Google's C++ WebGPU implementation: Chrome's, Skia
  Graphite's target, and the API our compositor (§1) is written against
  **[verified: §4 Skia entry; RENDERING.md]**.
- **wgpu** — the Rust implementation. On desktop, Rust UI projects use
  the `wgpu` crate, which compiles to its own GPU layer over
  Vulkan/Metal/D3D12. `wgpu-native` packages it as a C library exposing
  the standard `webgpu.h` header **[verified: gfx-rs/wgpu-native README —
  "a native WebGPU implementation in Rust... bindings are based on the
  WebGPU-native header"]**.

These two are **different stacks**. A wgpu device and a Dawn device in
one process cannot share textures, buffers, or a swapchain. There is no
standard way to pass GPU objects between them. So "a wgpu stack beside
a Dawn-based host" always means one of:

1. **Buffer handoff** — the UI renders into pixels, we copy the pixels to
   the other stack (CPU copy). This is exactly the component's mode-b
   fallback (§1.2). Slow-ish, but simple and proven.
2. **External memory** — share the underlying OS buffer (IOSurface,
   DMA-BUF) between stacks. Possible in principle, unsupported by either
   stack's public API today. Slint's own issue #4499 shows they have not
   solved rendering into a foreign texture either **[verified: issue
   title "Feature Request: Adding Slint into a custom renderer",
   discussing dmabuf conversion as future work]**.
3. **One stack only** — everything on Dawn, or everything on wgpu. That
   is what the component does (Blitz CPU + our Dawn compositor, §1.3).
   It is impossible when the UI stack insists on wgpu and the host on
   Dawn — no implementation hands its devices to another **[inferred]**.

One useful fact for later: both implementations speak the same standard
`webgpu.h` C API **[verified for wgpu-native; Dawn defines it by
construction]**. A hand-rolled Dart executor written against `webgpu.h`
FFI could talk to either one by loading a different library. That keeps
the "hand-rolled WGSL renderer" option (§2 B) portable across the two.

### Candidate-by-candidate

Every candidate from `RENDERING.md` was checked.

**Vello** (linebender/vello)
- WebGPU via `wgpu`; native desktop (macOS/Linux/Windows) plus WASM
  **[verified: README]**.
- Explicit `render_to_texture()` API — Vello does not need to own the
  window **[verified: README shows `renderer.render_to_texture(...)`]**.
  This matters: it fits *under* our executor seam.
- Text: Vello itself has none. Its sibling crate Parley is the shaping
  and layout stack; Xilem and Bevy both use Parley today **[verified:
  Xilem README links "the Parley text stack"; bevy_text Cargo.toml lists
  `parley` + `swash`]**.
- License Apache-2.0 OR MIT; shader files also Unlicense **[verified]**.
- Very active: v0.10.0 released 2026-08-14 **[verified: releases API]**.
- No C API. Rust only — we would write and build a small Rust `cdylib`
  wrapper **[verified: no C API mentioned; inferred: wrapper size ~few
  hundred lines]**.

**FemtoVG** (femtovg/femtovg)
- Two backends: wgpu and OpenGL ES2 **[verified: README]**.
- Real text shaping, and more than expected: the `textlayout` feature
  pulls `rustybuzz` (a Rust port of HarfBuzz), `unicode-bidi`, and
  `unicode-segmentation` **[verified: Cargo.toml]**. This is stronger
  text than `RENDERING.md` credits ("no shaping").
- License Apache-2.0 OR MIT; active: v0.26.0 released 2026-07-20,
  commits in August 2026 **[verified]**.
- No C API, Rust only **[verified]**. NanoVG-style API — simple, fills
  and strokes, no compute-shader path rendering.

**Makepad** (makepad/makepad)
- **No WebGPU backend.** Its renderer targets Metal (macOS), DX11
  (Windows), OpenGL (Linux), and WebGL (browser) through its own
  abstraction **[verified: README — "compiles to wasm/webGL, osx/metal,
  windows/dx11 linux/opengl"]**.
- This corrects `RENDERING.md`, which lists Makepad as "targets `wgpu`".
  At the source level that claim does not hold today.
- MIT, active, no tagged releases (rolling development) **[verified]**.
- No C API **[verified]**. **Disqualified for this purpose** — no
  WebGPU at all, so nothing to share with any Dawn- or wgpu-based host.

**Iced** (iced-rs/iced)
- Two renderers: `iced_wgpu` (Vulkan/Metal/D3D12 — i.e. wgpu on desktop)
  and `iced_tiny_skia` (CPU fallback) **[verified: README]**.
- Text via `cosmic-text` 0.19 plus a fork called `cryoglyph`, with
  `basic-shaping` and `advanced-shaping` feature flags **[verified:
  workspace Cargo.toml]**.
- MIT; last release 0.14.0 on 2025-12-07; README still calls it
  "experimental software" **[verified]**.
- No C API **[verified]**. It is a full framework with its own widget
  tree and windowing — it wants to own the window, not sit under our
  `DisplayListExecutor` **[inferred from architecture]**.

**Bevy UI** (bevyengine/bevy)
- Renders through `bevy_render`, which depends on `wgpu` v30 with
  `wgsl`, `metal`, `vulkan`, `dx12` features **[verified: bevy_render
  Cargo.toml]**. Native desktop, yes.
- Text: `bevy_text` uses `parley` + `swash` — *not* cosmic-text as often
  assumed **[verified: bevy_text Cargo.toml]**.
- MIT OR Apache-2.0; very active: v0.19.1 released 2026-08-13
  **[verified]**.
- No C API **[verified]**. It is a full game engine — ECS, assets,
  scheduling. Embedding "just the UI renderer" means fighting the
  framework, not using it **[inferred]**.

**Xilem / Druid** (linebender/xilem)
- Xilem renders with Vello + wgpu and uses Parley/Fontique for text
  **[verified: README]**. Native desktop target.
- Explicitly "experimental", no releases on the releases API
  **[verified]**. Druid is the older, dormant line; Xilem is its
  successor **[verified: README positions them]**.
- Apache-2.0; Rust only, no C API **[verified]**.
- Not usable as a component today; relevant mainly as the reference
  architecture for Vello + Parley **[inferred]**.

**Slint** (slint-ui/slint)
- WebGPU path exists, but it is not a first-class "wgpu renderer": the
  cargo feature is `renderer-femtovg-wgpu` — FemtoVG running on wgpu —
  plus `unstable-wgpu-29` / `unstable-wgpu-30` flags that expose wgpu
  APIs **[verified: api/rs/slint Cargo.toml feature list]**. The docs
  page lists stable renderers as FemtoVG (GL), Skia (GL/Metal/Vulkan/
  D3D), software, and Qt; the wgpu variant rides on FemtoVG
  **[verified: docs.slint.dev backends-and-renderers]**. A newer
  "anyrender" abstraction is in progress in the repo **[verified:
  internal/renderers directory]**.
- License is the outlier: GPLv3, a royalty-free license, or a commercial
  license — *not* a simple permissive license, and the royalty-free tier
  excludes embedded use **[verified: README]**.
- Language bindings: Rust, C++, JavaScript, Python **[verified: README]**;
  the Skia and software renderers have public C++ APIs, the FemtoVG one
  Rust only **[verified: docs renderer table]**.
- Active: v1.17.1 released 2026-07-07 **[verified]**.
- It is a complete UI toolkit with its own markup language and window
  ownership. Under our seam it does not fit; beside our framework it
  duplicates everything above the canvas **[inferred]**.

**ThorVG** (thorvg/thorvg)
- Real WebGPU renderer, treated as a full citizen: "All vector rendering
  features are fully supported on the WebGPU backend", ~1.8× throughput
  vs their GL backend **[verified: README]**.
- Native desktop uses **wgpu-native v29** under the hood; browsers use
  native WebGPU **[verified: README]**. So: wgpu stack, not Dawn.
- **Has a C API** — build with `meson -Dbindings="capi"` **[verified:
  README]**. This is the only candidate with a ready-made C ABI besides
  Skia.
- Text: TTF/OTF fonts and multi-line layout are listed, but no HarfBuzz
  or shaping engine is mentioned **[verified: README; absence of claim]**.
  Treat shaping as limited **[inferred]**.
- MIT; active: v1.1.0 released 2026-07-22 **[verified]**.

**Skia Graphite** (google/skia)
- Graphite's cross-platform GPU path is Dawn — the *same* implementation
  our compositor targets (§1). Dawn covers D3D12 (Windows), Vulkan
  (Linux), Metal (macOS); Graphite first shipped in Chrome on
  Apple-Silicon/Metal **[verified: Skia announce blog + SkiaSharp
  Graphite tracking issue; RENDERING.md §ladder]**.
- Text: full stack bundled (HarfBuzz/FreeType/ICU) — the only candidate
  where text "just works" **[verified: RENDERING.md; Skia docs]**.
- License BSD; production code path in Chrome; no releases, rolls with
  Chrome **[verified]**.
- C++ API; the C API in `include/c/` is an old subset that does not
  cover Graphite **[verified: RENDERING.md]** — we would write the same
  C wrapper §RENDERING describes, ~500–1500 lines for a subset.
- Same-implementation caveat: two separately created Dawn devices in one
  process (a host's and ours) still cannot share objects — one side
  must hand its device to the other **[inferred]**. And the cost is the
  known one: ~100 MB build,
  "Flutter rendering, externalized" **[verified: RENDERING.md]**.

### Comparison table

| Candidate | Real WebGPU backend? | Native desktop? | wgpu or Dawn? | Text shaping | License | Last release | C API for FFI? | Fits under our Canvas seam? |
|---|---|---|---|---|---|---|---|---|
| Vello | yes (wgpu) | yes | wgpu | via Parley (sibling crate) | Apache-2.0 OR MIT | v0.10.0, 2026-08-14 | no — Rust cdylib wrapper | **yes** — `render_to_texture` |
| FemtoVG | yes (wgpu) | yes | wgpu | yes — rustybuzz + bidi | Apache-2.0 OR MIT | v0.26.0, 2026-07-20 | no — Rust cdylib wrapper | yes — rasterizer-shaped |
| Makepad | **no** (Metal/DX11/GL/WebGL) | yes | own stack | unverified | MIT | none (rolling) | no | no — owns everything |
| Iced | yes (wgpu) | yes | wgpu | yes — cosmic-text | MIT | 0.14.0, 2025-12-07 | no | no — full framework |
| Bevy UI | yes (wgpu 30) | yes | wgpu | yes — parley + swash | MIT OR Apache-2.0 | v0.19.1, 2026-08-13 | no | no — full engine |
| Xilem | via Vello | yes | wgpu | yes — Parley/Fontique | Apache-2.0 | none (experimental) | no | no — full framework |
| Slint | via FemtoVG (`renderer-femtovg-wgpu`, unstable flags) | yes | wgpu | present, engine unverified | **GPLv3 / royalty-free / commercial** | v1.17.1, 2026-07-07 | C++ (skia, software renderers) | no — full toolkit |
| ThorVG | yes (full features, 1.8× vs GL) | yes | **wgpu-native v29** | fonts + line layout, no shaper verified | MIT | v1.1.0, 2026-07-22 | **yes** (`-Dbindings=capi`) | yes — renderer-shaped |
| Skia Graphite | yes (Dawn) | yes | **Dawn** | yes — HarfBuzz/ICU bundled | BSD | rolling (Chrome) | partial, old C subset | yes, but heaviest |

wgpu-native itself, for size reference: latest release v29.0.1.1;
desktop release zips are 13.7 MB (macOS arm64), 16.0 MB (Linux x64),
15.5–17.1 MB (Windows x64) **[verified: GitHub releases API]**. ThorVG
and any wgpu-based candidate bring roughly that much plus their own code.

### Recommendation

**No full UI framework is the right pick for Flutter Zero.** All five
frameworks (Makepad, Iced, Bevy UI, Xilem, Slint) want to own the
window, the event loop, and the widget tree. Four of them are Rust-only
with no C API. Slint has C++ bindings but a restrictive license and the
same ownership problem. Adopting any of them means abandoning the Dart
framework we are building — which is the point of the project
**[inferred]**.

**The unified WebGPU UI stack should be a renderer under the seam, and
the best one is Vello + Parley.** Reasons:

1. It fits the architecture we already have. `RecordingCanvas` emits a
   `DisplayList`; a `VelloDisplayListExecutor` walks it and calls Vello;
   Vello renders to a texture **[verified API exists; executor is our
   code]**. Nothing above the seam changes.
2. It coexists with any host, without GPU interop, through the buffer
   handoff: Vello renders into its texture, one GPU→CPU copy, the host
   uploads and composites. That is the mode-b handoff of §1.2 with a
   concrete renderer named. At
   800×600 this is cheap; measure at target resolution before
   committing **[inferred]**.
3. Text comes bundled in practice: Parley (shaping, layout) + swash
   (rasterization) is the same stack Bevy ships **[verified]**. This
   closes the biggest gap in `UI_RENDERER_PLAN.md`'s hand-rolled path.
4. It is the most alive project on the list (released yesterday, at
   time of writing) with the cleanest license **[verified]**.

**Runner-up: ThorVG.** The only candidate with a ready C API, which
makes Dart FFI trivial — no Rust wrapper to write or build. MIT,
active, full WebGPU feature support. Two reasons it is not the pick:
text shaping is unproven, and it rides on wgpu-native, so it can never
share a device with a Dawn-based host **[verified wgpu-native dependency;
shaping unverified]**. Worth a one-day spike if Vello's Rust wrapper
turns out to hurt.

**Skia Graphite is the only Dawn-native option**, so the only candidate
that could ever take a Dawn device directly (ours, §1). It also solves
text completely. It loses
on size (~100 MB) and on the "we just rebuilt Flutter" problem
`RENDERING.md` names. Keep it as the escape hatch if quality demands
it, not the plan **[inferred from RENDERING.md's analysis]**.

**Correction to `RENDERING.md`:** Makepad is listed there as a wgpu
target; per its own README it is not. The WebGPU-framework shortlist is
effectively Iced, Bevy UI, Xilem, and Slint — and none of them fit
under our seam.

**Impact on this plan: the research record stands as context.** The
component (§1) later chose Blitz rather than a renderer under a Dart
canvas; §5 reopened the question with window ownership allowed. Vello +
Parley remains the named 2D-only GPU renderer on wgpu if that shape is
ever wanted — buffer-level first, GPU interop deferred until either
stack grows external-memory support.

## 5. Widget framework on a WebGPU backend

New requirements from Nick, which change the question this plan asks:

- The framework **may own its window**. Windowing is not a blocker.
- It may bring its own renderer, but that renderer **must run on WebGPU
  natively** on desktop (wgpu or Dawn) — not just WASM.
- We will write Dart FFI bindings ourselves if there is a C ABI, or a
  small C shim / Rust cdylib if not.
- **Retained-mode preferred.** Immediate-mode acceptable if nothing
  retained fits.
- Small and fast preferred. Permissive license strongly preferred.

So the question becomes: is there a widget framework we can *adopt*,
rather than building widgets in Dart over a renderer? §4 concluded "no
full framework fits" — but that was under the old constraint that the
framework had to sit under our `DisplayListExecutor`. With window
ownership allowed, the field reopens. Everything below was checked
against upstream source on 2026-08-16. Claims are **[verified]** (read
from the project's repo/docs this round) or **[inferred]**.

### 5.1 GPUI deep-dive (Nick's hunch)

The zed repo splits GPUI into many crates: `gpui` (core), `gpui_platform`
(selector), `gpui_macos`/`gpui_apple`, `gpui_windows`, `gpui_linux`,
`gpui_web`, and — the one that matters here — **`gpui_wgpu`**
**[verified: repo crate listing]**.

**Does GPUI render via wgpu on native desktop?** Partly:

- **Linux: yes.** Both the X11 and Wayland window implementations
  construct `gpui_wgpu::WgpuRenderer::new(...)` for every window
  **[verified: `crates/gpui_linux/src/linux/x11/window.rs:733` and
  `.../wayland/window.rs:574`]**. `gpui_wgpu` is a real wgpu renderer:
  wgpu dependency, WGSL shader files (including a storage-buffer and a
  WebGL variant), a sprite atlas, and a cosmic-text 0.19 text system
  **[verified: `gpui_wgpu/Cargo.toml` + src listing]**.
- **macOS: no.** macOS uses `gpui_apple::metal_renderer::MetalRenderer`
  — literally `pub type Renderer = MetalRenderer;` **[verified:
  `crates/gpui_apple/src/metal_renderer.rs:45`]**. Direct Metal, no
  wgpu, no WebGPU.
- **Windows: no.** `gpui_windows` has `directx_renderer.rs`,
  `directx_devices.rs`, `direct_write.rs`, and HLSL shaders — Direct3D
  + DirectWrite **[verified: crate file listing]**.
- **Web: yes.** `gpui_web` compiles `gpui_wgpu` for wasm with a WebGL
  fallback feature **[verified: `gpui_wgpu/Cargo.toml` wasm deps]**.

**Is the renderer pluggable?** No. There is no runtime "Renderer" trait
with selectable implementations. The seam is the `Platform` /
`PlatformWindow` trait, and each platform crate hard-wires its renderer
at compile time (Linux→wgpu, macOS→Metal, Windows→DirectX)
**[verified structurally: each platform constructs its own renderer;
no shared renderer trait exists in `gpui/src/platform.rs`]**. The
`gpui_wgpu` crate itself has no OS gates — only wasm/non-wasm — so in
principle it could be compiled for macOS or Windows, but you would have
to write your own `Platform` implementation to use it there
**[inferred]**. The direction of travel is clearly toward wgpu
everywhere (a new wgpu crate, web on wgpu, `// todo("windows")` markers
in the code **[verified: `gpui/src/scene.rs:2`]**), but it is not there
today.

**Is GPUI usable as a library outside Zed?** Half-yes:

- `gpui` is on crates.io as 0.2.2, last updated 2025-10-22 — it lags
  the repo **[verified: crates.io API]**.
- `gpui_wgpu` is **not on crates.io** at all **[verified]**. Using the
  wgpu renderer means a git dependency on the whole zed repo.
- The crate ships examples (`animation.rs`, `data_table.rs`,
  `drag_drop.rs`, `gradient.rs`, …) **[verified:
  `crates/gpui/examples`]**, so it is not purely Zed-internal.
- No API stability promise; Zed develops it for Zed first **[inferred]**.
- The `gpui.rs` website could not be fetched from this container (403);
  not verified.

**gpui-base / gpui-component (Longbridge):** both live in
`longbridge/gpui-component`, Apache-2.0, active (pushed 2026-08-16,
12.8k stars). `gpui-component` 0.5.1 released 2026-02-05;
`gpui-base` 0.1.0 released 2026-08-11 **[verified: crates.io +
GitHub API]**. They inherit GPUI's platform story unchanged: on macOS
they render through Metal, not WebGPU **[inferred: they call GPUI]**.
Note: GPUI's rendering input is a `Scene` type (paths, shadows,
sprites — a display list in all but name **[verified:
`gpui/src/scene.rs`]**), which is architecturally close to our
`DisplayList`. But `Scene` is a Rust type with no C ABI.

**Driving GPUI from Dart:** GPUI's API is closure- and entity-based
Rust (`AppContext`, `cx.spawn`, `Window` callbacks). There is no C ABI.
The only realistic shape is a Rust cdylib that owns the entire GPUI app
and exposes a small message-passing surface to Dart. That inverts the
project: the UI lives in Rust, Dart becomes the host. Binding surface
would be large and unstable **[inferred]**.

**VERDICT: No — GPUI cannot be our WebGPU widget framework today.**
The wgpu path is real but Linux-only; macOS is baked to Metal and
Windows to DirectX; the renderer is not swappable without forking
platform crates; and the Dart binding cost is the highest of any
candidate. Revisit if Zed finishes the wgpu-everywhere migration —
`gpui_wgpu` existing at all says that is where they are going
**[inferred]**.

### 5.2 Missed candidates, verified

Searched systematically (GitHub topic/keyword search for "wgpu gui
framework" plus direct checks of every name suggested). The GitHub
search surfaced only small projects (<350 stars, most started in 2026)
**[verified]**. The established ones:

**Dear ImGui** (ocornut/imgui)
- `imgui_impl_wgpu` ships in the main repo **[verified:
  `backends/imgui_impl_wgpu.{h,cpp}`]**. It is written against the
  **standard `webgpu.h` C API** and requires exactly one of three
  defines: `IMGUI_IMPL_WEBGPU_BACKEND_DAWN`, `..._WGPU`
  (wgpu-native), or `..._WGVK` (a native Vulkan-based WebGPU, added
  2026-03, SPIR-V shaders) **[verified: header + changelog]**. Dawn
  support has been maintained since 2024-10 **[verified: changelog]**.
- It renders into a **caller-owned render pass**:
  `ImGui_ImplWGPU_RenderDrawData(ImDrawData*, WGPURenderPassEncoder)`,
  initialized with `ImGui_ImplWGPU_InitInfo { WGPUDevice,
  RenderTargetFormat, ... }` **[verified: header]**. So it renders
  into any texture on any device we create — it does not need to own
  the swapchain.
- Platform backend for **SDL3** exists (`imgui_impl_sdl3`)
  **[verified: backends listing]**.
- C ABI: the core has one via **cimgui** (MIT, active), which also
  wraps the SDL2/SDL3/GLFW/OpenGL/Vulkan backends — but **not** the
  wgpu backend **[verified: `cimgui_impl.h` defines list — no
  `CIMGUI_USE_WGPU`]**. We would write a ~50–100 line C shim over
  `ImGui_ImplWGPU_*` and link it beside cimgui **[inferred: size]**.
- Immediate mode. MIT. Very active: v1.92.9b released 2026-07-31
  **[verified: releases API]**. Small: core+backends compile to a few
  hundred KB **[inferred]**.
- Text: rasterizes glyphs itself (stb_truetype by default, FreeType
  optional, dynamic font atlas added recently). No complex-script
  shaping **[inferred from docs/features]**.

**egui** (emilk/egui)
- `egui-wgpu` is an official crate, "bindings for using egui natively
  using the wgpu library", 0.36.1 released 2026-08-07 **[verified:
  crates.io]**. Immediate mode. Rust only — no C API **[verified]**.
  Apache-2.0 (repo license) **[verified: GitHub API]**.
- Mature (used in production by Rerun and others), but for us it has
  the same cdylib-wrapper cost as every Rust option, on top of an
  immediate-mode model that duplicates what our own widget layer is
  for **[inferred]**.

**Floem** (lapce/floem)
- Retained-mode ("the view tree is constructed only once"), native
  Windows/macOS/Linux, GPU rendering through **wgpu** via `vger` or
  `vello`, plus an AnyRender Skia option and a `tiny-skia` CPU
  fallback **[verified: README]**. MIT **[verified]**.
- Maturing: README warns of "occasional breaking changes" pre-1.0
  **[verified]**. Last tagged release v0.2.0 in 2024-11; repo pushes
  through 2026-06 **[verified: GitHub API]** — alive, slow release
  cadence.
- No C API **[verified]**. Rust cdylib wrapper required.

**Dioxus / Blitz** (DioxusLabs/blitz)
- Blitz is an HTML/CSS rendering engine (Servo's Stylo for CSS) that
  renders via **Vello** (`blitz-renderer-vello`), with `blitz-shell`
  (winit) for native windowing; `dioxus-native` is the Dioxus frontend
  on top **[verified: README]**. Native desktop builds exist
  (Win/mac/Linux) **[verified]**.
- Beta: "usable for making apps if you are an early adopter", "many
  bugs and missing features" **[verified: README]**. Active (pushed
  2026-08-15). Apache-2.0/MIT dual, with one MPL-2.0 crate (stylo
  interop) **[verified]**. No C API **[verified]**.
- It is an HTML/CSS engine, not a widget toolkit — adopting it means
  writing UI in HTML/CSS, and Dioxus (RSX) for logic. Big departure
  from a Dart widget tree **[inferred]**. *(Update 2026-08-16: the
  renderer is now the `anyrender` crate family, not
  `blitz-renderer-vello`, and it includes a CPU renderer. Blitz became
  the pick — see §1 and §6 for the component plan.)*

**Vizia** (vizia/vizia) — **excluded.** The README says rendering
"leverages the powerful and robust skia library" — it moved off
femtovg to Skia **[verified: README]**. No native WebGPU backend of
its own (the WebGPU route would be the Skia-Graphite-Dawn build, §4).
MIT, 0.4.0 released 2026-04-23, pushed 2026-08-13 **[verified]**.

**Freya** (marc2332/freya) — **excluded.** Now "powered by Skia"
**[verified: repo description]**. Not WebGPU.

**RmlUi** (mikke89/RmlUi) — **excluded.** HTML/CSS C++ library, no
WebGPU backend found in its README **[verified: grep, absence]**.

Recalled from §4 (not re-researched): Slint (wgpu via
`renderer-femtovg-wgpu`, license problem), Xilem (Vello, experimental,
no releases), ThorVG (renderer with C API, on wgpu-native — Dart
bindings exist per earlier work in this thread, but not for the WebGPU
backend **[prior conversation, unverified this round]**), Skia
Graphite (Dawn, ~100 MB).

### 5.3 Comparison table

| Framework | Mode | Native desktop WebGPU? | Which impl | C ABI? | License | Last release | Size | Text shaping |
|---|---|---|---|---|---|---|---|---|
| **Dear ImGui** | immediate | yes | **Dawn, wgpu-native, or WGVK — pick at compile** | core via cimgui; wgpu backend needs ~50-line shim | MIT | v1.92.9b, 2026-07-31 | ~100s KB [inferred] | rasterization only, no shaping |
| **egui** | immediate | yes | wgpu | no — cdylib | Apache-2.0 | 0.36.1, 2026-08-07 | few MB [inferred] | none |
| **Floem** | **retained** | yes | wgpu (vger/vello) | no — cdylib | MIT | v0.2.0, 2024-11 (pushed 2026-06) | ~wgpu + renderer [inferred] | yes (own stack, unverified which) |
| **Blitz (Dioxus)** | retained (HTML/CSS) | yes | wgpu (Vello) | no — cdylib | Apache-2.0/MIT (+1 MPL crate) | none tagged; beta | large (Stylo) [inferred] | yes (browser-grade CSS text) |
| **GPUI** | retained | **Linux only** | wgpu (macOS=Metal, Windows=DirectX, baked) | no — closure-heavy Rust | Apache-2.0 | 0.2.2, 2025-10 (lags repo) | large [inferred] | yes (cosmic-text) |
| Slint | retained | yes (unstable feature) | wgpu (via FemtoVG) | C++ (skia/software only) | **GPLv3 / royalty-free / commercial** | v1.17.1, 2026-07-07 | few MB [inferred] | yes |
| Vizia | retained | **no** (Skia) | — | no | MIT | 0.4.0, 2026-04 | — | — |
| Freya | retained | **no** (Skia) | — | no | MIT | — | — | — |
| Xilem | retained | via Vello | wgpu | no | Apache-2.0 | none (experimental) | — | Parley |

### 5.4 Recommendation

**Split the answer by what "use a framework" means for us.**

**1. The pragmatic pick today: Dear ImGui on Dawn.**
It is the only candidate that satisfies every hard requirement at once:

- Native WebGPU on desktop, and it can sit on **Dawn — the same WebGPU
  implementation our compositor targets (§1)** **[verified]**. No other
  widget framework can (everything Rust is wgpu; Slint is wgpu; GPUI is
  Metal/DirectX outside Linux).
- It has a C ABI story today: cimgui for the core, a ~50-line shim for
  `ImGui_ImplWGPU_*` **[verified cimgui gap; inferred shim size]**.
- It has an official **SDL3 platform backend** — the same SDL3 Flutter
  Zero already runs **[verified]**. Input plumbing is solved, not
  written.
- It renders into a caller-owned render pass on a device we create
  **[verified]**, so integration has two clean shapes:
  - **Same window:** the presenting side hands its Dawn device to
    ImGui; the ImGui pass encodes into the same swapchain texture
    after the host's pass, then present. Requires an exposed Dawn
    device — see open questions.
  - **In a texture:** ImGui renders to an offscreen texture, one
    readback, the host uploads and composites — the mode-b handoff of
    §1.2 **[verified pattern at the API level]**.
- MIT, tiny, fast, very actively maintained **[verified]**.

Costs, stated plainly: immediate mode (Nick's second choice), "dev
tool" visual identity out of the box, no complex-script shaping, and
the UI would be written against ImGui's retained-state immediate API
from Dart — which does **not** go through our `DisplayList` seam. It
replaces the widget layer for whatever surface uses it. Best fit: HUDs,
debug overlays, tool panels around a 3D viewport — the same niche
ImGui holds in every game engine **[inferred]**.

**2. The retained pick, if we accept the Rust wrapper: Floem.**
The only retained-mode, permissively-licensed, native-wgpu framework
that is a real toolkit (not a research project) **[verified]**. Costs:
Rust cdylib wrapper (~1–2 weeks **[inferred]**), wgpu stack — so no
sharing with a Dawn-based host, interop via buffer handoff only; pre-1.0
with breaking changes; releases lag (last tag Nov 2024). It owns its
window (winit), which the new requirements allow.

**3. GPUI: no.** See §5.1 verdict.

**4. If we want retained + WebGPU + library-grade and can wait:** watch
Slint's wgpu renderer stabilizing (license still blocks permissive use)
and Xilem shipping releases. Neither is usable for us today
**[verified statuses]**.

**5. wgpu vs Dawn, restated for this section.** Of everything checked,
exactly two widget-ish stacks can run on Dawn: Dear ImGui (compile-time
flag, standard `webgpu.h`) and Skia Graphite. Every Rust framework is
wgpu. So the coexistence story with a Dawn-based host is:

| Stack under the UI | Shares our Dawn device? | Interop path |
|---|---|---|
| ImGui on Dawn | yes — same implementation; the presenting side must hand over its device | same-pass or texture-composite (§5.4.1) |
| Anything on wgpu | no | RGBA8 buffer handoff (§1.2 mode b) |

The cheapest real unlock for tight coexistence is a presenting side
that exposes its Dawn `WGPUDevice`/queue through its API — our
compositor (§2.3) would offer exactly that. Then any Dawn-side UI layer
can encode directly on the same device and swapchain. Speculative until
swapchain mode lands (§6.6 B3) **[inferred]**.

**6. Impact on the plan.** What this section adds: (a) GPUI is out,
with evidence; (b) for an adopted framework rather than built widgets,
the shortlist was **Floem for retained** (accept the wrapper and the
wgpu split) or **Dear ImGui on Dawn for immediate** (cheapest binding,
the only Dawn-compatible option, SDL3 backend done) — and the deep-dive
then chose **Blitz** (§6): HTML/CSS rather than a Rust widget toolkit,
with a CPU renderer that keeps Dawn the only GPU stack. §4's conclusion
(Vello for a 2D-only renderer under a Dart canvas) stands as context.

## 6. Blitz + WebGPU: evidence, options, milestones

Nick's goal: an **HTML/CSS widget layer** running on a WebGPU backend.
Preferred implementation: **Dawn** — one GPU implementation in the
process; two different ones cannot share a GPU device (§4). §1–§3
specify the component; this section is its evidence base and its
option/milestone detail. Everything below was read from upstream source
on 2026-08-16 (shallow clone of `DioxusLabs/blitz`, plus the
`DioxusLabs/anyrender`, `linebender/vello`, `gfx-rs/wgpu`, and
`rust-windowing/winit` repos). Claims are **[verified]** (read from
source this round) or **[inferred]**.

### 6.1 Verified facts about Blitz

Blitz is an **HTML/CSS rendering engine** from the Dioxus project. It is not
a widget toolkit. You write the UI in HTML and CSS; layout, styling, text,
and painting all happen inside Blitz.

| Layer | What Blitz uses | Source |
|---|---|---|
| CSS | Servo's **stylo** 0.20 | workspace `Cargo.toml` **[verified]** |
| Layout | **Taffy** (DioxusLabs fork, pinned rev `864b4fd…`) via the `stylo_taffy` package; `blitz-dom` glues CSS results to it | **[verified]** |
| Text | **parley** 0.10 (shaping + layout) | **[verified]** |
| Paint | `blitz-paint` — "Paint a Blitz Document using anyrender" | **[verified]** |
| Renderer | **anyrender** 0.12 abstraction, with `anyrender_vello` 0.13 (GPU), `anyrender_vello_cpu` 0.15 (CPU), `anyrender_vello_hybrid` 0.9, `anyrender_skia` 0.10 | **[verified]** |
| GPU stack | **wgpu 29** (vello pins wgpu 29.0.3) | **[verified]** |
| Windowing | `blitz-shell` on **winit** | **[verified]** |

This corrects §5, which described Blitz's renderer as
`blitz-renderer-vello`; upstream has since moved to the anyrender crate
family **[verified]**. That change matters to us — it means Blitz now has a
pluggable renderer abstraction, including a **CPU renderer**.

State of the project:

- Version **0.3.0-beta.1** (`blitz` and `blitz-shell` on crates.io,
  published 2026-07-10); repo pushed 2026-08-15 **[verified]**. The README
  calls it beta: "many bugs and missing features" **[verified]**.
- License **Apache-2.0 OR MIT** at the repo root **[verified]**.
- Platforms: runnable builds shipped for **Windows / macOS / Linux /
  Android** — macOS is first-class **[verified: README downloads page]**.
- Size: the workspace `Cargo.lock` lists **897 packages** for the whole
  workspace (that includes their browser app and test suites). Our shim
  needs a subset, but stylo + taffy + parley + vello + wgpu dominate. Expect
  a linked library in the tens of MB **[inferred; count verified]**.
- **No C API.** There is no `extern "C"` anywhere in the packages or
  examples, and no cbindgen setup. Rust only, so a **Rust `cdylib` shim**
  is required for Dart FFI **[verified]**.

Three ways to drive Blitz, all verified from source:

1. **Headless, no window at all.** `examples/screenshot.rs`:
   `HtmlDocument::from_html(html, DocumentConfig { base_url, net_provider,
   viewport })` → `document.resolve(time)` → `paint_scene(scene, doc,
   scale, w, h, 0, 0)` → `render_to_buffer::<VelloCpuImageRenderer, _>(…)`
   → RGBA8 pixels → PNG **[verified]**. No window, no event loop, no winit.
2. **Offscreen GPU buffer.** `anyrender_vello`'s `VelloImageRenderer`
   creates its own `WGPUContext`, renders the scene with vello
   (`use_cpu: false`) into a storage texture, and copies the result into a
   CPU `Vec<u8>` via `render_to_vec(…)` **[verified]**. This is Blitz's GPU
   path into an ordinary byte buffer.
3. **Windowed.** `VelloWindowRenderer` + winit event loop
   (`BlitzApplication`, `WindowConfig`). The frame loop in `blitz-shell`'s
   `redraw()`: `doc.resolve(t)` → `paint_scene(...)` →
   `renderer.render(...)`, and it only requests another frame when the
   document `is_animating()` **[verified]** — a dirty-driven, not
   render-always, loop.

Input is decoupled from winit. `blitz-shell` converts winit events into
`UiEvent` values (`PointerMove` / `PointerUp` / `PointerDown` /
`PointerCancel` / `Wheel` / `KeyDown` / `KeyUp` / `Ime` /
`AppleStandardKeybinding`, from `blitz-traits`) and feeds them to
`doc.handle_ui_event(event)` **[verified]**. We can construct those events
ourselves. SDL3 → `UiEvent` is a small, boring translation table.

Two more verified details we rely on below:

- **Custom widgets can get the wgpu device.** The `wgpu_texture` example
  downcasts the renderer context to a `DeviceHandle` and renders its own
  wgpu pipeline into the Blitz scene **[verified]**. (This is how 3D
  content could someday be drawn *inside* an HTML page.)
- **Surfaces can come from raw handles.** Blitz's `WGPUContext::
  create_surface` takes wgpu's `SurfaceTarget`, which includes
  window-handle variants and an unsafe raw-handle variant
  (`SurfaceTargetUnsafe`) **[verified]**. On macOS, wgpu documents that
  surface creation must happen on the main thread **[verified]** — fine for
  us, everything already runs on the platform thread.

### 6.2 The Dawn verdict

The question: can Blitz render through **Dawn**, the same WebGPU
implementation our compositor targets (§1)? The chain, verified link
by link:

1. Blitz's GPU renderer is `anyrender_vello` → **vello** **[verified]**.
2. Vello uses **wgpu** for all GPU access. Its workspace pins
   `wgpu = 29.0.3` **[verified]**. There is no other GPU backend: the old
   custom HAL (`piet-gpu-hal`) was dropped in favor of wgpu, and the README
   states "using [`wgpu`] for GPU access" **[verified]**. `vello_cpu` is
   the CPU variant — not a Dawn path **[verified]**.
3. A search of vello's issues for "Dawn" returns **zero** results
   **[verified]**. No backend trait exists to swap in.
4. **wgpu itself has no Dawn backend.** Its `Cargo.toml` backend features
   are `dx12`, `metal`, `vulkan`, `gles`, `webgpu` (WASM-only), and
   `webgl` (WASM-only) **[verified]**. Nothing targets native Dawn.

**Verdict: "Blitz on Dawn" is not achievable today.** Not with a flag, not
with a small patch. Blitz's whole GPU path is compiled against wgpu's Rust
API (`Device`/`Queue`/`Texture` types), not against the standard
`webgpu.h` C API that Dawn and wgpu-native share. Porting vello to Dawn
would mean reimplementing vello's renderer.

What *is* achievable, stated plainly:

- **Blitz on wgpu** — the only native GPU path Blitz has.
- **Blitz on CPU** (`anyrender_vello_cpu`) — no GPU stack at all inside
  Blitz. The screenshot example uses exactly this **[verified]**. This is
  the interesting one for us: on the buffer-handoff path (option A below)
  the CPU renderer means **no second WebGPU stack in the process**.
  Dawn stays the only GPU stack **[inferred — the CPU renderer
  exists and is proven; its speed at our frame sizes is unmeasured]**.
- **A different UI stack on Dawn**: Dear ImGui's `imgui_impl_wgpu`
  compiled with `IMGUI_IMPL_WEBGPU_BACKEND_DAWN` (§5), or Skia Graphite
  (§4). If sharing a host's Dawn device ever becomes the hard
  requirement, Blitz is the wrong tool and ImGui is the cheap answer.

So the real choice for Blitz is: **CPU renderer + buffer handoff (one GPU
stack: Dawn)**, or **wgpu renderer (GPU quality, second WebGPU
stack, still a CPU copy to reach any host)**. Device sharing is impossible
in both — §4's conclusion stands.

### 6.3 Integration options

The two modes of §1.2 become three options once "who owns the window" is
decided.

#### Option A — render-target mode: composite into a host
*(recommended first — renders into an offscreen texture, works with any
host; the composite anatomy is §6.4)*

```
Dart (platform thread, every frame)
  ├─ window events → fz_blitz_dispatch(events[])          [cdylib]
  ├─ tick → fz_blitz_render(time_ms) → RGBA8 bytes         [cdylib:
  │        resolve(t) → paint_scene → render_to_buffer — CPU, no wgpu]
  └─ hand the UI to the host, weakest first:
       A1: host uploads the bytes as its own texture and composites
           them in an overlay pass   (no Dawn compositor needed at all)
       A2: our Dawn compositor renders the quad into an offscreen
           texture; the host samples that texture
           • host exposes a Dawn device → same device, shared texture,
             zero copies
           • no exposed device → our own device, one readback → host
             upload (same cost as A1 plus a GPU draw)
```

- **What we build:** the §2.1 cdylib + §2.2 bindings, always. Then A1
  costs nothing more — the host already knows how to sample a texture.
  A2 adds the §2.3 compositor in offscreen form.
- **Input:** §2.2. Hit-testing is Blitz's; the routing policy is Dart's.
- **Vsync / frame scheduling:** the host owns presentation entirely. The
  component is a pixel producer; the host's frame loop calls the shots.
- **The DisplayList seam:** Blitz does not go through it, and cannot — a
  `DisplayList` is a flat list of draw commands; HTML/CSS brings its own
  layout, styling, and retained DOM. Blitz sits **beside** the seam
  (§7). Dart-drawn UI can still use it in the same frame.
- **Interop reality:** no GPU interop needed. A1 is one CPU copy per
  frame. A2 is zero copies only if the host hands over its Dawn device;
  otherwise it is A1 plus a GPU draw **[inferred; both standard]**.
- **Costs:** the copy (800×600 RGBA8 ≈ 1.9 MB/frame; 4K ≈ 33 MB — fine
  at the first size, measure at the second), and layout + style + paint
  running on the platform thread. Stylo is a real CSS engine; per-frame
  cost for a realistic HUD is unknown **[inferred; measure in B2]**.

#### Option B — swapchain mode on the SDL3 window

The compositor draws the UI **directly into the Flutter Zero window**:
Dawn creates a surface from the window's raw handle and presents.

```
Dart (platform thread, every frame)
  ├─ window events → fz_blitz_dispatch(events[])
  ├─ tick → fz_blitz_present(time_ms)              [compositor:
  │        resolve → paint_scene → Dawn surface from the SDL3 window's
  │        native handle → draw quad → present (Fifo → vsync-paced)]
  └─ a host renderer CANNOT also present to this window — one
       presentation path per window. Either this window has no host 3D
       content, or the host composites offscreen and feeds the result
       back into the UI as a texture (an image/custom node) — the
       option A copy, paid in the other direction.
```

- **What we build:** option A's pieces plus surface creation
  (`fz_blitz_attach_surface(raw_window_handle, raw_display_handle)`),
  present, and resize (surface reconfigure + `set_viewport`).
- **Input:** identical to option A.
- **Vsync / frame scheduling:** presentation moves to the compositor.
  `Fifo` present blocks to vsync **[inferred]**; the Dart frame loop
  paces behind it.
- **The DisplayList seam:** replaced for this window, as in option A.
- **Interop reality:** if a host renderer is also in the process, its
  GPU stack and our Dawn device are separate — no shared devices, no
  shared swapchain (§4). This option is cleanest when the window is
  UI-only.
- **Plumbing risk:** the raw-handle surface. On macOS, GPU surface
  creation is main-thread-only in the toolkits we checked **[verified
  for wgpu's docs; inferred for Dawn]** — fine for us, everything runs on
  the platform thread. The handle itself has a wrinkle: our SDL3 code
  obtains a `CAMetalLayer` (`SDL_Metal_GetLayer`) **[verified]**, and
  whether Dawn's surface creation consumes a layer or wants the NSView
  is exactly the one-day spike B3 starts with **[inferred]**. On
  Linux/X11 the raw-handle path (window XID + display connection) is
  standard **[inferred]**.

#### Option C — the component owns its own window

Run a windowing layer inside the cdylib (Blitz's own shell does this
with winit): own window, own event loop, own surface.

```
cdylib: window event loop (winit via blitz-shell)
  ├─ own OS window, own Dawn surface, own vsync (RedrawRequested)
  └─ HTML/CSS UI lives entirely here
Dart: the rest of the app, its own window(s), unchanged
Link: message passing (Dart FFI → cdylib mailbox; cdylib → Dart via a
      NativeCallable / SendPort)
```

- **What we build:** the thinnest Rust of the three — blitz-shell
  already does window, input, and rendering **[verified, §6.1]**. We
  expose `fz_app_start(html)`, `fz_app_message(...)`, and a callback
  into Dart.
- **The blocker, verified:** **on macOS this cannot run in-process.**
  winit's macOS backend panics unless the event loop is created on the
  process main thread — `MainThreadMarker::new().expect("on macOS,
  `EventLoop` must be created on the main thread!")`
  (`winit-appkit/src/event_loop.rs:362`) **[verified]**. SDL3's macOS
  video backend has the same main-thread requirement **[verified:
  UI_BRAINSTORMING's SDL affinity writeup]**. Dart already runs on that
  thread. Two windowing toolkits cannot both own `NSApplication`.
  Variants:
  - **C-process:** run the UI as a **separate process**, talk over a
    pipe or socket, share nothing. Works, but input forwarding, window
    z-order, and lifecycle all become our problem, and there is no
    texture sharing across processes **[inferred]**.
  - **C-replace:** the component's window is the app window; SDL3 is
    dropped for it. Then a host renderer must composite offscreen and
    feed the UI as a texture — the wgpu-vs-Dawn device problem returns
    unless the host runs on our Dawn device **[inferred]**.
- **Vsync:** owned by the windowing layer; Dart's frame loop is not in
  the loop for that window at all.
- **The DisplayList seam:** untouched — separate window, separate
  everything.
- **Where it fits:** a second window (debugger, inspector, web-content
  panel) is the honest use case **[inferred]**.

### 6.4 Composite architecture: the UI layer over a host

How the overlay actually works in option A: a host renders its scene,
then composites the UI on top as **one textured quad with alpha
blending**. The pattern is general — any renderer that can sample a
texture and blend a fullscreen (or partial-screen) quad can host the
component's output.

```
Host renderer (any engine; something like thermion, or any other)
  ├─ pass 1: the host scene (3D or 2D) → rendered into the window / target
  └─ pass 2: UI overlay — a fullscreen quad whose material samples the
         UI texture (RGBA8), alpha-blended over pass 1's output
         (transparent UI pixels let the host scene show through)

UI texture contents (the component, option A):
  HTML/CSS DOM → resolve(t) → paint_scene → render_to_buffer
    → RGBA8 bytes (CPU, no wgpu) → upload (host's or compositor's
    texture) → sampled by the overlay quad
```

- **Alpha.** The overlay needs per-fragment alpha: the quad's material
  must sample the texture's alpha channel and blend, so transparent UI
  pixels show the host scene beneath **[verified pattern]**. The
  **multiply-factor gotcha**, worth naming because it silently breaks
  this overlay in stock material setups: many standard materials
  multiply the texture sample by a base-color factor whose default is
  *transparent black* `(0, 0, 0, 0)` — the fragment color becomes
  `texture × factor`, and every UI pixel renders as nothing. Set the
  factor to `(1, 1, 1, 1)` **[verified in one host engine's ubershader
  during bring-up; check yours]**.
- **Dirty-skip.** When nothing changed — no input event, no CSS
  animation — skip the re-render *and* the re-upload. The overlay just
  re-samples the resident texture, which is near-free; only the host's
  own scene keeps costing **[inferred: re-sampling an uploaded texture
  is cheap]**. The component's gate is §2.1's frame gating (Blitz's own
  `is_animating()` loop is the precedent **[verified, §6.1]**).
- **Input.** Window events arrive on the platform thread, translate to
  `UiEvent`, and go to `doc.handle_ui_event(...)` — same thread, no
  marshalling **[verified, §6.1]**. Hit-testing is Blitz's job, and it
  is DOM-aware: it knows which element is under the cursor (`:hover`,
  click targets). The hit-test surface exists:
  `Document::set_hover_to(x, y) -> bool`, `get_hover_node_id()`, and
  the event driver's `handle_pointer_move` returns the `NodeId` under
  the pointer **[verified in blitz-dom]**. Routing policy: the overlay
  owns the pointer while it is over interactive UI; otherwise the event
  falls through to the host scene **[inferred policy]**. One wrinkle:
  `handle_ui_event` returns nothing (unit type **[verified
  signature]**), so "did the UI consume this?" must come from a separate
  hover query the cdylib adds — small, but it is cdylib work, not free.
- **Sizing.** The UI texture is created at window size. On resize:
  recreate the texture (GPU textures are fixed-size; an upload cannot
  grow one), update the overlay quad if needed, and call
  `fz_blitz_set_viewport` **[inferred]**.
- **Perf profile.** One CPU copy per frame in A1 (bytes → host texture).
  Milestone B2 measures whether the CPU renderer holds 60 Hz. The
  fallback ladder, cheapest first: (1) re-render only when dirty — a
  static HUD skips nearly every frame; (2) smaller UI texture or
  partial uploads; (3) Blitz's wgpu GPU renderer — last resort, it
  breaks the single-GPU-stack property (§6.2) **[inferred ordering]**.
- **The GPU-drawn alternative, for contrast.** Drawing the UI directly
  on the GPU into the same swapchain (an ImGui-on-Dawn layer, §5, is
  the example) requires the presenting side to expose its Dawn device
  (and queue, and the swapchain's current texture) so the UI pass can
  encode *after* the host's pass, on the same device. With no exposed
  device, a second Dawn or wgpu instance cannot touch that swapchain —
  no device sharing between implementations (§4). The texture-quad
  route avoids the entire problem: it needs nothing from the host
  beyond "sample a texture and blend a quad."

### 6.5 Comparison

| | A: render target | B: swapchain on our window | C: own window |
|---|---|---|---|
| Window | host's (or none) | SDL3 (ours), presented by Dawn | the component's |
| Who presents | host | our Dawn compositor | the component's window layer |
| Host 3D under the UI | yes, any host | not on this window (or pay the copy inverted) | separate window |
| GPU stacks in process | host's + ours only in A2-no-share; A1 = host's only | ours (Dawn) + host's if any | ours (Dawn) |
| Copies per frame | 1 in A1; 0–1 in A2 | 0 if UI-only; 1–2 with host content | 0 between windows |
| macOS viable in-process | yes | probably (surface spike first) | **no** (winit main-thread panic) |
| New code | cdylib + bindings (A1 adds nothing) | + surface attach, present, resize | smallest Rust, biggest architecture |
| Event loop owner | host / Dart app | Dart app; present blocks | the component's |
| DisplayList seam | beside it (kept) | replaced for this window | untouched |

### 6.6 Milestones

Ordered; each produces a runnable thing. No external project is a
prerequisite. Estimates are for one engineer **[inferred]**.

1. **B1 — cdylib + Dart FFI spike (days, ~3–5).** The §2.1 ABI, CPU
   renderer, headless. A plain Dart script loads a small HTML/CSS file,
   renders it at t=0, writes a PNG. No window, no host. Exit criteria:
   bytes out, image correct. (Blitz's `screenshot` example is the
   reference — this milestone is mostly plumbing.)
2. **B2 — render-target mode with a trivial host composite (week 1).**
   Option A: feed B1's bytes to any host that can display a texture —
   start with the simplest thing available (a host overlay pass, or even
   an SDL3 texture blit for the spike). Add the event table (mouse +
   key first). Exit criteria: hover/click on HTML elements works over a
   host-drawn background; frame time recorded. This milestone answers
   whether the CPU renderer is fast enough (§6.7 question 1).
3. **B3 — swapchain mode on the SDL3 window (1–2 weeks).** Option B:
   the Dawn compositor presents to the SDL3 window's native handle.
   Start with the one-day macOS handle spike (layer vs NSView). Exit
   criteria: HTML/CSS UI owns the window at vsync pace; Dawn linked and
   the binary-size delta recorded.
4. **B4 — perf and dirty-region (week).** Implement §2.1's frame gating
   and §6.4's dirty-skip; measure CPU renderer cost at target sizes
   (800×600 and one large window); add partial uploads if the copy
   shows up in the profile. Exit criteria: numbers for §6.7's open
   questions, and a static UI at ~zero per-frame cost.
5. **B5 — hardening (1–2 weeks).** Resize, HiDPI scale changes, text
   input (IME), the consumed-event hover query, accessibility surface,
   a local-asset net provider, packaging (universal binaries, the
   native-assets build hook). Exit criteria: the component survives a
   resize and a HiDPI change without artifacts.

### 6.7 Risks and open questions

Risks:

- **Blitz is beta.** Its own README says many bugs and missing features;
  CSS coverage is tracked on their status page **[verified]**. We would
  be early adopters on a moving 0.x **[inferred]**.
- **Platform-thread cost.** Stylo + taffy + parley run inline on the
  calling thread. A big DOM or a heavy relayout can stall the app's
  event loop **[inferred; measure in B2]**.
- **The copy.** Option A pays one full-frame CPU copy per frame at every
  resolution **[verified pattern, unmeasured cost]**.
- **Binary size.** Even the CPU path brings stylo (a Servo component)
  and its dependency tree (§6.1's count). Adding Dawn for modes a/A2
  brings its static libraries too. "Small" is not the word for it
  **[inferred]**.
- **Build complexity.** A Rust cdylib in a native-assets build hook,
  plus Dawn linked beside it (C++ toolchain, static-lib quirks), with
  matching macOS universal binaries **[inferred]**.
- **Blitz on wgpu (if ever taken).** Second WebGPU stack, larger
  binary, a new class of driver-maturity issues **[inferred]**.

Open questions:

1. Is the CPU renderer fast enough at 800×600 for a HUD-sized DOM?
   (B2 measures this; it decides the whole GPU question.)
2. How complete is Blitz's CSS for our UI needs — flexbox, grid,
   position, transforms, overflow? Their status page tracks it; our
   layouts must be checked against it **[verified page exists]**.
3. Text quality: parley + swash on macOS — kerning, emoji, CJK.
   Untested by us **[inferred]**.
4. Accessibility: blitz-shell has an accesskit integration **[verified]** —
   can it survive without winit, driven from our cdylib? Unknown.
5. Networking: `DocumentConfig` takes a `net_provider`; for local assets
   we need a custom one. Whether Blitz's own net provider can be pointed
   at a local asset store is unverified **[verified the field exists]**.
6. Does the CPU renderer path pull in any hidden GPU dependency?
   (It should not — the headless example uses no GPU **[inferred from
   the example]**.)
7. macOS HiDPI: viewport scale vs. buffer size — does Blitz give us the
   physical-pixel buffer we want to upload?
8. Dawn surface creation from SDL3 handles: which handle does Dawn want
   on macOS — the `CAMetalLayer` or the NSView? And what are Dawn's
   thread rules for surface creation? (B3's opening spike.)
9. Dawn from Rust via `webgpu.h`, or a small C++ library? Both work on
   paper; the choice follows the build hook that ends up simpler
   **[inferred]**.
10. Present-mode behavior: does `Fifo` present block as expected on all
    three desktop platforms, and how does it interact with the host's
    own presentation when both exist (option B with host content)?

### 6.8 What this does to the rest of the plan

- **§4 and §5 are the research record that led here.** §4 established
  the two-implementations constraint and priced the renderers; §5
  reopened framework adoption with window ownership allowed and found
  the candidates. Blitz won (§6.1) — HTML/CSS, permissive license,
  active, and the only one with a proven headless CPU path.
- **Dawn is our compositor's API, not Blitz's backend.** Nothing in this
  plan moves toward Blitz-on-Dawn (impossible today, §6.2) nor toward
  device sharing. The day device sharing becomes a hard requirement, the
  answer is a host that exposes its Dawn device, or the Skia
  Graphite / ImGui-on-Dawn alternatives of §3.
- **§7 (the Dart-side seam) is unchanged in spirit:** the component sits
  beside it, not through it.

## 7. The Dart-side seam, and how the component relates

Our Dart examples established a clean seam before this proposal:
a recording `Canvas` produces a `DisplayList`; a `DisplayListExecutor`
walks it and issues real draw calls. The executor is the only thing
that knows what renderer is underneath. We have swapped executors for
real (SDL3's renderer; a Dart software rasterizer).

The component does **not** go through that seam, and cannot: a
`DisplayList` is a flat list of draw commands, while HTML/CSS brings its
own layout, styling, and retained DOM. The component's seam is one level
up — the **C ABI of §2.1**. Above it, Dart owns the app; below it,
Blitz owns HTML/CSS. The `DisplayList` path stays alive beside it for
Dart-drawn UI, and both can appear in one frame.

Two things to protect while this lands:

1. **Do not leak backend concepts upward.** No "Dawn texture" or "WGSL
   pipeline" above the C ABI; no "DOM node" above the Dart frontend's
   public API. Events and pixels cross the boundary; nothing else.
2. **Keep the host contract narrow.** Mode b's consumer is "a texture or
   an RGBA8 buffer." Anything more specific re-couples the component to
   one host — the thing this revision removed.

**First milestone: B1 (§6.6).** A Dart script loads HTML, renders one
frame headless, writes a PNG. It proves the cdylib boundary, the FFI
shape, and the CPU renderer, with no window and no host. Every later
decision (mode order, dirty gating, Dawn necessity) depends on its
numbers, so nothing bigger should be scheduled before it.

## 8. Risks, open questions, prototype order

§6.7 carries the Blitz-specific list. This section is the whole-plan
view.

### Risks

- **Dawn binary size and build.** Dawn's static libraries (Tint,
  abseil, platform glue) are the biggest unknown in modes a and A2.
  Mitigation: measure in B3 before committing to swapchain mode; A1
  needs no Dawn at all.
- **Blitz maturity and API churn.** 0.3.0-beta.1 with a pinned Taffy
  fork **[verified, §6.1]**; expect breaking changes on update.
- **Single-thread cost.** Everything runs on the platform thread
  (§2.1). A heavy page stalls the app loop. Mitigation: measure in B2;
  keep HUD-sized DOMs; cache layouts.
- **Two presentation paths (option B with host content).** Pacing a
  Dawn present against a host's present in one process is uncharted
  here; avoid by keeping option B windows UI-only **[inferred]**.
- **The copy at scale.** 4K buffers make A1's per-frame copy visible.
  Mitigation: dirty-skip first, partial uploads second (B4).

### Open questions

1. All ten from §6.7.
2. Does the component ever need multi-window (option C) on macOS, given
   the winit main-thread block makes in-process C impossible there
   **[verified, §6.3]**?
3. Whose Dawn device wins in A2 when a host exposes one — and does any
   host we care about actually expose one today? **[inferred: most
   don't; check per host]**
4. Is there a browser story? The cdylib is native; Blitz itself compiles
   to WASM, so a web variant of the frontend is conceivable but out of
   scope **[inferred]**.

### Prototype order

§6.6's B1–B5, in order. Each step produces a runnable thing and a
number; no step depends on any external project's artifact.

## Cross-references

- `RENDERING.md` — backend survey, WebGPU-era renderers, power/text
  costs, the recording-canvas architecture.
- `UI_BRAINSTORMING.md` — threading model and frame-scheduler seam; the
  SDL3 main-thread affinity writeup cited in §6.3.
- `UI_RENDERER_PLAN.md` — the Dart-canvas UI renderer plan; context for
  the DisplayList seam (§7).
- §4 candidate facts were read from each project's README, docs, or
  source on 2026-08-15: linebender/vello, femtovg/femtovg,
  makepad/makepad, iced-rs/iced, bevyengine/bevy (`bevy_render` +
  `bevy_text` Cargo.tomls), linebender/xilem, slint-ui/slint
  (backends-and-renderers docs + `api/rs/slint/Cargo.toml`),
  thorvg/thorvg, gfx-rs/wgpu-native, plus Skia's Graphite announcement
  and SkiaSharp's Graphite tracking issue.
- §5 facts were read on 2026-08-16 from the zed repo (sparse clone of
  `crates/gpui*` at `main`), ocornut/imgui `backends/imgui_impl_wgpu.*`
  and cimgui's `cimgui_impl.h`, lapce/floem and DioxusLabs/blitz
  READMEs, vizia/vizia and marc2332/freya repo descriptions, and the
  crates.io / GitHub releases APIs for version dates.
- §6 facts were read on 2026-08-16 from a shallow clone of
  DioxusLabs/blitz (workspace + packages' `Cargo.toml`s,
  `examples/screenshot.rs`, `examples/wgpu_texture/`, and
  `blitz-shell`'s `window.rs`/`event.rs`/`application.rs`), the
  DioxusLabs/anyrender repo (`anyrender_vello`'s image/window renderers,
  `wgpu_context/src/lib.rs`), linebender/vello (workspace `Cargo.toml`,
  README, issue search), gfx-rs/wgpu (`wgpu/Cargo.toml` features,
  `src/api/surface.rs` `SurfaceTarget`), and rust-windowing/winit
  (`winit-appkit/src/event_loop.rs`).

## Updating this plan

When B1 lands, replace §2.1's sketch with the ABI as actually built and
record the headless render time. When B2 lands, record the CPU renderer
frame cost at the test sizes and whether dirty-skip was needed. When B3
lands, record the Dawn binary-size delta, the macOS surface answer
(layer vs NSView), and the present-mode behavior. If the component is
abandoned, note why here — the C ABI of §2.1 is the seam that would let
a different HTML/CSS engine slot in without touching the Dart frontend.
