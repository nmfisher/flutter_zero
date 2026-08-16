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
- **Blitz (HTML/CSS on WebGPU) cannot use Dawn** (§6). Its whole GPU path
  is vello → wgpu, and wgpu has no Dawn backend. But Blitz ships a CPU
  renderer (proven headless: HTML → RGBA8 bytes), so the recommended
  integration is **§6 option A: headless Blitz → RGBA8 buffer → Filament
  texture** — the exact handoff `thermion_ui` already runs, and with the
  CPU renderer there is still only one GPU stack in the process
  (Filament's Dawn). ~1–2 weeks to a composite HTML HUD over the lit cube.
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
  from a Dart widget tree **[inferred]**. *(Update 2026-08-16: the
  renderer is now the `anyrender` crate family, not
  `blitz-renderer-vello`, and it includes a CPU renderer. Blitz became
  Nick's pick for a deep-dive — see §6 for the full integration plan.)*

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

## 6. Blitz + WebGPU integration plan

Nick's goal: an **HTML/CSS widget layer** for Flutter Zero, running on a
WebGPU backend. Preferred implementation: **Dawn**, because Filament/thermion
bundles Dawn, and two different WebGPU implementations cannot share a GPU
device (§4). This section is the plan. Everything below was read from
upstream source on 2026-08-16 (shallow clone of `DioxusLabs/blitz`, plus the
`DioxusLabs/anyrender`, `linebender/vello`, `gfx-rs/wgpu`, and
`rust-windowing/winit` repos). Claims are **[verified]** (read from source
this round) or **[inferred]**.

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
implementation Filament bundles? The chain, verified link by link:

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
  Filament keeps Dawn as the only GPU stack **[inferred — the CPU renderer
  exists and is proven; its speed at our frame sizes is unmeasured]**.
- **A different UI stack on Dawn**: Dear ImGui's `imgui_impl_wgpu`
  compiled with `IMGUI_IMPL_WEBGPU_BACKEND_DAWN` (§5), or Skia Graphite
  (§4). If sharing a device with Filament ever becomes the hard
  requirement, Blitz is the wrong tool and ImGui is the cheap answer.

So the real choice for Blitz is: **CPU renderer + buffer handoff (one GPU
stack, Filament's Dawn)**, or **wgpu renderer (GPU quality, second WebGPU
stack, still a CPU copy to reach Filament)**. Device sharing is impossible
in both — §4's conclusion stands.

### 6.3 Integration options

#### Option A — headless Blitz → RGBA8 buffer → Filament texture
*(recommended first step; the composite anatomy — how the overlay View,
the swapchain, and the texture fit together — is §6.4)*

Same shape as the pipeline `thermion_ui` already runs: something produces
RGBA8 pixels, we upload them as a Filament texture, and composite the UI
View over the 3D View. Here, "something" is Blitz.

```
Dart (platform thread, every frame)
  ├─ SDL3 poll → translate events → blitz_dispatch(events[])   [Rust]
  │       Rust: doc.handle_ui_event(UiEvent)                    [verified API]
  ├─ FrameScheduler tick → blitz_render(time_ms) → RGBA8 bytes  [Rust]
  │       Rust: doc.resolve(t) → paint_scene(...) →
  │              render_to_buffer(VelloCpuImageRenderer)   — no wgpu at all
  │              or render_to_vec(VelloImageRenderer)      — wgpu offscreen
  │       (pointer returned is borrowed; copied into a Dart Uint8List)
  └─ Texture.setImage(bytes) → UI View (renderOrder 1) over 3D View →
     Filament endFrame — presentation and vsync unchanged
```

- **What we build:** a Rust `cdylib` exposing roughly this C ABI (sketch;
  ~300–600 lines of Rust **[inferred]**):

  ```c
  typedef struct blitz_engine_t blitz_engine_t;

  blitz_engine_t* blitz_create(int width, int height, float hidpi_scale,
                               int use_gpu);          /* 0 = vello_cpu */
  void  blitz_load_html(blitz_engine_t*, const char* html,
                        const char* base_url);
  void  blitz_set_viewport(blitz_engine_t*, int width, int height,
                           float hidpi_scale);
  void  blitz_dispatch(blitz_engine_t*, const blitz_event_t* events,
                       int count);   /* mouse, key, wheel, text */
  const uint8_t* blitz_render(blitz_engine_t*, double time_ms,
                              int* out_width, int* out_height);
  void  blitz_destroy(blitz_engine_t*);
  ```

  Dart side: `ffigen` over the header, or six hand-written FFI lookups —
  either is days **[inferred]**. Threading is trivial: everything is
  called from the platform thread, like every other FFI call we make.
- **Input:** SDL3 events → `blitz_event_t` → `UiEvent`. Click, move,
  wheel, key, IME text. No winit involved **[verified that `UiEvent` is
  the input boundary]**. Focus/zoom niceties from blitz-shell (pinch-zoom,
  devtools hotkeys) are ours to re-add or skip.
- **Vsync / frame scheduling:** nothing changes. Our `FrameScheduler`
  still owns the tick; Filament still owns presentation. Blitz is a pure
  pixel producer. Re-render only when Blitz reports an animation is
  running or an event arrived (blitz-shell's own `is_animating()` gate
  **[verified]**), or pay for a wasted layout every frame.
- **The DisplayList seam:** Blitz does **not** go through it, and cannot —
  a `DisplayList` is a flat list of draw commands; HTML/CSS brings its own
  layout, styling, and retained DOM. Blitz sits **beside** the seam: the
  `RecordingCanvas` → `DisplayList` → executor path stays alive for any
  Dart-drawn UI, and the Blitz texture is just another input to the UI
  View. The two can coexist in one frame.
- **wgpu-vs-Dawn interop:** none needed. One CPU copy per frame. With the
  CPU renderer there is no wgpu in the process at all — the only option
  that keeps a single GPU stack.
- **Costs:** the copy itself (800×600 RGBA8 ≈ 1.9 MB/frame; 4K ≈
  33 MB/frame — fine at the first size, must be measured at the second
  **[inferred]**), and layout+style+paint running on the platform thread.
  Stylo is a real CSS engine; per-frame cost for a realistic HUD is
  unknown **[inferred; measure in milestone B1]**.

#### Option B — Blitz renders into a wgpu surface on the SDL3 window

Blitz draws HTML/CSS **directly into the Flutter Zero window**: the shim
creates a wgpu surface from the SDL3 window's raw handle and presents it
itself.

```
Dart (platform thread, every frame)
  ├─ SDL3 poll → blitz_dispatch(events[])
  ├─ tick → blitz_render_to_surface(time_ms)        [Rust]
  │       Rust: doc.resolve(t) → paint_scene(...) →
  │              WGPUContext.create_surface(SurfaceTarget from the SDL3
  │              window's raw handle) → SurfaceRenderer → present
  └─ Filament: CANNOT also present to this window — one presentation
         path per window. So either
         B1: Filament renders 3D offscreen → readback → bytes → Blitz
             draws them (as a custom widget / <img>), i.e. the option A
             copy inverted and paid twice, or
         B2: this window has no Filament content at all.
```

- **What we build:** the option A shim plus a surface-creation entry point
  (`blitz_attach_surface(raw_window_handle, raw_display_handle)`), a
  `SurfaceRenderer` instead of a `BufferRenderer`, and resize handling
  (surface reconfigure on SDL window events).
- **Input:** identical to option A.
- **Vsync / frame scheduling:** presentation moves from Filament to wgpu.
  A wgpu surface presents in `Fifo` mode by default, which paces to vsync
  **[verified: wgpu's default present mode; behavior on our SDL3 window
  untested]**. Our scheduler calls `blitz_render_to_surface` and the
  present blocks — frame pacing now lives behind the shim.
- **The DisplayList seam:** replaced for this window, same as option A.
- **wgpu-vs-Dawn interop:** this is the **worst** interop position of the
  three. Blitz (wgpu) and Filament (Dawn) are both in the process, both
  driving the GPU every frame, with no way to share devices, textures, or
  the swapchain (§4). B1 re-introduces the CPU copy anyway. B2 means no 3D
  on the window — which drops the reason Filament is there.
- **Plumbing risk:** the raw-handle surface must be created on the main
  thread on macOS **[verified: wgpu documents the panic]**, and the
  macOS handle story has a wrinkle — wgpu's Metal backend wants an
  NSView/NSWindow handle and creates its own `CAMetalLayer`, while our
  existing code passes a `CAMetalLayer` from `SDL_Metal_GetLayer` to
  Filament **[verified for our side; the wgpu side needs a one-day spike
  to confirm which handle it accepts — `SurfaceTargetUnsafe` takes raw
  window+display handles, but Metal layer reuse is not documented there]**
  **[inferred]**. On Linux/X11 the raw-handle path is standard
  **[inferred from `SurfaceTargetUnsafe`'s design]**.

This option only pays off if Flutter Zero becomes "an HTML/CSS app with a
wgpu swapchain" — Filament demoted or gone. It is not a good *first* step.

#### Option C — Blitz owns its own window (winit)

Run blitz-shell as designed: it creates its own window, own event loop,
own surface.

```
Rust cdylib: blitz-shell application (winit event loop)
  ├─ own OS window, own wgpu surface, own vsync (RedrawRequested)
  └─ HTML/CSS UI lives entirely here
Dart: SDL3 window + Filament 3D exactly as today
Link: message passing (Dart FFI → Rust mailbox; Rust → Dart via a
      NativeCallable / SendPort)
```

- **What we build:** the thinnest Rust of the three — blitz-shell already
  does window, input, and rendering **[verified]**. We expose
  `blitz_app_start(html)`, `blitz_app_message(...)`, and a callback into
  Dart.
- **The blocker, verified:** **on macOS this cannot run in-process.**
  winit's macOS backend panics unless the event loop is created on the
  process main thread — `MainThreadMarker::new().expect("on macOS,
  `EventLoop` must be created on the main thread!")`
  (`winit-appkit/src/event_loop.rs:362`) **[verified]**. SDL3's macOS
  video backend has the same main-thread requirement **[verified:
  UI_BRAINSTORMING's SDL affinity writeup]**. Dart already runs on that
  thread. Two windowing toolkits cannot both own `NSApplication`.
  In-process option C is therefore **macOS-blocked**. The variants:
  - **C-process:** run the Blitz UI as a **separate process** (spawned by
    the engine), talk over a socket or pipe, share nothing. Works, but it
    is an IPC integration — input forwarding, window z-order, and
    lifecycle all become our problem, and there is no texture sharing
    across processes **[inferred]**.
  - **C-replace:** give up SDL3 and let Blitz own the one window. Then
    Filament must attach to *Blitz's* surface — which brings back the
    wgpu-vs-Dawn device problem, or Filament renders offscreen with a
    readback into Blitz's custom-widget path (the `wgpu_texture` example
    proves a custom wgpu pipeline can draw inside the scene, but a
    Filament/Dawn device still cannot hand pixels to a wgpu device
    without a copy **[verified example exists; interop inference from
    §4]**).
- **Vsync:** owned by winit/blitz-shell; our `FrameScheduler` is not in
  the loop for that window at all.
- **The DisplayList seam:** untouched — Blitz is a separate window with
  its own everything.
- **Where it fits:** a second window (a debugger, an inspector, a
  web-content panel) is the honest use case **[inferred]**.

### 6.4 Composite architecture: Filament swapchain + UI on top

Nick's question: how does it actually work when thermion (Filament)
renders into the window swapchain and we draw the UI on top? Short
answer: **two Filament Views, one swapchain, UI pixels from Blitz's CPU
buffer.** Almost all of it already runs in `examples/thermion_ui` today.

```
SDL3 window (one native handle: CAMetalLayer on macOS, X11 Window on Linux)
  └─ Filament SwapChain (created from that handle; Dawn presents)
       ├─ View 0 — renderOrder 0 — the 3D scene
       │     lights, meshes, PBR. Renders into the swapchain image.
       │
       ├─ View 1 — renderOrder 1 — the UI overlay
       │     orthographic camera → fullscreen quad (NDC [-1,1]²)
       │     unlit ubershader, AlphaMode.BLEND
       │     baseColorMap = the UI texture (RGBA8)
       │     View blend mode: transparent, post-processing off
       │     → drawn on top of View 0's output
       │
       └─ Filament composites both views into the swapchain image in
          renderOrder and presents ONCE per frame.

UI texture contents (Blitz, option A — CPU only, no window):
  HTML/CSS DOM
    → HtmlDocument::from_html → resolve(t) → paint_scene     [Rust cdylib]
    → render_to_buffer (vello_cpu) → RGBA8 bytes              no wgpu
    → Texture.setImage(bytes)                                 one upload/frame
```

**The model, verified in code.** `examples/thermion_ui` creates the UI
overlay exactly as the diagram says
(`examples/thermion_ui/lib/src/filament_executor.dart`, landed in commit
`e148b50472d` "UI overlay on top of 3D via second View at renderOrder: 1")
**[verified]**:

- One `SwapChain` from the SDL3 window handle; the 3D View attaches at the
  default order (0), the UI View attaches to the **same** SwapChain with
  `renderManager.attach(uiView, swapChain, renderOrder: 1)` **[verified]**.
- The UI View: its own `Scene` holding one fullscreen quad, an
  orthographic camera (`-1..1`), `BlendMode.transparent`, post-processing
  off **[verified]**.
- The quad's material: unlit ubershader, `hasBaseColorTexture`,
  `AlphaMode.BLEND`, `baseColorMap` = our RGBA8 `Texture` **[verified]**.
- Filament renders View 0, then View 1 on top, then presents once. One
  present, one GPU stack, no second window **[verified: the example
  renders the cube behind and the HUD on top in one `render()` call]**.

**Where the UI pixels come from.** Blitz runs headless — the §6.3 option A
chain: `from_html → resolve(t) → paint_scene → render_to_buffer` → RGBA8
bytes on the CPU **[verified, §6.1]**. Dart uploads them with
`Texture.setImage(0, bytes, w, h, RGBA, UBYTE)` per frame; Filament
re-samples the texture through the quad's UVs, so the GPU does any scaling
**[verified upload call]**. Dirty-region optimization: when nothing
changed — no input event, no CSS animation — skip the re-render *and* the
re-upload entirely. Filament re-composites the resident texture at
near-zero cost **[inferred: re-sampling an already-uploaded texture is
cheap; the composite pass itself still runs each frame while the 3D scene
animates]**. Blitz's own gate is the precedent: `blitz-shell` only requests
another frame while the document `is_animating()` **[verified, §6.1]**.
And because the CPU renderer path is used, **wgpu never enters the
process** — Filament's Dawn stays the only WebGPU implementation
**[verified the CPU renderer needs no GPU; single-stack claim follows]**
(§6.2).

**What changes vs `thermion_ui` today: only the source of the bytes.**

| | `thermion_ui` today | with Blitz (option A) |
|---|---|---|
| UI authoring | Dart code → `RecordingCanvas` → `DisplayList` | HTML + CSS |
| Rasterizer | pure-Dart software rasterizer (executor loop) | Blitz CPU renderer (vello_cpu) in the cdylib |
| Bytes | `Uint8List` built in Dart | RGBA8 buffer from `blitz_render` (borrowed → one copy) |
| Upload | `Texture.setImage` each frame | same call, same format |
| Texture, quad, overlay View, blend, `renderOrder` | — | **unchanged** |

The Filament side is untouched. The swap happens above it: what produces
the RGBA8 bytes changes from our rasterizer to Blitz. (The
`DisplayList` seam survives beside this, as §6.3 said — Dart-drawn UI can
still go through it; Blitz is an alternative producer of bytes, not a new
executor.)

**The details.**

- **Alpha.** `AlphaMode.BLEND` emits per-fragment alpha, so transparent UI
  pixels let the 3D scene show through — the translucent HUD panel in the
  demo does exactly this **[verified]**. The **`baseColorFactor` gotcha**
  **[verified, and load-bearing]**: the ubershader's fragment color is
  `baseColorTexture × baseColorFactor`, and the factor defaults to
  `(0, 0, 0, 0)` — without `setBaseColorFactor(1, 1, 1, 1)` every UI pixel
  renders as transparent black. The executor's comment calls this
  "load-bearing, not cosmetic."
- **Input.** SDL events are polled on the platform thread, translated to
  `UiEvent`, and passed to `doc.handle_ui_event(...)` — same thread, no
  marshalling **[verified API, §6.1]**. Hit-testing is Blitz's job, and it
  is DOM-aware: it knows which element is under the cursor (`:hover`,
  click targets). The hit-test surface exists:
  `Document::set_hover_to(x, y) -> bool`, `get_hover_node_id()`, and the
  event driver's `handle_pointer_move` returns the `NodeId` under the
  pointer **[verified in blitz-dom]**. Routing policy: the overlay owns
  the pointer while it is over interactive UI; otherwise the event falls
  through to the 3D scene (camera orbit today) **[inferred policy]**. One
  wrinkle: `handle_ui_event` returns nothing (unit type **[verified
  signature]**), so "did the UI consume this?" must come from a separate
  hover query the shim adds — small, but it is shim work, not free.
- **Sizing.** The UI texture is created at window size (`createTexture(w,
  h, RGBA8)`) **[verified]**. On resize: recreate the texture (Filament
  textures are fixed-size; `setImage` cannot grow one), set both view
  viewports, and call `blitz_set_viewport` on the Blitz side **[inferred —
  the example never resizes; the executor fixes width/height at creation]**.
- **Perf profile.** One CPU copy per frame: Blitz's buffer → `setImage`
  (§6.3's stated cost). Milestone B2 (§6.6) measures whether the CPU
  renderer holds 60 Hz. The fallback ladder, cheapest first: (1) re-render
  only when dirty — a static HUD skips nearly every frame; (2) smaller UI
  texture or partial uploads; (3) the wgpu GPU renderer — last resort,
  because it breaks the single-GPU-stack property **[inferred ordering]**.

**The GPU-rendered alternative, for contrast.** Drawing the UI directly on
the GPU into the same swapchain (ImGui-on-Dawn is the example, §5) requires
a thermion patch: expose Filament's internal `wgpu::Device` (and queue,
and the swapchain's current texture) so the UI pass can encode *after*
Filament's pass, on the same device, into the same swapchain image. Today
that device stays private inside `WebGPUPlatform` **[verified, §1]**; with
no patch, a second Dawn or wgpu instance cannot touch Filament's swapchain
at all — no device sharing between implementations (§4). The texture-quad
route avoids the entire problem: the only thing it needs from Filament is
"sample a texture and alpha-blend a quad," which is public API.

**Bottom line.** "Thermion renders the window, UI on top" = **View 0 (3D)
+ View 1 (UI quad) in one swapchain, UI pixels from Blitz's CPU buffer.**
About 90% of it already exists in `thermion_ui` **[verified: the entire
overlay path is `filament_executor.dart`, commit `e148b50472d`]**. The
remaining work is the Blitz cdylib shim that feeds the texture —
milestones B1–B3 in §6.6.

### 6.5 Comparison

| | A: buffer handoff | B: wgpu surface on our window | C: own window |
|---|---|---|---|
| Window | SDL3 (ours) | SDL3 (ours), but presented by wgpu | winit (Blitz's) |
| Filament 3D under the UI | yes, unchanged | not on this window (or pay two copies) | yes, separate window |
| GPU stacks in process | **1 with CPU renderer; 2 with GPU renderer** | 2 (Dawn + wgpu), both active | 1–2 depending on variant |
| Copies per frame | 1 (Blitz→Filament) | 0 if no 3D; 2 with 3D | 0 between windows |
| macOS viable in-process | yes | probably (surface spike needed) | **no** (winit main-thread panic) |
| Shim size | ~300–600 LOC Rust + FFI | A + surface attach/resize | smallest Rust, biggest architecture |
| Event loop owner | ours (unchanged) | ours; present blocks | winit |
| DisplayList seam | beside it (kept) | replaced for this window | untouched |

### 6.6 Milestones

Ordered; each produces a runnable thing. Estimates are for one engineer,
assuming the thermion WebGPU artifact from §1 is already usable.

1. **B1 — headless pixel proof (days, ~3–5).** Rust `cdylib` with the
   option A API, CPU renderer only. A plain Dart script loads a small
   HTML/CSS file, renders it at t=0, writes a PNG. No SDL, no Filament.
   Exit criteria: bytes out, image correct. (The screenshot example is the
   reference — this milestone is mostly plumbing **[inferred]**.)
2. **B2 — composite over Filament (week 1).** Wire the same bytes into
   `thermion_ui`'s texture path; run the existing demo with an HTML HUD
   over the lit cube. Add the SDL3 → `UiEvent` table (mouse + key first).
   Exit criteria: hover/click on HTML elements works; frame time recorded.
   Decide here whether the CPU renderer is fast enough — if yes, we are
   done with GPU-stack questions entirely.
3. **B3 — animated + IME (week 2).** CSS transitions/animations (respect
   `is_animating()` to avoid re-rendering static frames), text input,
   HiDPI scale changes, resize. Exit criteria: a text field works inside
   the HUD.
4. **B4 (optional) — GPU renderer swap (days, ~2–3).** Flip
   `use_gpu` to 1: `VelloImageRenderer` instead of CPU. Same Dart code.
   Measure: is the wgpu offscreen render + readback faster than CPU paint
   at our sizes, and what does the second WebGPU stack cost in memory and
   binary size? Keep whichever wins **[inferred: this is a measurement,
   not a rewrite]**.
5. **B5 (only if 3D-in-HTML becomes a requirement) — option B spike
   (week+).** Raw-handle surface on the SDL3 window, one-day macOS handle
   spike first. Stop and re-evaluate before committing.
6. **Option C — never in-process on macOS.** If a second window is
   wanted, prototype C-process (separate process + pipe) as a debug tool
   only.

### 6.7 Risks and open questions

Risks:

- **Blitz is beta.** Its own README says many bugs and missing features;
   CSS coverage is tracked on their status page **[verified]**. We would
  be early adopters on a moving 0.x **[inferred]**.
- **Platform-thread cost.** Stylo + taffy + parley run inline on our only
  thread. A big DOM or a heavy relayout could stall SDL and Dart
  **[inferred; measure in B2]**.
- **The copy.** One full-frame CPU copy per frame is the price of option
  A at every resolution **[verified pattern, unmeasured cost]**.
- **Binary size.** Even the CPU path brings stylo (a Servo component) and
  its dependency tree; the workspace lock has 897 packages. Our subset is
  smaller, but "small" is not the word for it **[inferred]**.
- **Build complexity.** A Rust cdylib in a native-assets build hook, next
  to thermion's C++ hooks, with matching macOS universal binaries
  **[inferred]**.
- **wgpu if we take the GPU renderer.** Second WebGPU stack, larger
  binary, and the same class of driver-maturity issues §1 documented for
  Dawn, now on the wgpu side **[inferred]**.

Open questions:

1. Is `VelloCpuImageRenderer` fast enough at 800×600 for a HUD-sized DOM?
   (B1/B2 measure this; it decides the whole GPU question.)
2. How complete is Blitz's CSS for our UI needs — flexbox, grid,
   position, transforms, overflow? Their status page tracks it; our
   layouts must be checked against it **[verified page exists]**.
3. Text quality: parley + swash on macOS — kerning, emoji, CJK. Untested
   by us **[inferred]**.
4. Accessibility: blitz-shell has an accesskit integration **[verified:
   `accessibility.rs`]** — can it survive without winit, driven from our
   shim? Unknown.
5. Networking: `DocumentConfig` takes a `net_provider`; for local assets
   we need a custom one (no network in the engine). Their `blitz-net`
   exists; whether it can be pointed at a local asset store is unverified
   **[verified the field exists; the provider unverified]**.
6. Does `blitz_render` need to own a wgpu context at all in CPU mode?
   (It should not — confirm no hidden wgpu dependency in the CPU renderer
   path **[inferred from screenshot.rs using it with no GPU]**.)
7. macOS HiDPI: viewport scale vs. buffer size — does Blitz give us the
   physical-pixel buffer we want for `Texture.setImage`?

### 6.8 What this does to the rest of the plan

- **§2/§7 unchanged.** Option A (thermion WebGPU) and the first milestone
  are still the opening moves. Blitz does not replace them; it rides the
  same RGBA8 path `thermion_ui` already runs.
- **§5's recommendation gains a footnote.** For an *adopted framework*,
  Blitz is now the third candidate alongside Floem (retained toolkit) and
  Dear ImGui (immediate, Dawn-capable) — with a unique pitch: full CSS,
  a CPU renderer that avoids the two-GPU-stacks problem, and a proven
  headless mode. Its costs are equally clear: beta quality, HTML/CSS
  instead of Dart widgets, and no Dawn path **[inferred]**.
- **Dawn remains Filament's stack only.** Nothing in the Blitz plan moves
  toward device sharing; the day device sharing becomes a requirement,
  the answer is ImGui-on-Dawn (§5) or the Skia Graphite escape hatch
  (§4), not Blitz.

## 7. The Canvas/DisplayList seam, and the first milestone

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

## 8. Risks, open questions, prototype order

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

When milestone 1 lands, replace the effort estimates and open questions
in §8 with measured numbers, record the binary-size delta, and decide
C1 vs C2 based on whether the matc/WGSL path for our own materials
worked. When §6's milestones B1–B2 land, record the Blitz render time,
the copy cost, and whether the CPU renderer held 60 Hz — that number
decides B4 (wgpu renderer) and closes §6.7's first three questions. If
we abandon WebGPU, note why here — the same seam makes the next backend
swap just as cheap.
