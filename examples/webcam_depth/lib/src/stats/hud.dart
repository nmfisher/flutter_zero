import 'package:thermion_dart/thermion_dart.dart';

import 'bitmap_font.dart';
import 'character_set.dart' as charset;
import 'pipeline_stats.dart';

/// On-screen overlay of the per-stage pipeline timings.
///
/// The design doc (§2.7, §5.2) asks for a HUD showing per-stage ms, fps,
/// drop count and glass-to-glass ms, toggled with a key. Thermion has no
/// text renderer, so the HUD rasterises its own 5x7 glyphs into one RGBA8
/// buffer and uploads that as a texture on a second Filament view layered
/// above the video.
///
/// The upload happens only when the HUD is visible and at most
/// [refreshInterval] apart, so an overlay that updates twice a second
/// costs two small uploads per second, not one per frame.
class StatsHud {
  StatsHud._({
    required this.view,
    required Texture texture,
    required this.canvas,
    required int width,
  })  : _texture = texture,
        _width = width,
        _visible = true;

  /// Glyph scale of the message screen. The stats grid draws at 1, so a
  /// scale of 3 makes a permission or error notice readable from a metre
  /// away without a second font.
  static const _messageScale = 3;

  final View view;

  final Texture _texture;
  final GlyphCanvas canvas;
  final int _width;

  bool _visible = true;

  /// A message screen owns the canvas until it is explicitly dismissed,
  /// so the periodic stats redraw cannot paint over a permission prompt.
  bool _messageShowing = false;

  Duration _lastUpload = Duration.zero;

  /// How often the HUD re-uploads while visible. Twice a second is ample
  /// for a stats readout and keeps the overlay off the frame budget.
  final Duration refreshInterval = const Duration(milliseconds: 500);

  /// Builds the HUD view, layered above the video at `renderOrder: 1`.
  static Future<StatsHud> create({
    required int width,
    required int height,
    required SwapChain swapChain,
  }) async {
    final app = FilamentApp.instance!;
    final font = BitmapFont.standard();

    // Window-sized rather than grid-sized: the message screen needs room
    // for large glyphs, and the stats grid uses only the top-left corner.
    final texture = await app.createTexture(
      width,
      height,
      textureFormat: TextureFormat.RGBA8,
      flags: const {
        TextureUsage.TEXTURE_USAGE_SAMPLEABLE,
        TextureUsage.TEXTURE_USAGE_UPLOADABLE,
      },
    );
    final canvas = GlyphCanvas(
      width: width,
      height: height,
      font: font,
    );

    final material = await app.createUbershaderMaterial(
      unlit: true,
      hasBaseColorTexture: true,
      // Alpha blend: transparent regions of the overlay must show the
      // video underneath.
      alphaMode: AlphaMode.BLEND,
      doubleSided: true,
      baseColorUV: 0,
    );
    final sampler = await app.createTextureSampler();
    await material.setBaseColorTexture(texture, sampler);
    await material.setBaseColorFactor(1.0, 1.0, 1.0, 1.0);

    final quad = await app.createGeometry(
      Geometry(
        Float32List.fromList([
          -1.0, -1.0, 0.0, //
          1.0, -1.0, 0.0, //
          1.0, 1.0, 0.0, //
          -1.0, 1.0, 0.0, //
        ]),
        Uint16List.fromList([0, 1, 2, 0, 2, 3]),
        normals: Float32List.fromList([
          0.0, 0.0, 1.0, //
          0.0, 0.0, 1.0, //
          0.0, 0.0, 1.0, //
          0.0, 0.0, 1.0, //
        ]),
        uvs: Float32List.fromList([
          0.0, 1.0, //
          1.0, 1.0, //
          1.0, 0.0, //
          0.0, 0.0, //
        ]),
        primitiveType: PrimitiveType.TRIANGLES,
        indexType: IndexType.USHORT,
      ),
      materialInstances: [material.materialInstance],
    );

    final scene = await app.createScene();
    await scene.add(quad);

    final camera = await app.createCamera();
    await camera.setProjection(Projection.Orthographic, -1, 1, -1, 1, 0.1, 10);
    await camera.lookAt(Vector3(0, 0, 1));

    final view = await app.createView();
    await view.setName('hud');
    await view.setScene(scene);
    await view.setCamera(camera);
    await view.setViewport(width, height);
    // Transparent so the video pass-through shows through.
    await view.setBlendMode(BlendMode.transparent);
    await view.setPostProcessing(false);
    await view.setFrustumCullingEnabled(false);

    await app.renderManager.attach(view, swapChain, renderOrder: 1);

    return StatsHud._(view: view, texture: texture, canvas: canvas, width: width);
  }

