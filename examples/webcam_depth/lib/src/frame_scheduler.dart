import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:thermion_dart/thermion_dart.dart';

/// Drives the render loop from Thermion's port-based frame scheduler.
///
/// On native, Thermion does not render on its own: `setRendering(true)` only
/// attaches a view to a swapchain. `FrameScheduler_startWithPort` spawns a
/// native thread that posts an integer per frame to a Dart `ReceivePort`;
/// Dart's event loop wakes on each tick and the [onFrame] callback runs.
/// That keeps SDL event polling and Filament rendering on the same thread,
/// which is what the other Flutter Zero examples do.
class FrameLoop {
  FrameLoop({required this.targetFps});

  /// Requested frame rate. The scheduler treats this as a target, not a
  /// ceiling it enforces by dropping work.
  final int targetFps;

  ReceivePort? _port;
  StreamSubscription<dynamic>? _subscription;
  bool _running = false;

  /// Called once per scheduler tick with the time since the loop started.
  void Function(Duration elapsed)? onFrame;

  Duration get elapsed => _clock.elapsed;
  final Stopwatch _clock = Stopwatch();

  void start() {
    if (_running) return;
    _running = true;

    // Registers Dart_PostCObject_DL so the native thread can post to a port.
    FrameScheduler_initDartApi(ffi.NativeApi.initializeApiDLData);

    _clock.start();
    _port = ReceivePort();
    _subscription = _port!.listen((_) {
      if (!_running) return;
      onFrame?.call(_clock.elapsed);
    });

    FrameScheduler_startWithPort(_port!.sendPort.nativePort, targetFps);
  }

  void stop() {
    if (!_running) return;
    _running = false;
    FrameScheduler_stop();
    _subscription?.cancel();
    _subscription = null;
    _port?.close();
    _port = null;
    _clock.stop();
  }
}
