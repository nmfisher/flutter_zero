import 'geometry.dart';

/// Recording canvas — appends draw commands to a [DisplayList] rather than
/// issuing FFI calls directly. The renderer-specific [DisplayListExecutor]
/// is what turns the list into actual draw calls per frame.
///
/// Same shape as Flutter's `dart:ui` `PictureRecorder` / `Canvas` /
/// `Picture` triple. Decouples the framework above from the renderer below.
sealed class DrawCommand {
  const DrawCommand();
}

class ClearCommand extends DrawCommand {
  const ClearCommand(this.color);
  final Color color;
}

class FillRectCommand extends DrawCommand {
  const FillRectCommand(this.rect, this.color);
  final Rect rect;
  final Color color;
}

class StrokeRectCommand extends DrawCommand {
  const StrokeRectCommand(this.rect, this.color, {this.width = 1.0});
  final Rect rect;
  final Color color;
  final double width;
}

class SaveCommand extends DrawCommand {
  const SaveCommand();
}

class RestoreCommand extends DrawCommand {
  const RestoreCommand();
}

class TranslateCommand extends DrawCommand {
  const TranslateCommand(this.offset);
  final Offset offset;
}

/// An ordered list of draw commands produced by a [RecordingCanvas] in one
/// frame. Cheap to build, cheap to compare, cheap to ship across threads or
/// (eventually) isolates.
class DisplayList {
  DisplayList(this.commands);
  final List<DrawCommand> commands;

  int get length => commands.length;
}

class RecordingCanvas {
  final List<DrawCommand> _commands = [];

  void clear(Color color) => _commands.add(ClearCommand(color));

  void fillRect(Rect rect, Color color) =>
      _commands.add(FillRectCommand(rect, color));

  void strokeRect(Rect rect, Color color, {double width = 1.0}) =>
      _commands.add(StrokeRectCommand(rect, color, width: width));

  void save() => _commands.add(const SaveCommand());

  void restore() => _commands.add(const RestoreCommand());

  void translate(double dx, double dy) =>
      _commands.add(TranslateCommand(Offset(dx, dy)));

  /// Finalize the recording and return the display list.
  DisplayList build() => DisplayList(List.unmodifiable(_commands));
}

/// Walks a [DisplayList] and emits real draw calls into a backend renderer.
/// Implementations: a SDL3 renderer executor (see `examples/sdl_ui`), a
/// Filament executor (see `filament_executor.dart`), a no-op debug executor,
/// etc.
abstract class DisplayListExecutor {
  Future<void> execute(DisplayList list);
}
