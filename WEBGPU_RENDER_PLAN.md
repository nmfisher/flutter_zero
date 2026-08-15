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

## 4. The Canvas/DisplayList seam, and the first milestone

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

## 5. Risks, open questions, prototype order

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

## Updating this plan

When milestone 1 lands, replace the effort estimates and open questions
in §5 with measured numbers, record the binary-size delta, and decide
C1 vs C2 based on whether the matc/WGSL path for our own materials
worked. If we abandon WebGPU, note why here — the same seam makes the
next backend swap just as cheap.
