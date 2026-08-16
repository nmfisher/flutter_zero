# WebGPU rendering plan — one standalone component

A proposal for **one standalone component**: a WebGPU (Dawn) rendering
backend for **Blitz**, with a **Dart** frontend. The preferred pathway
renders Blitz's HTML/CSS **natively on the GPU through Dawn**: Blitz's
**Skia renderer** running on **Skia Graphite** compiled with **Dawn**.
The component draws into either (1) a swapchain — direct presentation to
a window surface — or (2) a view/texture render target that a host
renderer can composite — composited into something like thermion (or any
other renderer).

A CPU-rendered path (Blitz → RGBA8 bytes) stays in the plan as the first
milestone and the fallback, not the destination.

Companion to `RENDERING.md` (backend survey) and `UI_BRAINSTORMING.md`
(threading model). Those documents survey and ask; this one specifies one
component and prices it.

This is a proposal only. No code has been changed.

## TL;DR

- **The preferred pathway (§1.2):** HTML/CSS (Blitz) → Blitz's **Skia
  renderer** (`anyrender_skia`) → **skia-safe, forked** (+ a Dawn backend
  module) → **Skia Graphite** → **Dawn** (WebGPU) → a swapchain or an
  offscreen texture. HTML/CSS drawn on the GPU through one WebGPU
  implementation. Chrome ships this same Skia-Graphite-on-Dawn
  architecture **[verified, §6.2]**.
- **The fork is the price.** rust-skia exposes Graphite for Metal and
  Vulkan but has no Dawn support anywhere — no feature, no build flag, no
  bindings **[verified, §6.2]**. We fork it, add a `dawn` module next to
  `graphite/mtl.rs`, and turn on Skia's `skia_use_dawn` build flag. Skia
  + Dawn is a large build (~100 MB class) and the fork needs maintenance
  **[verified §4; inferred §6.7]**.
- **The stepping stone (M1, kept as fallback):** the same cdylib running
  Blitz's **CPU renderer** into an RGBA8 buffer. Fastest first runnable
  thing; it validates the cdylib and the Dart FFI with no Skia build at
  all.
- **Two target modes** (§1.2). **Swapchain mode**: the UI is presented
  directly to a window surface — an SDL3 window via its native handle.
  **Render-target mode**: the UI renders into an offscreen texture and a
  host composites it — something like thermion (or any other renderer).
- **The device story (§2.3):** the cdylib creates and owns a Dawn
  instance + device. In render-target mode it can instead take a
  **host-provided Dawn device** and render on the same device (zero
  copies); without one it renders on its own device and pays one
  readback. Sharing works only because both sides run Dawn — one
  implementation, one device handed over (§4).
- **Milestones M1–M7** (§6.6): cdylib + FFI spike (CPU) → Skia built with
  Graphite+Dawn → rust-skia fork + dawn module → Blitz's Skia renderer
  rendering through Graphite-Dawn → swapchain mode → render-target mode
  → perf + hardening. Each produces a runnable thing. No external
  project is a prerequisite.
- Known costs: the Skia+Dawn build and the fork (§6.7); Blitz is beta
  (0.3.0-beta.1); Blitz's Skia renderer is the less-travelled path — its
  image renderer is CPU today, and nobody runs it on Graphite-Dawn yet
  **[verified, §6.2]**.

## 1. The component

One standalone component. It does not depend on any particular 3D engine
or host renderer. Three parts, two target modes.

### 1.1 The three parts

1. **Blitz, inside a Rust cdylib.** Blitz turns HTML/CSS into a scene:
   `HtmlDocument::from_html` → `resolve(t)` → `paint_scene` **[verified,
   §6.1]**. In the preferred pathway that scene is painted by Blitz's
   **Skia renderer** (`anyrender_skia`), which draws through a plain
   Skia `Canvas` **[verified, §6.2]**. In the stepping stone the same
   scene is painted by the CPU renderer into an RGBA8 buffer. The cdylib
   wraps either and exposes one small C ABI (§2.1).
2. **A Dart frontend.** Dart owns the app: it creates the engine, loads
   HTML/CSS, dispatches input, requests frames, and receives the output.
   Plain FFI over ~eight functions (§2.2). Unchanged by the pathway
   choice.
3. **The Dawn layer.** A Dawn instance and device, plus the forked
   skia-safe. Skia Graphite does the actual drawing — in the preferred
   pathway we write no UI renderer of our own. A tiny quad compositor of
   ours exists only in the CPU fallback, where there are plain pixels to
   blit **[inferred]**.

### 1.2 The pathway and the two target modes

```
              ┌─────────────────────────────────────────────────────┐
              │     the component (one cdylib + Dart bindings)      │
              │                                                     │
 window events│  Dart frontend (owns the app)                       │
 (same thread)│    │ FFI: create / load_html / dispatch / render    │
              │    ▼                                                 │
              │  Blitz (HTML/CSS → DOM → layout → paint scene)      │
              │    │                                                │
              │    ▼                                                │
              │  anyrender skia renderer — paints a plain Skia      │
              │  Canvas   (stepping stone: CPU renderer → RGBA8     │
              │  bytes instead, same cdylib, same ABI)              │
              │    │                                                │
              │    ▼                                                │
              │  skia-safe, forked (+dawn module)                   │
              │    │                                                │
              │    ▼                                                │
              │  Skia Graphite (GPU backend) → Dawn (WebGPU)        │
              │  Dawn instance + device: ours, or a host's          │
              └─────────────┬──────────────────┬────────────────────┘
                            │                  │
          MODE a: SWAPCHAIN │                  │ MODE b: RENDER TARGET
                            ▼                  ▼
              present to the window      offscreen texture → a host
              surface (SDL3 window's    renderer composites it —
              native handle); the UI    something like thermion, or
              is the window content    any renderer; or one readback
                                        → host upload
```

