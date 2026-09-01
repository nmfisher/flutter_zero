import 'dart:async';

import '../stats/pipeline_stats.dart';
import 'camera_frame.dart';
import 'camera_source.dart';

/// Drives the permission flow and owns the newest camera frame.
///
/// The design doc (§2.2) asks for permission to be requested on launch
/// with a clear error screen when denied. This class is deliberately
/// free of any window/rendering concern so both paths can be tested
/// without a display.
class CameraController {
  CameraController({required CameraSource source, PipelineStats? stats})
      : _source = source,
        _stats = stats;

  final CameraSource _source;
  final PipelineStats? _stats;

  CameraState _state = CameraState.idle;
  CameraFailure? _failure;

  /// Set once [start] resolves, then per-frame by [acquireFrame].
  CameraFormat? get format => _source.format;

  CameraState get state => _state;

  CameraFailure? get failure => _failure;

  bool get isRunning => _state == CameraState.running;

  /// Completes when the permission dialog is dismissed and the session
  /// has either started or failed. Callers use [state]/[failure] to pick
  /// what to draw.
  Future<void> start() async {
    if (_state == CameraState.running) return;

    if (!_source.isSupported) {
      _fail(CameraUnavailableReason.unknown,
          'This platform has no camera capture implementation.');
      return;
    }

    _state = CameraState.requestingPermission;
    final result = await _source.start();

    if (!result.isSuccess) {
      _fail(result.reason ?? CameraUnavailableReason.unknown, result.detail);
      return;
    }

    _failure = null;
    _state = CameraState.running;
  }

  void _fail(CameraUnavailableReason reason, String? detail) {
    _failure = CameraFailure(reason: reason, detail: detail);
    _state = CameraState.failed;
  }

  /// Returns the newest frame, or null when nothing new arrived.
  ///
  /// A frame that was superseded while nobody was looking is counted as
  /// stale here: the doc's newest-wins slot (§2.4).
  CameraFrame? acquireFrame() {
    final frame = _source.takeFrame();
    if (frame == null) return null;

    final superseded = _source.supersededFrames;
    if (_lastObservedSuperseded >= 0 && superseded > _lastObservedSuperseded) {
      _stats?.noteStaleFrame();
    }
    _lastObservedSuperseded = superseded;
    return frame;
  }

  int _lastObservedSuperseded = 0;

  Future<void> stop() async {
    if (_state == CameraState.stopped) return;
    await _source.stop();
    _state = CameraState.stopped;
  }
}

/// Everything the error screen needs to explain itself.
class CameraFailure {
  const CameraFailure({required this.reason, this.detail});

  final CameraUnavailableReason reason;
  final String? detail;

  /// One-line explanation shown on the error screen.
  String get title => switch (reason) {
        CameraUnavailableReason.denied ||
        CameraUnavailableReason.deniedPreviously =>
          'Camera access denied',
        CameraUnavailableReason.noDevice => 'No camera found',
        CameraUnavailableReason.configurationFailed =>
          'Could not start the camera',
        CameraUnavailableReason.unknown => 'Camera unavailable',
      };

  /// What the user can do about it.
  String get remediation => switch (reason) {
        CameraUnavailableReason.denied =>
          'Grant camera access and restart the app.',
        CameraUnavailableReason.deniedPreviously =>
          'Allow camera access in System Settings > Privacy & Security > '
              'Camera, then restart the app.',
        CameraUnavailableReason.noDevice =>
          'Connect a camera and restart the app.',
        CameraUnavailableReason.configurationFailed =>
          detail ?? 'Try restarting the app.',
        CameraUnavailableReason.unknown => 'Try restarting the app.',
      };

  @override
  String toString() => '$title — $remediation';
}
