import 'package:flutter_zero_webcam_depth/src/capture/camera_controller.dart';
import 'package:flutter_zero_webcam_depth/src/capture/camera_frame.dart';
import 'package:flutter_zero_webcam_depth/src/stats/bitmap_font.dart';
import 'package:flutter_zero_webcam_depth/src/stats/character_set.dart' as charset;
import 'package:flutter_zero_webcam_depth/src/stats/hud.dart';
import 'package:flutter_zero_webcam_depth/src/stats/pipeline_stats.dart';
import 'package:test/test.dart';

void main() {
  group('character set', () {
    test('upper-cases before lookup, so mixed case renders', () {
      expect(charset.glyphFor('a'), isNotNull);
      expect(charset.glyphFor('A'), same(charset.glyphFor('a')));
    });

    test('returns null for unknown glyphs', () {
      expect(charset.glyphFor('~'), isNull);
      expect(charset.glyphFor(''), isNull);
    });

    test('canRender accepts the strings the HUD draws', () {
      const hudStrings = [
        'FPS 60.0 (CAMERA 30.0) OK',
        'FRAMES 1800 DROPS 0',
        'CAPTURE 0.1MS MAX 0.4MS',
        'UPLOAD 1.2MS MAX 2.0MS (BUDGET 2MS) OVER',
        'RENDER 1.0MS MAX 1.5MS (BUDGET 2MS)',
        'PRESENT INSIDE RENDER SUBMIT',
        'GLASS-TO-GLASS 42.3MS MAX 88.0MS (BUDGET 100MS)',
        'WITHIN 100MS 99.9%',
        'PRESS ESCAPE TO QUIT',
      ];
      for (final line in hudStrings) {
        expect(charset.canRender(line), isTrue, reason: line);
      }
    });

    test('rejects strings with no glyph', () {
      // Lowercase is fine (lookups upper-case); truly unknown glyphs are not.
      expect(charset.canRender('LOWERCASE ok'), isTrue);
      expect(charset.canRender('OK ~'), isFalse);
      expect(charset.canRender('§'), isFalse);
    });

    test('every CameraFailure screen is fully renderable', () {
      // The error screen shows the failure copy through the bitmap font; a
      // missing glyph there would silently blank characters on screen.
      final failures = [
        const CameraFailure(
            reason: CameraUnavailableReason.denied, detail: null),
        const CameraFailure(
            reason: CameraUnavailableReason.deniedPreviously, detail: null),
        const CameraFailure(
            reason: CameraUnavailableReason.noDevice, detail: null),
        const CameraFailure(
            reason: CameraUnavailableReason.configurationFailed,
            detail: 'Session preset rejected'),
        const CameraFailure(
            reason: CameraUnavailableReason.unknown, detail: null),
      ];
      for (final failure in failures) {
        expect(charset.canRender(failure.title), isTrue,
            reason: failure.title);
        expect(charset.canRender(failure.remediation), isTrue,
            reason: failure.remediation);
      }
    });
  });

  group('BitmapFont', () {
    test('cell size is glyph size plus a one-pixel gap', () {
      final font = BitmapFont.standard();
      expect(font.glyphWidth, 5);
      expect(font.glyphHeight, 7);
      expect(font.cellWidth, 6);
      expect(font.cellHeight, 8);
    });

    test('rowsFor returns 7 rows, blank for unknown characters', () {
      final font = BitmapFont.standard();
      expect(font.rowsFor('H'.codeUnitAt(0)).length, 7);
      expect(font.rowsFor('~'.codeUnitAt(0)).every((row) => row == 0), isTrue);
    });
  });

  group('GlyphCanvas', () {
    GlyphCanvas canvas({int width = 64, int height = 32}) => GlyphCanvas(
          width: width,
          height: height,
          font: BitmapFont.standard(),
        );

    test('drawText writes opaque pixels only where glyphs have bits set', () {
      final c = canvas();
      c.drawText('I', 0, 0); // 'I' is a solid bar: top row 0x1F.

      // Top row of 'I' is a full 5-wide bar at y=0, x=0..4.
      expect(c.pixels[0 * 4 + 3], 255); // alpha of first pixel
      expect(c.pixels[(0 * 64 + 4) * 4 + 3], 255); // last bar pixel
      // The gap column (x=5) stays transparent.
      expect(c.pixels[(0 * 64 + 5) * 4 + 3], 0);
      // 'I' has empty side columns at x=0 on rows 1..5 (0x04 pattern).
      expect(c.pixels[(2 * 64 + 0) * 4 + 3], 0);
    });

    test('scale fills square blocks', () {
      final c = canvas();
      c.drawText('I', 0, 0, scale: 2);

      // A 2x2 block covers x=0..1 at y=0..1.
      expect(c.pixels[(0 * 64 + 1) * 4 + 3], 255);
      expect(c.pixels[(1 * 64 + 1) * 4 + 3], 255);
      // Nothing at the scale-1-only position y=0 x=2 ('I' bar is 5 wide
      // at scale 1, so x=2 is set there, but at scale 2 the bar spans
      // x=0..9 and x=2 is inside it).
      expect(c.pixels[(0 * 64 + 2) * 4 + 3], 255);
      // Below the 2x-scaled glyph (y=14) it is transparent.
      expect(c.pixels[(14 * 64 + 0) * 4 + 3], 0);
    });

    test('clips glyphs that run off the canvas', () {
      final c = canvas(width: 8, height: 8);
      c.drawText('III', 0, 0); // needs 18px width, canvas is 8.
      // No throw, and pixels stay inside the buffer.
      expect(c.pixels.length, 8 * 8 * 4);
    });

    test('drawWrapped breaks between words', () {
      final c = canvas(width: 64, height: 64);
      final nextY = c.drawWrapped(
        'AA BB CC',
        0,
        0,
        scale: 1,
        maxWidth: 64,
      );
      // 64px / 6px cells = 10 glyphs per line, so 'AA BB CC' fits on one
      // line and the cursor advances by exactly one line height.
      expect(nextY, c.lineHeight());
    });

    test('drawWrapped emits several lines for long text', () {
      final c = canvas(width: 64, height: 64);
      final nextY = c.drawWrapped(
        'AAAA BBBB CCCC DDDD',
        0,
        0,
        scale: 1,
        maxWidth: 64,
      );
      expect(nextY, greaterThan(c.lineHeight()));
    });

    test('measure and lineHeight follow the scale', () {
      final c = canvas();
      expect(c.measure('AB'), 2 * 6);
      expect(c.measure('AB', scale: 3), 2 * 6 * 3);
      expect(c.lineHeight(scale: 3), 24);
    });
  });

  group('assertHudStringsRenderable', () {
    test('passes for renderable text', () {
      expect(() => assertHudStringsRenderable(const ['FPS 60.0 OK']),
          returnsNormally);
    });

    test('throws for text the font cannot draw', () {
      expect(() => assertHudStringsRenderable(const ['OK ~']), throwsStateError);
    });
  });

  group('stats HUD data path', () {
    test('snapshot feeds every string the grid draws', () {
      // Exercises the numeric -> string conversions the HUD performs so a
      // formatting regression (e.g. a locale comma) shows up in tests.
      final stats = PipelineStats();
      final now = DateTime.now().microsecondsSinceEpoch;
      stats.record(
        FrameTimingUs.of(
          captureDeliveryUs: 120,
          uploadUs: 1400,
          renderUs: 900,
          presentUs: 0,
          glassToGlassUs: 42000,
        ),
        cameraTimestampUs: now,
      );
      stats.recordRenderTick();
      final s = stats.snapshot();

      final rendered = [
        'FPS ${s.fps.toStringAsFixed(1)}',
        'CAMERA ${s.captureFps.toStringAsFixed(1)}',
        'UPLOAD ${s.uploadMs}MS',
        'GLASS-TO-GLASS ${s.glassToGlassMs}MS',
        'WITHIN 100MS ${(s.glassToGlassWithinBudget * 100).toStringAsFixed(1)}%',
      ];
      for (final line in rendered) {
        expect(charset.canRender(line), isTrue, reason: line);
      }
    });
  });
}
