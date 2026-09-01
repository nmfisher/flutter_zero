# Realtime Webcam Depth — Standalone macOS App Plan

Status: Phase 1 (capture + pass-through + HUD) is implemented in this
directory; Phase 2 (the depth model) is still plan only. The
authoritative design doc is
`video_editor/docs/compositing/standalone-macos-webcam-depth.md`
(ref `4052f79`); this file is the background research behind it.
Research facts below were checked against the linked repos/docs in
**August 2026**; ML model status changes fast — re-check before
implementation. FPS/latency numbers are as published or community-reported;
none are measured in this app yet — Phase 2 is the real benchmark pass.

## 0. Summary

A small **standalone macOS app** (native Swift, Apple Silicon M1+) that:

1. captures the webcam with **AVFoundation** (`AVCaptureSession`),
2. runs **realtime monocular depth estimation** on the live frames,
3. displays the result — depth colormap, alpha overlay, or side-by-side —
   rendered with **Metal**.

One window, one camera, one model, one pipeline. The point is to prove the
realtime on-device depth loop — **capture → inference → render** — end to
end, with per-stage instrumentation, before anything builds on it.

Headline decisions made in this document:

| Decision | Choice |
|---|---|
| Model | **Depth Anything V2 Small** (Apache-2.0 weights), via Apple's published Core ML package |
| Runtime | **Core ML** with `.all` compute units (ANE-first), measured against GPU-only; escalation ladder in §4.2 |
| Render | **Metal** (`MTKView`); the depth result never crosses back to CPU |
| Capture | `AVCaptureSession` + `AVCaptureVideoDataOutput`; YUV→RGB and resize on GPU |
| Loop discipline | Inference **decoupled** from the render tick; newest frame wins; frames drop, never queue |

---

## 1. Goals

| # | Goal | Notes |
|---|------|-------|
| G1 | Webcam capture at 30–60 fps | AVFoundation; built-in + external UVC cameras |
| G2 | Realtime per-frame monocular depth on Apple Silicon | ≥ 24 fps with depth every frame, or depth every Nth frame with video at full rate |
| G3 | Visualize depth over the live feed | colormap / overlay / split display modes (§2.6) |
| G4 | Low glass-to-glass latency | ≤ 100 ms working target, ≤ 50 ms stretch (§5) |
| G5 | Per-stage instrumentation | signposts + on-screen HUD; every budget in §5 is measured, not assumed |
| G6 | Shippable licensing | model code and weights permissive (Apache/MIT); see §3.1 |

### 1.1 Out of scope

- Training or fine-tuning depth models. Prebuilt, open-weight models only.
- Multi-camera capture, streaming out, recording/export of the output.
- Pixel/object tracking (hand landmarks, segmentation trackers). A possible
  later extension; the frame contract (§2.5) reserves a timestamped slot so
  such results could ride beside frames, but nothing tracks here.
- iOS/iPadOS builds. A depth *sensor* path exists on LiDAR-equipped devices
  (§3.3) but this app is macOS-first.
- Intel Macs.

---

## 2. Architecture

### 2.1 Pipeline

```
AVCaptureSession
  └─ AVCaptureVideoDataOutput ──(CVPixelBuffer)──►
       preprocess (GPU): convert to RGB + resize → model input texture
            │                       [serial capture queue]
            ▼
       inference (actor, one in-flight job, newest-wins)
            │  Core ML model → depth texture at model resolution
            ▼
       render (MTKView @ display cadence)
          upscale depth to camera resolution (GPU sampler)
          colormap + blend with video (fragment shader)
            ▼
          screen
```

Three owners, three threads:

| Owner | Thread | Cadence |
|---|---|---|
| Capture | serial dispatch queue, `AVCaptureVideoDataOutput` delegate | camera fps (30/60) |
| Inference | `actor DepthEngine`, single in-flight job | as fast as the model allows |
| Render | `MTKViewDelegate.draw` | display vsync |

### 2.2 Capture

