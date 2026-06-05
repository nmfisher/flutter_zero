// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io' show File, Platform;
import 'dart:math';

import 'package:sdl3/sdl3.dart';

const _width = 800;
const _height = 600;

void main() {
  _registerSdlLibrary();

  if (!sdlInit(SDL_INIT_VIDEO)) {
    print('Failed to initialize SDL: ${sdlGetError()}');
    return;
  }
  sdlSetHint(SDL_HINT_RENDER_VSYNC, '1');

  final window = SdlWindowEx.create(
    title: 'Flutter Zero + SDL3',
    w: _width,
    h: _height,
    flags: SDL_WINDOW_RESIZABLE,
  );
  if (window == nullptr) {
    print('Failed to create window: ${sdlGetError()}');
    sdlQuit();
    return;
  }

  final renderer = window.createRenderer();
  if (renderer == nullptr) {
    print('Failed to create renderer: ${sdlGetError()}');
    window.destroy();
    sdlQuit();
    return;
  }

  print('SDL3 window created. Press Escape (or close the window) to exit.');
  print('Press 1-4 to change the background color. Move the mouse around.');

  final bgColors = [
    SdlxColor(30, 30, 46),
    SdlxColor(24, 24, 37),
    SdlxColor(17, 17, 27),
    SdlxColor(49, 50, 68),
  ];

  var running = true;
  var mouseX = (_width / 2).toDouble();
  var mouseY = (_height / 2).toDouble();
  var bgIndex = 0;
  var frame = 0;

  while (running) {
    SdlxEvent? event;
    while ((event = sdlxPollEvent()) != null) {
      if (event is SdlxQuitEvent) {
        running = false;
      } else if (event is SdlxKeyboardEvent &&
          event.type == SdlkEvent.keyDown) {
        switch (event.scancode) {
          case SdlkScancode.escape:
            running = false;
          case SdlkScancode.on1:
            bgIndex = 0;
          case SdlkScancode.on2:
            bgIndex = 1;
          case SdlkScancode.on3:
            bgIndex = 2;
          case SdlkScancode.on4:
            bgIndex = 3;
        }
      } else if (event is SdlxMouseMotionEvent) {
        mouseX = event.x;
        mouseY = event.y;
      }
    }

    frame++;
    final t = frame * 0.02;
    const cx = _width / 2;
    const cy = _height / 2;

    renderer
      ..setDrawColor(bgColors[bgIndex])
      ..clear();

    // Outer ring: six spinning, color-cycling squares.
    for (var i = 0; i < 6; i++) {
      final angle = t + i * (pi * 2 / 6);
      const radius = 160.0;
      final rx = cx + cos(angle) * radius;
      final ry = cy + sin(angle) * radius;
      final size = 40.0 + sin(t * 2 + i) * 12;

      final r = (127 + sin(angle + t) * 127).toInt();
      final g = (127 + sin(angle + t + 2) * 127).toInt();
      final b = (127 + sin(angle + t + 4) * 127).toInt();

      renderer
        ..setDrawColor(SdlxColor(r, g, b))
        ..fillRect(SdlxFRect(
          x: rx - size / 2,
          y: ry - size / 2,
          w: size,
          h: size,
        ));
    }

    // Inner ring: twelve small counter-rotating dots.
    renderer.setDrawColor(SdlxColor(205, 214, 244));
    for (var i = 0; i < 12; i++) {
      final angle = -t * 1.5 + i * (pi * 2 / 12);
      const radius = 60.0;
      final rx = cx + cos(angle) * radius;
      final ry = cy + sin(angle) * radius;
      renderer.fillRect(SdlxFRect(x: rx - 3, y: ry - 3, w: 6, h: 6));
    }

    // Mouse cursor indicator: filled centre + outlined target box.
    renderer
      ..setDrawColor(SdlxColor(243, 139, 168))
      ..fillRect(SdlxFRect(x: mouseX - 5, y: mouseY - 5, w: 10, h: 10))
      ..rect(SdlxFRect(x: mouseX - 14, y: mouseY - 14, w: 28, h: 28));

    renderer.present();
  }

  renderer.destroy();
  window.destroy();
  sdlQuit();

  print('SDL3 cleaned up. Goodbye!');
}

// dlopen's default search path on macOS includes /usr/local/lib (Intel
// Homebrew) but NOT /opt/homebrew/lib (Apple Silicon Homebrew). When the
// example runs inside a Flutter .app bundle, DYLD_LIBRARY_PATH is also
// usually stripped by SIP — so probe known install locations and pin an
// absolute path on SdlDynamicLibraryService before sdlInit.
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
