import 'dart:typed_data';

import 'character_set.dart' as charset;

/// A 5x7 bitmap font, one byte of row bits per glyph row.
///
/// Thermion ships no text renderer and the HUD needs to show per-stage
/// timings, so the app draws its own glyphs into an RGBA buffer and
/// uploads the result as a texture — the same approach `thermion_ui` uses
/// for its rectangle-based stand-in HUD.
///
/// Each glyph is 5 wide and 7 tall. Bit 4 of a row byte is the left-most
/// column, bit 0 the right-most. One row per byte, top row first, so a
/// glyph is 7 bytes and a full glyph is 35 pixels of coverage.
class BitmapFont {
  BitmapFont._(this.glyphWidth, this.glyphHeight, this.glyphStride);

  /// The only font the app ships: 5x7 uppercase.
  BitmapFont.standard() : this._(5, 7, 7);

  final int glyphWidth;
  final int glyphHeight;

  /// Bytes per glyph in the source table (one per row).
  final int glyphStride;

  /// Advances to the next glyph position, including one column of gap.
  int get cellWidth => glyphWidth + 1;
  int get cellHeight => glyphHeight + 1;

  /// Returns the 7 row bytes for [character], or blank rows when the font
  /// has no glyph for it.
  Uint8List rowsFor(int character) {
    final rows = Uint8List(glyphHeight);
    final glyph = charset.glyphFor(String.fromCharCode(character));
    if (glyph == null) return rows;
    for (var row = 0; row < glyphHeight && row < glyph.length; row++) {
      rows[row] = glyph[row];
    }
    return rows;
  }

  bool contains(int character) =>
      charset.glyphFor(String.fromCharCode(character)) != null;
}

/// An RGBA8 canvas glyphs can be blitted into.
///
/// Held by the HUD so the whole overlay is one texture upload per refresh
/// instead of one per glyph.
class GlyphCanvas {
  GlyphCanvas({
    required this.width,
    required this.height,
    required BitmapFont font,
    Color color = const Color(0xff, 0xff, 0xff, 0xff),
  })  : _font = font,
        _color = color,
        pixels = Uint8List(width * height * 4);

  final int width;
  final int height;
  final BitmapFont _font;
  final Color _color;

  /// RGBA8, row-major, top-down.
  final Uint8List pixels;

  int _cursorX = 0;
  int _cursorY = 0;

  void clear() {
    pixels.fillRange(0, pixels.length, 0);
    _cursorX = 0;
    _cursorY = 0;
  }

  void moveTo(int x, int y) {
    _cursorX = x;
    _cursorY = y;
  }

  /// Width of [text] in pixels at the given glyph scale.
  int measure(String text, {int scale = 1}) =>
      text.runes.length * _font.cellWidth * scale;

  /// Vertical advance of one text line at the given glyph scale.
  int lineHeight({int scale = 1}) => _font.cellHeight * scale;

  /// Draws [text] at the cursor and advances by one scaled line.
  void drawLine(String text, {int scale = 1}) {
    drawText(text, _cursorX, _cursorY, scale: scale);
    _cursorY += _font.cellHeight * scale;
  }

  /// Draws [text] wrapped to [maxWidth] pixels, breaking between words,
  /// and returns the vertical position past the last line. Words longer
  /// than a whole line are clipped by the canvas bounds rather than split.
  int drawWrapped(
    String text,
    int x,
    int y, {
    required int scale,
    required int maxWidth,
  }) {
    var cursorY = y;
    for (final line in _wrap(text, maxWidth ~/ (_font.cellWidth * scale))) {
      drawText(line, x, cursorY, scale: scale);
      cursorY += _font.cellHeight * scale;
    }
    return cursorY;
  }

  /// Splits [text] into lines of at most [maxCells] glyphs each.
  Iterable<String> _wrap(String text, int maxCells) sync* {
    var line = '';
    for (final word in text.split(' ')) {
      if (line.isEmpty) {
        line = word;
      } else if (line.length + 1 + word.length <= maxCells) {
        line = '$line $word';
      } else {
        yield line;
        line = word;
      }
    }
    if (line.isNotEmpty) yield line;
  }

  /// Draws [text] with its top-left glyph origin at ([x], [y]). Each font
  /// pixel becomes an [scale]×[scale] block, so the same 5x7 glyphs serve
  /// both the small stats grid and the large message screen.
  void drawText(String text, int x, int y, {int scale = 1}) {
    var penX = x;
    for (final rune in text.runes) {
      if (rune == 0x20) {
        penX += _font.cellWidth * scale;
        continue;
      }
      final rows = _font.rowsFor(rune);
      _blitGlyph(rows, penX, y, scale);
      penX += _font.cellWidth * scale;
    }
  }

  void _blitGlyph(Uint8List rows, int x, int y, int scale) {
    final c = _color;
    for (var row = 0; row < rows.length; row++) {
      final bits = rows[row];
      if (bits == 0) continue;
      final py = y + row * scale;
      if (py < 0 || py >= height) continue;
      for (var column = 0; column < _font.glyphWidth; column++) {
        final isSet = (bits >> (_font.glyphWidth - 1 - column)) & 1 == 1;
        if (!isSet) continue;
        final px = x + column * scale;
        if (px < 0 || px >= width) continue;
        // Fill a scale x scale block, clipped to the canvas edges.
        for (var dy = 0; dy < scale; dy++) {
          final rowStart = ((py + dy) * width + px) * 4;
          for (var dx = 0; dx < scale; dx++) {
            if (px + dx >= width) break;
            final offset = rowStart + dx * 4;
            pixels[offset] = c.r;
            pixels[offset + 1] = c.g;
            pixels[offset + 2] = c.b;
            pixels[offset + 3] = c.a;
          }
        }
      }
    }
  }
}

/// Simple RGBA colour used by the HUD.
class Color {
  const Color(this.r, this.g, this.b, this.a);

  const Color.white() : this(0xff, 0xff, 0xff, 0xff);

  /// Catppuccin Mocha green — used when a stage is inside budget.
  const Color.ok() : this(0xa6, 0xe3, 0xa1, 0xff);

  /// Catppuccin Mocha red — used when a stage exceeds its budget.
  const Color.overBudget() : this(0xf3, 0x8b, 0xa8, 0xff);

  final int r;
  final int g;
  final int b;
  final int a;
}
