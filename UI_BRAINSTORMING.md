# UI brainstorming — a UI layer on top of Flutter Zero + SDL3

Roughly we need: render backend, text shaping/rasterization, image decoding,
layout, widget tree, input routing, animation. SDL3 already gives us render +
input + ticker. Everything else is a build-vs-borrow call.

## Shopping list per layer

**Text rendering** (the hardest layer to get right):
- **[SDL_ttf](https://github.com/libsdl-org/SDL_ttf)** — FreeType wrapper,
  pairs natively with SDL3. Gets you glyph atlases easily. No HarfBuzz, so
  no kerning/ligatures/RTL — fine for European scripts.
- **[stb_truetype](https://github.com/nothings/stb/blob/master/stb_truetype.h)**
  — ~4k LOC single header. ASCII-tier labels. Tiny.
- **[FreeType](https://gitlab.freedesktop.org/freetype/freetype) +
  [HarfBuzz](https://github.com/harfbuzz/harfbuzz)** — the real deal:
  shaping, complex scripts, OpenType. ~300k LOC combined but battle-tested.
- **[fontdue](https://github.com/mooman219/fontdue)** (Rust) — pure Rust,
  has C ABI. Smaller than FreeType, no shaping.

**Image decoding:**
- **[SDL_image](https://github.com/libsdl-org/SDL_image)** — PNG/JPG/WebP.
  Same drop-in story as SDL_ttf.
- **[stb_image](https://github.com/nothings/stb/blob/master/stb_image.h)** —
  ~7k LOC single header. PNG/JPG/BMP/TGA/GIF. Hard to beat.

**Layout:**
- **[Yoga](https://github.com/facebook/yoga)** (Facebook) — flexbox, C ABI,
  used by React Native. Solid.
- **[Clay](https://github.com/nicbarker/clay)** — pure C, ~2k LOC,
  declarative flexbox-ish. Emits render commands you execute against SDL3.
  Designed exactly for this.
- **[Taffy](https://github.com/DioxusLabs/taffy)** (Rust) — Yoga port + CSS
  grid. C bindings.
- **Hand-rolled** — column/row/padding in ~200 LOC Dart if your needs are
  simple.

**Widget tree / scene graph:**
- Pure Dart. ~500–1500 LOC for retained tree + invalidation + hit testing.
  This is the easy part.

**Immediate-mode shortcuts** (skip widget tree entirely):
- **[Dear ImGui](https://github.com/ocornut/imgui)** — most popular, C++,
  has Dart bindings. Looks like a dev tool.
- **[Nuklear](https://github.com/Immediate-Mode-UI/Nuklear)** — single
  header C, more skinnable than ImGui.
- **[microui](https://github.com/rxi/microui)** — ~1k LOC C, very bare.

## Four realistic paths

| Path                 | Stack                                                  | LOC native      | LOC Dart | Looks like                  |
| -------------------- | ------------------------------------------------------ | --------------- | -------- | --------------------------- |
| **Cheap & cheerful** | SDL3 + Nuklear/ImGui FFI                               | ~25k            | ~500     | Dev tool / debugger         |
| **Minimal retained** | SDL3 + stb_truetype + stb_image + Clay + Dart widgets  | ~13k            | ~1500    | Compact app, Latin-only text |
| **Proper widgets**   | SDL3 + SDL_ttf + SDL_image + Yoga + Dart widgets       | ~SDL deps + Yoga | ~2500    | Real UI (think Sublime)     |
| **Steal [Skia](https://github.com/google/skia)** | Skia FFI + Dart widgets                    | enormous        | many     | Flutter, the hard way       |

## Sketched architecture (path 3)

```
sdl3 (window, input, renderer)
  ↓
SDL_ttf + SDL_image (glyph atlas, image surfaces) ──┐
                                                    ↓
Yoga FFI (flexbox tree: setWidth, setFlexDirection) │
  ↓                                                 │
Dart widget tree:                                   │
  Widget → build() → Element/RenderBox-lite ────────┘
  ↓
Dart render walker: tree → SDL3 draw calls per frame
```

Dart-side API could feel Flutter-ish:

```dart
Column(
  children: [
    Padding(padding: EdgeInsets.all(16), child: Text('Hello', style: ...)),
    Image.asset('logo.png'),
    Row(children: [Button(onTap: ..., child: Text('OK'))]),
  ],
)
```

…but built on plain Dart classes that map straight to Yoga nodes + SDL3 draw
calls. No `RenderObject` machinery, no compositing layers, no isolate split.
Maybe 5% of Flutter's surface, 0.1% of its LOC.

## Flutter Zero's threading model — and what it forces on us

This is the constraint everything else gets shaped by. Standard Flutter has
four threads (Platform, UI, Raster, IO). Flutter Zero has **ripped out Raster
and IO entirely** (`engine/src/flutter/common/task_runners.h:19` only carries
`platform_` and `ui_`). The Platform/UI question is then governed by a
runtime setting `Settings::merged_platform_ui_thread`
(`engine/src/flutter/common/settings.h:293–306`) with three values:

- **`kEnabled`** — single thread from boot; the embedder constructs
  `TaskRunners` with `platform_runner_ == ui_runner_`, so there isn't a
  separate UI thread at any point. **This is the Flutter Zero default.**
- **`kDisabled`** — separate UI and platform threads, classic Flutter style.
- **`kMergeAfterLaunch`** — start with two threads, then call
  `MessageLoopTaskQueues::Merge()` after the root isolate launches
  (`shell/common/engine.cc:190–199`) to redirect UI tasks onto the platform
  thread.

README.md states the project's policy bluntly: *"All Dart code runs on the
platform thread. No other threading configurations are supported."* But
**that's a policy statement, not a compile-time fact** — the unmerged code
paths still exist in the shared shell code (`shell/common/shell.cc:320`,
`engine.cc:156` and `:190`, plus the Android and iOS embedder branches).
There's also a per-platform `require_merged_platform_ui_thread` guard
(`shell/common/switches.cc:451`); iOS sets it (`FLTEnableMergedPlatformUIThread=false`
is a hard `FML_CHECK` failure on iOS), and the macOS desktop embedder
reads `FLTEnableMergedPlatformUIThread` from the Info.plist and respects
it.

In other words: with the default `kEnabled`, the picture is:

```
Platform thread (== process main thread)
├── fml::MessageLoop  (NSRunLoop / glib / Win32 message pump)
├── root Dart isolate — main() runs here
│     └── all FFI calls happen here
└── (no separate UI thread exists)

Dart VM concurrent worker pool
└── Isolate.spawn()'d isolates run here, NOT on the platform thread
```

…and the rest of this section assumes that default. See "Unmerging as an
option" below for what changes if you flip the setting.

The current `examples/sdl_window` already exercises the load-bearing
implication: `main()` enters a blocking `while (running)` loop that polls
SDL3 and renders. Because the platform thread is now busy in that loop, the
message loop **stops pumping** — Dart `Future`s, microtasks, and timers
queued during the loop don't fire until the loop yields. The current demo
doesn't notice because it uses a frame counter for animation; a real UI
will notice the moment it touches `async/await`.

### What this means per layer

**Texture upload and SDL renderer calls** — must stay on the platform
thread. SDL3's renderer is bound to the thread that created the window
(macOS Cocoa enforces it; everywhere else SDL3 documents it). Good news:
that thread is where Dart already lives, so no marshalling. Bad news: any
isolate that produces pixel data has to hand the bytes back for the
platform thread to upload — no shortcut where a worker isolate calls
`SDL_UpdateTexture` directly.

**Text rasterization** (SDL_ttf / stb_truetype / FreeType) — synchronous C
calls, fast enough (~microseconds per glyph) that running them on the
platform thread is fine. Build the glyph atlas at startup or lazily on
first-use; cache aggressively so you're not re-rasterizing per frame.

**Text shaping** (HarfBuzz) — fast for Latin (sub-millisecond per line),
genuinely slow for Indic/Arabic on long runs. If you ship complex-script
support, shape on a worker isolate and cache the shaping result keyed by
`(text, font, size)`. Layout has to wait for the shaping result, so this
trade only pays off if you can pre-shape ahead of layout or if frame
budgets are forgiving.

**Image decoding** (SDL_image / stb_image) — the obvious isolate candidate.
A 1080p JPEG takes 30–100 ms to decode; doing that on the platform thread
will visibly hitch the SDL event loop. Pattern:

```
spawn isolate
  → FFI-call decoder, get a malloc'd RGBA buffer back
  → SendPort the pointer address as an int + width/height
main thread
  → Pointer.fromAddress(...)
  → SDL_UpdateTexture from that buffer
  → free the buffer
```

Each isolate has its own `DynamicLibrary` handle, so `dlopen` happens
per-isolate — cheap but not free. Pointers cross isolates as ints; the
underlying memory must be malloc'd (not Dart-heap) so the GC doesn't move
it underneath the receiving isolate.

**Layout** (Yoga / Clay / Taffy) — fast (microseconds for typical trees),
no reason to leave the platform thread. Keep it inline with the frame.

**Widget tree** — pure Dart, single isolate. No locks, no `Mutex`, no
synchronization. This is genuinely the easiest layer.

**Immediate-mode UIs** (ImGui, Nuklear, microui) — designed to run inline
with the render thread. Drop-in fit; nothing to think about.

### The blocking-event-loop problem (the real headache)

A `while (sdlxPollEvent())` loop starves Dart's microtask queue. `async`
support is non-negotiable for a real UI framework, so the current example's
"never return from main()" shape has to go. Two viable replacements:

**A. Yield to the message loop — Dart-driven frame timer.** `main()` does
SDL setup and then returns, leaving the Dart isolate alive via a recurring
timer:

```dart
void main() {
  _initSdl();
  Timer.periodic(const Duration(microseconds: 16667), (_) => _frame());
}

void _frame() {
  SdlxEvent? e;
  while ((e = sdlxPollEvent()) != null) _dispatchEvent(e);
  _layoutAndRender();
}
```

Between ticks, Flutter Zero's `fml::MessageLoop` pumps as normal —
microtasks fire, `Future`s complete, `dart:io` async I/O works, isolate
SendPort messages get delivered. **Tradeoff: this is not real vsync
alignment.** A `Timer.periodic` is phase-locked to Dart's scheduler, not to
the display's vsync signal. Phase drifts over hundreds of frames (visible
as judder); a hardcoded 16.67ms interval pretends every display is 60Hz so
ProMotion (24–120Hz adaptive), 120Hz, and 144Hz screens all degrade; and
on macOS Metal, `renderer.present()` doesn't strictly block on vsync — it
queues a drawable and back-pressures via the drawable pool — so even with
`SDL_HINT_RENDER_VSYNC=1` you end up 2–3 frames latent.

So (A) is **an interim scaffold**, not a destination. Useful for
unblocking the whole framework-above-the-loop while the real vsync work
ships.

**B. SDL3 main-callbacks model — the actual target.** SDL3 supports a
callback-driven entry point (`SDL_AppInit` / `SDL_AppIterate` /
`SDL_AppEvent` / `SDL_AppQuit`, gated by `SDL_MAIN_USE_CALLBACKS`) where
SDL owns the runloop and calls your code per-frame and per-event. On macOS
this routes through `NSApplication`'s runloop, using `CADisplayLink`
underneath to fire `SDL_AppIterate` at the right phase for each display
vsync (including ProMotion / variable refresh). On Linux it uses Wayland
frame events or whatever the active backend exposes; on Windows it uses
the DXGI / DWM mechanisms. Free correct vsync handling per platform.

Doable single-threaded — no unmerging needed; `SDL_AppIterate` fires on
the main thread which is also where Dart lives. The work to ship it:

1. Add `SDL_MAIN_USE_CALLBACKS` to the SDL3 build/link, write
   `SDL_AppInit/Iterate/Event/Quit` in a small C file (~150 LOC).
2. Reconcile with Flutter Zero's embedder ownership of `main()`. The
   cooperate-on-shared-runloop path is easier: on macOS, SDL's
   main-callbacks runs on top of `[NSApp run]` / CFRunLoop, which is the
   same runloop `fml::MessageLoop` sits on, so they share automatically.
   SDL_AppInit becomes the spot where the embedder stands up the engine
   and isolate. (Replacing the embedder's `main()` entirely is cleaner
   but more invasive — defer.)
3. Bridge to Dart with `NativeCallable.isolateLocal`. Dart registers a
   function pointer at startup; the C side calls it from inside
   `SDL_AppIterate` and `SDL_AppEvent`. Same thread, fully synchronous,
   no isolate ports involved.
4. Verify Dart microtasks pump between `SDL_AppIterate` calls — should be
   automatic via shared CFRunLoop, but worth a focused test.

Days of work, not weeks. The widget framework above the loop doesn't
care which driver runs it as long as it gets a `beginFrame(timestamp)`
call each tick.

A third fallback exists — manually draining Dart microtasks from inside a
blocking SDL loop via embedder FFI (`Dart_HandleMessage` and friends) —
but it's fragile (reentering a message loop the embedder thinks it owns)
and there's no reason to pick it over (A).

**Plan:** (A) first as a temporary scaffold so framework work can begin;
(B) as the real loop driver before anything user-facing ships.

### Designing the (A)→(B) seam so stage 1 isn't throwaway

The reason it's safe to ship (A) and migrate later is that the *framework
above the loop* is identical under both. Pattern after Flutter's
`SchedulerBinding`: expose a single entry point the framework calls into
when a frame should run.

```dart
abstract class FrameScheduler {
  void scheduleFrame();                              // request the next tick
  set onBeginFrame(void Function(Duration t) cb);    // framework registers here
  set onDrawFrame(void Function() cb);
}
```

Under (A): a Timer-backed implementation; `onBeginFrame` is called with a
synthesized monotonic timestamp on each tick.

Under (B): a native-callback-backed implementation; the C side hands the
real vsync timestamp to `onBeginFrame`. The framework code (widgets,
animations, tickers, render walk) doesn't change — its `AnimationController`
just receives more honest `t` values.

If we wire the framework against `FrameScheduler` from day one, swapping
in the SDL_AppIterate implementation is one file change and a small
embedder PR. The stage-1 work isn't wasted; it's the framework on a
placeholder scheduler.

### Helper-isolate cheat sheet

| Task | Where it runs | Notes |
| ---- | ------------- | ----- |
| SDL render/event/window calls | Platform thread | Single-threaded affinity, no choice |
| Glyph rasterization | Platform thread | Fast, cache the atlas |
| Text shaping (Latin) | Platform thread | Sub-ms, just do it |
| Text shaping (complex scripts) | Worker isolate (optional) | Cache by `(text, font, size)` |
| Image decode | Worker isolate | Return malloc'd pixels by pointer address |
| File / network I/O | Worker isolate or `dart:io` async | `dart:io` async only works if the event loop is pumping (see above) |
| Layout (Yoga/Clay) | Platform thread | Microseconds, inline |
| Hit testing | Platform thread | Walk the widget tree, no contention |

### SDL3's main-thread affinity — the constraint behind the constraint

A lot of what's above hangs on "SDL3 calls have to come from the platform
thread." Worth pinning down precisely what that means, because it's the
single biggest reason a "just move Dart off the main thread" plan isn't
free.

**The rule.** Whichever thread calls `SDL_Init(SDL_INIT_VIDEO)` becomes the
SDL video thread for the rest of the process. All of the following must be
called from *that* thread:

- `SDL_CreateWindow` / `SDL_DestroyWindow`
- `SDL_PollEvent` / `SDL_PumpEvents` / `SDL_WaitEvent`
- `SDL_CreateRenderer` and every renderer call (`SDL_RenderClear`,
  `SDL_RenderFillRect`, `SDL_RenderPresent`, texture create/upload, …)

Other subsystems are loose: audio runs its own callback thread; math, time,
file I/O, and bitmap *decoding* are all thread-safe. It's specifically the
video/window/renderer surface that has affinity.

**On macOS and iOS the SDL video thread *must* be the process main thread**
— not "the thread that started the engine," the actual first thread the OS
gives you. This is because `NSApplication` is hardcoded to the main thread:
its run loop, `NSResponder` chain, and event delivery only work there, and
`CAMetalLayer` / `NSOpenGLContext` mutations must happen there. Violations
crash with `NSInternalInconsistencyException`. On Windows the rule is
softer ("the thread that *created* the window"), and on X11/Wayland softer
still (a connection has affinity but you can choose any thread to own it).
Practically, SDL3 funnels everything through one chosen thread regardless,
so the user-facing rule is identical: pick a thread for SDL video, do
everything there. On Apple platforms that thread has to be `main`.

**SDL3's escape hatches** (added precisely because this is painful):

- `SDL_RunOnMainThread(callback, userdata, wait_complete)` — post a
  callback to be invoked on the SDL main thread from any thread.
  Fire-and-forget or block until it returns.
- `SDL_MAIN_USE_CALLBACKS` + `SDL_AppInit` / `SDL_AppIterate` /
  `SDL_AppEvent` / `SDL_AppQuit` — SDL owns `main()` and the runloop, you
  hand it callbacks that always run on the right thread. This is the same
  shape as approach (B) above.

**What it means for us:**

- *Today (merged threads, current example):* Flutter Zero's platform thread
  *is* the process main thread, and Dart runs there. FFI calls into SDL
  happen on the main thread by construction. Cocoa is happy and no
  marshalling is needed — this is precisely why the demo works.
- *Unmerged threads (the hypothetical in the next subsection):* Dart moves
  to a separate UI thread, but SDL's affinity doesn't. A naive
  `renderer.fillRect(...)` from the UI thread would crash on macOS the
  moment it reached Cocoa. The fix is a marshalling layer: every SDL call
  from Dart becomes a `PostTask(...)` to the platform task runner (or a
  `SDL_RunOnMainThread` on the C side), the platform thread executes, and
  the result is shipped back. To keep this affordable you batch — build a
  whole frame's draw commands on the UI thread, ship the batch over, replay
  on the platform thread. That's basically a mini command buffer, and it's
  exactly what real Flutter does between its UI and raster threads.
- *Worker isolates for decode:* a worker isolate runs on its own native
  thread, so it must not touch SDL APIs directly. Decode the JPEG into a
  malloc'd RGBA buffer, send the pointer address back to the main isolate,
  and the *main isolate* on the platform thread is the one that calls
  `SDL_UpdateTexture`. The isolate boundary already enforces this, but
  it's worth knowing why.

The `sdl3` Dart package currently does direct FFI lookups
(`dylib.lookupFunction<...>('SDL_RenderFillRect')`) with no thread checks
or posting. That works *because* of the merged-thread default — and is
what would need to change first if we ever went unmerged.

### Unmerging as an option (not engine surgery, just a flag)

Because the merge is governed by a setting, "give Dart its own thread again"
is one switch away rather than a fork of the engine. The dials:

- CLI: `--disable-merged-platform-ui-thread` or
  `--merged-platform-ui-thread=disabled|enabled|mergeAfterLaunch`
  (`shell/common/switches.cc:446–477`)
- macOS embedder: `FLTEnableMergedPlatformUIThread` in Info.plist
- Android: `io.flutter.embedding.android.DisableMergedPlatformUIThread`
  manifest meta-data
- Direct embedder C++: set the `Settings` field before constructing the
  shell

Caveats before celebrating:

1. iOS is hardcoded merged (`FlutterDartProject.mm:188`). Not our concern
   for an SDL3 desktop demo, but a portability ceiling.
2. The Flutter Zero project hasn't promised this configuration works.
   `kEnabled` is the only one anyone has run; `kDisabled` will compile and
   set up threads, but whatever assumptions the trimmed-down shell/runtime
   make about "Dart and platform live together" are landmines waiting to
   be found. Expect to debug.
3. SDL3 still has main-thread affinity for window/renderer on macOS
   (NSApplication requirement). If Dart lives on its own UI thread,
   `SDL_CreateWindow` / `SDL_CreateRenderer` / event polling / present must
   be marshalled back to the platform (= main) thread. The `sdl3` Dart
   package currently calls straight through FFI — to make it cross-thread,
   you'd need either a C-side queue that the platform thread drains, or
   `task_runners_.GetPlatformTaskRunner()->PostTask(...)` shim from inside
   `runtime/`.

If it does work, the payoff is real: the blocking SDL `while` loop only
blocks the *UI thread*, the platform thread keeps pumping its native
runloop independently, and approach (B) (SDL3 main-callbacks driving from
the platform thread, framework code reacting from the UI thread) becomes
the natural shape. That's also what real Flutter does — Dart on the UI
thread, platform-thread events and vsync posted across.

**Recommendation:** don't bother. The (A)→(B) plan delivers vsync-aligned
frame scheduling on a single thread (`SDL_AppIterate` fires on main, Dart
runs on main, no marshalling), which removes the main reason to unmerge.
Unmerging would only be on the table if we needed Dart compute and SDL
event polling to run truly in parallel — and our compute budget per frame
is tiny enough that the single-threaded model is genuinely fine.

## Tricky bits worth flagging up front

1. **Glyph atlas management.** Even with SDL_ttf, you'll want to cache
   rasterized glyphs into a texture atlas keyed by (font, size, codepoint).
   Naive "render text per frame" is slow.
2. **Text layout vs shaping.** Without HarfBuzz, you can't do Arabic/Indic/CJK
   properly — and even Latin loses kerning/ligatures. Decide up front if you
   need it.
3. **Hit testing & event routing.** Walk the tree top-down for
   hover/focus/click. Easy but you have to actually do it.
4. **Animation/ticker.** Build on top of a `FrameScheduler` seam (see the
   threading section) so the ticker receives a frame timestamp from
   whichever driver is wired in. Under interim (A) that's a Dart-side
   monotonic clock; under target (B) it's the real vsync timestamp from
   `SDL_AppIterate`. `Future.delayed` / `Stream.periodic` work normally
   between ticks under both.
5. **DPI scaling.** SDL3 exposes display scale; your layout must multiply
   through it.

## Recommendation

**Stack: path 3** — SDL_ttf + SDL_image + Yoga + Dart widgets — is the
sweet spot. SDL_ttf/SDL_image are already in the SDL3 family so they bind
cleanly via the existing `sdl3` package surface. Yoga gives you a
battle-tested layout brain so you don't reinvent flexbox edge cases.
Everything above that is plain Dart that you fully control.

**Threading: single-threaded (merged), with `SDL_AppIterate` driving the
frame loop.** Ship in two stages so framework work isn't blocked on
embedder work:

1. *Stage 1 (Dart-only):* `Timer.periodic` (or `await Future<void>.delayed(Duration.zero)`)
   replaces the current blocking SDL loop. Async starts working, the
   framework layer can be built and tested. Wire everything against a
   `FrameScheduler` abstraction so the loop driver is swappable.
2. *Stage 2 (C + embedder):* swap the Timer-backed `FrameScheduler` for an
   `SDL_MAIN_USE_CALLBACKS` / `SDL_AppIterate` implementation that
   delivers real vsync timestamps. ~150 LOC of C, small embedder
   integration, no widget code changes.

Don't unmerge threads. Don't ship the Timer-driven loop as final.

**Starting probe:** open SDL3 window → render a single line of text via
SDL_ttf into the renderer → wire up Yoga to position a `Text` next to a
`Padding(child: Image)`, with `Image.asset` decoded on a worker isolate.
That alone validates the whole stack — paths through every layer except
the (B)-stage embedder work.
