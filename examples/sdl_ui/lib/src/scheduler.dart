/// Called once per frame with a monotonic timestamp.
typedef FrameCallback = void Function(Duration timestamp);

/// Abstraction over the per-frame driver. Two intended implementations:
///
/// - [YieldFrameScheduler] (this file): a `while (running) { onFrame(); await
///   Future.delayed(Duration.zero); }` loop. Pacing comes from whatever the
///   frame body does (typically a vsync-blocking `renderer.present()`).
///   Approach (A) in UI_BRAINSTORMING.md.
/// - A future `SdlAppIterateFrameScheduler` that wires into SDL3's
///   `SDL_MAIN_USE_CALLBACKS` model and receives real vsync timestamps from
///   the platform display link. Approach (B).
///
/// The framework above this class only cares about [onFrame] firing per
/// frame with a timestamp it can use for animation/interpolation. Swapping
/// (A) for (B) shouldn't require changes above this seam.
abstract class FrameScheduler {
  /// Register the callback invoked once per scheduled frame.
  set onFrame(FrameCallback callback);

  /// Request another frame after the current one. Idempotent within a tick.
  void scheduleFrame();

  /// Run the scheduler until [stop] is called or no frame is requested.
  Future<void> run();

  /// Stop the scheduler. The current frame (if any) completes first.
  void stop();
}

class YieldFrameScheduler implements FrameScheduler {
  FrameCallback? _onFrame;
  final Stopwatch _clock = Stopwatch();
  bool _running = false;
  bool _frameScheduled = false;

  @override
  set onFrame(FrameCallback callback) => _onFrame = callback;

  @override
  void scheduleFrame() => _frameScheduled = true;

  @override
  Future<void> run() async {
    _running = true;
    _frameScheduled = true;
    _clock.start();

    while (_running && _frameScheduled) {
      _frameScheduled = false;
      _onFrame?.call(_clock.elapsed);
      // Yield so the embedder message loop drains microtasks, Future
      // callbacks, dart:io async, and isolate SendPort messages between
      // frames. Frame pacing comes from the frame body (typically a
      // vsync-blocking renderer.present()).
      await Future<void>.delayed(Duration.zero);
    }

    _clock.stop();
  }

  @override
  void stop() => _running = false;
}
