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
`platform_` and `ui_`), and the default
`merged_platform_ui_thread = kEnabled`
(`engine/src/flutter/common/settings.h`) collapses the UI thread onto the
platform thread once the root isolate has launched
(`engine.cc:190–199`). The result:

```
Platform thread (== process main thread)
├── fml::MessageLoop  (NSRunLoop / glib / Win32 message pump)
├── root Dart isolate — main() runs here
│     └── all FFI calls happen here
└── (UI thread merged into this one after isolate startup)

Dart VM concurrent worker pool
└── Isolate.spawn()'d isolates run here, NOT on the platform thread
```

README.md states this explicitly: *"All Dart code runs on the platform
thread. No other threading configurations are supported."*

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
SendPort messages get delivered. The downside: a 60 Hz timer floors latency
at ~16 ms even when work could finish faster, and vsync alignment is on
SDL's terms (with `SDL_HINT_RENDER_VSYNC` you'll still block in
`renderer.present()` but at least only on the timer tick). Cheapest path
to working `async`; what we'd ship first.

**B. SDL3 main-callbacks model.** SDL3 supports a callback-driven entry
point (`SDL_AppInit` / `SDL_AppIterate` / `SDL_AppEvent` / `SDL_AppQuit`,
gated by `SDL_MAIN_USE_CALLBACKS`) where SDL owns the runloop and calls
your code per-frame and per-event. On macOS this routes through
`NSApplication`'s runloop natively, on Linux through whatever it integrates
with there. Bigger lift — needs C glue and probably a small embedder
change so the platform-thread runloop is SDL's rather than
`fml::MessageLoop`'s (or so they cooperate via a CFRunLoopSource /
glib `GSource`). Pays off with proper vsync, lower idle CPU, and tighter
platform integration. The architecturally honest answer if/when a Timer
hack starts feeling load-bearing.

A third fallback exists — manually draining Dart microtasks from inside a
blocking SDL loop via embedder FFI (`Dart_HandleMessage` and friends) —
but it's fragile (reentering a message loop the embedder thinks it owns)
and there's no reason to pick it over (A).

Start with (A); plan a graceful migration to (B) if/when vsync, power, or
runloop integration becomes a real problem.

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

## Tricky bits worth flagging up front

1. **Glyph atlas management.** Even with SDL_ttf, you'll want to cache
   rasterized glyphs into a texture atlas keyed by (font, size, codepoint).
   Naive "render text per frame" is slow.
2. **Text layout vs shaping.** Without HarfBuzz, you can't do Arabic/Indic/CJK
   properly — and even Latin loses kerning/ligatures. Decide up front if you
   need it.
3. **Hit testing & event routing.** Walk the tree top-down for
   hover/focus/click. Easy but you have to actually do it.
4. **Animation/ticker.** SDL3 gives you a frame loop, but you need an
   interpolation/easing primitive and a way to mark widgets dirty. With
   approach (A) from the threading section the frame timer doubles as the
   ticker, and `Future.delayed`/`Stream.periodic` work normally between
   ticks.
5. **DPI scaling.** SDL3 exposes display scale; your layout must multiply
   through it.

## Recommendation

**Path 3** (SDL_ttf + SDL_image + Yoga + Dart widgets) is the sweet spot.
SDL_ttf/SDL_image are already in the SDL3 family so they bind cleanly via the
existing `sdl3` package surface. Yoga gives you a battle-tested layout brain
so you don't reinvent flexbox edge cases. Everything above that is plain
Dart that you fully control. You can ship a working "Hello World + button +
image" demo in a few hundred lines on top of this.

If you want a starting probe, the smallest interesting milestone is: open
SDL3 window → render a single line of text via SDL_ttf into the renderer →
wire up Yoga to position a `Text` next to a `Padding(child: Image)`. That
alone validates the whole stack.
