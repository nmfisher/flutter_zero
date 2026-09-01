import 'dart:math' as math;

/// Per-stage timings for one frame, in microseconds.
///
/// Mirrors the stage table in the design doc (§5.1). Phase 1 has no
/// inference, so [inferenceUs] stays at zero and is reported as n/a.
extension type FrameTimingUs._(List<int> _v) {
  FrameTimingUs.empty()
      : this._(List<int>.filled(_fieldCount, 0, growable: false));

  FrameTimingUs.of({
    required int captureDeliveryUs,
    required int uploadUs,
    required int renderUs,
    required int presentUs,
    required int glassToGlassUs,
  }) : this._(<int>[
          captureDeliveryUs,
          uploadUs,
          renderUs,
          presentUs,
          glassToGlassUs,
        ]);

  static const _fieldCount = 5;
  static const _captureDelivery = 0;
  static const _upload = 1;
  static const _render = 2;
  static const _present = 3;
  static const _glassToGlass = 4;

  /// Time from the camera's presentation timestamp to the frame being
  /// handed off for upload. Budget: <= 1 frame interval (§5.1).
  int get captureDeliveryUs => _v[_captureDelivery];

  /// Cost of copying the camera buffer into the render texture.
  /// Budget: <= 2 ms (the doc's preprocess bucket).
  int get uploadUs => _v[_upload];

  /// Cost of the Filament draw that samples the texture.
  /// Budget: <= 2 ms.
  int get renderUs => _v[_render];

  /// Time waiting for the swapchain to accept the frame.
  /// Budget: <= 1 vsync.
  int get presentUs => _v[_present];

  /// Camera presentation timestamp -> frame presented.
  /// Budget: <= 100 ms working, <= 50 ms stretch.
  int get glassToGlassUs => _v[_glassToGlass];
}

/// One stage of the pipeline, used as a key into [PipelineStats].
enum PipelineStage { captureDelivery, upload, render, present, glassToGlass }

/// A single bucketed histogram, kept allocation-free on the hot path.
///
/// Buckets are exponentially spaced (fine near zero, coarse near the top)
/// so a single histogram covers both sub-millisecond and 100 ms readings
/// without tuning.
class TimingHistogram {
  TimingHistogram({this.unitName = 'ms'})
      : _counts = List<int>.filled(_bucketBounds.length + 1, 0),
        _totalUs = 0,
        _sampleCount = 0,
        _maxUs = 0;

  /// Bucket upper bounds in microseconds. The final implicit bucket
  /// catches everything above the last bound.
  static const _bucketBounds = <int>[
    500, // 0.5 ms
    1000, // 1 ms
    2000, // 2 ms
    4000, // 4 ms
    8000, // 8 ms
    16667, // 1 frame @ 60 Hz
    33333, // 2 frames @ 60 Hz
    50000, // 50 ms stretch budget
    100000, // 100 ms working budget
    200000,
  ];

  final List<int> _counts;
  final String unitName;
  int _totalUs;
  int _sampleCount;
  int _maxUs;

  void addMicros(int micros) {
    if (micros < 0) return;
    _counts[_bucketIndex(micros)]++;
    _totalUs += micros;
    _sampleCount++;
    if (micros > _maxUs) _maxUs = micros;
  }

  int _bucketIndex(int micros) {
    // Linear scan is fine: 11 bounds, called ~4x per frame.
    for (var i = 0; i < _bucketBounds.length; i++) {
      if (micros < _bucketBounds[i]) return i;
    }
    return _bucketBounds.length;
  }

  int get sampleCount => _sampleCount;

  int get meanUs => _sampleCount == 0 ? 0 : _totalUs ~/ _sampleCount;

  int get maxUs => _maxUs;

  void reset() {
    _counts.fillRange(0, _counts.length, 0);
    _totalUs = 0;
    _sampleCount = 0;
    _maxUs = 0;
  }

  /// Mean in whole milliseconds, as displayed by the HUD.
  int get meanMs => meanUs ~/ 1000;

  int get maxMs => maxUs ~/ 1000;

  /// Fraction of samples inside [budgetUs], e.g. 0.997.
  double fractionWithin(int budgetUs) {
    if (_sampleCount == 0) return 1.0;
    var within = 0;
    for (var i = 0; i < _bucketBounds.length; i++) {
      if (_bucketBounds[i] > budgetUs) break;
      within += _counts[i];
    }
    return within / _sampleCount;
  }
}

