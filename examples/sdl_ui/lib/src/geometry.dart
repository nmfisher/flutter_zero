class Color {
  const Color(this.r, this.g, this.b, [this.a = 255]);

  final int r;
  final int g;
  final int b;
  final int a;

  static const black = Color(0, 0, 0);
  static const white = Color(255, 255, 255);
}

class Rect {
  const Rect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;
}

class Size {
  const Size(this.width, this.height);

  final double width;
  final double height;
}
