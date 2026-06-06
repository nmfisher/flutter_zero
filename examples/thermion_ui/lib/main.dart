// ignore_for_file: avoid_print, implementation_imports, unnecessary_import

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show File, Platform;
import 'dart:isolate';
import 'dart:math';

import 'package:sdl3/sdl3.dart';
import 'package:thermion_dart/thermion_dart.dart';
import 'package:thermion_dart/src/filament/src/implementation/ffi_filament_app.dart';

import 'src/canvas.dart';
import 'src/filament_executor.dart';
import 'src/geometry.dart' as ui;
import 'src/scheduler.dart';

/// Wires sdl_ui's framework abstractions (`FrameScheduler`, recording
/// `Canvas`, `DisplayList`, `DisplayListExecutor`) against Thermion.
///
/// Renders the same lit cube as `examples/thermion_basic` for visual
/// confirmation, but drives the per-frame work through:
///
///   ThermionFrameScheduler  // wraps FrameScheduler_startWithPort
///         │ onFrame(t)
///         ↓
///   RecordingCanvas → DisplayList
///         │
///         ↓
///   StubFilamentExecutor (counts; future: emits Filament UI quads)
///
/// The 3D scene (cube + lights + camera orbit) still goes directly through
/// Thermion's `ThermionViewer` API — no UI overlay rendering yet. The
/// `RecordingCanvas` is exercised every frame so the seam is in place and
/// swappable: when the real executor lands, the consumer code below
/// doesn't change.
///
/// Run:
///   ../../bin/dart run lib/main.dart                       (macOS)
///   xvfb-run -s "-screen 0 800x600x24" \
///     ../../bin/dart run lib/main.dart                     (Linux headless)
const _width = 800;
const _height = 600;
const _targetFps = 60;

Future<void> main() async {
  if (!Platform.isMacOS && !Platform.isLinux) {
    print('Platform not supported yet: ${Platform.operatingSystem}');
    return;
  }

  // 1. SDL3 setup ------------------------------------------------------------
  final sdlPath = _findSdlPath();
  if (sdlPath != null) {
    SdlDynamicLibraryService().set('sdl', sdlPath);
  }
  if (!sdlInit(SDL_INIT_VIDEO)) {
    print('Failed to initialize SDL: ${sdlGetError()}');
    return;
  }

  var windowFlags = SDL_WINDOW_RESIZABLE;
  if (Platform.isMacOS) windowFlags |= SDL_WINDOW_METAL;

  final window = SdlWindowEx.create(
    title: 'Flutter Zero + Thermion (sdl_ui wired)',
    w: _width,
    h: _height,
    flags: windowFlags,
  );
  if (window == nullptr) {
    print('Failed to create window: ${sdlGetError()}');
    sdlQuit();
    return;
  }

  // 2. Native surface acquisition -------------------------------------------
  final Pointer<NativeType> handle;
  void Function()? releaseNativeView;

  if (Platform.isMacOS) {
    final result = _acquireMetalLayer(window, sdlPath!);
    if (result == null) {
      window.destroy();
      sdlQuit();
      return;
    }
    handle = result.layer;
    releaseNativeView = result.release;
  } else {
    final props = sdlGetWindowProperties(window);
    final xid = sdlGetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    if (xid == 0) {
      print('X11 Window XID unavailable.');
      window.destroy();
      sdlQuit();
      return;
    }
    handle = Pointer.fromAddress(xid);
  }

  // 3. Filament bootstrap ----------------------------------------------------
  await FFIFilamentApp.create();
  final swapChain = await FilamentApp.instance!.createSwapChain(handle.cast());

  final viewer = ThermionViewerFFI();
  await viewer.initialized;
  await FilamentApp.instance!.renderManager.attach(viewer.view, swapChain);
  await viewer.view.setFrustumCullingEnabled(false);
  await viewer.setViewport(_width, _height);
  await viewer.setBackgroundColor(0.117, 0.117, 0.180, 1.0);

  // 4. 3D scene --------------------------------------------------------------
  await viewer.addDirectLight(DirectLight.sun(
    intensity: 25000.0,
    color: const LinearColor(1.0, 0.95, 0.85),
    direction: Vector3(-0.4, -0.7, -0.6)..normalize(),
    castShadows: false,
  ));
  await viewer.addDirectLight(DirectLight.sun(
    intensity: 8000.0,
    color: const LinearColor(0.6, 0.7, 1.0),
    direction: Vector3(0.5, -0.3, 0.5)..normalize(),
    castShadows: false,
  ));
  await viewer.createGeometry(GeometryUtils.cube());

  final camera = await viewer.getActiveCamera();
  await camera.setLensProjection();

  // 5. The framework wiring --------------------------------------------------
  final scheduler = ThermionFrameScheduler(targetFps: _targetFps);
  final executor = StubFilamentExecutor();
  final stopwatch = Stopwatch()..start();
  final quit = Completer<void>();

  scheduler.onFrame = (timestamp) {
    // Run the per-frame work as an async chain — the scheduler invokes
    // synchronously, but our render submission and SDL polling are async.
    _frame(
      timestamp: timestamp,
      scheduler: scheduler,
      executor: executor,
      camera: camera,
      stopwatch: stopwatch,
      quit: quit,
    );
  };

  scheduler.scheduleFrame();
  unawaited(scheduler.run());

  print('Rendering. Press Escape or close the window to quit.');
  await quit.future;

  // 6. Cleanup ---------------------------------------------------------------
  print('Shutting down...');
  print('UI executor stats: ${executor.framesExecuted} frames, '
      '${executor.commandsTotal} draw commands recorded.');

  scheduler.stop();

  // Skip viewer.dispose() + FilamentApp.destroy(): they hit a Thermion
  // concurrent-modification bug on develop. cli_windows does the same.
  releaseNativeView?.call();
  window.destroy();
  sdlQuit();

  print('Goodbye!');
  Isolate.current.kill();
}

