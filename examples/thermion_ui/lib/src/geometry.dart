/// Renderer-agnostic UI geometry types — same shape as `examples/sdl_ui`'s
/// versions, so consumer code can move between backends unchanged.
library;

class Color {
  const Color(this.r, this.g, this.b, [this.a = 255]);

  final int r;
  final int g;
  final int b;
  final int a;

  static const black = Color(0, 0, 0);
  static const white = Color(255, 255, 255);
  static const transparent = Color(0, 0, 0, 0);
}

class Offset {
  const Offset(this.dx, this.dy);
  final double dx;
  final double dy;

  static const zero = Offset(0, 0);

  Offset operator +(Offset other) => Offset(dx + other.dx, dy + other.dy);
}

class Size {
  const Size(this.width, this.height);
  final double width;
  final double height;
}

class Rect {
  const Rect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  Rect.fromLTWH(double left, double top, double w, double h) : this(left, top, w, h);
}
