import 'dart:ffi';

import 'package:sdl3/sdl3.dart';

import 'geometry.dart';

/// Thin wrapper around the SDL3 renderer with framework-side types.
/// All calls run on the platform thread (where SDL3 wants them).
class Canvas {
  Canvas(this._renderer);

  final Pointer<SdlRenderer> _renderer;

  void clear(Color color) {
    _renderer
      ..setDrawColor(SdlxColor(color.r, color.g, color.b, color.a))
      ..clear();
  }

  void fillRect(Rect rect, Color color) {
    _renderer
      ..setDrawColor(SdlxColor(color.r, color.g, color.b, color.a))
      ..fillRect(SdlxFRect(
        x: rect.x,
        y: rect.y,
        w: rect.width,
        h: rect.height,
      ));
  }

  void strokeRect(Rect rect, Color color) {
    _renderer
      ..setDrawColor(SdlxColor(color.r, color.g, color.b, color.a))
      ..rect(SdlxFRect(
        x: rect.x,
        y: rect.y,
        w: rect.width,
        h: rect.height,
      ));
  }
}
