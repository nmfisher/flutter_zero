import 'dart:ffi';
import 'dart:io' show File, Platform;

import 'package:sdl3/sdl3.dart';

import 'canvas.dart';
import 'scheduler.dart';

/// Called once per frame to paint the next scene. Receives a [Canvas] tied
/// to the SDL renderer and a monotonic [timestamp] suitable for animation.
typedef RenderCallback = void Function(Canvas canvas, Duration timestamp);

/// Optional event hook. Return `false` to quit the app.
typedef EventCallback = bool Function(SdlxEvent event);

class SdlApp {
  static Future<void> run({
    required String title,
    required int width,
    required int height,
    required RenderCallback onFrame,
    EventCallback? onEvent,
    FrameScheduler? scheduler,
  }) async {
    _registerSdlLibrary();

    if (!sdlInit(SDL_INIT_VIDEO)) {
      print('Failed to initialize SDL: ${sdlGetError()}');
      return;
    }
    sdlSetHint(SDL_HINT_RENDER_VSYNC, '1');

    final window = SdlWindowEx.create(
      title: title,
      w: width,
      h: height,
      flags: SDL_WINDOW_RESIZABLE,
    );
    if (window == nullptr) {
      print('Failed to create window: ${sdlGetError()}');
      sdlQuit();
      return;
    }

    final rendererPtr = window.createRenderer();
    if (rendererPtr == nullptr) {
      print('Failed to create renderer: ${sdlGetError()}');
      window.destroy();
      sdlQuit();
      return;
    }

    final canvas = Canvas(rendererPtr);
    final sched = scheduler ?? YieldFrameScheduler();

    sched.onFrame = (timestamp) {
      var keepRunning = true;
      SdlxEvent? event;
      while ((event = sdlxPollEvent()) != null) {
        if (event is SdlxQuitEvent) {
          keepRunning = false;
          break;
        }
        if (onEvent != null && !onEvent(event!)) {
          keepRunning = false;
          break;
        }
      }
      if (!keepRunning) {
        sched.stop();
        return;
      }

      onFrame(canvas, timestamp);

      // Blocks for vsync when SDL_HINT_RENDER_VSYNC is on — the natural
      // frame pacer for approach (A).
      rendererPtr.present();

      sched.scheduleFrame();
    };

    await sched.run();

    rendererPtr.destroy();
    window.destroy();
    sdlQuit();
  }
}

/// dlopen's default search path on macOS includes /usr/local/lib (Intel
/// Homebrew) but NOT /opt/homebrew/lib (Apple Silicon Homebrew). When
/// running inside a Flutter .app bundle, DYLD_LIBRARY_PATH is also usually
/// stripped by SIP — so probe known install locations and pin an absolute
/// path on SdlDynamicLibraryService before sdlInit.
void _registerSdlLibrary() {
  if (!Platform.isMacOS) return;
  const candidates = [
    '/opt/homebrew/lib/libSDL3.dylib',
    '/usr/local/lib/libSDL3.dylib',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      SdlDynamicLibraryService().set('sdl', path);
      return;
    }
  }
}
