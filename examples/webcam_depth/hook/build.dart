import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds the macOS capture shim.
///
/// `CBuilder` can compile Objective-C directly, but only when `language`
/// is `Language.objectiveC`: the `-x c++` it passes for C++ would override
/// clang's `.m` detection, and `-framework` flags are only emitted for the
/// Objective-C language. `Language.objectiveC` emits no `-x` at all, so
/// clang picks Objective-C up from the file extension and the frameworks
/// get linked.
///
/// `-fobjc-arc` is passed by hand because the toolchain does not add it,
/// and the shim needs it: `AVCaptureVideoDataOutput` holds its sample
/// buffer delegate weakly, so the delegate must own itself through ARC.
///
/// On every platform other than macOS this hook emits nothing — the app is
/// macOS-only, and an empty hook keeps `dart analyze` and the pure-Dart
/// tests working on Linux.
void main(List<String> args) async {
  await build(args, (input, output) async {
    final logger = Logger('')
      ..level = Level.ALL
      ..onRecord.listen((record) => print(record.message));

    if (input.config.code.targetOS != OS.macOS) {
      return;
    }

    final cbuilder = CBuilder.library(
      name: input.packageName,
      language: Language.objectiveC,
      assetName: 'webcam_depth_capture.dart',
      sources: const ['native/src/webcam_depth_capture.m'],
      frameworks: const [
        'Foundation',
        'AVFoundation',
        'CoreMedia',
        'CoreVideo',
      ],
      flags: const ['-fobjc-arc', '-Wall', '-Wextra', '-Wno-unused-parameter'],
    );
    await cbuilder.run(input: input, output: output, logger: logger);
  });
}
