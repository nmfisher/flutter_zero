import 'dart:async';
import 'dart:typed_data';

import 'camera_frame.dart';

/// The platform-facing half of the capture pipeline.
///
/// Implementations own the native capture session and the frame buffer
/// pool. Frames are delivered newest-wins: if the consumer has not
/// released the previous frame when a new one arrives, the older frame is
/// superseded and reported as stale (design doc §2.4, "frames drop,
/// never queue").
///
/// The interface exists so the permission flow and render loop can be
/// exercised on a machine with no camera (and on CI) via [FakeCameraSource].
abstract class CameraSource {
  /// True when the platform can support capture at all (macOS only here).
  bool get isSupported;

  /// Asks for camera permission and starts the session.
  ///
  /// Completes once the permission dialog is resolved and the session is
  /// either configured or has failed; the app shows a permission screen
  /// while this is in flight.
  Future<CameraStartResult> start();

  /// Takes the newest frame, or null if none has arrived since the last
  /// take. The caller owns the frame until it calls [CameraFrame.release].
  CameraFrame? takeFrame();

  /// Number of frames superseded before the consumer read them.
  int get supersededFrames;

  /// Stops the session and frees the pool.
  Future<void> stop();

  /// The negotiated format, available after a successful [start].
  CameraFormat? get format;
}

/// A no-camera implementation that synthesises frames on a timer.
///
/// Used on Linux (where the app cannot run capture) and by the tests. It
/// emits a moving gradient so a render loop wired to it visibly changes
/// over time — enough to prove the upload and present path without a
/// camera.
class FakeCameraSource implements CameraSource {
  FakeCameraSource({
    this.width = 1280,
    this.height = 720,
    this.framesPerSecond = 30,
    this.emitRealFrames = true,
  });

  final int width;
  final int height;
  final int framesPerSecond;

  /// When false, no frames are produced at all — exercises the
  /// "render tick with nothing new to show" path.
  final bool emitRealFrames;

  final StreamController<CameraFormat> _started =
      StreamController.broadcast();

  Timer? _timer;
  int _sequence = 0;
  int _superseded = 0;
  CameraFrame? _pending;
  CameraFormat? _format;
  int _lastTimestampUs = 0;

  @override
  bool get isSupported => true;

  @override
  CameraFormat? get format => _format;

  @override
  int get supersededFrames => _superseded;

  /// Fires once per successful [start], with the negotiated format.
  Stream<CameraFormat> get onStarted => _started.stream;

  @override
  Future<CameraStartResult> start() async {
    if (_format != null) {
      return CameraStartResult.granted(_format!);
    }
    _format = CameraFormat(
      width: width,
      height: height,
      framesPerSecond: framesPerSecond,
      layout: PixelLayout.rgba8,
    );
    _started.add(_format!);
    if (emitRealFrames) {
      // A periodic timer stands in for the camera's delegate callback.
      _timer = Timer.periodic(
        Duration(microseconds: 1000000 ~/ framesPerSecond),
        (_) => _produce(),
      );
    }
    return CameraStartResult.granted(_format!);
  }

  void _produce() {
    _sequence++;
    final now = DateTime.now().microsecondsSinceEpoch;
    final stride = width * 4;
    final buffer = Uint8List(stride * height);
    _paintGradient(buffer, _sequence);

    final frame = CameraFrame(
      pixels: buffer,
      width: width,
      height: height,
      bytesPerRow: stride,
      timestampUs: now,
      layout: PixelLayout.rgba8,
      onRelease: () {},
    );

    // Newest-wins: a frame nobody took is dropped, not queued.
    final previous = _pending;
    if (previous != null) {
      _superseded++;
      previous.release();
    }
    _pending = frame;
    _lastTimestampUs = now;
  }

  /// Blue-to-magenta ramp that scrolls with [_sequence], so successive
  /// frames are visibly different.
  void _paintGradient(Uint8List buffer, int sequence) {
    final stride = width * 4;
    for (var y = 0; y < height; y++) {
      final rowPhase = (y * 255 ~/ height + sequence * 4) & 0xff;
      var offset = y * stride;
      for (var x = 0; x < width; x++) {
        buffer[offset++] = rowPhase;
        buffer[offset++] = (x * 255 ~/ width) & 0xff;
        buffer[offset++] = 255 - rowPhase;
        buffer[offset++] = 255;
      }
    }
  }

  @override
  CameraFrame? takeFrame() {
    final frame = _pending;
    _pending = null;
    return frame;
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _pending?.release();
    _pending = null;
    _format = null;
  }

  /// Test hook: synthesises one frame without waiting for the timer.
  CameraFrame produceOnce() {
    _produce();
    return _pending!;
  }

  /// Test hook: injects a frame the consumer never takes, so the next
  /// [produceOnce] reports a superseded frame.
  void primeStaleFrame() => _produce();

  int get lastTimestampUs => _lastTimestampUs;
}
