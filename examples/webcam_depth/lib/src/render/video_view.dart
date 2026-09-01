import 'dart:math' as math;

import 'package:thermion_dart/thermion_dart.dart';

import '../capture/camera_frame.dart';

/// Full-screen pass-through of a camera frame.
///
/// Owns one RGBA8 texture that is re-uploaded per frame and sampled by an
/// unlit screen-filling quad. This is the doc's §2.6 "Video" display mode,
/// the Phase 1 baseline.
///
/// Geometry and material setup follow `thermion_ui`'s proven
/// `FilamentDisplayListExecutor`; the differences are an opaque material
/// (video is not blended over anything) and `renderOrder: 0`.
class VideoPassThrough {
  VideoPassThrough._({
    required Texture texture,
    required this.view,
  }) : _texture = texture;

  final View view;

  /// The texture frames are uploaded into. Re-created in
  /// [configureCamera] when the camera format is known, because Filament
  /// textures are immutable in size.
  Texture _texture;
  TextureSampler? _sampler;
  UbershaderMaterialInstance? _material;
  MaterialInstance? _materialInstance;
  ThermionAsset? _quad;
  Camera? _camera;

  /// Resolution the texture was last allocated at.
  int _textureWidth = 0;
  int _textureHeight = 0;

  /// Camera aspect ratio, used to letterbox instead of stretch.
  double _cameraAspect = 16 / 9;

  /// True once the texture is sized for the real camera.
  bool get isConfigured => _textureWidth > 0;

  /// Builds the quad, material, scene and camera.
  ///
  /// [width]/[height] are the window size in physical pixels.
  static Future<VideoPassThrough> create({
    required int width,
    required int height,
    required SwapChain swapChain,
  }) async {
    final app = FilamentApp.instance!;

    // 1x1 placeholder so the quad has something valid to sample before the
    // first camera frame; [configureCamera] replaces it at camera size.
    final texture = await app.createTexture(
      1,
      1,
      textureFormat: TextureFormat.RGBA8,
      flags: const {
        TextureUsage.TEXTURE_USAGE_SAMPLEABLE,
        TextureUsage.TEXTURE_USAGE_UPLOADABLE,
      },
    );

    final pass = VideoPassThrough._(
      texture: texture,
      view: await app.createView(),
    );
    await pass._buildQuad(width, height, swapChain);
    return pass;
  }

  Future<void> _buildQuad(int width, int height, SwapChain swapChain) async {
    final app = FilamentApp.instance!;
    // Owned by the view once set; not kept past setup. (The Scene type is
    // not exported by thermion_dart's public barrel, so it stays local and
    // its type is inferred.)
    final scene = await app.createScene();

    // Unlit: the camera frame is a source image, not a lit surface.
    // Opaque: it is the only thing in the scene.
    final material = await app.createUbershaderMaterial(
      unlit: true,
      hasBaseColorTexture: true,
      alphaMode: AlphaMode.OPAQUE,
      doubleSided: true,
      baseColorUV: 0,
    );
    final sampler = await app.createTextureSampler();
    await material.setBaseColorTexture(_texture, sampler);
    // The ubershader multiplies the sample by baseColorFactor, whose
    // default of (0,0,0,0) silently blacks out the whole quad.
    await material.setBaseColorFactor(1.0, 1.0, 1.0, 1.0);

    // Screen-filling quad in NDC. The V axis is flipped so texture row 0
    // (the top row of the uploaded buffer) appears at the top of the
    // window, since video buffers are top-down.
    final vertices = Float32List.fromList([
      -1.0, -1.0, 0.0, //
      1.0, -1.0, 0.0, //
      1.0, 1.0, 0.0, //
      -1.0, 1.0, 0.0, //
    ]);
    final indices = Uint16List.fromList([0, 1, 2, 0, 2, 3]);
    final uvs = Float32List.fromList([
      0.0, 1.0, // bottom-left
      1.0, 1.0, // bottom-right
      1.0, 0.0, // top-right
      0.0, 0.0, // top-left
    ]);
    // The ubershader layout requires normals even for unlit materials.
    final normals = Float32List.fromList([
      0.0, 0.0, 1.0, //
      0.0, 0.0, 1.0, //
      0.0, 0.0, 1.0, //
      0.0, 0.0, 1.0, //
    ]);

    _quad = await app.createGeometry(
      Geometry(
        vertices,
        indices,
        normals: normals,
        uvs: uvs,
        primitiveType: PrimitiveType.TRIANGLES,
        indexType: IndexType.USHORT,
      ),
      materialInstances: [material.materialInstance],
    );
    await scene.add(_quad!);

    _camera = await app.createCamera();
    await _setOrtho(-1, 1, -1, 1);
    await _camera!.lookAt(Vector3(0, 0, 1));

    await view.setScene(scene);
    await view.setCamera(_camera!);
    await view.setViewport(width, height);
    await view.setPostProcessing(false);
    await view.setFrustumCullingEnabled(false);
    await view.setBlendMode(BlendMode.opaque);
    await app.renderManager.attach(view, swapChain, renderOrder: 0);

    _material = material;
    _materialInstance = material.materialInstance;
    _sampler = sampler;
  }

