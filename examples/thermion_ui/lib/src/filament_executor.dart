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
/// each frame, uploads to a Filament Texture, and composites it ON TOP of
/// the 3D scene via a separate Filament View attached to the same SwapChain
/// at `renderOrder: 1`.
///
/// Architecture (per the user's call: Filament does 3D only, we own 2D):
///
///   DisplayList ─► pure-Dart rasterizer ─► Uint8List (RGBA8)
///                                              │
///                                              ↓
///                              Texture.setImage(0, ...)   one upload per frame
///                                              │
///                                              ↓
///         UI View → orthographic camera → fullscreen quad
///         (unlit ubershader, AlphaMode.BLEND, baseColorMap=our texture)
///                                              │
///                                              ↓
///       SwapChain composes the 3D View (order 0) and UI View (order 1)
///
/// The 2D backend stays in 2D land. To upgrade quality (AA, gradients,
/// text), swap the rasterizer body — Blend2D, NanoVG-to-buffer, anything
/// that can produce a `Uint8List` — without changing the Filament side.
///
/// **Notable gotcha during bring-up:** the ubershader's `baseColorFactor`
/// uniform defaults to `(0, 0, 0, 0)`. The fragment color is
/// `baseColorTexture × baseColorFactor`, so without explicitly setting the
/// factor to `(1, 1, 1, 1)` everything multiplies to zero — the UI view
/// renders, but every pixel is transparent black. `setBaseColorFactor`
/// below is load-bearing, not cosmetic.
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

  /// Construct the executor, set up the UI View, and attach it to the
  /// SwapChain at `renderOrder: 1` so it draws on top of the 3D View.
  static Future<FilamentDisplayListExecutor> create({
    required int width,
    required int height,
    required SwapChain swapChain,
  }) async {
    final app = FilamentApp.instance!;

    // 1. The UI surface texture (RGBA8) and an empty seed upload.
    final texture = await app.createTexture(
      width,
      height,
      textureFormat: TextureFormat.RGBA8,
      flags: const {
        TextureUsage.TEXTURE_USAGE_SAMPLEABLE,
        TextureUsage.TEXTURE_USAGE_UPLOADABLE,
      },
    );
    final seed = Uint8List(width * height * 4); // all zero = transparent
    await texture.setImage(
      0,
      seed,
      width,
      height,
      PixelDataFormat.RGBA,
      PixelDataType.UBYTE,
    );

    // 2. Material: unlit ubershader with a base-color texture, alpha blend.
    //    AlphaMode.BLEND emits per-fragment alpha so the UI View's
    //    transparent blend composites it over the 3D output.
    final material = await app.createUbershaderMaterial(
      unlit: true,
      hasBaseColorTexture: true,
      alphaMode: AlphaMode.BLEND,
      doubleSided: true,
      baseColorUV: 0,
    );
    final sampler = await app.createTextureSampler();
    await material.setBaseColorTexture(texture, sampler);
    // Ubershader multiplies the texture sample by baseColorFactor. Default
    // is (0,0,0,0) which silently zeros everything out — set it to white.
    await material.setBaseColorFactor(1.0, 1.0, 1.0, 1.0);

    // 3. Screen-filling quad in NDC space.
    //    Vertices in world coords [-1, 1] × [-1, 1] at z=0. The V axis is
    //    flipped so texture row 0 (top of our buffer) maps to the top of
    //    the screen.
    final vertices = Float32List.fromList([
      -1.0, -1.0, 0.0,
      1.0, -1.0, 0.0,
      1.0, 1.0, 0.0,
      -1.0, 1.0, 0.0,
    ]);
    final indices = [0, 1, 2, 0, 2, 3];
    final uvs = Float32List.fromList([
      0.0, 1.0, // bottom-left  → samples row height-1 (bottom of buffer)
      1.0, 1.0, // bottom-right
      1.0, 0.0, // top-right    → samples row 0 (top of buffer)
      0.0, 0.0, // top-left
    ]);
    // Normals (0, 0, 1) for all vertices — quad faces +Z toward the
    // camera. The ubershader vertex layout requires normals even for unlit
    // materials.
    final normals = Float32List.fromList([
      0.0, 0.0, 1.0,
      0.0, 0.0, 1.0,
      0.0, 0.0, 1.0,
      0.0, 0.0, 1.0,
    ]);
    final geometry = Geometry(
      vertices,
      indices,
      normals: normals,
      uvs: uvs,
      primitiveType: PrimitiveType.TRIANGLES,
      indexType: IndexType.UINT,
    );

    final quadAsset = await app.createGeometry(
      geometry,
      materialInstances: [material.materialInstance],
    );

    // 4. UI scene + camera + view.
    final uiScene = await app.createScene();
    await uiScene.add(quadAsset);

    final uiCamera = await app.createCamera();
    await uiCamera.setProjection(
      Projection.Orthographic,
      -1, 1, -1, 1, 0.1, 10,
    );
    await uiCamera.lookAt(Vector3(0, 0, 1));

    final uiView = await app.createView();
    await uiView.setName('ui');
    await uiView.setScene(uiScene);
    await uiView.setCamera(uiCamera);
    await uiView.setViewport(width, height);
    await uiView.setBlendMode(BlendMode.transparent);
    await uiView.setPostProcessing(false);
    await uiView.setFrustumCullingEnabled(false);

    await app.renderManager.attach(uiView, swapChain, renderOrder: 1);

    print('FilamentDisplayListExecutor: ${width}x$height RGBA8 UI on a '
        'transparent overlay View (renderOrder: 1).');
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
          _fillRect(x0, y0, rw, w, color);
          _fillRect(x0, y0 + rh - w, rw, w, color);
          _fillRect(x0, y0, w, rh, color);
          _fillRect(x0 + rw - w, y0, w, rh, color);
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
