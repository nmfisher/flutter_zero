// ignore_for_file: avoid_print

import 'dart:math';

import 'package:sdl3/sdl3.dart';

import 'src/app.dart';
import 'src/canvas.dart';
import 'src/geometry.dart';

/// The demo lives in a class so its [onEvent]/[onFrame] methods are passed to
/// [SdlApp.run] as tear-offs. Hot reload swaps the code of methods on live
/// instances, but never re-creates closures from already-executed code — so
/// keeping the frame logic in `main()` closures would make edits to it
/// silently invisible to hot reload.
class Demo {
  var bgIndex = 0;

  static const bgPalette = [
    Color(30, 30, 46),   // Catppuccin Mocha base
    Color(24, 24, 37),   // mantle
    Color(17, 17, 27),   // crust
    Color(49, 50, 68),   // surface0
  ];

  bool onEvent(SdlxEvent event) {
    if (event is SdlxKeyboardEvent && event.type == SdlkEvent.keyDown) {
      switch (event.scancode) {
        case SdlkScancode.escape:
          return false;
        case SdlkScancode.on1:
          bgIndex = 0;
        case SdlkScancode.on2:
          bgIndex = 1;
        case SdlkScancode.on3:
          bgIndex = 2;
        case SdlkScancode.on4:
          bgIndex = 3;
        default:
          break;
      }
    }
    return true;
  }

  void onFrame(Canvas canvas, Duration timestamp) {
    final t = timestamp.inMicroseconds / 1e6;
    canvas.clear(bgPalette[bgIndex]);

    // Six animated squares orbit the centre, color-cycling.
    const cx = 400.0;
    const cy = 300.0;
    const orbitRadius = 180.0;
    for (var i = 0; i < 2; i++) {
      final angle = t * 0.7 + i * pi * 2 / 6;
      final size = 50.0 + sin(t * 2 + i) * 10;
      final x = cx + cos(angle) * orbitRadius - size / 2;
      final y = cy + sin(angle) * orbitRadius - size / 2;
      canvas.fillRect(Rect(x, y, size, size), _hueColor(angle));
    }

    // A static centre square so it's obvious whether the scene is
    // painting on top of the background each frame.
    canvas.strokeRect(const Rect(390, 290, 20, 20), const Color(243, 139, 168));
  }
}

void main() async {
  print('Starting sdl_ui demo. Press Escape (or close the window) to exit.');

  final demo = Demo();
  await SdlApp.run(
    title: 'Flutter Zero + SDL3 — sdl_ui foundation',
    width: 800,
    height: 600,
    onEvent: demo.onEvent,
    onFrame: demo.onFrame,
  );

  print('Goodbye!');
}

Color _hueColor(double angleRad) {
  final hueDeg = (angleRad * 180 / pi) % 360;
  final h = (hueDeg < 0 ? hueDeg + 360 : hueDeg) / 60;
  final x = (1 - (h % 2 - 1).abs());
  late double r, g, b;
  if (h < 1) {
    r = 1;
    g = x;
    b = 0;
  } else if (h < 2) {
    r = x;
    g = 1;
    b = 0;
  } else if (h < 3) {
    r = 0;
    g = 1;
    b = x;
  } else if (h < 4) {
    r = 0;
    g = x;
    b = 1;
  } else if (h < 5) {
    r = x;
    g = 0;
    b = 1;
  } else {
    r = 1;
    g = 0;
    b = x;
  }
  return Color((r * 220).toInt(), (g * 220).toInt(), (b * 220).toInt());
}
