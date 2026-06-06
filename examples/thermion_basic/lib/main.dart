// ignore_for_file: avoid_print, implementation_imports, unnecessary_import

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show File, Platform;
import 'dart:isolate';

import 'package:sdl3/sdl3.dart';
import 'package:thermion_dart/thermion_dart.dart';
import 'package:thermion_dart/src/filament/src/implementation/ffi_filament_app.dart';

/// Vanilla Thermion bootstrap into an SDL3 window.
///
/// Opens an 800×600 window, hands the backing native surface (CAMetalLayer
/// on macOS, X11 Window on Linux) to Filament, renders a solid background
/// at 60 Hz. Escape or closing the window quits.
///
/// Frame loop: on native Thermion does NOT drive frames automatically.
/// `setRendering(true)` only attaches the view to the swapchain; it does not
/// start a render loop. The actual continuous rendering uses Thermion's port-
/// based `FrameScheduler`, which spawns a native scheduler thread that posts
/// per-frame ticks to a Dart `ReceivePort`. Dart's event loop wakes up on
/// each tick, the listener pumps SDL events and calls `FilamentApp.render()`.
///
/// Run:
///   ../../bin/dart run lib/main.dart                       (macOS)
///   xvfb-run -s "-screen 0 800x600x24" \
///     ../../bin/dart run lib/main.dart                     (Linux/headless)
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
    title: 'Flutter Zero + Thermion',
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
    // Linux: hand Filament the X11 Window XID directly. Filament's stock
    // VulkanPlatform on Linux interprets the swapchain handle as an X11
    // Window (see filament/SwapChain.h: "X11 | Window").
    final props = sdlGetWindowProperties(window);
    final xid = sdlGetNumberProperty(
      props,
      SDL_PROP_WINDOW_X11_WINDOW_NUMBER,
      0,
    );
    if (xid == 0) {
      print('X11 Window XID unavailable. Wayland session, perhaps?');
      window.destroy();
      sdlQuit();
      return;
    }
    handle = Pointer.fromAddress(xid);
  }

  print('SDL3 window created. Native surface @ 0x'
      '${handle.address.toRadixString(16)}');

  // 3. Filament bootstrap ----------------------------------------------------
  print('Bootstrapping FFIFilamentApp...');
  await FFIFilamentApp.create();
  print('FilamentApp ready.');

  final swapChain = await FilamentApp.instance!.createSwapChain(handle.cast());

  final viewer = ThermionViewerFFI();
  await viewer.initialized;
  await FilamentApp.instance!.renderManager.attach(viewer.view, swapChain);
  await viewer.view.setFrustumCullingEnabled(false);
  await viewer.setViewport(_width, _height);
  await viewer.setBackgroundColor(0.117, 0.117, 0.180, 1.0); // Catppuccin Mocha base

  // 4. Port-based frame loop -------------------------------------------------
  // Thermion's port-based FrameScheduler spawns a native thread that posts
  // an int per frame to the supplied SendPort.nativePort. Dart's event loop
  // wakes up, listener runs, we drain SDL events + call render().
  FrameScheduler_initDartApi(NativeApi.initializeApiDLData);

  final framePort = ReceivePort();
  final quit = Completer<void>();
  var frames = 0;

  framePort.listen((_) async {
    if (quit.isCompleted) return;

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

    await FilamentApp.instance!.render();
    if (++frames % _targetFps == 0) {
      print('  frame $frames');
    }
  });

  FrameScheduler_startWithPort(framePort.sendPort.nativePort, _targetFps);
  print('Rendering. Press Escape or close the window to quit.');

  await quit.future;

  // 5. Cleanup ---------------------------------------------------------------
  print('Shutting down...');
  FrameScheduler_stop();
  framePort.close();

  // NOTE: skipping `viewer.dispose()` + `FilamentApp.destroy()` for now —
  // they trigger a "Concurrent modification during iteration" in Thermion
  // 0.4.0/develop's FFIFilamentApp.destroy when the swapchain list is in
  // certain states. The cli_windows example sidesteps it the same way
  // (just kill the isolate). Worth filing upstream.
  releaseNativeView?.call();
  window.destroy();
  sdlQuit();

  print('Goodbye!');
  Isolate.current.kill();
}

class _NativeView {
  _NativeView(this.layer, this.release);
  final Pointer<NativeType> layer;
  final void Function() release;
}

/// macOS: SDL_Metal_CreateView returns an NSView, then SDL_Metal_GetLayer
/// returns the backing CAMetalLayer*. The sdl3 2.8.5 Dart bindings for these
/// have broken C signatures (declare Void returns and drop the view arg),
/// so reach for raw FFI against the same dylib.
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
    // macOS
    '/opt/homebrew/lib/libSDL3.dylib',
    '/usr/local/lib/libSDL3.dylib',
    // Linux (the auto-loader should find these, but be explicit)
    '/usr/local/lib/libSDL3.so.0',
    '/usr/local/lib/libSDL3.so',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