- `AVCaptureSession` with an `AVCaptureVideoDataOutput`; request ≥ 720p at
  30 fps; prefer the device's native YUV 4:2:0 planar format (cheapest to
  convert) or BGRA — either way conversion happens in a Metal kernel via
  `CVMetalTextureCache`. No CPU pixel access anywhere on the live path.
- Buffers come from the output's `CVPixelBufferPool`; never allocate
  per frame.
- Device selection: `AVCaptureDevice.DiscoverySession` (built-in camera
  first, then external/UVC). Capture cards enumerate as cameras and need no
  extra plumbing.
- Permission: `NSCameraUsageDescription` in Info.plist; request on launch,
  degrade to a clear error screen if denied.

### 2.3 Preprocess

- One Metal pass converts to RGB and scales/crops to the model's input size
  (§3.2), writing into a reused texture. Inference always sees the same
  size, independent of camera resolution.
- The camera frame's presentation timestamp (`CMSampleBuffer`) travels with
  the job; the depth result inherits it.

### 2.4 Inference

- An actor with **one in-flight job**: if a new frame arrives while
  inference is busy, the busy job's input is replaced by the newer frame
  (drop-stale, never queue).
- The result lands in a newest-wins slot: `(depthTexture, timestamp)`. The
  renderer samples whatever is freshest at draw time and never waits.
- **Alignment tolerance:** a depth result one camera frame interval older
  than the displayed color frame is fine; older than two intervals, it is
  dropped. Depth is never interpolated across frames (an optional temporal
  EMA shader pass exists as a smoothing flag, off by default).

### 2.5 Frame + depth contracts

```swift
struct DepthFrame {
    let depth: MTLTexture          // R32Float, model resolution
    let timestamp: CMTime          // matches the sibling color frame
    let spec: DepthSpec
}

struct DepthSpec {
    var encoding: DepthEncoding    // .relativeInverse | .metricMeters
    var near: Float?, far: Float?  // metres, when encoding is metric
    var confidence: MTLTexture?    // optional; sensor-depth only (§3.3)
}
```

