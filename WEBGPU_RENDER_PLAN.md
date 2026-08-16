# WebGPU rendering plan — a proposal

A proposal for rendering Flutter Zero through WebGPU instead of Metal (or
OpenGL/Vulkan). Companion to `RENDERING.md` (backend survey) and
`UI_RENDERER_PLAN.md` (the Filament-native UI renderer we are building).
Where those documents survey and commit, this one asks: is WebGPU the
right next backend, and what would it cost to find out?

This is a proposal only. No code has been changed.

## TL;DR

- The Thermion `asb/webgpu` branch (PR #242) already does the hard part of
  "Filament on WebGPU": Dawn build scaffolding for macOS and Linux, a
  `--webgpu` build flag, WebGPU (WGSL) variants of every built-in
  material, and a working engine-creation path through
  `WebGPUPlatformApple` / `WebGPUPlatformLinux`.
- The cheapest useful step for Flutter Zero is **Option A: run our
  existing examples on Thermion's WebGPU backend**. Same window, same
  scene, same UI architecture — one enum value and a build flag. That
  gets us a WebGPU swapchain on the SDL3 window and answers most open
  questions for the cost of about a week.
- **Option B** (skip Filament for 2D; drive Dawn or `wgpu-native`
  directly, e.g. Vello) is a bigger bet. It only pays off if we decide
  Filament is not the 2D answer, and it puts two WebGPU stacks in one
  process if Filament stays for 3D.
- **No full UI framework fits under our seam** (§4). Makepad has no
  WebGPU at all; Iced, Bevy UI, Xilem, and Slint are complete toolkits
  that would own the window and replace our Dart framework. The
  unified-WebGPU pick for a *renderer under the seam* is **Vello +
  Parley**, composed over Filament through the RGBA8 buffer path
  `thermion_ui` already runs.
- **If we adopt a whole widget framework instead** (window ownership
  allowed, §5): **GPUI is out** — its wgpu renderer is Linux-only;
  macOS is hard-wired to Metal, Windows to DirectX. The retained pick
  is **Floem** (wgpu, MIT, needs a Rust cdylib wrapper). The pragmatic
  pick is **Dear ImGui on Dawn** — the only widget stack that can sit
  on Filament's Dawn, has a C ABI (cimgui + small shim), and ships an
  SDL3 platform backend. Immediate mode, but everything else fits.
- **Recommended combination:** Filament-on-WebGPU as the single GPU stack
  (Option A, then Option C1), with the UI renderer from
  `UI_RENDERER_PLAN.md` compiled to WGSL instead of MSL/GLSL/SPIR-V.
  Vello remains the fallback if the Filament-native UI renderer hits its
  ceiling — and it can be adopted at the RGBA8-buffer level first
  (Option C2) without any GPU interop work.
- Known costs carried over from the Thermion branch: a blitter blending
  bug that breaks `readPixels` on float formats (workaround shipped, bug
  unfiled upstream), Dawn's binary size, async readback, and the usual
  text-shaping problem — WebGPU gives us WGSL, not HarfBuzz.

## 1. What already exists — facts from thermion `asb/webgpu`

Read from the branch itself (cloned at
`https://github.com/nmfisher/thermion`, branch `asb/webgpu`, PR #242
"feat(webgpu): WebGPU backend via Dawn, rebased onto v1.75.0").
Everything below is grounded in the diff; file paths are thermion's.

### Build scaffolding (macOS + Linux)

- `scripts/build_macos.sh` and `scripts/build_linux.sh` take a new
  `--webgpu` flag. It injects `-DFILAMENT_SUPPORTS_WEBGPU=ON` into
  Filament's own `build.sh` via `sed`, so Dawn is built as a Filament
  third-party subproject and the WebGPU backend lands in `libbackend.a`.
- Both scripts gained `copy_dawn_artifacts()`: it copies every `*.a`
  under `<build>/third_party/dawn` (Dawn produces many small static
  libs — `dawn_native`, `dawn_proc`, the Tint compiler stack, abseil)
  plus the webgpu headers from both the source tree
  (`include/webgpu/*`) and the generated tree
  (`gen/include/webgpu/*`) into the artifact directory.
- WebGPU builds are zipped with a `-webgpu` suffix so they never
  overwrite the canonical R2 artifact that normal builds download.
- `--upload` ships the zips to Cloudflare R2. `FILAMENT_VERSION=latest`
  resolves the newest `v*.*` tag on google/filament at build time.
- `.github/workflows/build-filament.yml` gains a `webgpu` workflow
  input (macOS and Linux jobs). The Linux job installs the full
  `libxcb-*` set for Dawn's X11 backend — "dri3, present, randr, sync,
  shape, xfixes, shm-fence and friends."

### Build hook and linking

- `thermion_dart/hook/build.dart` reads a `backend` user define
  (`native` / `webgpu` / `webgl2` / `hybrid`; legacy `webgpu: true`
  still works). `webgpu` downloads the `-webgpu` R2 artifact, compiles
  the `_webgpu` material variant, defines `THERMION_SUPPORTS_WEBGPU`,
  and links Dawn.
- Dawn linking notes, quoted from the hook's comments: link the
  `webgpu_dawn` **monolith** plus `abseil` only — the monolith already
  bundles `dawn_native`, `dawn_proc`, the Tint stack, and linking the
  granular archives beside it produces multiple-definition errors.
- Linux-specific: `-fno-rtti` (Filament's `libbackend.a` is built that
  way; RTTI-on subclasses get vtables referencing missing typeinfo and
  the `.so` fails to load) and `-Wl,--allow-multiple-definition` when
  WebGPU is on (Dawn's bundled SPIRV-Tools collides with filamat's).
  `imageio`/`tinyexr` are excluded on Linux until libc++-clean R2
  artifacts are published.

### Engine and swapchain

- `TBackend` gains `BACKEND_WEBGPU = 4` (`NOOP` moves to 5). Dart's
  `Backend` enum matches.
- `TEngine.cpp` creates `WebGPUPlatformApple` / `WebGPUPlatformLinux` /
  `WebGPUPlatformWindows` / `WebGPUPlatformAndroid` when
  `THERMION_SUPPORTS_WEBGPU` is defined and the WebGPU backend is
  requested, and stores the platform in a `g_webgpuPlatform` global so
  other translation units can reach the Dawn instance for event
  processing.
- Swapchain creation is unchanged: `Engine_createSwapChain(engine,
  window, flags)` passes the same native window handle the caller
  already supplies today. In `examples/thermion_ui` that handle is a
  `CAMetalLayer` from `SDL_Metal_GetLayer` on macOS and an X11 `Window`
  XID from `SDL_GetWindowProperties` on Linux. No SDL-side changes were
  needed in thermion — SDL3 has no WebGPU surface helper; the platform
  class wraps the raw handle.

### Materials as WGSL variants

- `materials/build.sh` now builds **four variants per material**:

  | Variant | matc flags | Use |
  |---|---|---|
  | `_native` | `-a opengl -a metal -a vulkan` | Metal/Vulkan/GL today |
  | `_webgpu` | `-a webgpu` | Native Dawn or WebGPU-only web |
  | `_web_webgl` | `-a opengl` | WebGL2-only web (smallest) |
  | `_web_combined` | `-a opengl -a webgpu` | Web dual-backend |

  All variants keep identical C symbols (`IMAGE_PACKAGE`,
  `IMAGE_IMAGE_DATA`, …). A forwarding header (`image.h`) picks the
  variant via `#ifdef THERMION_MATERIAL_*`. Only one `.c` is compiled —
  selected by the build hook (native) or `native/web/CMakeLists.txt`
  (web).
- `matc` itself must be built with `FILAMENT_SUPPORTS_WEBGPU=ON` to
  emit the webgpu target.

### Known gotchas (documented in the branch)

- **Blitter blending bug.** `docs/upstream.md` (new file, status
  "Unfiled") describes it precisely: `WebGPUBlitter::createRenderPipeline`
  enables blending unconditionally. On a non-blendable destination format
  (e.g. `RGBA32Float`) Dawn rejects the pipeline, the whole command
  encoder is invalidated, and anything queued on it — including the
  `CopyTextureToBuffer` for `readPixels` — is silently dropped. Result:
  all-zero pixels.
- **FLOAT→UBYTE workaround.** `FFIFilamentApp.capture()` detects
  `Backend.WEBGPU` + `PixelDataType.FLOAT` + headless swapchain
  (RGBA8Unorm) and forces `UBYTE` so the format-conversion blit never
  runs. Tests in `capture_tests_webgpu.dart` pin both paths.
- **readPixels needs recent Filament.** The test header notes Filament
  must be built "from main (post-v1.71.5)" for WebGPU `readPixels` to
  exist at all; the branch rebases onto v1.75.0.
- **Async readback.** WebGPU queues a GPU→CPU staging copy that only
  completes when Dawn processes events. Thermion handles this in
  `Engine_flushAndWait()` after `endFrame`; the `CaptureCallbackHandler`
  comment in `TRenderer.cpp` explains that on synchronous backends the
  callback fires inside `readPixels()`, on WebGPU it fires later.

### Web backend

- `native/web/CMakeLists.txt` adds `-sUSE_WEBGPU=1` and selects the
  material variant the same way (`THERMION_MATERIAL_VARIANT`, default
  `web_webgl`).
- `ThermionWebApi.cpp` adds `ThermionWebGPUPlatform`, a
  `WebGPUPlatform` subclass whose `createSurface()` builds a
  `wgpu::Surface` from a canvas selector — so the web build now offers
  WebGPU alongside WebGL2, with runtime selection via the `hybrid`
  material variant.
- A `WebGpu.isSupported()` check (navigator.gpu) gates it from Dart.

### Tests shipped on the branch

- `webgpu_smoke_test.dart` — `Backend.WEBGPU` engine create + teardown
  on Linux. Needs a Vulkan ICD; lavapipe (software) is fine headless.
- `capture_tests_webgpu.dart` — full beginFrame → render → readPixels →
  endFrame with the UBYTE and FLOAT-workaround paths.
- `_webgpu_asset_tests.dart` — skybox/gltf/bounding-box capture tests
  against the WebGPU backend.

**Net:** "Filament renders through Dawn on a native window" is built and
smoke-tested. What has *not* been proven (by thermion, on this branch):
a windowed WebGPU swapchain driven from an SDL3 window inside Flutter
Zero, and the WebGPU path on macOS end-to-end (the smoke/capture tests
are Linux-headless).

## 2. Options for WebGPU in Flutter Zero

### Option A — Thermion/Filament on its WebGPU (Dawn) backend

Keep the architecture exactly as `examples/thermion_ui` has it today:
SDL3 window → native handle → Filament SwapChain → 3D View + UI View.
Only the backend enum changes: Metal → WebGPU. The UI layer keeps
whatever executor it has (today: software rasterizer → RGBA8 texture →
composite View; tomorrow: the material-based renderer from
`UI_RENDERER_PLAN.md`).

**What changes in flutter_zero:**

| Area | Change |
|---|---|
| `examples/*/pubspec.yaml` | Point the `thermion_dart` git dependency at `asb/webgpu` instead of `develop`; add `hooks.user_defines.thermion_dart.backend: webgpu` (or legacy `webgpu: true`). |
| Example `main.dart`s | Pass `backend: Backend.WEBGPU` to `FFIFilamentApp.create()`. Window-handle acquisition code (`SDL_Metal_GetLayer` / X11 XID) stays as-is. |
| Our UI materials (`UI_RENDERER_PLAN.md` §2) | Compile with `matc -a webgpu` in addition to (or instead of) the native targets. Same `.mat` source; WGSL comes out. Follows thermion's variant/forwarding-header pattern. |
| CI / build | Either consume thermion's `-webgpu` R2 artifacts (macOS + Linux jobs exist behind a workflow input) or build Filament locally once with the thermion scripts. Nothing in flutter_zero's own engine code changes. |

**Effort:** ~1 week for macOS bring-up (artifact + enum + handle
verification + run all four examples); +2–4 days for Linux/X11; the UI
plan's phases are unchanged, only `matc` gains a flag.

**What WebGPU buys here:**

- One backend enum across macOS, Linux, Windows (thermion ships
  `WebGPUPlatformWindows`), and — through the separate emscripten path,
  not Dawn — the browser. Today we write per-platform handle code; with
  WebGPU the *shader* side also unifies (WGSL everywhere).
- A modern pipeline model (explicit command encoding, no implicit GL
  state), which is what Filament's newer backends are designed around.
- A single GPU stack: no Filament-on-Metal *plus* something-on-Vulkan
  juggling if we add Linux/Windows targets.
- The web option later: the same WGSL materials and the same UI code
  run under the `hybrid` web variant.

**What it costs:**

- Dawn in the binary. The `webgpu_dawn` monolith bundles Tint, abseil,
  and the platform glue. Expect the linked `.so`/`.dylib` to grow by
  tens of MB; exact number unknown until we link it (measure in the
  first milestone).
- The blitter/readPixels bug above (workaround exists; the underlying
  fix belongs upstream in Filament).
- Async readback semantics for anything that reads pixels (captures,
  picking, screenshot tests).
- Dawn maturity on Linux X11 (the CI dependency list shows how deep its
  XCB surface goes); Wayland unverified. Dawn on macOS runs over Metal,
  so it is the safest of the three.
- Power: an extra translation layer (WebGPU → Metal) that Flutter's
  direct-Metal path does not pay. Likely small; unmeasured.

### Option B — Direct Dawn (or wgpu-native) swapchain for 2D only

Drop Filament for the UI layer. Create a WebGPU surface on the SDL3
window ourselves and rasterize the DisplayList with either:

- **Vello via `wgpu-native`** (`RENDERING.md` tier 4): compute-shader
  2D, Parley text shaping bundled, ~3 weeks integration, brings a Rust
  toolchain. `wgpu-native` is a *different* WebGPU implementation than
  Dawn — if Filament (via Dawn) is also in the process for 3D, that is
  two full WebGPU stacks, `RENDERING.md`'s explicit warning.
- **Hand-rolled WGSL renderer**: essentially `UI_RENDERER_PLAN.md`
  re-targeted from Filament materials to raw WGSL pipelines — SDF
  rounded rect, gradient, glyph atlas quads — plus our own swapchain,
  surface, and command-buffer plumbing. 4–6 weeks, and we re-own
  everything Filament was giving us (command buffering, texture
  management, HDR/color config).

**What changes in flutter_zero:** a new package
(`packages/flutter_zero_ui/` or an example) with FFI bindings to
`wgpu-native` (or Dawn's C API), per-platform surface creation from SDL
window properties, a `WgpuDisplayListExecutor`, and — if Vello — a Rust
c-wrapper crate plus a native-assets build hook. All of it *below* the
existing `RecordingCanvas` seam; nothing above changes.

**Effort:** 3 weeks (Vello) to 6 weeks (hand-rolled) for a 2D-only
result — i.e. more than Option A costs for *less* rendered (no 3D).

**Buys:** the best-quality 2D of the surveyed options (Vello), the only
bundled text-shaping stack (Parley), no Filament dependency for UI.
**Costs:** two GPU stacks if 3D stays; Rust toolchain (Vello); we own
the swapchain; battery cost of compute-shader rendering on older
integrated GPUs.

Option B is only the right *next* move if we have already decided
Filament is the wrong 2D home. We have not — `UI_RENDERER_PLAN.md`
committed the other way, and the software-rasterizer executor in
`thermion_ui` was explicitly designed so the rasterizer body can be
swapped without touching Filament.

### Option C — Combinations

- **C1 (recommended destination): Filament-on-WebGPU for everything.**
  Option A, then build `UI_RENDERER_PLAN.md`'s UI materials as WGSL
  variants. One GPU stack, one shader language, one backend enum. The
  UI plan's phase list is unchanged; each `matc` invocation just gains
  `-a webgpu`. This is the "same scene/UI architecture as today" path.
- **C2 (quality upgrade, low risk): Vello as a *buffer* rasterizer.**
  Keep the exact `thermion_ui` pipeline — DisplayList → rasterizer →
  RGBA8 `Uint8List` → `Texture.setImage` → composite View — but replace
  the pure-Dart rasterizer body with Vello rendering into a buffer
  (`wgpu` render-to-texture + one GPU→CPU readback per frame). This
  gets Vello's AA/gradients/Parley text without any GPU interop, at the
  cost of a per-frame readback (fine at 800×600; measurable at 4K).
  Thermion's WebGPU branch proves the readback pattern works (their
  `readPixels` workaround is exactly a format-matched GPU→CPU copy).
- **C3 (later, unproven): zero-copy interop.** Vello renders into a
  `wgpu` texture that Filament imports directly (IOSurface / DMA-BUF /
  AHardwareBuffer external memory). Removes the readback but requires
  `wgpu-native` and Dawn to agree on external texture handles. Do not
  schedule this; note it and move on.

## 3. Option comparison

| | A: Filament WebGPU | B: Vello / hand-rolled on Dawn or wgpu | C1: A + WGSL UI materials | C2: Vello-in-a-buffer |
|---|---|---|---|---|
| Changes above the Canvas seam | none | none | none | none |
| New native deps | Dawn (via thermion artifact) | wgpu-native + Vello + Rust (or nothing but our own WGSL) | same as A | wgpu-native + Vello |
| GPU stacks in process | 1 | 2 (if Filament stays) | 1 | 2, but only one talks to the window |
| Effort to first pixel | ~1 week | 3–6 weeks | +days on top of A | ~2–3 weeks |
| Text shaping | still ours (stb_truetype v1) | Parley (Vello path) | still ours | Parley |
| readPixels / capture | workaround needed | our problem | workaround needed | our problem |
| Binary size | +Dawn (measure; tens of MB) | +wgpu (~5 MB) / ~0 hand-rolled | same as A | +wgpu |
| Browser story | yes (hybrid web variant) | yes (wgpu WASM) | yes | no (readback per frame) |

## 4. UI framework WebGPU backend research

Nick asked: of the frameworks listed in `RENDERING.md`, which ones really
support WebGPU, and could one of them be *the* unified WebGPU UI stack for
Flutter Zero, sitting next to Filament for 3D? Each candidate was checked
against its upstream README, docs, or source on 2026-08-15. Facts below
are **[verified]** (read from the project's own repo/docs this round) or
**[inferred]** (our judgment, flagged as such).

### The key constraint first: two WebGPU implementations exist

- **Dawn** — Google's C++ WebGPU implementation. This is what Filament's
  WebGPU backend uses. Thermion links Dawn's `webgpu_dawn` monolith
  statically into the same `.so` as Filament **[verified, §1]**.
- **wgpu** — the Rust implementation. On desktop, Rust UI projects use
  the `wgpu` crate, which compiles to its own GPU layer over
  Vulkan/Metal/D3D12. `wgpu-native` packages it as a C library exposing
  the standard `webgpu.h` header **[verified: gfx-rs/wgpu-native README —
  "a native WebGPU implementation in Rust... bindings are based on the
  WebGPU-native header"]**.

These two are **different stacks**. A wgpu device and a Dawn device in
one process cannot share textures, buffers, or a swapchain. There is no
standard way to pass GPU objects between them. So "UI framework on wgpu
next to Filament on Dawn" always means one of:

1. **Buffer handoff** — the UI renders into pixels, we copy the pixels to
   the other stack (CPU copy). This is exactly what `thermion_ui` does
   today with its software rasterizer. Slow-ish, but proven.
2. **External memory** — share the underlying OS buffer (IOSurface,
   DMA-BUF) between stacks. Possible in principle, unsupported by either
   stack's public API today. Slint's own issue #4499 shows they have not
   solved rendering into a foreign texture either **[verified: issue
   title "Feature Request: Adding Slint into a custom renderer",
   discussing dmabuf conversion as future work]**.
3. **One stack only** — everything on Dawn, or everything on wgpu. Not
   possible while Filament brings its own bundled Dawn **[inferred;
   unless Thermion exposed its Dawn `wgpu::Device`, which it does not
   today — verified: the device stays inside `WebGPUPlatform`]**.

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
  WebGPU, and no way to share a backend with Filament.

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
- Graphite's cross-platform GPU path is Dawn — the *same* WebGPU
  implementation Filament uses. Dawn covers D3D12 (Windows), Vulkan
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
- Same-implementation caveat: Filament bundles its *own* Dawn copy.
  Two statically-linked Dawn copies still create two separate devices —
  sharing a device would need a Thermion patch to expose its
  `wgpu::Device` **[inferred; nothing in the thermion branch exposes
  it — verified]**. And the cost is the known one: ~100 MB build,
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
| Skia Graphite | yes (Dawn) | yes | **Dawn (same as Filament)** | yes — HarfBuzz/ICU bundled | BSD | rolling (Chrome) | partial, old C subset | yes, but heaviest |

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
2. It coexists with Filament today, without GPU interop, through the
   path `thermion_ui` already runs: Vello renders into its texture, one
   GPU→CPU copy, upload to the Filament texture, composite View on top.
   That is option C2 from §2, now with a concrete renderer named. At
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
share a device with Filament's Dawn **[verified wgpu-native dependency;
shaping unverified]**. Worth a one-day spike if Vello's Rust wrapper
turns out to hurt.

**Skia Graphite is the only Dawn-native option**, so the only candidate
that could ever share a GPU device with Filament (after a Thermion
patch to expose the device). It also solves text completely. It loses
on size (~100 MB) and on the "we just rebuilt Flutter" problem
`RENDERING.md` names. Keep it as the escape hatch if quality demands
it, not the plan **[inferred from RENDERING.md's analysis]**.

**Correction to `RENDERING.md`:** Makepad is listed there as a wgpu
target; per its own README it is not. The WebGPU-framework shortlist is
effectively Iced, Bevy UI, Xilem, and Slint — and none of them fit
under our seam.

**Impact on this plan's recommendation: none at the top level.** §2's
sequencing stands: milestone 1 (Filament on Dawn), then C1 (WGSL UI
materials). What this research adds is a sharper C2: if the
hand-rolled UI renderer stalls, the named replacement is Vello + Parley
behind the existing executor interface — buffer-level first, per-frame
copy into the Filament texture, GPU interop deferred until either stack
grows external-memory support.

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
  from a Dart widget tree **[inferred]**.

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
  implementation Filament bundles** **[verified]**. No other widget
  framework can (everything Rust is wgpu; Slint is wgpu; GPUI is
  Metal/DirectX outside Linux).
- It has a C ABI story today: cimgui for the core, a ~50-line shim for
  `ImGui_ImplWGPU_*` **[verified cimgui gap; inferred shim size]**.
- It has an official **SDL3 platform backend** — the same SDL3 Flutter
  Zero already runs **[verified]**. Input plumbing is solved, not
  written.
- It renders into a caller-owned render pass on a device we create
  **[verified]**, so integration with Filament has two clean shapes:
  - **ImGui over Filament, same window:** Filament renders 3D to the
    swapchain, then an ImGui pass encodes into the same swapchain
    texture, then present. Requires exposing Filament's Dawn device
    (or a second Dawn device + external memory) — see open questions.
  - **ImGui in a texture, composited by Filament:** ImGui renders to
    an offscreen texture, one readback, upload as a Filament texture —
    the exact path `thermion_ui` already runs **[verified pattern]**.
- MIT, tiny, fast, very actively maintained **[verified]**.

Costs, stated plainly: immediate mode (Nick's second choice), "dev
tool" visual identity out of the box, no complex-script shaping, and
the UI would be written against ImGui's retained-state immediate API
from Dart — which does **not** go through our `DisplayList` seam. It
replaces the widget layer for whatever surface uses it. Best fit: HUDs,
debug overlays, tool panels around a Filament viewport — the same niche
ImGui holds in every game engine **[inferred]**.

**2. The retained pick, if we accept the Rust wrapper: Floem.**
The only retained-mode, permissively-licensed, native-wgpu framework
that is a real toolkit (not a research project) **[verified]**. Costs:
Rust cdylib wrapper (~1–2 weeks **[inferred]**), wgpu stack — so no
sharing with Filament's Dawn, interop via buffer handoff only; pre-1.0
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
wgpu. So the coexistence story with Filament is:

| Stack under the UI | Shares Filament's Dawn? | Interop path |
|---|---|---|
| ImGui on Dawn | same implementation, but Filament does not expose its device — second Dawn copy or Thermion patch | same-pass or texture-composite (§5.4.1) |
| Anything on wgpu | no | RGBA8 buffer handoff (proven in `thermion_ui`) |

The cheapest real unlock for tight coexistence would be a small
Thermion patch: export Filament's Dawn `WGPUDevice`/queue (or accept an
external one) through the C API. Then an ImGui-on-Dawn layer could
encode directly after Filament's pass on the same swapchain. That patch
is speculative until milestone 1 lands **[inferred]**.

**6. Impact on the plan's recommendation.** None at the top. Milestone
1 (Filament on Dawn) and C1 (WGSL UI materials) stay the path for the
*product* UI. What this section adds: (a) GPUI is out, with evidence;
(b) if Nick wants an adopted framework rather than built widgets, the
answer is **Floem for retained** (accept the wrapper and the wgpu
split) or **Dear ImGui on Dawn for immediate** (cheapest binding, only
Dawn-compatible option, SDL3 done). And the earlier conclusion in §4
stands for renderers under our seam: Vello remains the pick there.

## 6. The Canvas/DisplayList seam, and the first milestone

The seam is already right, and this is the main reason the proposal is
cheap. `RecordingCanvas` produces a `DisplayList`; a
`DisplayListExecutor` walks it (`examples/thermion_ui/lib/src/canvas.dart`).
The executor is the only thing that knows what GPU API is underneath.
We have already swapped it once for real: `sdl_ui` executes the same
command set through SDL3's renderer; `thermion_ui` executes it through a
Dart rasterizer into a Filament texture. Changing the GPU backend is
therefore *not* a Canvas change at all — it is a change inside the
executor and below (which Filament backend is compiled in; which matc
target the UI materials were built for). Widget code, scheduler, layout,
and the command vocabulary are untouched.

Two things to protect while this lands:

1. **Do not leak backend concepts into `DrawCommand`s.** Commands stay
   in pixel-space with colors and rects; "WGSL pipeline" or "wgpu
   texture" never appears above the executor interface.
2. **Compile UI materials for multiple targets even if only one runs.**
   Follow thermion's variant pattern (`_native` / `_webgpu`) from day
   one, so flipping the backend is a define, not a rebuild of the
   material library.

**First milestone: `thermion_ui` rendering through Dawn on macOS,
visually identical to today's Metal output.**

Concretely:

1. Build (or download) a `-webgpu` Filament artifact with thermion's
   scripts — the CI input exists for macOS and Linux.
2. Point `examples/thermion_ui/pubspec.yaml` at `nmfisher/thermion`
   `asb/webgpu`, set the `backend: webgpu` user define.
3. Pass `backend: Backend.WEBGPU` to `FFIFilamentApp.create()`; keep the
   existing `CAMetalLayer` handle and verify Filament's
   `WebGPUPlatformApple` accepts it as the surface source.
4. Run the existing demo: lit cube (3D View) + drifting HUD rects (UI
   View over the software-rasterized texture). Success = pixel-for-pixel
   parity with the Metal run, no warnings from Dawn validation.
5. Record three numbers: linked binary size delta, frame time, and
   whether `capture()` (readPixels UBYTE path) returns non-zero pixels.

That milestone answers — with running code — the surface question, the
size question, the readPixels question, and the perf question. Every
later decision (C1 vs C2, Linux timing, whether to keep Metal as the
default) depends on those answers, so nothing bigger should be
scheduled before it.

## 7. Risks, open questions, prototype order

### Risks

- **Dawn binary size.** The monolith plus abseil is the single biggest
  unknown. Mitigation: measure in milestone 1 before committing.
- **Upstream blitter bug.** Unfiled per `docs/upstream.md`. The UBYTE
  workaround covers headless captures; any future feature wanting float
  readback (HDR picking, HDRR screenshots) hits it. Action: file the
  upstream Filament issue with the branch's writeup.
- **Async readback semantics.** Any code that assumed `readPixels`
  returns data synchronously needs the flush-and-wait pattern. Our
  examples don't read pixels today; capture-based tests will.
- **Linux X11 depth.** Dawn's XCB dependency surface is large and
  driver-sensitive; Wayland is unverified in the branch. Keep Linux
  behind macOS in the sequence.
- **Power.** WebGPU-over-Metal adds a layer versus direct Metal. For a
  game-engine-shaped project this is probably acceptable; measure if
  battery becomes a pitch (see `RENDERING.md` §power).
- **Dawn maturity.** Dawn is Chrome's GPU stack, so it is far from
  toy-grade — but Filament's WebGPU backend is newer than its Metal
  one. Expect validation-strict bugs like the blitter one.
- **Thermion branch liquidity.** `asb/webgpu` is unmerged. Flutter Zero
  would track a branch, or we help merge it. The R2 `-webgpu` artifacts
  are opt-in CI outputs, not the canonical ones.

### Open questions

1. Does `WebGPUPlatformApple::createSurface` accept the exact
   `CAMetalLayer` we get from `SDL_Metal_GetLayer`? (Almost certainly —
   it is the same handle Metal backend consumes — but verify in
   milestone 1.)
2. Do the published `-webgpu` R2 zips include a `matc` built with
   `FILAMENT_SUPPORTS_WEBGPU=ON`, or do we need a local Filament build
   to compile our own UI materials to WGSL?
3. Window resize: does the WebGPU swapchain handle SDL resize events as
   cleanly as the Metal one? (Filament recreates swapchains; untested
   on WebGPU in our examples.)
4. Linux: X11 only, or is Wayland viable? (Thermion's example uses the
   X11 XID property.)
5. Does the `thermion_ui` dispose-skip (a known Thermion
   concurrent-modification bug on `develop`) reproduce on the webgpu
   branch?
6. Is the macOS frame pacing (vsync) behavior the same through Dawn as
   through Metal? Relevant once the scheduler cares about real vsync.

### Prototype order

1. **Engine smoke on macOS** — `FFIFilamentApp.create(backend:
   Backend.WEBGPU)` headless, thermion's smoke test ported. Days.
2. **Milestone 1 above** — windowed `thermion_ui` on Dawn, parity
   screenshot, size/perf numbers. ~1 week.
3. **Linux X11 repeat** of milestone 1 under xvfb + lavapipe, then real
   GPU. ~days.
4. **One WGSL UI material** — take `solid.mat` from
   `UI_RENDERER_PLAN.md` phase 1, compile `-a webgpu`, render one rect
   through the UI View on the WebGPU backend. Proves C1 end-to-end.
5. **Only if the Filament-native UI renderer stalls:** C2 spike —
   Vello rasterizing the DisplayList into the existing RGBA8 buffer,
   swapped in behind the same executor interface.

## Cross-references

- `RENDERING.md` — backend survey, WebGPU-era renderers, power/text
  costs, the recording-canvas architecture.
- `UI_RENDERER_PLAN.md` — the committed UI renderer this proposal
  re-targets at WGSL.
- `UI_BRAINSTORMING.md` — threading model and frame-scheduler seam.
- thermion `asb/webgpu` (PR #242) — everything in §1; `docs/upstream.md`
  on that branch is the canonical writeup of the blitter bug.
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

## Updating this plan

When milestone 1 lands, replace the effort estimates and open questions
in §7 with measured numbers, record the binary-size delta, and decide
C1 vs C2 based on whether the matc/WGSL path for our own materials
worked. If we abandon WebGPU, note why here — the same seam makes the
next backend swap just as cheap.