  /// Redraws the overlay from [snapshot] and uploads it if the refresh
  /// interval has elapsed.
  ///
  /// [now] is the frame-loop clock, so the HUD owns no clock of its own.
  /// Returns the upload cost in microseconds, or 0 when nothing was
  /// uploaded.
  Future<int> update(
    PipelineSnapshot snapshot, {
    required Duration now,
  }) async {
    if (!_visible || _messageShowing) {
      return 0;
    }
    if (now - _lastUpload < refreshInterval) {
      return 0;
    }

    _render(snapshot);
    final costUs = await _upload();
    _lastUpload = now;
    return costUs;
  }

  void _render(PipelineSnapshot s) {
    canvas.clear();
    canvas.moveTo(_pad, _pad);

    final colour = s.allBudgetsMet ? 'OK' : 'OVER BUDGET';
    canvas.drawLine('FPS ${s.fps.toStringAsFixed(1)} '
        '(CAMERA ${s.captureFps.toStringAsFixed(1)}) $colour');
    canvas.drawLine('FRAMES ${s.frameCount}   DROPS ${s.totalDrops}');
    canvas.drawLine('');

    // (mean ms / max ms) per stage, with the budget from the design doc.
    // Present is not separately measurable in Phase 1: thermion's render
    // call is synchronous through drawable submission, so the present
    // wait lands inside the render number.
    _stage('CAPTURE', s.captureDeliveryMs, s.captureDeliveryMaxMs, null);
    _stage('UPLOAD', s.uploadMs, s.uploadMaxMs, 2);
    _stage('RENDER', s.renderMs, s.renderMaxMs, 2);
    canvas.drawLine('PRESENT INSIDE RENDER SUBMIT');
    canvas.drawLine('');
    _stage('GLASS-TO-GLASS', s.glassToGlassMs, s.glassToGlassMaxMs, 100);
    canvas.drawLine(
        'WITHIN 100MS ${(s.glassToGlassWithinBudget * 100).toStringAsFixed(1)}%');
  }

  /// Draws [lines] as a large wrapped message screen and uploads
  /// immediately. The canvas stays owned by the message until
  /// [clearMessage] is called, so the periodic stats redraw cannot paint
  /// over a permission prompt or error notice.
  ///
  /// Used for the permission prompt and the error screen the design doc
  /// requires when the camera is denied or absent (§2.2).
  Future<void> showMessage(List<String> lines) async {
    canvas.clear();
    var y = _pad;
    final maxWidth = _width - 2 * _pad;
    for (final line in lines) {
      if (line.isEmpty) {
        y += canvas.lineHeight(scale: _messageScale);
        continue;
      }
      y = canvas.drawWrapped(
        line.toUpperCase(),
        _pad,
        y,
        scale: _messageScale,
        maxWidth: maxWidth,
      );
    }
    _messageShowing = true;
    await _upload();
  }

  /// Returns the canvas to the stats grid and forces a redraw on the next
  /// [update], skipping the rest of the refresh interval.
  void clearMessage() {
    if (!_messageShowing) return;
    _messageShowing = false;
    _lastUpload = Duration.zero;
  }

  void _stage(String label, int meanMs, int maxMs, int? budgetMs) {
    final budget = budgetMs == null ? '' : ' (BUDGET ${budgetMs}MS)';
    final over = budgetMs != null && meanMs > budgetMs ? ' OVER' : '';
    canvas.drawLine('$label ${meanMs}MS MAX ${maxMs}MS$budget$over');
  }

  /// Uploads the canvas; returns the cost in microseconds.
  Future<int> _upload() async {
    final stopwatch = Stopwatch()..start();
    await _texture.setImage(
      0,
      canvas.pixels,
      canvas.width,
      canvas.height,
      PixelDataFormat.RGBA,
      PixelDataType.UBYTE,
    );
    stopwatch.stop();
    return stopwatch.elapsedMicroseconds;
  }

  static const _pad = 2;

  /// Shows or hides the HUD. A hidden HUD uploads nothing, so it costs
  /// nothing per frame while dismissed.
  Future<void> setVisible(bool value) async {
    if (_visible == value) return;
    _visible = value;
    if (value) {
      // Redraw immediately on the next update rather than waiting out the
      // refresh interval.
      _lastUpload = Duration.zero;
    }
  }

  Future<void> dispose() async {
    await _texture.destroy();
  }
}

/// Ensures the HUD format strings only use glyphs the font can draw.
///
/// Called once at startup so a missing glyph is a startup failure with a
/// clear message rather than silently blank characters on screen.
void assertHudStringsRenderable(Iterable<String> lines) {
  for (final line in lines) {
    if (!charset.canRender(line)) {
      throw StateError('HUD font is missing a glyph for: "$line"');
    }
  }
}
