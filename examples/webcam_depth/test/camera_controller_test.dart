import 'dart:typed_data';

import 'package:flutter_zero_webcam_depth/src/capture/camera_controller.dart';
import 'package:flutter_zero_webcam_depth/src/capture/camera_frame.dart';
import 'package:flutter_zero_webcam_depth/src/capture/camera_source.dart';
import 'package:flutter_zero_webcam_depth/src/stats/pipeline_stats.dart';
import 'package:test/test.dart';

void main() {
  group('CameraController permission flow', () {
    test('transitions to running after a successful start', () async {
      final controller = CameraController(source: FakeCameraSource());
      expect(controller.state, CameraState.idle);

      await controller.start();

      expect(controller.state, CameraState.running);
      expect(controller.isRunning, isTrue);
      expect(controller.failure, isNull);
      expect(controller.format, isNotNull);
    });

    test('reports the negotiated format', () async {
      final controller = CameraController(
        source: FakeCameraSource(width: 1280, height: 720, framesPerSecond: 30),
      );
      await controller.start();

      final format = controller.format!;
      expect(format.width, 1280);
      expect(format.height, 720);
      expect(format.framesPerSecond, 30);
      expect(format.layout, PixelLayout.rgba8);
    });

    test('start is idempotent while running', () async {
      final source = FakeCameraSource();
      final controller = CameraController(source: source);
      await controller.start();
      await controller.start();

      expect(controller.state, CameraState.running);
      expect(source.lastTimestampUs, 0, reason: 'no frames requested yet');
    });

    test('an unsupported source fails with an explanatory reason',
        () async {
      final controller = CameraController(source: _UnsupportedSource());
      await controller.start();

      expect(controller.state, CameraState.failed);
      expect(controller.failure, isNotNull);
      expect(controller.failure!.title, 'Camera unavailable');
    });

    test('stop moves to stopped and clears the frame slot', () async {
      final source = FakeCameraSource();
      final controller = CameraController(source: source);
      await controller.start();
      source.produceOnce();

      await controller.stop();

      expect(controller.state, CameraState.stopped);
      expect(controller.isRunning, isFalse);
      expect(controller.acquireFrame(), isNull);
    });
  });

  group('CameraController frame handoff', () {
    test('acquireFrame returns the newest frame exactly once', () async {
      final source = FakeCameraSource();
      final controller = CameraController(source: source);
      await controller.start();

      final frame = source.produceOnce();

      final acquired = controller.acquireFrame();
      expect(acquired, same(frame));
      expect(controller.acquireFrame(), isNull,
          reason: 'a frame is delivered once');
    });

    test('counts a frame superseded before it was taken', () async {
      final source = FakeCameraSource();
      final stats = PipelineStats();
      final controller = CameraController(source: source, stats: stats);
      await controller.start();

      source.primeStaleFrame(); // produced, never taken
      source.produceOnce(); // supersedes it
      controller.acquireFrame();

      expect(stats.staleFrames, 1);
      expect(source.supersededFrames, 1);
    });

    test('does not count staleness when frames are consumed promptly',
        () async {
      final source = FakeCameraSource();
      final stats = PipelineStats();
      final controller = CameraController(source: source, stats: stats);
      await controller.start();

      for (var i = 0; i < 5; i++) {
        source.produceOnce();
        expect(controller.acquireFrame(), isNotNull);
      }

      expect(stats.staleFrames, 0);
      expect(source.supersededFrames, 0);
    });

    test('returns null on every tick when the camera emits nothing',
        () async {
      final source = FakeCameraSource(emitRealFrames: false);
      final stats = PipelineStats();
      final controller = CameraController(source: source, stats: stats);
      await controller.start();

      expect(controller.isRunning, isTrue,
          reason: 'the session is up even before the first frame');
      expect(controller.acquireFrame(), isNull);
      expect(controller.acquireFrame(), isNull);
    });
  });

  group('CameraFailure copy', () {
    test('denied explains how to re-enable access', () {
      const failure = CameraFailure(reason: CameraUnavailableReason.denied);
      expect(failure.title, 'Camera access denied');
      expect(failure.remediation, contains('Grant camera access'));
    });

    test('previously denied points at System Settings', () {
      const failure = CameraFailure(
        reason: CameraUnavailableReason.deniedPreviously,
      );
      expect(failure.remediation, contains('System Settings'));
      expect(failure.remediation, contains('Camera'));
    });

    test('no device asks for hardware', () {
      const failure = CameraFailure(reason: CameraUnavailableReason.noDevice);
      expect(failure.title, 'No camera found');
      expect(failure.remediation, contains('Connect a camera'));
    });

    test('configuration failure surfaces the platform detail', () {
      const failure = CameraFailure(
        reason: CameraUnavailableReason.configurationFailed,
        detail: 'session rejected output',
      );
      expect(failure.title, 'Could not start the camera');
      expect(failure.remediation, 'session rejected output');
    });
  });

  group('FakeCameraSource', () {
    test('frames are tightly packed BGRA', () async {
      final source = FakeCameraSource(width: 64, height: 32);
      await source.start();
      final frame = source.produceOnce();

      expect(frame.bytesPerRow, 64 * 4);
      expect(frame.pixels.length, 64 * 4 * 32);
      expect(frame.layout, PixelLayout.rgba8);
      await source.stop();
    });

    test('consecutive frames differ, so the pass-through visibly moves',
        () async {
      final source = FakeCameraSource(width: 32, height: 32);
      await source.start();

      final first = source.produceOnce();
      final firstBytes = Uint8List.fromList(first.pixels);
      final second = source.produceOnce();

      expect(second.pixels, isNot(orderedEquals(firstBytes)));
      await source.stop();
    });
  });
}

class _UnsupportedSource implements CameraSource {
  @override
  bool get isSupported => false;
  @override
  CameraFormat? get format => null;
  @override
  int get supersededFrames => 0;
  @override
  Future<CameraStartResult> start() async {
    throw StateError('should not be called when isSupported is false');
  }

  @override
  CameraFrame? takeFrame() => null;
  @override
  Future<void> stop() async {}
}