- Depth is single-channel float at **model resolution** (well under half
  the camera's pixel count — edges get filtered at render time).
- Monocular ML depth is **relative** (inverse-depth ordering, no absolute
  scale): the app treats it as normalized inverse depth and exposes a
  depth-range control. `.metricMeters` is reserved for sensor or
  metric-model sources (§3.3, §3.4 escalation).

### 2.6 Render / display modes

All Metal, all GPU-resident; depth is upscaled with a filtered sampler and
colored through a LUT (Turbo):

1. **Video** — pass-through (baseline).
2. **Depth** — colormap only.
3. **Overlay** — video tinted by depth, alpha slider (default view).
4. **Split** — side-by-side video/depth.

Optional later modes on the same depth input: depth-threshold background
blur / synthetic DOF, depth-aware relighting. Not in the first build.

### 2.7 App shell

Swift 6 + SwiftUI hosting one `MTKView`; a stats HUD (per-stage ms, fps,
drop count, glass-to-glass ms) toggled with a key. Sandboxed app, hardened
runtime, camera entitlement only.

---

## 3. Model choice

### 3.1 Verdict table (realtime monocular depth, RGB-only)

| Name | Year | Licence | Realtime? | Output | Deploy path | Verdict |
|---|---|---|---|---|---|---|
| **Depth Anything V2 Small** ([repo](https://github.com/DepthAnything/Depth-Anything-V2)) | 2024 (NeurIPS) | Code Apache-2.0; **Small weights Apache-2.0** (Base/Large/Giant CC-BY-NC) | Yes at reduced res on Apple Silicon; §3.4 shows single-digit ms at 448² is reachable on an M4 Pro | Dense relative (inverse) depth; metric variants exist at small sizes | **Apple-published Core ML package: `apple/coreml-depth-anything-v2-small`**; community ONNX (`fabio-sim/Depth-Anything-ONNX`) | ✅ **Primary recommendation** (§3.2) |
| **Depth Anything 3 — SMALL/BASE/METRIC** ([repo](https://github.com/bytedance-seed/depth-anything-3), Nov 2025) | 2025 | Code Apache-2.0; **DA3-SMALL (0.08 B), DA3-BASE (0.12 B), DA3METRIC-LARGE (0.35 B), DA3MONO-LARGE Apache-2.0** (LARGE/GIANT/NESTED CC-BY-NC) | Unproven outside CUDA; examples are GPU/CUDA-bound; "DA3-Streaming" targets long video, `< 12 GB VRAM` | Monocular relative (DA3MONO) or **metric** (`focal * net_out / 300`) | **No ONNX/CoreML published at all yet** `[gap]` | Watch-list: strongest open metric models, not portable today |
| **Video Depth Anything** ([repo](https://github.com/DepthAnything/Video-Depth-Anything), 2025, CVPR'25) | 2025 | Apache-2.0 | Offline-class; online variant (oVDA, [arXiv 2510.09182](https://arxiv.org/html/2510.09182v1)): 42 FPS A100 / 20 FPS Jetson | Temporally consistent video depth | PyTorch; no official ONNX/CoreML | Out of scope for live; candidate for future recorded-video depth |
| **Prompt Depth Anything** ([repo](https://github.com/DepthAnything/PromptDA), 2024) | 2024 | DepthAnything org; confirm LICENSE before shipping `[VERIFY]` | Interleaved use, not per-frame | Sharp 4K **metric** depth when prompted by low-res LiDAR | PyTorch demo | Only relevant with a depth sensor (§3.3); not on macOS |
| **Apple Depth Pro** ([repo](https://github.com/apple/ml-depth-pro), 2024) | 2024 | Code permissive; weights have own terms `[VERIFY]` | No — ~0.3 s/frame on a V100 | High-fidelity metric depth + focal estimate | PyTorch | Too slow for live |
| **MoGe-2** ([repo](https://github.com/microsoft/moge), 2025) | 2025 | Code MIT; weight terms `[check repo]` | Heavier than DA-V2-Small | Metric point maps / depth / normals | PyTorch | Not a live target |
| **Metric3D v2 / UniDepthV2** | 2024/25 | **Non-commercial / academic** licences | n/a | Metric depth | — | ❌ Excluded by licence |
| **GPU-DSL depth (TypeGPU demo)** — [Konrad Reczko, Aug 18 2026](https://x.com/reczko_konrad/status/2089670934009413751) | 2026 | TypeGPU library MIT ([repo](https://github.com/software-mansion/TypeGPU)); **demo's model/weights unspecified** | Claimed **~8 ms @ 448² on an M4 Pro** (~250 GPU dispatches) — corroborated by third-party reposts, not independently measured | Monocular depth, GPU-resident | TypeScript over **WebGPU** — browser-only today; no native/Node/Dawn runtime documented | Watch-list — see §3.4; a throughput datapoint, not an integrable model |

Reading of the field: the Depth Anything family is the only line that is
simultaneously open-weight-permissive *at the sizes that run in real time*,
portable to Apple runtimes, and maintained. Everything else is too slow,
not portable, or licence-blocked.

### 3.2 Recommendation: Depth Anything V2 Small via Core ML

- **Weights:** `depth-anything-v2-small` (~25 M params), Apache-2.0 — the
  only V2 size with permissive weights. Do not accidentally bundle
  Base/Large/Giant (CC-BY-NC).
- **Package:** `apple/coreml-depth-anything-v2-small` — Apple's own Core ML
  conversion makes this the lowest-risk starting point on macOS.
- **Input:** 518² is the reference resolution; smaller inputs (384/448²)
  are usable and likely necessary for budget — run the res-vs-latency sweep
  (B1, §6) before locking.
- **Output:** dense inverse depth, relative. Map to
  `DepthSpec.encoding = .relativeInverse`; the depth-range control stands
  in for a metric scale.
- **Working inference budget: 8–40 ms** on Apple Silicon laptops. The
  earlier working estimate was 15–40 ms; the TypeGPU/WebGPU datapoint
  (§3.4) shows the floor is single-digit ms when the whole network runs as
  GPU dispatches. Core ML may sit at the slow end `[measure]`.

Escalation: re-evaluate **DA3-SMALL/BASE** (and the metric DA3METRIC
variants, also Apache) the moment they grow a Core ML/ONNX export; until
then they are CUDA-first and not integrable.

### 3.3 Why not a depth sensor? (LiDAR note)

Real metric depth plus a confidence map is available on **LiDAR-equipped
iPhone/iPad** devices (iPhone Pro family since 12 Pro, iPad Pro 2020+):
ARKit `sceneDepth`/`smoothedSceneDepth`, enabled via
`frameSemantics.insert(.sceneDepth)` (**nil unless requested** — classic
trap). Native plane ≈ **192×256 px**, values already in metres, ~30 fps
class, confidence map included; the smoothed variant trades a little
latency for temporal stability.

**Macs have no depth sensor**, and Continuity Camera streams color only
`[VERIFY whether AVDepthData can surface from a Continuity Camera]` — so on
this app's target platform, ML monocular depth is the only live path. The
sensor recipe is recorded because it remains the right answer on
LiDAR-equipped hardware (a future iPadOS sibling of this app, or a paired
device): sensor depth outranks ML depth wherever present, at a fraction of
the latency, and its confidence map feeds edge filtering directly. Prompt
Depth Anything (§3.1) is the matching sharpener for such a pipeline.

### 3.4 Signal: GPU-resident inference — the TypeGPU depth demo (Aug 2026)

Source: [Konrad Reczko on X, 2026-08-18](https://x.com/reczko_konrad/status/2089670934009413751).
Verification caveat: the post itself could not be fetched (X returns 402 to
unauthenticated requests); its content is corroborated by multiple
independent third-party reposts describing the same details, and the status
ID's snowflake timestamp decodes to mid-August 2026. Treat the numbers as
credible but unmeasured here.

What was shown: a 448×448 monocular depth model expressed as **~250 GPU
dispatches** via [TypeGPU](https://github.com/software-mansion/TypeGPU) —
an MIT TypeScript toolkit by Software Mansion over the **WebGPU** API —
running at **~8 ms per frame on an M4 Pro**, with the depth buffer staying
GPU-resident and feeding rendering/lighting directly. No CPU hop.

Why it matters here:

1. **It is the latency floor.** ~8 ms at 448² on Apple-class silicon is the
   target to reproduce with our stack (B5, §6). It is why the working
   inference budget reads 8–40 ms rather than 15–40 ms.
2. **The trick is owning the whole GPU path.** The speed comes from never
   leaving a single GPU context: preprocess, network, and display are all
   dispatches. A Core ML + Metal app can approximate this, but every
   cross-API hop costs a copy — which is the design pressure behind §4.
3. **TypeGPU itself is not integrable.** It is TypeScript over browser
   WebGPU with no native runtime documented. Its relevance is the
   datapoint plus a pointer to the *WebGPU-style runtime* option in §4.1,
   where the same fully-GPU-resident shape becomes possible via native
   wgpu/Dawn if Core ML disappoints.

---

## 4. Accelerator / runtime decision

### 4.1 Options

| Option | What it is | Strengths | Weaknesses |
|---|---|---|---|
| **Core ML, `.all` compute units** (`MLModel`) | Apple's model runtime; schedules ANE → GPU → CPU | Model already packaged by Apple; ANE offload = low power and leaves the GPU free for rendering; least code | Operator support varies per compute-unit config — parts can silently fall back to CPU `[measure with MLComputePlan]`; cross-API input copy; least control |
| **Core ML, GPU-only** | Same model, `computeUnits = .gpu` | No ANE-fallback variance; inference lives on the same device as the render | Contends with the render pass for GPU time; typically hotter than ANE |
| **MLX / Metal-native inference** | Apple's ML framework on Metal; community DA-family conversions exist `[VERIFY]` | Fully GPU-resident pipeline — closest to the §3.4 shape; Swift-native | GPU only (no ANE); conversion fidelity/performance per model `[measure]`; smaller ecosystem |
| **Custom Metal / MPS kernels** | Hand-written network | Maximum control | Reimplementing a DPT-style network by hand: not worth it |
| **WebGPU-style runtime (native wgpu/Dawn)** | The runtime shape the TypeGPU demo demonstrates | One GPU context end to end; compute-graph authoring in WGSL | Foreign API that lowers to Metal anyway; heavyweight for one model; only wins if cross-API copies dominate the profile |
| **CPU (Accelerate)** | — | Trivial | Not realtime for this network |

### 4.2 Recommendation

**Core ML with `.all` compute units first.** The Apple-packaged model makes
this a configuration problem rather than an engineering problem, and ANE
inference keeps the GPU free for rendering. Measure per-compute-unit
latency in Phase 2 (B1, §6).

**Escalation ladder if the §5 budget is missed:**

1. Core ML GPU-only — removes ANE-fallback variance, keeps inference on the
   render device.
2. MLX / Metal-native conversion — fully GPU-resident; attempt to reproduce
   the §3.4 floor.
3. Native WebGPU-style runtime (wgpu) for the inference sub-graph only —
   last resort, only if profiling shows the remaining cost is cross-API
   copies.

Design principle inherited from the §3.4 datapoint: **the fewer
device/context hops per frame, the better** — but hops are measured, never
assumed.

---

## 5. Performance budgets and rules

### 5.1 Budgets (targets; every cell gets a measured number in Phase 2)

Sizing: 1080p RGBA = 8.3 MB/frame ≈ 250 MB/s at 30 fps; the depth map at
model resolution (e.g. 448² float) is ~0.8 MB.

Glass-to-glass on an M-series laptop, 720p–1080p camera:

| Stage | Target | Note |
|---|---|---|
| Capture delivery | ≤ 1 frame interval (16.7 ms @ 60) | callback cadence, pooled buffers |
| Preprocess (convert + resize, GPU) | ≤ 2 ms | one Metal pass |
| Inference | **≤ 16 ms** (8–40 ms working range) | §3.2; Nth-frame decimation allowed at first |
| Result handoff | ~0 | newest-wins slot, no queue |
| Render (upscale + colormap + blend) | ≤ 2 ms | model-res depth, LUT in shader |
| Present | ≤ 1 vsync | — |
| **Total** | **≤ 100 ms** working, **≤ 50 ms** stretch | HUD shows the real number |

Frame-rate floor: ≥ 24 fps display with depth every frame; if inference
cannot keep up, video stays at full rate while depth updates every Nth
frame — the depth layer's visible staleness is capped at N × frame
interval.

### 5.2 Rules

- **Never read back to CPU on the live path.** No `CVPixelBuffer` locking
  of model output, no `MTLTexture.getBytes`. Conversion, resize, inference,
  colormap: all GPU-resident.
- **Pool everything.** Pixel buffers from the capture pool; reused input/
  output textures; no per-frame allocations in any stage.
- **Frames drop, never queue.** One newest-wins slot between stages;
  back-pressure propagates up (inference slows its intake), nothing lines
  up behind it.
- **Depth at model/native resolution**; upscale and edge-filter on the GPU
  at render time.
- **Inference is decoupled from render.** The renderer never waits on the
  model; a late depth result costs one stale overlay frame, never a missed
  render tick.
- **Instrument from day one:** `os_signpost` intervals per stage plus the
  HUD. Every budget above is a measured cell, not a hope.

---

## 6. Benchmarks to run (Phase 2 gate)

| # | Measurement | Method | Fills |
|---|---|---|---|
| B1 | DA-V2-Small inference latency per compute-unit config (ANE-only / GPU-only / CPU+ANE) at 518² / 448² / 384² inputs | `MLComputePlan` + signposts | §3.2, §5.1 |
| B2 | End-to-end glass-to-glass | timestamped capture buffer → present (HUD) | §5.1 |
| B3 | Sustained thermals: 30 min at target fps, ANE vs GPU configs | fps + power metrics (`MetricKit`) | §4.2 choice |
| B4 | Preprocess cost at each input res | signpost | §5.1 |
| B5 | §3.4 floor check — MLX/Metal-native DA-V2-Small at 448² vs the ~8 ms M4 Pro claim | only if the GPU-resident route is taken | §3.4 |
| B6 | Drop/staleness behaviour under simulated slow inference | inject synthetic delays | §5.2 |

**Exit criteria:** ≥ 24 fps with per-frame depth at ≤ 100 ms glass-to-glass
on an M-series laptop, with the HUD showing every stage inside budget.

---

## 7. Phased plan

Phases are ordered by risk retirement; each ends in a committed artifact.

**Phase 0 — this document.** Architecture, model + runtime choice, budgets.

**Phase 1 — capture + render skeleton (no model).**
App shell, permission flow, `AVCaptureSession` → Metal pass-through at
30–60 fps, HUD. *Exit:* stable pass-through, zero dropped frames over a
10-minute run.

**Phase 2 — model wired (synchronous, correctness first).**
Core ML DA-V2-Small integrated inline in the capture path; depth colormap
on screen; **run the full benchmark matrix (§6)** and record the numbers in
this doc. *Exit:* B1/B2 measured; compute-unit decision made (§4.2).

**Phase 3 — realtime pipeline.**
Decouple inference into the actor; newest-wins; Nth-frame decimation;
overlay and split display modes; temporal-smoothing flag. *Exit:* the §6
gate — ≥ 24 fps, ≤ 100 ms glass-to-glass, HUD green.

**Phase 4 — escalation (only if the gate failed).**
Walk §4.2's ladder: Core ML GPU-only → MLX/Metal-native → (last) native
wgpu inference sub-graph, re-running B1/B2/B5 at each step.

**Phase 5 — polish (optional).**
Depth-threshold background blur / DOF display mode; recorded-video depth
(Video Depth Anything for temporally consistent offline depth); settings
UI (device, resolution, model input res). Watch-item: DA3 Core ML/ONNX
export, which would re-open the model choice (§3.2).

---

## 8. Risks and open questions

**Risks**

1. **ANE operator coverage.** The Core ML conversion may fall back to
   GPU/CPU for parts of the network, costing the ANE's latency/power win.
   Mitigation: `MLComputePlan` inspection (B1); GPU-only and MLX fallbacks
   exist.
2. **Inference slower than budget.** The 8–40 ms range is partly estimate;
   if reality is ~40 ms at 518², first drop to 384² or Nth-frame
   decimation before changing runtime.
3. **Temporal instability.** Per-frame monocular depth flickers (no
   temporal model). First mitigation is the optional EMA shader pass; the
   real fix — video-consistent depth — is offline-class today (§3.1).
4. **Licence drift.** Only V2-Small weights are permissive; DA3 splits per
   size; keep a licence check on whatever gets bundled.
5. **Thermals.** Sustained GPU inference + render on a laptop; B3 decides
   whether ANE offload is not just cheaper but necessary.
6. **Privacy.** Camera permission UX; frames never leave the process;
   state that in the app's about screen.

**Open questions**

- Does the Apple Core ML package run DA-V2-Small cleanly on ANE at 518²,
  or at what reduced input resolution? (B1 answers.)
- Is there a faithful, fast MLX conversion of DA-V2-Small? `[VERIFY]`
- Can Continuity Camera expose depth from a paired LiDAR iPhone?
  `[VERIFY]` — would put sensor depth on macOS after all.
- Metric scale: stay relative + user range control, or wait for a DA3
  metric runtime before offering metric output?
- Is a native wgpu (TypeGPU-style) inference path worth the dependency for
  one model if the §3.4 floor is otherwise unreachable?