- **Mode a — swapchain.** The cdylib creates a Dawn surface from the
  window's native handle — an SDL3 window, or a window the component
  owns — Skia renders into the swapchain texture, Dawn presents. The UI
  *is* the window content. Options B and C in §6.3.
- **Mode b — render target.** Skia renders into an offscreen texture. A
  host renderer composites that texture into its own frame — composited
  into something like thermion (or any other renderer). Interop reality
  in brief: if the host exposes its Dawn device, the cdylib renders on
  the **same device** and hands over a texture (no copies); if not, it
  renders on its own device and the pixels cross once through the CPU
  (readback → host upload) **[inferred: both are standard patterns;
  neither is built yet]**. The minimal fallback needs no GPU at all: the
  CPU renderer's bytes, uploaded by the host itself (option A1, §6.3).

### 1.3 The Dawn reality, stated plainly

- Blitz's default GPU renderer is **Vello on wgpu**. There is no
  Vello/Dawn path, and wgpu has no Dawn backend **[verified, §6.2]**.
  So "Blitz on Dawn" can never mean Vello.
- But Blitz also ships a **Skia renderer**, and Skia reaches Dawn.
  Skia's **Graphite** GPU backend runs on Dawn — Chrome's production
  architecture — and Skia's build gates it behind `skia_use_dawn`
  **[verified, §6.2]**. `anyrender_skia` paints through a plain Skia
  `Canvas` **[verified]**, so a Graphite-Dawn-backed surface can replace
  today's CPU surface without touching the painting code.
- **rust-skia has no Dawn support** — not in its features, its build
  script, or its source **[verified, §6.2]**. Graphite is exposed for
  Metal (`graphite/mtl.rs`) and Vulkan (`graphite/vk.rs`). So the
  pathway needs a **fork**: one new `dawn` module parallel to `mtl.rs`,
  plus build support for `skia_use_dawn`.
- This keeps **Dawn the only GPU implementation in the process** — no
  wgpu, no second WebGPU stack (§4 explains why two cannot share a
  device).
- The CPU bridge (M1) stays as the fallback: proven headless, no build
  risk, one CPU copy per frame **[verified, §6.1]**.

