// ignore_for_file: avoid_print, unnecessary_import

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:thermion_dart/thermion_dart.dart';

import 'canvas.dart';
import 'geometry.dart' as ui;

/// Stub executor — counts only. Kept for reference / tests / fallback.
class StubFilamentExecutor implements DisplayListExecutor {
  int framesExecuted = 0;
  int commandsTotal = 0;

  @override
  Future<void> execute(DisplayList list) async {
    framesExecuted++;
    commandsTotal += list.length;
  }
}

/// Real executor — software-rasterizes the DisplayList into an RGBA8 buffer
/// each frame, uploads to a Filament Texture, and asks Filament to display
/// it on the scene's background plane.
///
/// Architecture (per the user's call: Filament does 3D only, we own 2D):
///
///   DisplayList ─► pure-Dart rasterizer ─► Uint8List (RGBA8)
///                                              │
///                                              ↓
///                              Texture.setImage(0, ...)   one upload per frame
///                                              │
///                                              ↓
///               viewer.setBackgroundImageFromTexture(texture)
///
/// **Caveat for this iteration:** the texture lands on Filament's
/// *background* plane (behind the 3D content) rather than as an overlay
/// on top. The stock `TexturedQuad` / image-material path is OPAQUE — its
/// fragment shader pre-blends inside the material and outputs alpha=1, so
/// it can't be used as an overlay surface. A real overlay needs either
/// a custom transparent material (compiled via `matc`) or a separate UI
/// `View` with an orthographic camera and its own quad geometry — both a
/// chunk more work than the seam shape itself. This commit gets the
/// rasterizer + upload + Filament wiring correct end-to-end so the
/// overlay-positioning rework is purely about *where* the texture renders,
/// not whether the pipeline works.
///
/// The 2D backend stays in 2D land. To upgrade quality (AA, gradients,
/// text), swap the rasterizer body — Blend2D, NanoVG-to-buffer, anything
/// that can produce a `Uint8List` — without changing the Filament side.
class FilamentDisplayListExecutor implements DisplayListExecutor {
  FilamentDisplayListExecutor._({
    required this.width,
    required this.height,
    required Texture texture,
  })  : _texture = texture,
        _buffer = Uint8List(width * height * 4);

  final int width;
  final int height;
  final Texture _texture;
  final Uint8List _buffer;

  int framesExecuted = 0;
  int commandsTotal = 0;

  /// Construct the executor and bind its texture to the viewer's background.
  static Future<FilamentDisplayListExecutor> create({
    required ThermionViewer viewer,
    required int width,
    required int height,
  }) async {
    final texture = await FilamentApp.instance!.createTexture(
      width,
      height,
      textureFormat: TextureFormat.RGBA8,
      // Default flags are just SAMPLEABLE; we also need UPLOADABLE to call
      // setImage() per frame from the CPU side.
      flags: const {
        TextureUsage.TEXTURE_USAGE_SAMPLEABLE,
        TextureUsage.TEXTURE_USAGE_UPLOADABLE,
      },
    );
    // Seed with the Catppuccin background color so the first frame isn't
    // black before the rasterizer fills it in.
    final initial = Uint8List(width * height * 4);
    for (var i = 0; i < initial.length; i += 4) {
      initial[i] = 30;
      initial[i + 1] = 30;
      initial[i + 2] = 46;
      initial[i + 3] = 255;
    }
    await texture.setImage(
      0,
      initial,
      width,
      height,
      PixelDataFormat.RGBA,
      PixelDataType.UBYTE,
    );

    await viewer.setBackgroundImageFromTexture(texture);

    print('FilamentDisplayListExecutor: ${width}x$height RGBA8 UI surface ready (background plane).');
    return FilamentDisplayListExecutor._(
      width: width,
      height: height,
      texture: texture,
    );
  }

  @override
  Future<void> execute(DisplayList list) async {
    framesExecuted++;
    commandsTotal += list.length;

    // Start each frame fully transparent so 3D shows through everywhere
    // not explicitly painted over.
    _buffer.fillRange(0, _buffer.length, 0);

    var tx = 0;
    var ty = 0;
    final stack = <List<int>>[];

    for (final cmd in list.commands) {
      switch (cmd) {
        case ClearCommand(:final color):
          _fillRect(0, 0, width, height, color);
        case FillRectCommand(:final rect, :final color):
          _fillRect(
            rect.x.toInt() + tx,
            rect.y.toInt() + ty,
            rect.width.toInt(),
            rect.height.toInt(),
            color,
          );
        case StrokeRectCommand(:final rect, :final color, :final width):
          final w = math.max(1, width.round());
          final x0 = rect.x.toInt() + tx;
          final y0 = rect.y.toInt() + ty;
          final rw = rect.width.toInt();
          final rh = rect.height.toInt();
          _fillRect(x0, y0, rw, w, color); // top
          _fillRect(x0, y0 + rh - w, rw, w, color); // bottom
          _fillRect(x0, y0, w, rh, color); // left
          _fillRect(x0 + rw - w, y0, w, rh, color); // right
        case SaveCommand():
          stack.add([tx, ty]);
        case RestoreCommand():
          if (stack.isNotEmpty) {
            final t = stack.removeLast();
            tx = t[0];
            ty = t[1];
          }
        case TranslateCommand(:final offset):
          tx += offset.dx.toInt();
          ty += offset.dy.toInt();
      }
    }

    await _texture.setImage(
      0,
      _buffer,
      width,
      height,
      PixelDataFormat.RGBA,
      PixelDataType.UBYTE,
    );
  }

  /// Source-over blend the colour into the buffer, clamped to bounds.
  /// `color.a == 255` is a fast-path overwrite; partial alpha does a
  /// standard porter-duff source-over against whatever's in the buffer.
  void _fillRect(int x, int y, int w, int h, ui.Color color) {
    final x0 = x.clamp(0, width);
    final y0 = y.clamp(0, height);
    final x1 = (x + w).clamp(0, width);
    final y1 = (y + h).clamp(0, height);
    if (x0 >= x1 || y0 >= y1) return;

    if (color.a == 255) {
      for (var py = y0; py < y1; py++) {
        var i = (py * width + x0) * 4;
        for (var px = x0; px < x1; px++) {
          _buffer[i] = color.r;
          _buffer[i + 1] = color.g;
          _buffer[i + 2] = color.b;
          _buffer[i + 3] = 255;
          i += 4;
        }
      }
      return;
    }

    // Source-over: out = src * srcA + dst * (1 - srcA)
    final srcA = color.a;
    final invA = 255 - srcA;
    for (var py = y0; py < y1; py++) {
      var i = (py * width + x0) * 4;
      for (var px = x0; px < x1; px++) {
        _buffer[i] = (color.r * srcA + _buffer[i] * invA) ~/ 255;
        _buffer[i + 1] = (color.g * srcA + _buffer[i + 1] * invA) ~/ 255;
        _buffer[i + 2] = (color.b * srcA + _buffer[i + 2] * invA) ~/ 255;
        _buffer[i + 3] = math.max(_buffer[i + 3], srcA);
        i += 4;
      }
    }
  }
}
