// ignore_for_file: implementation_imports, unnecessary_import

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:thermion_dart/thermion_dart.dart';

/// Called once per scheduled frame with a monotonic timestamp.
typedef FrameCallback = void Function(Duration timestamp);

/// Same shape as `examples/sdl_ui`'s [FrameScheduler] interface — that's the
/// whole point. Consumer code (widget trees, animation tickers, the eventual
/// render walker) targets this and stays oblivious to whether ticks come
/// from a Dart `Timer`, a yield-loop, or Thermion's native scheduler.
abstract class FrameScheduler {
  set onFrame(FrameCallback callback);
  void scheduleFrame();
  Future<void> run();
  void stop();
}

/// Drives frames from Thermion's port-based native scheduler.
///
/// Thermion spawns a native scheduler thread that sends an integer message
/// per frame via `Dart_PostCObject_DL` to the supplied [SendPort]. Dart's
/// event loop wakes up on each tick; the listener invokes [onFrame] and
/// then `FilamentApp.render()` (in the consumer code, not here).
///
/// This is approach (B) from `UI_BRAINSTORMING.md`: real vsync-ish frame
/// pacing without owning the runloop and without any C glue on our side.
class ThermionFrameScheduler implements FrameScheduler {
  ThermionFrameScheduler({this.targetFps = 60});

  final int targetFps;

  FrameCallback? _onFrame;
  ReceivePort? _port;
  StreamSubscription<dynamic>? _portSub;
  Completer<void>? _runCompleter;
  final Stopwatch _clock = Stopwatch();
  bool _running = false;
  bool _scheduled = true;

  @override
  set onFrame(FrameCallback callback) => _onFrame = callback;

  /// No-op: Thermion's scheduler ticks continuously until [stop]. Consumers
  /// don't need to request individual frames the way a Flutter ticker would.
  /// Kept for interface parity with `YieldFrameScheduler`.
  @override
  void scheduleFrame() {
    _scheduled = true;
  }

  @override
  Future<void> run() async {
    if (_running) {
      throw StateError('ThermionFrameScheduler is already running');
    }
    _running = true;
    _clock.start();

    FrameScheduler_initDartApi(NativeApi.initializeApiDLData);

    _port = ReceivePort();
    _runCompleter = Completer<void>();

    _portSub = _port!.listen((_) {
      if (!_running || !_scheduled) return;
      _onFrame?.call(_clock.elapsed);
    });

    FrameScheduler_startWithPort(_port!.sendPort.nativePort, targetFps);

    return _runCompleter!.future;
  }

  @override
  void stop() {
    if (!_running) return;
    _running = false;
    FrameScheduler_stop();
    _portSub?.cancel();
    _port?.close();
    _clock.stop();
    if (!(_runCompleter?.isCompleted ?? true)) {
      _runCompleter!.complete();
    }
  }
}