Related work, context only: Dawn desktop build scaffolding (macOS/Linux
CI, static-library linking rules) has already been worked out in another
project (thermion's `asb/webgpu` branch) **[verified]**. Useful prior art
for §2.3's build questions; not a dependency, and nothing below requires
it.

## 2. What we build

### 2.1 The Rust cdylib — Blitz engine + C ABI

Blitz has no C API **[verified, §6.1]**, so the cdylib is the boundary.
Sketch of the whole ABI (~400–800 lines of Rust **[inferred]**):

```c
typedef struct fz_blitz_t fz_blitz_t;

enum { FZ_BACKEND_CPU = 0, FZ_BACKEND_SKIA_DAWN = 1 };

fz_blitz_t*    fz_blitz_create(int width, int height, float hidpi_scale,
                               int backend);
void           fz_blitz_load_html(fz_blitz_t*, const char* html,
                                  const char* base_url);
void           fz_blitz_set_viewport(fz_blitz_t*, int width, int height,
                                     float hidpi_scale);
void           fz_blitz_dispatch(fz_blitz_t*, const fz_blitz_event_t* events,
                                 int count);

/* CPU backend: render, return borrowed RGBA8 bytes. */
const uint8_t* fz_blitz_render(fz_blitz_t*, double time_ms,
                               int* out_w, int* out_h);

/* Skia-Dawn backend: render on the GPU, then present or export. */
void           fz_blitz_attach_surface(fz_blitz_t*,
                                       void* raw_window_handle,
                                       void* raw_display_handle);
void           fz_blitz_set_host_device(fz_blitz_t*, void* wgpu_device);
void           fz_blitz_render_frame(fz_blitz_t*, double time_ms);
const uint8_t* fz_blitz_readback(fz_blitz_t*, int* out_w, int* out_h);

void           fz_blitz_destroy(fz_blitz_t*);
```

- **Backend choice at create.** CPU first (M1); Skia-Dawn once the fork
  lands (M4+). The rest of the ABI is the same either way — that is the
  point of the seam.
- **Threading is trivial.** Everything is called from one thread — the
  Dart platform thread — like every other FFI call the app makes. No
  winit, no event loop inside the cdylib: input arrives as data
  (`fz_blitz_event_t` → Blitz's `UiEvent`, a boring translation table)
  **[verified: `UiEvent` is Blitz's input boundary, §6.1]**.
- **Frame gating.** Re-render only when something changed — an event
  arrived, or an animation is running. Blitz's own shell does exactly
  this (`is_animating()` gate) **[verified, §6.1]**.
- **Sizing.** `fz_blitz_set_viewport` on window resize; the surface or
  buffer follows the window.

### 2.2 The Dart frontend

- Eight to ten functions: hand-written FFI lookups are fine; `ffigen`
  optional. Days of work **[inferred]**.
- Dart owns the app and the frame loop: poll window events →
  `fz_blitz_dispatch` → the render call → present, export, or hand off
  bytes, depending on backend and mode.
- **Input routing.** Window events become `fz_blitz_event_t` values.
  Hit-testing and hover are Blitz's job — DOM-aware, it knows which
  element is under the cursor **[verified, §6.4]**. The routing policy —
  the UI owns the pointer over interactive elements, events fall through
  to the host scene elsewhere — is Dart's choice **[inferred]**.

### 2.3 The Dawn layer (and where our own compositor went)

- **Device story.** The cdylib creates and owns a Dawn instance and
  device — the default in swapchain mode. In render-target mode it can
  instead take a **host-provided Dawn device**
  (`fz_blitz_set_host_device`): Skia Graphite accepts a client-created
  Dawn instance/device/queue (`DawnBackendContext`, §6.2), so the UI
  renders on the host's device into a texture the host samples — zero
  copies **[verified the Skia entry point exists]**. Without a host
  device, the cdylib uses its own and pays one readback per frame.
  Honest interop note: this sharing works because both sides run **the
  same implementation (Dawn) and share one device object**; two
  separately created devices — even both Dawn — still cannot share
  textures **[inferred from §4]**.
- **Where the drawing happens.** Skia Graphite renders the scene. A quad
  compositor of our own — a textured quad, a blend state, a WGSL shader
  of tens of lines — survives **only in the CPU fallback**, where the
  cdylib's bytes must be drawn to a GPU target **[inferred]**. In the
  preferred pathway we write no shader at all.
- **Mode a plumbing:** create the Dawn surface from the window's native
  handle — on macOS the handle SDL3 exposes (`SDL_Metal_GetLayer`), on
  Linux the X11 window + display, on Windows the HWND **[verified SDL3
  exposes these handles; whether Dawn consumes the layer or wants the
  NSView needs a one-day spike — inferred]**. Present in `Fifo` mode so
  frames pace to vsync **[inferred]**.
- **Mode b plumbing:** an offscreen `RGBA8_UNORM` texture with
  `RENDER_ATTACHMENT` (and `COPY_SRC` when a readback path is wanted).
- **Resize:** recreate surface or texture, call `fz_blitz_set_viewport`.
- **Build cost:** Skia with Graphite+Dawn is the ~100 MB-class build of
  §4, on top of Dawn's own static libraries. rust-skia's prebuilt
  binary cache will have nothing for a forked feature set, so expect
  source builds in CI **[inferred]**. Measure in M2.

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
| **Blitz Skia renderer on Graphite-Dawn** (forked skia-safe) — this plan | 1 (Dawn) | browser-grade CSS: stylo + taffy + parley **[verified §6.1]**, drawn by Skia's GPU raster | Skia+Dawn build (~100 MB class **[verified §4]**) + a rust-skia fork (one module + build flags) | **preferred** — HTML/CSS natively on the GPU, one WebGPU stack |
| Blitz CPU renderer + our Dawn quad compositor | 1 (Dawn) | same CSS; CPU raster **[verified §6.1]** | Rust cdylib + a small quad renderer; no Skia build | **stepping stone (M1) and fallback** — fastest first runnable, one CPU copy per frame |
| Blitz GPU renderer (Vello on wgpu) | 2 (wgpu + host's), or 1 with no host | same CSS, GPU-quality AA | cdylib + wgpu | wgpu-split option — second WebGPU stack, still a copy to reach a host **[verified §6.2]** |
| Dear ImGui on Dawn | 1 (Dawn) | rasterized glyphs, no shaping **[verified §5]** | small: cimgui + ~50-line shim **[verified §5]** | immediate-mode alternative; no HTML/CSS |
| Hand-rolled WGSL UI renderer | 1 | ours to build (no CSS, no shaper) | 4–6 weeks | rebuilds what Blitz gives for free |

The choice follows the requirements: HTML/CSS authoring, retained mode,
Dawn as the only GPU implementation, Dart owns the app, permissively
licensed (Blitz is Apache-2.0 OR MIT **[verified, §6.1]**). The preferred
row satisfies all five and pays in build size and fork maintenance. The
stepping-stone row satisfies them too — minus GPU-quality rendering —
and pays almost nothing to start. That is why M1 runs on it before the
fork exists.

## 4. UI framework WebGPU backend research

Nick asked: of the frameworks listed in `RENDERING.md`, which ones really
support WebGPU, and could one of them be *the* unified WebGPU UI stack for
Flutter Zero, sitting beside a host 3D renderer? Each candidate was checked
against its upstream README, docs, or source on 2026-08-15. Facts below
are **[verified]** (read from the project's own repo/docs this round) or
**[inferred]** (our judgment, flagged as such).

### The key constraint first: two WebGPU implementations exist

- **Dawn** — Google's C++ WebGPU implementation: Chrome's, Skia
  Graphite's target, and the WebGPU implementation the component renders
  through (§1) **[verified: §4 Skia entry; RENDERING.md]**.
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
   is what the component does: Blitz's Skia renderer on Graphite-Dawn,
   with the CPU bridge as the no-GPU fallback (§1.3). It is impossible
   when the UI stack insists on wgpu and the host on
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
  the component renders through (§1). Dawn covers D3D12 (Windows), Vulkan
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
- Update (2026-08-16): this is no longer just the escape hatch. The
  component's preferred pathway now renders Blitz's HTML/CSS through
  Skia Graphite on Dawn — but via Blitz's Skia renderer and a forked
  rust-skia, not a hand-written C wrapper over Skia's canvas API (§1.3,
  §6.2).

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
`RENDERING.md` names. This section wrote it off as the escape hatch; the
component later adopted it as the preferred pathway — through Blitz's
Skia renderer on a forked rust-skia, which keeps HTML/CSS authoring and
avoids the hand-written canvas wrapper (§1.3, §6.2) **[inferred from
RENDERING.md's analysis + §6.2's verification]**.

**Correction to `RENDERING.md`:** Makepad is listed there as a wgpu
target; per its own README it is not. The WebGPU-framework shortlist is
effectively Iced, Bevy UI, Xilem, and Slint — and none of them fit
under our seam.

**Impact on this plan: the research record stands as context.** The
component (§1) later chose Blitz rather than a renderer under a Dart
canvas; §5 reopened the question with window ownership allowed. Vello +
Parley remains the named 2D-only GPU renderer on wgpu if that shape is
ever wanted — buffer-level first, GPU interop deferred until either
stack grows external-memory support. The preferred pathway then adopted
this section's Dawn-native pick: Blitz's Skia renderer on Graphite-Dawn
(§1.3), with Skia entering through Blitz instead of as a standalone
canvas API.

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
  `blitz-renderer-vello`, and it includes a CPU renderer and a Skia
  renderer. Blitz became the pick — first on the CPU renderer, now
  aimed at its Skia renderer on Graphite-Dawn; see §1 and §6.)*

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
| **Blitz (Dioxus)** | retained (HTML/CSS) | yes | wgpu (Vello) default; the Skia renderer can reach Dawn via a fork (§6.2) | no — cdylib | Apache-2.0/MIT (+1 MPL crate) | none tagged; beta | large (Stylo) [inferred] | yes (browser-grade CSS text) |
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
  implementation the component renders through (§1)** **[verified]**. No other
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
that exposes its Dawn `WGPUDevice`/queue through its API — our cdylib's
Dawn layer (§2.3) would offer exactly that. Then any Dawn-side UI layer
can encode directly on the same device and swapchain. Speculative until
swapchain mode lands (§6.6 M5) **[inferred]**.

**6. Impact on the plan.** What this section adds: (a) GPUI is out,
with evidence; (b) for an adopted framework rather than built widgets,
the shortlist was **Floem for retained** (accept the wrapper and the
wgpu split) or **Dear ImGui on Dawn for immediate** (cheapest binding,
the only Dawn-compatible option, SDL3 backend done) — and the deep-dive
then chose **Blitz** (§6): HTML/CSS rather than a Rust widget toolkit.
The CPU renderer kept Dawn the only GPU stack at first; the preferred
pathway now renders Blitz's Skia output on Graphite-Dawn (§1.3), which
makes Blitz itself the Dawn-compatible option this section was looking
for. §4's conclusion (Vello for a 2D-only renderer under a Dart canvas)
stands as context.

## 6. Blitz + WebGPU: evidence, options, milestones

Nick's goal: an **HTML/CSS widget layer** running on a WebGPU backend.
Preferred implementation: **Dawn** — one GPU implementation in the
process; two different ones cannot share a GPU device (§4). §1–§3
specify the component; this section is its evidence base and its
option/milestone detail. Everything below was read from upstream source
on 2026-08-16 (shallow clone of `DioxusLabs/blitz`, plus the
`DioxusLabs/anyrender`, `linebender/vello`, `gfx-rs/wgpu`,
`rust-windowing/winit`, `rust-skia/rust-skia`, and `google/skia`
repos). Claims are **[verified]** (read from
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
implementation the component targets (§1)? Two answers, because Blitz
has two GPU-capable renderers.

**Vello: no — verified, link by link.**

1. Blitz's default GPU renderer is `anyrender_vello` → **vello**
   **[verified]**.
2. Vello uses **wgpu** for all GPU access. Its workspace pins
   `wgpu = 29.0.3` **[verified]**. There is no other GPU backend: the old
   custom HAL (`piet-gpu-hal`) was dropped in favor of wgpu, and the
   README states "using [`wgpu`] for GPU access" **[verified]**.
   `vello_cpu` is the CPU variant — not a Dawn path **[verified]**.
3. A search of vello's issues for "Dawn" returns **zero** results
   **[verified]**. No backend trait exists to swap in.
4. **wgpu itself has no Dawn backend.** Its `Cargo.toml` backend features
   are `dx12`, `metal`, `vulkan`, `gles`, `webgpu` (WASM-only), and
   `webgl` (WASM-only) **[verified]**. Nothing targets native Dawn.

Vello is compiled against wgpu's Rust API (`Device`/`Queue`/`Texture`
types), not the standard `webgpu.h` C API that Dawn and wgpu-native
share. Porting vello to Dawn would mean reimplementing vello's renderer.

**Skia: yes — through a fork. This is the preferred pathway (§1).**

- Blitz's renderer list includes `anyrender_skia` 0.10 **[verified,
  §6.1]**. It uses the **stock `skia-safe` crate** — 0.97.0 (0.97.2 with
  `metal` on Apple), plus an optional `vulkan` feature. Not a fork
  **[verified]**.
- Its image renderer is **CPU raster today**: it wraps the caller's
  buffer with `surfaces::wrap_pixels(...)`, clears to transparent, and
  paints **[verified]**. But the painting goes through
  `SkiaScenePainter`, which draws with a plain `skia_safe::Canvas` —
  Paint, Path, Shader, ImageFilter, Font; no surface or GPU-context
  types of its own **[verified]**. Any Skia surface can back it,
  including a Graphite-Dawn one. The painting code is the compatible
  seam.
- Skia's **Graphite** backend has a first-class **Dawn** path: the
  public header `include/gpu/graphite/dawn/DawnBackendContext.h` holds a
  `wgpu::Instance`, `wgpu::Device`, and `wgpu::Queue` that the **client**
  creates, and `ContextFactory::MakeDawn(...)` builds the Graphite
  context from them; a full `src/gpu/graphite/dawn/` implementation sits
  under it **[verified]**. Skia's GN args make the relationship explicit:
  `skia_use_dawn` defaults to false, and
  `assert(!skia_use_dawn || skia_enable_graphite)` — Dawn is
  Graphite-only **[verified]**. Chrome ships Graphite on Dawn (§4)
  **[verified]**.
- **rust-skia has no Dawn support.** A search of the whole repo for
  "dawn" returns zero hits — no feature, no build flag, no bindings
  **[verified]**. What it does have, behind the `graphite` feature
  (part of `all-macos`/`all-linux`/`all-windows`, not the default):
  `skia-safe/src/graphite/` with `Context`/`Recorder`/`Recording`,
  Graphite surfaces and images, and two backend modules — `mtl.rs`
  (Metal, cfg `metal`) and `vk.rs` (Vulkan, cfg `vulkan`) — each with a
  `make_context` built from raw handles; plus examples
  (`graphite_offscreen.rs`, `graphite_offscreen_vulkan.rs`,
  `graphite_readback.rs`) **[verified]**. The build passes
  `skia_enable_graphite` when the feature is on **[verified]**.
- **The fork, then:** (1) build support — turn on `skia_use_dawn` in
  `skia-bindings`' build, next to the existing `skia_enable_graphite`
  arg, and fetch Dawn's source through Skia's dependency checkout;
  (2) bindings — wrap `DawnBackendContext`, `MakeDawn`, and a
  `BackendTexture` made from a Dawn `WGPUTexture`; (3)
  `skia-safe/src/graphite/dawn.rs`, parallel to `mtl.rs`, plus a `dawn`
  feature **[inferred: the work plan; each piece has a verified
  precedent in the same repo]**.

**Verdict, restated: "Blitz on Dawn" is achievable — through the Skia
renderer.** Not through Vello (wgpu-locked), but through `anyrender_skia`
on forked skia-safe with Graphite-Dawn. The costs: the Skia+Dawn build
(~100 MB class, §4), the fork's maintenance, and being first — nobody
runs `anyrender_skia` on Graphite-Dawn today, and its own image renderer
is CPU-only until we change it **[verified]**.

What is achievable, stated plainly:

- **Blitz's Skia renderer on Graphite-Dawn** — the preferred pathway.
  One GPU stack (Dawn); HTML/CSS drawn by Skia; same-device sharing with
  a Dawn-based host is possible because the Graphite context is made
  from a client-provided Dawn device.
- **Blitz on CPU** (`anyrender_vello_cpu`) — no GPU stack inside Blitz;
  proven headless (the screenshot example); our stepping stone and
  fallback **[verified]**.
- **Blitz on wgpu** (Vello) — GPU quality, but a second WebGPU stack
  that cannot share with Dawn, and still a CPU copy to reach a host.

Device sharing exists only on the first bullet, and only when one side
hands its Dawn device to the other (§4).

### 6.3 Integration options

The two modes of §1.2 become three options once "who owns the window" is
decided.

#### Option A — render-target mode: composite into a host
*(renders into an offscreen texture, works with any host; the composite
anatomy is §6.4)*

```
Dart (platform thread, every frame)
  ├─ window events → fz_blitz_dispatch(events[])          [cdylib]
  └─ tick → fz_blitz_render_frame(time_ms)          [cdylib: resolve(t)
         → paint_scene → Skia draws the scene on the GPU via Dawn]
       then hand the UI to the host, strongest first:
       GPU + host device: host exposes a Dawn device → Skia renders on
           that same device into a texture → host samples it
           (zero copies)
       GPU, no host device: our own Dawn device → offscreen texture →
           one readback → host upload
       A1 (CPU stepping stone / fallback): fz_blitz_render → RGBA8
           bytes → the host uploads them itself (no Dawn inside the
           component at all)
```

- **What we build:** the §2.1 cdylib + §2.2 bindings, always. The GPU
  lanes need the fork (M4); A1 needs nothing more — the host already
  knows how to sample a texture.
- **Input:** §2.2. Hit-testing is Blitz's; the routing policy is Dart's.
- **Vsync / frame scheduling:** the host owns presentation entirely. The
  component is a pixel producer; the host's frame loop calls the shots.
- **The DisplayList seam:** Blitz does not go through it, and cannot — a
  `DisplayList` is a flat list of draw commands; HTML/CSS brings its own
  layout, styling, and retained DOM. Blitz sits **beside** the seam
  (§7). Dart-drawn UI can still use it in the same frame.
- **Interop reality:** the zero-copy lane needs the host to hand over
  its Dawn device; without one, one readback per frame. A1 needs no GPU
  interop at all — one CPU copy per frame **[inferred; both standard]**.
- **Costs:** the readback copy (800×600 RGBA8 ≈ 1.9 MB/frame; 4K ≈
  33 MB — fine at the first size, measure at the second), and layout +
  style + paint running on the platform thread. Stylo is a real CSS
  engine; per-frame cost for a realistic HUD is unknown **[inferred;
  measure in M6]**.

#### Option B — swapchain mode on the SDL3 window

The component draws the UI **directly into the Flutter Zero window**:
Skia renders into a Dawn surface created from the window's raw handle,
and Dawn presents.

```
Dart (platform thread, every frame)
  ├─ window events → fz_blitz_dispatch(events[])
  ├─ tick → fz_blitz_render_frame(time_ms)         [cdylib: resolve →
  │        paint_scene → Skia renders into the Dawn swapchain texture
  │        (surface from the SDL3 window's native handle) → present
  │        (Fifo → vsync-paced)]
  └─ a host renderer CANNOT also present to this window — one
       presentation path per window. Either this window has no host 3D
       content, or the host composites offscreen and feeds the result
       back into the UI as a texture (an image/custom node) — the
       option A copy, paid in the other direction.
```

- **What we build:** option A's pieces plus surface creation
  (`fz_blitz_attach_surface(raw_window_handle, raw_display_handle)`),
  present, and resize (surface reconfigure + `set_viewport`). The
  drawing itself is Skia's — no compositor, no shader of ours.
- **Input:** identical to option A.
- **Vsync / frame scheduling:** presentation moves to the cdylib's Dawn
  layer. `Fifo` present blocks to vsync **[inferred]**; the Dart frame
  loop paces behind it.
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
  is exactly the one-day spike M5 starts with **[inferred]**. On
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
  preferred: HTML/CSS DOM → resolve(t) → paint_scene → Skia Graphite
    draws the scene on a Dawn device straight into the texture (the
    host's device, if it exposed one) → the overlay quad samples it
  fallback: paint_scene → CPU renderer → RGBA8 bytes → upload →
    sampled by the overlay quad
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
- **Perf profile.** The zero-copy lane (host device) pays no per-frame
  copy; the readback and CPU lanes pay one. M6 measures both lanes, and
  M7 adds the ladder, cheapest first: (1) re-render only when dirty — a
  static HUD skips nearly every frame; (2) smaller UI texture or
  partial uploads; (3) fall back to the CPU renderer — last resort for
  a broken build, and it keeps the single-GPU-stack property (§6.2)
  **[inferred ordering]**.
- **The GPU-drawn path is the destination.** With Graphite-Dawn the
  component draws the UI on the GPU itself (§1.2). On a host-owned
  swapchain this needs the presenting side to expose its Dawn device
  (and queue, and the swapchain's current texture) so Skia can render
  into it — the same-device story of §2.3. With no exposed device, a
  second Dawn or wgpu instance cannot touch that swapchain — no device
  sharing between implementations (§4). The texture-quad route with one
  readback avoids the entire problem: it needs nothing from the host
  beyond "sample a texture and blend a quad." (An ImGui-on-Dawn layer,
  §5, is the same shape with a different renderer.)

### 6.5 Comparison

| | A: render target | B: swapchain on our window | C: own window |
|---|---|---|---|
| Window | host's (or none) | SDL3 (ours), presented by Dawn | the component's |
| Who presents | host | Dawn (we call present) | the component's window layer |
| Host 3D under the UI | yes, any host | not on this window (or pay the copy inverted) | separate window |
| GPU stacks in process | one (Dawn) if the host shares its device or on A1; host's + ours otherwise | ours (Dawn) + host's if any | ours (Dawn) |
| Copies per frame | 0 same-device; 1 on readback or CPU | 0 if UI-only; 1–2 with host content | 0 between windows |
| macOS viable in-process | yes | probably (surface spike first) | **no** (winit main-thread panic) |
| New code | cdylib + bindings + the fork (GPU lanes); A1 adds nothing | + surface attach, present, resize | smallest Rust, biggest architecture |
| Event loop owner | host / Dart app | Dart app; present blocks | the component's |
| DisplayList seam | beside it (kept) | replaced for this window | untouched |

### 6.6 Milestones

Ordered; each produces a runnable thing. No external project is a
prerequisite. M1 is deliberately free of build risk; M2–M4 build the
Graphite-Dawn pathway; M5–M7 turn it into the two target modes and harden
it. Estimates are for one engineer **[inferred]**.

1. **M1 — cdylib + Dart FFI spike, CPU renderer (days, ~3–5).** The
   §2.1 ABI with `FZ_BACKEND_CPU`, headless. A plain Dart script loads a
   small HTML/CSS file, renders it at t=0, writes a PNG. No window, no
   host, no Skia build. Exit criteria: bytes out, image correct; the
   headless render time recorded. (Blitz's `screenshot` example is the
   reference — mostly plumbing.) This is the stepping stone: it validates
   the cdylib boundary and the FFI shape every later milestone reuses.
2. **M2 — Skia compiled with Graphite + Dawn (1–2 weeks).** Stand up the
   build before any Rust: check out Skia with its Dawn dependency, set
   the GN args (`skia_enable_graphite=true`, `skia_use_dawn=true`),
   produce a macOS artifact, and render something with it (a small C++
   tool is fine). Exit criteria: a Skia static library built with
   Graphite-Dawn on macOS; build time and artifact size recorded.
3. **M3 — rust-skia fork + dawn backend module (1–2 weeks).** Fork
   rust-skia at a skia-safe revision compatible with Blitz's pin (0.97.x
   today **[verified]**). Add the three pieces of §6.2: the
   `skia_use_dawn` build support, the C++ wrapper + bindgen for
   `DawnBackendContext`/`MakeDawn` and a `BackendTexture` from a
   `WGPUTexture`, and `skia-safe/src/graphite/dawn.rs` next to `mtl.rs`
   with a `dawn` feature. Exit criteria: a Rust example creates a Dawn
   device, makes a Graphite context, renders offscreen, reads back —
   the mirror of the existing `graphite_readback` example.
4. **M4 — Blitz's Skia renderer wired to the fork (~1 week).** Point
   `anyrender_skia` at the fork (a `[patch.crates-io]` redirect, or a
   small fork of that crate too) and swap its image renderer's surface
   from `surfaces::wrap_pixels` to a Graphite surface on a Dawn texture.
   The painter code does not change — that is the §6.2 seam. Exit
   criteria: one HTML/CSS frame rendered on the GPU through Dawn and
   read back correctly; frame time recorded next to M1's CPU number.
5. **M5 — swapchain mode on the SDL3 window (1–2 weeks).** Mode a: a
   Dawn surface from the SDL3 window's native handle; Skia renders into
   the swapchain texture; Dawn presents. Start with the one-day macOS
   handle spike (layer vs NSView). Add the event table (mouse + key
   first). Exit criteria: HTML/CSS UI owns the window at vsync pace;
   the Dawn + Skia binary-size delta recorded.
6. **M6 — render-target mode (week).** Mode b: an offscreen texture and
   a trivial host composite — any host that can display a texture, even
   an SDL3 texture blit for the spike. Both lanes: a host-provided Dawn
   device (same device, zero copies) and our own device (one readback).
   Exit criteria: hover/click on HTML elements works over a host-drawn
   background; both lanes measured.
7. **M7 — perf and hardening (1–2 weeks).** Dirty-region re-render and
   skip; resize and HiDPI scale changes; text input (IME); the
   consumed-event hover query; the accessibility surface; a local-asset
   net provider; packaging (universal binaries, the native-assets build
   hook, CI for the fork). Exit criteria: a static UI at ~zero per-frame
   cost; the component survives a resize and a HiDPI change.

### 6.7 Risks and open questions

Risks:

- **The Skia+Dawn build.** ~100 MB class, GN/ninja toolchain, Dawn's
  third-party dependencies. rust-skia's prebuilt binary cache has
  nothing for a forked feature set — every CI machine builds from
  source **[verified size class §4; inferred cache consequence]**.
- **Fork maintenance.** rust-skia tracks a fast-moving Skia, and Blitz
  pins skia-safe 0.97.x while the latest release is 0.99.0 **[verified]**.
  Rebases land on us. Mitigation: keep the fork to one module plus build
  flags, and try to upstream the dawn module **[inferred]**.
- **Blitz's Skia renderer is the less-travelled path.** Its image
  renderer is CPU-only today; the GPU backends it does have (Metal /
  OpenGL / Vulkan, via Ganesh) serve its window renderer. Nobody runs it
  on Graphite-Dawn **[verified]**. Feature parity with the Vello painter
  — filters, blend modes, masks — must be checked, not assumed
  **[inferred]**.
- **Blitz is beta.** Its own README says many bugs and missing features;
  CSS coverage is tracked on their status page **[verified]**. We would
  be early adopters on a moving 0.x **[inferred]**.
- **Platform-thread cost.** Stylo + taffy + parley run inline on the
  calling thread, and Skia records the scene there too. A big DOM or a
  heavy relayout can stall the app's event loop **[inferred; measure in
  M5]**.
- **The copy on the fallback lanes.** The CPU path and the no-host-device
  readback each pay one full-frame copy per frame **[verified pattern,
  unmeasured cost]**.
- **Binary size.** Skia + Dawn sit on top of Blitz's stylo tree (§6.1's
  package count). "Small" is not the word for it **[inferred]**.
- **Build complexity.** A Rust cdylib in a native-assets build hook,
  plus a forked skia-safe that compiles Skia + Dawn, with matching
  macOS universal binaries **[inferred]**.

Open questions:

1. Which rust-skia revision does the fork target — one close to
   Blitz's 0.97.x pin, or current master with a skia-safe upgrade on
   Blitz's side? (M3's first task.)