/// Aggregated, HUD-ready view of the pipeline.
///
/// All methods are safe to call from the frame loop: nothing allocates
/// per frame beyond the [PipelineSnapshot] returned by [snapshot], which
/// the HUD asks for at most a few times a second.
class PipelineStats {
  PipelineStats({this.historyLength = 600})
      : captureDelivery = TimingHistogram(),
        upload = TimingHistogram(),
        render = TimingHistogram(),
        present = TimingHistogram(),
        glassToGlass = TimingHistogram(),
        _frameIntervalsUs = List<int>.filled(600, 0);

  final TimingHistogram captureDelivery;
  final TimingHistogram upload;
  final TimingHistogram render;
  final TimingHistogram present;
  final TimingHistogram glassToGlass;

  /// Frames observed since the last [reset].
  int get frameCount => _frameCount;
  int _frameCount = 0;

  /// Frames that arrived out of order, or were superseded before upload.
  int get droppedFrames => _droppedFrames;
  int _droppedFrames = 0;

  /// Camera frames the capture callback saw but the pipeline skipped
  /// because a newer one was already pending.
  int get staleFrames => _staleFrames;
  int _staleFrames = 0;

  /// Render ticks that had no new camera frame to show.
  int get emptyRenderTicks => _emptyRenderTicks;
  int _emptyRenderTicks = 0;

  final List<int> _frameIntervalsUs;
  final int historyLength;
  int _historyCursor = 0;

  /// Camera-reported frame interval, used to detect drops on the capture
  /// side: if two consecutive frames are ~2 intervals apart, one was lost
  /// before it ever reached us.
  int _lastCameraTimestampUs = 0;

  /// Frames the camera dropped upstream, inferred from timestamps.
  int get upstreamDroppedFrames => _upstreamDroppedFrames;
  int _upstreamDroppedFrames = 0;

  /// Smoothed display rate, in frames per second.
  double get fps => _fps;
  double _fps = 0;

  /// Camera's own reported rate, from its presentation timestamps.
  double get captureFps => _captureFps;
  double _captureFps = 0;

  void record(FrameTimingUs timing, {required int cameraTimestampUs}) {
    _frameCount++;
    captureDelivery.addMicros(timing.captureDeliveryUs);
    upload.addMicros(timing.uploadUs);
    render.addMicros(timing.renderUs);
    present.addMicros(timing.presentUs);
    glassToGlass.addMicros(timing.glassToGlassUs);

    if (_lastCameraTimestampUs != 0) {
      final interval = cameraTimestampUs - _lastCameraTimestampUs;
      if (interval > 0) {
        _frameIntervalsUs[_historyCursor] = interval;
        _historyCursor = (_historyCursor + 1) % historyLength;
        _updateCaptureFps(interval);
        _countUpstreamDrop(interval);
      }
    }
    _lastCameraTimestampUs = cameraTimestampUs;
  }

  /// Called once per render tick, even when no camera frame arrived, so
  /// the displayed fps reflects the render loop rather than the camera.
  void recordRenderTick() {
    _tickCount++;
    final nowUs = _nowUs();
    if (_tickStartUs == 0) {
      _tickStartUs = nowUs;
      return;
    }
    final elapsed = nowUs - _tickStartUs;
    if (elapsed >= 500000) {
      // Recompute twice a second rather than every tick.
      _fps = _tickCount * 1e6 / elapsed;
      _tickCount = 0;
      _tickStartUs = nowUs;
    }
  }

  void noteDroppedFrame() => _droppedFrames++;
  void noteStaleFrame() => _staleFrames++;
  void noteEmptyRenderTick() => _emptyRenderTicks++;

  int _tickCount = 0;
  int _tickStartUs = 0;

  void _updateCaptureFps(int intervalUs) {
    if (intervalUs <= 0) return;
    final instant = 1e6 / intervalUs;
    // Exponential smoothing keeps the HUD readable without hiding real
    // rate changes (e.g. the camera dropping from 60 to 30 fps).
    _captureFps = _captureFps == 0
        ? instant
        : _captureFps + (instant - _captureFps) * 0.1;
  }

