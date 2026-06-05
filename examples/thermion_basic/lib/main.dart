// ignore_for_file: avoid_print, implementation_imports

import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:isolate';

import 'package:sdl3/sdl3.dart';
import 'package:thermion_dart/thermion_dart.dart';
import 'package:thermion_dart/src/filament/src/implementation/ffi_filament_app.dart';

/// Vanilla Thermion bootstrap into an SDL3 window, macOS only for now.
///
/// Opens an 800×600 window, hands the backing `CAMetalLayer` to Filament,
/// renders a solid Catppuccin-flavoured background continuously. Escape or
/// closing the window quits.
///
/// No UI layer yet — this is the windowed peer of the headless capture
/// example. It validates:
///   1. The Filament Metal backend bootstraps against an externally-owned
///      `CAMetalLayer` (SDL3 owns the layer, Filament owns the swapchain).
///   2. `registerRequestFrameHook` actually fires per frame.
///   3. SDL3 event polling coexists with Filament's render thread.
///
/// Run on macOS:
///   ../../bin/dart run lib/main.dart
const _width = 800;
const _height = 600;

Future<void> main() async {
  if (!Platform.isMacOS) {
    print('This example targets macOS only for now.');
    return;
  }

  // 1. SDL3 setup ------------------------------------------------------------
  final sdlPath = _findSdlPath();
  if (sdlPath == null) {
    print('libSDL3.dylib not found. Try: brew install sdl3');
    return;
  }
  SdlDynamicLibraryService().set('sdl', sdlPath);

  if (!sdlInit(SDL_INIT_VIDEO)) {
    print('Failed to initialize SDL: ${sdlGetError()}');
    return;
  }

  final window = SdlWindowEx.create(
    title: 'Flutter Zero + Thermion',
    w: _width,
    h: _height,
    flags: SDL_WINDOW_RESIZABLE | SDL_WINDOW_METAL,
  );
  if (window == nullptr) {
    print('Failed to create window: ${sdlGetError()}');
    sdlQuit();
    return;
  }

  // 2. Pull the CAMetalLayer back out --------------------------------------
  // The sdl3 2.8.5 Dart bindings for SDL_Metal_CreateView/GetLayer have
  // broken signatures (return Void and take no view arg), so reach for
  // raw FFI against the same dylib SDL itself was loaded from.
  final libSdl = DynamicLibrary.open(sdlPath);
  final sdlMetalCreateView = libSdl.lookupFunction<
    Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)
  >('SDL_Metal_CreateView');
  final sdlMetalGetLayer = libSdl.lookupFunction<
    Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)
  >('SDL_Metal_GetLayer');
  final sdlMetalDestroyView = libSdl.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('SDL_Metal_DestroyView');

  final metalView = sdlMetalCreateView(window.cast());
  if (metalView == nullptr) {
    print('SDL_Metal_CreateView failed: ${sdlGetError()}');
    window.destroy();
    sdlQuit();
    return;
  }

  final metalLayer = sdlMetalGetLayer(metalView);
  if (metalLayer == nullptr) {
    print('SDL_Metal_GetLayer failed');
    sdlMetalDestroyView(metalView);
    window.destroy();
    sdlQuit();
    return;
  }

  print('SDL3 window created. CAMetalLayer @ ${metalLayer.address.toRadixString(16)}');

  // 3. Filament bootstrap ----------------------------------------------------
  print('Bootstrapping FFIFilamentApp...');
  await FFIFilamentApp.create();
  print('FilamentApp ready.');

  final swapChain = await FilamentApp.instance!.createSwapChain(
    metalLayer.cast(),
  );

  final viewer = ThermionViewerFFI();
  await viewer.initialized;
  await FilamentApp.instance!.renderManager.attach(viewer.view, swapChain);
  await viewer.view.setFrustumCullingEnabled(false);
  await viewer.setViewport(_width, _height);
  await viewer.setBackgroundColor(0.117, 0.117, 0.180, 1.0); // Catppuccin Mocha base

  // 4. Frame hook + quit signal ---------------------------------------------
  final quit = Completer<void>();
  var frames = 0;

  Future<void> onFrame() async {
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
    if (++frames % 60 == 0) {
      print('  frame $frames');
    }
  }

  await FilamentApp.instance!.registerRequestFrameHook(onFrame);

  // 5. Drive frames ----------------------------------------------------------
  await viewer.setRendering(true);
  print('Rendering. Press Escape or close the window to quit.');

  await quit.future;

  // 6. Cleanup ---------------------------------------------------------------
  print('Shutting down...');
  await viewer.setRendering(false);
  await FilamentApp.instance!.unregisterRequestFrameHook(onFrame);
  await viewer.dispose();
  await FilamentApp.instance!.destroy();

  sdlMetalDestroyView(metalView);
  window.destroy();
  sdlQuit();

  print('Goodbye!');
  Isolate.current.kill();
}

String? _findSdlPath() {
  const candidates = [
    '/opt/homebrew/lib/libSDL3.dylib',
    '/usr/local/lib/libSDL3.dylib',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