2. Does `SkiaScenePainter` cover everything Blitz's Vello painter
   covers — CSS filters, blend modes, masks? Test with a stress page in
   M4 **[verified the painter exists; parity unverified]**.
3. Does Graphite-Dawn on macOS (Dawn's Metal backend) render everything
   Blitz paints, at speed? (M4/M5 measure.)
4. Dawn surface creation from SDL3 handles: which handle does Dawn want
   on macOS — the `CAMetalLayer` or the NSView? And what are Dawn's
   thread rules for surface creation? (M5's opening spike.)
5. Present-mode behavior: does `Fifo` present block as expected on all
   three desktop platforms, and how does it interact with a host's own
   presentation in mode b? (M5/M6.)
6. Whose Dawn device wins in mode b when a host exposes one — and does
   any host we care about actually expose one today? **[inferred: most
   don't; check per host]**
7. Final binary size and CI build time for the cdylib (Skia + Dawn +
   the stylo tree). (M2 gives the first number; M7 the final one.)
8. Accessibility: blitz-shell has an accesskit integration **[verified]** —
   can it survive without winit, driven from our cdylib? Unknown.
9. Networking: `DocumentConfig` takes a `net_provider`; for local assets
   we need a custom one. Whether Blitz's own net provider can be pointed
   at a local asset store is unverified **[verified the field exists]**.
10. macOS HiDPI: viewport scale vs. buffer size — does Blitz give us the
    physical-pixel surface we want?
11. Is the CPU renderer fast enough to stay a credible fallback at
    800×600 for a HUD-sized DOM? (M1 records the first number.)

### 6.8 What this does to the rest of the plan

- **§4 and §5 are the research record that led here.** §4 established
  the two-implementations constraint and priced the renderers; §5
  reopened framework adoption with window ownership allowed and found
  the candidates. Blitz won (§6.1) — HTML/CSS, permissive license,
  active, and the only one with a proven headless CPU path. This
  revision then moved the destination: from the CPU bridge to Blitz's
  Skia renderer on Graphite-Dawn (§1.3). Skia entered the plan through
  Blitz's renderer, not as a standalone canvas API.
- **Dawn is now Blitz's backend, not just our layer's API.** The cdylib
  owns the Dawn instance and device; Skia Graphite draws on it; Vello
  stays out; wgpu stays out. Device sharing with a host remains the
  §2.3 story — one Dawn device, handed over.
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

**First milestone: M1 (§6.6).** A Dart script loads HTML, renders one
frame headless, writes a PNG. It proves the cdylib boundary, the FFI
shape, and the CPU fallback renderer, with no window, no host, and no
Skia build. Every later decision (dirty gating, lane choice, the CPU
renderer's credibility as fallback) depends on its numbers. M2, the
Skia+Dawn build, may start in parallel — it touches no Rust.

## 8. Risks, open questions, prototype order

§6.7 carries the Blitz-specific list. This section is the whole-plan
view.

### Risks

- **The Skia+Dawn build and the fork.** The biggest unknown in every
  GPU lane: a ~100 MB-class Skia build with Dawn's static libraries
  (Tint, abseil, platform glue), compiled from source because the fork
  defeats rust-skia's prebuilt cache, and a fork to rebase against two
  moving upstreams (rust-skia, Blitz's pins). Mitigation: M2 measures
  the build before M3/M4 commit to it; the fork stays at one module
  plus build flags. The CPU lane (A1) needs none of it.
- **Blitz maturity and API churn.** 0.3.0-beta.1 with a pinned Taffy
  fork **[verified, §6.1]**; expect breaking changes on update.
- **Single-thread cost.** Everything runs on the platform thread
  (§2.1). A heavy page stalls the app loop. Mitigation: measure in M5;
  keep HUD-sized DOMs; cache layouts.
- **Two presentation paths (option B with host content).** Pacing a
  Dawn present against a host's present in one process is uncharted
  here; avoid by keeping option B windows UI-only **[inferred]**.
- **The copy at scale.** 4K buffers make the readback lane's per-frame
  copy visible. Mitigation: prefer the same-device lane; dirty-skip
  first, partial uploads second (M7).

### Open questions

1. All of §6.7's.
2. Does the component ever need multi-window (option C) on macOS, given
   the winit main-thread block makes in-process C impossible there
   **[verified, §6.3]**?
3. Whose Dawn device wins in mode b when a host exposes one — and does
   any host we care about actually expose one today? **[inferred: most
   don't; check per host]**
4. Is there a browser story? The cdylib is native; Blitz itself compiles
   to WASM, so a web variant of the frontend is conceivable but out of
   scope **[inferred]**.

### Prototype order

§6.6's M1–M7, in order (M2 may run in parallel with M1 — it touches no
Rust). Each step produces a runnable thing and a number; no step depends
on any external project's artifact.

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
- §6.2's Skia-pathway facts were read on 2026-08-16 from the
  DioxusLabs/anyrender repo (`crates/anyrender_skia`: `Cargo.toml`,
  `src/image_renderer.rs`, `src/scene.rs`, `src/metal.rs`,
  `src/window_renderer.rs`), the rust-skia/rust-skia repo at `master`
  (repo tree search for "dawn" — zero hits; `skia-safe/Cargo.toml`
  features; `skia-safe/src/graphite.rs` + `graphite/mtl.rs`; the
  `graphite_offscreen*`/`graphite_readback` examples;
  `skia-bindings/Cargo.toml`; `skia-bindings/build_support/skia/
  config.rs`), the google/skia repo at `main`
  (`include/gpu/graphite/dawn/DawnBackendContext.h`;
  `src/gpu/graphite/dawn/` listing; `gn/skia.gni`'s `skia_use_dawn`
  and its Graphite-only assert), and crates.io (skia-safe 0.99.0
  latest release).

## Updating this plan

When M1 lands, replace §2.1's sketch with the ABI as actually built and
record the headless render time. When M2 lands, record the Skia
Graphite+Dawn build time and artifact size on macOS. When M3 lands,
record the fork's surface (base revision, module list) and whether it
can track Blitz's skia-safe pin. When M4 lands, record the GPU frame
time next to the CPU number and any painter parity gaps. When M5 lands,
record the Dawn + Skia binary-size delta, the macOS surface answer
(layer vs NSView), and the present-mode behavior. If the Graphite-Dawn
pathway is abandoned, note why here — the M1 CPU bridge remains as the
fallback component, and the C ABI of §2.1 is the seam that lets a
different HTML/CSS engine slot in without touching the Dart frontend.
