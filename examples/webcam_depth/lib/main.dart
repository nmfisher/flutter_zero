// ignore_for_file: avoid_print, implementation_imports

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show File, Platform, exit;
import 'dart:isolate';

import 'package:sdl3/sdl3.dart';
import 'package:thermion_dart/thermion_dart.dart';
import 'package:thermion_dart/src/filament/src/implementation/ffi_filament_app.dart';

import 'src/capture/camera_controller.dart';
import 'src/capture/camera_frame.dart';
import 'src/capture/camera_source.dart';
import 'src/capture/native_camera_source.dart';
import 'src/frame_scheduler.dart';
import 'src/render/video_view.dart';
import 'src/stats/hud.dart';
import 'src/stats/pipeline_stats.dart';

/// Standalone macOS webcam pass-through — Phase 1 of the standalone macOS
/// webcam depth design doc.
///
/// One window, one camera, no model. `AVCaptureSession` fills a pooled set
/// of BGRA buffers, the newest frame is uploaded into a Filament texture
/// every render tick, and an unlit quad draws it full-screen. A stats HUD
/// reports per-stage timings so every budget in the design doc is a
/// measured number rather than an assumption.
///
/// Run (macOS):
///   ../../bin/dart run lib/main.dart
///
/// The pure-Dart logic (stats, permission flow, frame handoff) is covered
/// by `dart test` and runs on any platform; the capture shim itself is
/// macOS-only.
const _width = 1280;
const _height = 720;
const _targetFps = 60;

Future<void> main(List<String> arguments) async {
  final exitCode = await runApp(
    arguments,
    width: _width,
    height: _height,
    targetFps: _targetFps,
  );
  exit(exitCode);
}

/// Separated from [main] so the exit path is explicit and testable.
Future<int> runApp(
  List<String> arguments, {
  required int width,
  required int height,
  required int targetFps,
}) async {
  if (!Platform.isMacOS && !Platform.isLinux) {
    print('Unsupported platform: ${Platform.operatingSystem}');
    return 64;
  }

  final useNativeCapture = Platform.isMacOS;
  // On Linux there is no camera shim, so a synthetic source stands in: the
  // window, render loop and HUD all still run, which is what makes the
  // non-capture half of this app testable off a Mac.
  final cameraSource = useNativeCapture
      ? NativeCameraSource()
      : FakeCameraSource(
          width: width,
          height: height,
          framesPerSecond: 30,
        );

  final stats = PipelineStats();
  final controller = CameraController(source: cameraSource, stats: stats);

  // 1. SDL3 -----------------------------------------------------------------
  final sdlPath = _findSdlPath();
  if (sdlPath != null) {
    SdlDynamicLibraryService().set('sdl', sdlPath);
  }
  if (!sdlInit(SDL_INIT_VIDEO)) {
    print('Failed to initialize SDL: ${sdlGetError()}');
    return 65;
  }

  final windowFlags = SDL_WINDOW_RESIZABLE |
      (Platform.isMacOS ? SDL_WINDOW_METAL : 0);

  final window = SdlWindowEx.create(
    title: 'Webcam Depth — Phase 1 (pass-through)',
    w: width,
    h: height,
    flags: windowFlags,
  );
  if (window == nullptr) {
    print('Failed to create window: ${sdlGetError()}');
    sdlQuit();
    return 65;
  }

  // 2. Native surface -------------------------------------------------------
  final surface = Platform.isMacOS
      ? _acquireMetalLayer(window, sdlPath!)
      : _acquireX11Window(window);
  if (surface == null) {
    window.destroy();
    sdlQuit();
    return 65;
  }

  // 3. Filament -------------------------------------------------------------
  print('Bootstrapping Filament...');
  await FFIFilamentApp.create();
  final swapChain =
      await FilamentApp.instance!.createSwapChain(surface.handle.cast());

  final video = await VideoPassThrough.create(
    width: width,
    height: height,
    swapChain: swapChain,
  );
  final hud = await StatsHud.create(
    width: width,
    height: height,
    swapChain: swapChain,
  );

  // 4. Camera permission + session -----------------------------------------
  print('Requesting camera access...');
  await controller.start();

  switch (controller.state) {
    case CameraState.running:
      final format = controller.format!;
      print('Camera: $format');
      await video.configureCamera(format);
      await hud.showMessage([
        'CAPTURING',
        '',
        'AWAITING FIRST FRAME',
      ]);
    case CameraState.failed:
      final failure = controller.failure!;
      print('Camera unavailable: $failure');
      await hud.showMessage([
        failure.title.toUpperCase(),
        '',
        ...failure.remediation.toUpperCase().split('. ').map(_withPeriod),
        '',
        'PRESS ESCAPE TO QUIT',
      ]);
    default:
      await hud.showMessage(['STARTING...', '', 'PLEASE WAIT']);
  }

  // 5. Frame loop -----------------------------------------------------------
  final loop = FrameLoop(targetFps: targetFps);
  final quit = Completer<int>();
  var hudVisible = true;
  var messageCleared = false;
  var uploadUs = 0;

  loop.onFrame = (now) async {
    if (quit.isCompleted) return;

    // Input.
    SdlxEvent? event;
    while ((event = sdlxPollEvent()) != null) {
      if (event is SdlxQuitEvent) {
        quit.complete(0);
        return;
      }
      if (event is SdlxKeyboardEvent && event.type == SdlkEvent.keyDown) {
        if (event.scancode == SdlkScancode.escape) {
          quit.complete(0);
          return;
        }
        if (event.scancode == SdlkScancode.h) {
          hudVisible = !hudVisible;
          await hud.setVisible(hudVisible);
        }
      }
      if (event is SdlxWindowEvent && event.type == SDL_EVENT_WINDOW_RESIZED) {
        await video.resize(event.data1, event.data2);
      }
    }

    // Capture: poll the newest frame. Nothing new means the render tick
    // still runs at display rate and simply re-presents the last upload.
    final captureStart = Stopwatch()..start();
    final frame = controller.acquireFrame();
    captureStart.stop();

    if (frame != null) {
      uploadUs = await video.present(frame);
      if (!messageCleared) {
        messageCleared = true;
        hud.clearMessage();
      }
    } else {
      stats.noteEmptyRenderTick();
    }

    // Synchronous through drawable submission, so this wall time carries
    // both the render and present stages of the design doc's budget table.
    final renderStart = Stopwatch()..start();
    await FilamentApp.instance!.render();
    renderStart.stop();
    stats.recordRenderTick();

    if (frame != null) {
      final presentedUs = DateTime.now().microsecondsSinceEpoch;
      stats.record(
        FrameTimingUs.of(
          captureDeliveryUs: captureStart.elapsedMicroseconds,
          uploadUs: uploadUs,
          renderUs: renderStart.elapsedMicroseconds,
          presentUs: 0,
          glassToGlassUs: presentedUs - frame.timestampUs,
        ),
        cameraTimestampUs: frame.timestampUs,
      );
      frame.release();
    }

    await hud.update(stats.snapshot(), now: now);
  };

  loop.start();
  print('Rendering at $targetFps fps. '
      'H toggles the HUD, Escape quits.');

  final code = await quit.future;
  loop.stop();

  // 6. Teardown -------------------------------------------------------------
  // viewer.dispose()/FilamentApp.destroy() are deliberately skipped:
  // Thermion develop hits a concurrent-modification fault in
  // FilamentApp.destroy for certain swapchain states, and thermion_ui
  // works around it the same way. Killing the isolate reclaims everything.
  await controller.stop();
  surface.release();
  window.destroy();
  sdlQuit();
  Isolate.current.kill();

  return code;
}

