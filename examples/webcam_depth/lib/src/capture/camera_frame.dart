import 'dart:typed_data';

/// Pixel layout of a frame delivered by the capture shim.
///
/// Capture requests BGRA (the one 32-bit format every UVC camera can
/// deliver), and the shim swizzles to RGBA while copying into the pool,
/// because thermion's upload API only offers `PixelDataFormat.RGBA`. So
/// the buffers Dart sees are always RGBA and upload without conversion.
enum PixelLayout { rgba8 }

/// One captured camera frame.
///
/// The pixel memory is owned by the capture shim's buffer pool, not by
/// this object — [release] returns it to the pool. Nothing here copies or
/// allocates on the frame path; the design doc's §5.2 "pool everything"
/// rule.
class CameraFrame {
  CameraFrame({
    required this.pixels,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.timestampUs,
    required this.layout,
    required void Function() onRelease,
  }) : _onRelease = onRelease;

  /// View over the pooled buffer. Valid until [release].
  final Uint8List pixels;
  final int width;
  final int height;

  /// Row stride in bytes. Larger than `width * 4` when the source pads.
  final int bytesPerRow;

  /// Camera presentation timestamp in microseconds. This is the start of
  /// the glass-to-glass measurement (§5.1).
  final int timestampUs;
  final PixelLayout layout;

  final void Function() _onRelease;
  bool _released = false;

  bool get released => _released;

  /// Returns the buffer to the pool. Idempotent, so a frame that is both
  /// superseded and dropped does not double-release.
  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }

  @override
  String toString() =>
      'CameraFrame(${width}x$height, ${layout.name}, t=$timestampUs)';
}

/// Static description of the negotiated capture format.
class CameraFormat {
  const CameraFormat({
    required this.width,
    required this.height,
    required this.framesPerSecond,
    required this.layout,
    this.bytesPerRow,
  });

  final int width;
  final int height;
  final int framesPerSecond;
  final PixelLayout layout;

  /// Row stride in bytes, as reported by the capture session. Null when
  /// the platform layer does not report one, in which case the frame is
  /// assumed tightly packed.
  final int? bytesPerRow;

  int get bytesPerPixel => 4;

  /// Row stride used for uploads: the reported stride when there is one,
  /// otherwise the tightly packed width.
  int get effectiveBytesPerRow => bytesPerRow ?? width * bytesPerPixel;

  /// Size of one frame as delivered, including any row padding.
  int get frameBytes => effectiveBytesPerRow * height;

  @override
  String toString() => '${width}x$height@$framesPerSecond ${layout.name}';
}

/// Why the camera is unavailable. Drives the error screen copy.
enum CameraUnavailableReason {
  /// The user declined, or a previous denial is still in force.
  denied,

  /// Access was previously denied and must be re-enabled in System Settings.
  deniedPreviously,

  /// macOS reports no camera, or none the app can open.
  noDevice,

  /// The device exists but the session could not be configured.
  configurationFailed,

  /// Anything unexpected.
  unknown,
}

/// The permission + session state machine (§2.2).
enum CameraState {
  /// Nothing asked yet.
  idle,

  /// The system permission dialog is up.
  requestingPermission,

  /// Permission granted, configuring `AVCaptureSession`.
  configuring,

  /// Delivering frames.
  running,

  /// Permission denied or no camera. See [CameraFailure.reason].
  failed,

  /// Deliberately stopped.
  stopped,
}

/// Result of starting capture.
class CameraStartResult {
  const CameraStartResult.granted(this.format)
      : reason = null,
        detail = null,
        state = CameraState.running;

  const CameraStartResult.failed(this.reason, [this.detail])
      : format = null,
        state = CameraState.failed;

  final CameraFormat? format;
  final CameraState state;
  final CameraUnavailableReason? reason;

  /// Human-readable detail from the platform layer, if any.
  final String? detail;

  bool get isSuccess => format != null;

  @override
  String toString() => isSuccess
      ? 'CameraStartResult($format)'
      : 'CameraStartResult(${reason!.name}${detail == null ? '' : ': $detail'})';
}