  /// Re-sizes the texture for a newly negotiated camera format.
  ///
  /// Called once per camera start, never per frame.
  Future<void> configureCamera(CameraFormat format) async {
    _cameraAspect = format.width / format.height;
    if (_textureWidth == format.width && _textureHeight == format.height) {
      return;
    }

    final next = await FilamentApp.instance!.createTexture(
      format.width,
      format.height,
      textureFormat: TextureFormat.RGBA8,
      flags: const {
        TextureUsage.TEXTURE_USAGE_SAMPLEABLE,
        TextureUsage.TEXTURE_USAGE_UPLOADABLE,
      },
    );

    // Rebind before disposing the old texture so the quad never samples a
    // dead handle.
    await _material!.setBaseColorTexture(next, _sampler!);
    await _material!.setBaseColorFactor(1.0, 1.0, 1.0, 1.0);
    final previous = _texture;
    _texture = next;
    _textureWidth = format.width;
    _textureHeight = format.height;
    await previous.destroy();
  }

  /// Uploads one frame.
  ///
  /// The only per-frame work in the render path: one upload of a pooled
  /// buffer, no allocation, and no CPU readback — nothing is ever read
  /// back, only written. Returns the upload cost in microseconds for the
  /// HUD.
  Future<int> present(CameraFrame frame) async {
    final stopwatch = Stopwatch()..start();
    await _texture.setImage(
      0,
      frame.pixels,
      frame.width,
      frame.height,
      PixelDataFormat.RGBA,
      PixelDataType.UBYTE,
    );
    stopwatch.stop();
    return stopwatch.elapsedMicroseconds;
  }

  /// Keeps the view and camera aspect correct on window resize.
  ///
  /// The camera feed keeps its own aspect ratio and is letterboxed, not
  /// stretched: whichever orthographic extent is relatively too small is
  /// widened to match.
  Future<void> resize(int width, int height) async {
    if (width <= 0 || height <= 0) return;
    await view.setViewport(width, height);

    final windowAspect = width / height;
    if (windowAspect > _cameraAspect) {
      // Window relatively wider: pillarbox.
      final halfWidth = math.max(1.0, _cameraAspect / windowAspect);
      await _setOrtho(-halfWidth, halfWidth, -1, 1);
    } else {
      // Window relatively taller: letterbox.
      final halfHeight = math.max(1.0, windowAspect / _cameraAspect);
      await _setOrtho(-1, 1, -halfHeight, halfHeight);
    }
  }

  Future<void> _setOrtho(
    double left,
    double right,
    double bottom,
    double top,
  ) async {
    await _camera!.setProjection(
      Projection.Orthographic,
      left, right, bottom, top, 0.1, 10,
    );
  }

  /// Tears down everything this object created.
  ///
  /// Skipped on shutdown in `main.dart` — see the note there about the
  /// Thermion teardown bug on develop.
  Future<void> dispose() async {
    final quad = _quad;
    if (quad != null) {
      await FilamentApp.instance!.destroyAsset(quad);
      _quad = null;
    }
    await _materialInstance?.destroy();
    _materialInstance = null;
    await _sampler?.dispose();
    _sampler = null;
    await _texture.destroy();
  }
}