/// Restores the full stop that `.split('. ')` consumed, so the error
/// screen keeps normal sentence punctuation.
String _withPeriod(String sentence) =>
    sentence.endsWith('.') ? sentence : '$sentence.';

String? _findSdlPath() {
  const candidates = [
    '/opt/homebrew/lib/libSDL3.dylib',
    '/usr/local/lib/libSDL3.dylib',
    '/usr/local/lib/libSDL3.so.0',
    '/usr/local/lib/libSDL3.so',
  ];
  for (final path in candidates) {
    if (_fileExists(path)) return path;
  }
  return null;
}

bool _fileExists(String path) => File(path).existsSync();

class _Surface {
  _Surface(this.handle, this.release);
  final ffi.Pointer<ffi.NativeType> handle;
  final void Function() release;
}

/// macOS: `SDL_Metal_CreateView` returns an NSView and
/// `SDL_Metal_GetLayer` its backing CAMetalLayer, which is the handle
/// Filament's Metal backend wants.
///
/// The sdl3 Dart bindings for these two have broken C signatures (they
/// declare void returns and drop the view argument), so they are called
/// with raw FFI against the dylib — same workaround as thermion_basic.
_Surface? _acquireMetalLayer(
  Pointer<SdlWindow> window,
  String sdlPath,
) {
  final libSdl = ffi.DynamicLibrary.open(sdlPath);
  final create = libSdl.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>(
    'SDL_Metal_CreateView',
  );
  final getLayer = libSdl.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>(
    'SDL_Metal_GetLayer',
  );
  final destroyView = libSdl.lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Void>),
      void Function(ffi.Pointer<ffi.Void>)>('SDL_Metal_DestroyView');

  final view = create(window.cast());
  if (view == ffi.nullptr) {
    print('SDL_Metal_CreateView failed: ${sdlGetError()}');
    return null;
  }
  final layer = getLayer(view);
  if (layer == ffi.nullptr) {
    print('SDL_Metal_GetLayer failed');
    destroyView(view);
    return null;
  }
  return _Surface(layer, () => destroyView(view));
}

/// Linux: hand Filament the X11 Window XID for its Vulkan backend.
_Surface? _acquireX11Window(Pointer<SdlWindow> window) {
  final props = sdlGetWindowProperties(window);
  final xid = sdlGetNumberProperty(
    props,
    SDL_PROP_WINDOW_X11_WINDOW_NUMBER,
    0,
  );
  if (xid == 0) {
    print('X11 Window XID unavailable. Wayland session, perhaps?');
    return null;
  }
  return _Surface(
    ffi.Pointer.fromAddress(xid),
    () {},
  );
}