  /// Median camera interval; a gap near 2x median means one lost frame.
  int _medianIntervalUs() {
    final samples = <int>[];
    for (var i = 0; i < historyLength && i < _frameCount; i++) {
      final v = _frameIntervalsUs[i];
      if (v > 0) samples.add(v);
    }
    if (samples.length < 8) return 0;
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  void _countUpstreamDrop(int intervalUs) {
    final median = _medianIntervalUs();
    if (median == 0) return;
    // Allow 1.75x before calling it a drop: real cameras jitter, and the
    // interval is only quantised to the presentation timestamp's timescale.
    if (intervalUs > median * 7 ~/ 4) {
      _upstreamDroppedFrames += (intervalUs / median).round() - 1;
    }
  }

  /// Point-in-time values for the HUD.
  PipelineSnapshot snapshot() => PipelineSnapshot(
        fps: _fps,
        captureFps: _captureFps,
        frameCount: _frameCount,
        droppedFrames: _droppedFrames,
        staleFrames: _staleFrames,
        emptyRenderTicks: _emptyRenderTicks,
        upstreamDroppedFrames: _upstreamDroppedFrames,
        captureDeliveryMs: captureDelivery.meanMs,
        captureDeliveryMaxMs: captureDelivery.maxMs,
        uploadMs: upload.meanMs,
        uploadMaxMs: upload.maxMs,
        renderMs: render.meanMs,
        renderMaxMs: render.maxMs,
        presentMs: present.meanMs,
        presentMaxMs: present.maxMs,
        glassToGlassMs: glassToGlass.meanMs,
        glassToGlassMaxMs: glassToGlass.maxMs,
        glassToGlassWithinBudget: glassToGlass.fractionWithin(100000),
      );

  void reset() {
    captureDelivery.reset();
    upload.reset();
    render.reset();
    present.reset();
    glassToGlass.reset();
    _frameCount = 0;
    _droppedFrames = 0;
    _staleFrames = 0;
    _emptyRenderTicks = 0;
    _upstreamDroppedFrames = 0;
    _lastCameraTimestampUs = 0;
    _historyCursor = 0;
    _fps = 0;
    _captureFps = 0;
    _tickCount = 0;
    _tickStartUs = 0;
  }
}

/// Immutable read-out for the HUD.
class PipelineSnapshot {
  PipelineSnapshot({
    required this.fps,
    required this.captureFps,
    required this.frameCount,
    required this.droppedFrames,
    required this.staleFrames,
    required this.emptyRenderTicks,
    required this.upstreamDroppedFrames,
    required this.captureDeliveryMs,
    required this.captureDeliveryMaxMs,
    required this.uploadMs,
    required this.uploadMaxMs,
    required this.renderMs,
    required this.renderMaxMs,
    required this.presentMs,
    required this.presentMaxMs,
    required this.glassToGlassMs,
    required this.glassToGlassMaxMs,
    required this.glassToGlassWithinBudget,
  });

  final double fps;
  final double captureFps;
  final int frameCount;
  final int droppedFrames;
  final int staleFrames;
  final int emptyRenderTicks;
  final int upstreamDroppedFrames;

  final int captureDeliveryMs;
  final int captureDeliveryMaxMs;
  final int uploadMs;
  final int uploadMaxMs;
  final int renderMs;
  final int renderMaxMs;
  final int presentMs;
  final int presentMaxMs;
  final int glassToGlassMs;
  final int glassToGlassMaxMs;

  /// Fraction of frames meeting the 100 ms working budget (§5.1).
  final double glassToGlassWithinBudget;

  /// True when every stage is inside its §5.1 budget. Used to colour the
  /// HUD and to decide the Phase 1 exit gate.
  bool get allBudgetsMet =>
      glassToGlassWithinBudget >= 0.999 &&
      uploadMs <= 2 &&
      renderMs <= 2 &&
      _totalMs <= 100;

  int get _totalMs => glassToGlassMs;

  /// Total dropped/empty ticks, the number the Phase 1 gate cares about.
  int get totalDrops =>
      droppedFrames + staleFrames + emptyRenderTicks + upstreamDroppedFrames;

  @override
  String toString() {
    String stage(String label, int mean, int max, [int? budgetMs]) {
      final flag = budgetMs == null || mean <= budgetMs ? '' : ' OVER';
      return '$label ${mean}ms (max ${max}ms)$flag';
    }

    return 'fps ${fps.toStringAsFixed(1)} '
        '(camera ${captureFps.toStringAsFixed(1)}) '
        'frames $frameCount drops $totalDrops | '
        '${stage('capture', captureDeliveryMs, captureDeliveryMaxMs)} '
        '${stage('upload', uploadMs, uploadMaxMs, 2)} '
        '${stage('render', renderMs, renderMaxMs, 2)} '
        '${stage('present', presentMs, presentMaxMs)} | '
        'glass-to-glass ${stage('total', glassToGlassMs, glassToGlassMaxMs, 100)}';
  }
}

/// Wall clock, injectable so tests can drive the frame clock.
int _nowUs() => DateTime.now().microsecondsSinceEpoch;

/// Convenience for tests and callers that want to assert on a snapshot.
extension PipelineSnapshotX on PipelineSnapshot {
  bool get isHealthy => allBudgetsMet && totalDrops == 0;
}

/// Clamps [value] into [min, max]; used by HUD layout.
int clampInt(int value, int min, int max) =>
    math.max(min, math.min(max, value));
