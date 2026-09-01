import 'package:flutter_zero_webcam_depth/src/stats/pipeline_stats.dart';
import 'package:test/test.dart';

FrameTimingUs timing({
  int captureDeliveryUs = 0,
  int uploadUs = 0,
  int renderUs = 0,
  int presentUs = 0,
  int glassToGlassUs = 0,
}) =>
    FrameTimingUs.of(
      captureDeliveryUs: captureDeliveryUs,
      uploadUs: uploadUs,
      renderUs: renderUs,
      presentUs: presentUs,
      glassToGlassUs: glassToGlassUs,
    );

void main() {
  group('TimingHistogram', () {
    test('mean and max are derived from added samples', () {
      final h = TimingHistogram();
      h.addMicros(1000);
      h.addMicros(2000);
      h.addMicros(3000);
      expect(h.sampleCount, 3);
      expect(h.meanUs, 2000);
      expect(h.maxUs, 3000);
    });

    test('ignores negative samples rather than corrupting the total', () {
      final h = TimingHistogram();
      h.addMicros(-5);
      h.addMicros(1000);
      expect(h.sampleCount, 1);
      expect(h.meanUs, 1000);
    });

    test('fractionWithin counts samples under the budget', () {
      final h = TimingHistogram();
      for (var i = 0; i < 9; i++) {
        h.addMicros(1000); // 1 ms, inside 2 ms
      }
      h.addMicros(5000); // 5 ms, outside
      expect(h.fractionWithin(2000), closeTo(0.9, 1e-9));
    });

    test('fractionWithin is 1.0 with no samples', () {
      expect(TimingHistogram().fractionWithin(1000), 1.0);
    });

    test('a very large sample lands in the overflow bucket', () {
      final h = TimingHistogram();
      h.addMicros(500000);
      expect(h.sampleCount, 1);
      expect(h.maxUs, 500000);
    });

    test('reset clears every counter', () {
      final h = TimingHistogram();
      h.addMicros(1000);
      h.reset();
      expect(h.sampleCount, 0);
      expect(h.meanUs, 0);
      expect(h.maxUs, 0);
    });
  });

  group('PipelineStats', () {
    test('counts frames and reports per-stage means', () {
      final s = PipelineStats();
      s.record(
        timing(
          uploadUs: 1000,
          renderUs: 2000,
          glassToGlassUs: 40000,
        ),
        cameraTimestampUs: 33333,
      );
      s.record(
        timing(
          uploadUs: 3000,
          renderUs: 4000,
          glassToGlassUs: 60000,
        ),
        cameraTimestampUs: 66666,
      );

      expect(s.frameCount, 2);
      expect(s.upload.meanUs, 2000);
      expect(s.render.meanUs, 3000);
      expect(s.glassToGlass.meanUs, 50000);
    });

    test('counts stale, dropped and empty ticks', () {
      final s = PipelineStats();
      s.noteStaleFrame();
      s.noteDroppedFrame();
      s.noteEmptyRenderTick();
      expect(s.staleFrames, 1);
      expect(s.droppedFrames, 1);
      expect(s.emptyRenderTicks, 1);
      expect(s.snapshot().totalDrops, 3);
    });

    test('infers an upstream drop from a doubled camera interval', () {
      final s = PipelineStats(historyLength: 64);
      // Establish a 33.3 ms median interval (30 fps).
      var ts = 0;
      for (var i = 0; i < 16; i++) {
        ts += 33333;
        s.record(timing(), cameraTimestampUs: ts);
      }
      expect(s.upstreamDroppedFrames, 0);

      // One frame gap: a ~66.6 ms interval.
      ts += 66666;
      s.record(timing(), cameraTimestampUs: ts);
      expect(s.upstreamDroppedFrames, 1);
    });

    test('does not flag camera jitter as an upstream drop', () {
      final s = PipelineStats(historyLength: 64);
      var ts = 0;
      // Jitter well below the 1.75x threshold.
      for (var i = 0; i < 32; i++) {
        ts += 33333 + (i % 3) * 4000;
        s.record(timing(), cameraTimestampUs: ts);
      }
      expect(s.upstreamDroppedFrames, 0);
    });

    test('allBudgetsMet passes when every stage is inside budget', () {
      final s = PipelineStats();
      for (var i = 0; i < 100; i++) {
        s.record(
          timing(
            uploadUs: 800,
            renderUs: 900,
            glassToGlassUs: 40000,
          ),
          cameraTimestampUs: i * 33333,
        );
      }
      final snap = s.snapshot();
      expect(snap.uploadMs, 0);
      expect(snap.allBudgetsMet, isTrue);
    });

    test('allBudgetsMet fails when the upload budget is exceeded', () {
      final s = PipelineStats();
      s.record(
        timing(uploadUs: 6000, glassToGlassUs: 40000),
        cameraTimestampUs: 33333,
      );
      expect(s.snapshot().uploadMs, 6);
      expect(s.snapshot().allBudgetsMet, isFalse);
    });

    test('allBudgetsMet fails when glass-to-glass misses 100 ms', () {
      final s = PipelineStats();
      s.record(
        timing(uploadUs: 800, renderUs: 900, glassToGlassUs: 150000),
        cameraTimestampUs: 33333,
      );
      expect(s.snapshot().glassToGlassMs, 150);
      expect(s.snapshot().allBudgetsMet, isFalse);
    });

    test('reset clears frame counters and histograms', () {
      final s = PipelineStats();
      s.record(timing(uploadUs: 1000), cameraTimestampUs: 33333);
      s.noteDroppedFrame();
      s.reset();
      expect(s.frameCount, 0);
      expect(s.droppedFrames, 0);
      expect(s.upload.meanUs, 0);
      expect(s.snapshot().frameCount, 0);
    });

    test('snapshot toString mentions fps and glass-to-glass', () {
      final s = PipelineStats();
      s.record(timing(glassToGlassUs: 40000), cameraTimestampUs: 33333);
      final text = s.snapshot().toString();
      expect(text, contains('fps'));
      expect(text, contains('glass-to-glass'));
      expect(text, contains('drops'));
    });
  });
}