int _frames = 0;

Future<void> _frame({
  required Duration timestamp,
  required ThermionFrameScheduler scheduler,
  required StubFilamentExecutor executor,
  required Camera camera,
  required Stopwatch stopwatch,
  required Completer<void> quit,
}) async {
  if (quit.isCompleted) return;

  // --- SDL event drain (still our responsibility) --------------------------
  SdlxEvent? event;
  while ((event = sdlxPollEvent()) != null) {
    if (event is SdlxQuitEvent) {
      if (!quit.isCompleted) quit.complete();
      return;
    }
    if (event is SdlxKeyboardEvent &&
        event.type == SdlkEvent.keyDown &&
        event.scancode == SdlkScancode.escape) {
      if (!quit.isCompleted) quit.complete();
      return;
    }
  }

  // --- Build the per-frame display list ------------------------------------
  // Even though the executor is a stub, exercising the recording API every
  // frame proves the seam works end-to-end. When the real Filament executor
  // lands, the consumer code here is unchanged.
  final canvas = RecordingCanvas();
  canvas.clear(const ui.Color(20, 20, 30));
  // A "HUD" box that drifts horizontally — the kind of thing the eventual
  // overlay would render.
  final wobble = sin(timestamp.inMicroseconds / 1e6) * 60;
  canvas.fillRect(
    ui.Rect(20 + wobble, 20, 200, 40),
    const ui.Color(243, 139, 168),
  );
  canvas.strokeRect(
    const ui.Rect(20, 80, 760, 500),
    const ui.Color(166, 173, 200),
  );
  await executor.execute(canvas.build());

  // --- Orbit the camera around the cube ------------------------------------
  final t = stopwatch.elapsedMilliseconds / 1000.0;
  final angle = t * (2 * pi / 12);
  await camera.lookAt(Vector3(4 * sin(angle), 2.5, 4 * cos(angle)));

  // --- Submit the frame to Filament ---------------------------------------
  await FilamentApp.instance!.render();

  scheduler.scheduleFrame();

  if (++_frames % _targetFps == 0) {
    print('  frame $_frames  (display list: ${canvas.build().length} cmds)');
  }
}

class _NativeView {
  _NativeView(this.layer, this.release);
  final Pointer<NativeType> layer;
  final void Function() release;
}

_NativeView? _acquireMetalLayer(Pointer<SdlWindow> window, String sdlPath) {
  final libSdl = DynamicLibrary.open(sdlPath);
  final create = libSdl.lookupFunction<
    Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)
  >('SDL_Metal_CreateView');
  final getLayer = libSdl.lookupFunction<
    Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)
  >('SDL_Metal_GetLayer');
  final destroy = libSdl.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('SDL_Metal_DestroyView');

  final view = create(window.cast());
  if (view == nullptr) {
    print('SDL_Metal_CreateView failed: ${sdlGetError()}');
    return null;
  }
  final layer = getLayer(view);
  if (layer == nullptr) {
    print('SDL_Metal_GetLayer failed');
    destroy(view);
    return null;
  }
  return _NativeView(layer, () => destroy(view));
}

String? _findSdlPath() {
  const candidates = [
    '/opt/homebrew/lib/libSDL3.dylib',
    '/usr/local/lib/libSDL3.dylib',
    '/usr/local/lib/libSDL3.so.0',
    '/usr/local/lib/libSDL3.so',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
