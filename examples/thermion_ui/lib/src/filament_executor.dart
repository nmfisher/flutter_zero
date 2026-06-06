import 'canvas.dart';

/// Stub [DisplayListExecutor] — counts commands, doesn't render anything.
///
/// The real Filament executor will turn each [DrawCommand] into a textured
/// quad submitted via `FilamentApp.createGeometry`, batched onto a UI
/// `View` attached to the same `SwapChain` as the 3D scene with a higher
/// `renderOrder` (see `UI_BRAINSTORMING.md` and `RENDERING.md`). That's a
/// chunk of work — `View` setup, vertex buffer construction, material
/// instances, lifecycle management for per-frame geometry — so for this
/// first wire-up the executor is just a counter that proves the seam is
/// in place: same `RecordingCanvas` API, swap the executor when the UI
/// view machinery lands.
class StubFilamentExecutor implements DisplayListExecutor {
  int framesExecuted = 0;
  int commandsTotal = 0;

  @override
  Future<void> execute(DisplayList list) async {
    framesExecuted++;
    commandsTotal += list.length;
  }
}
