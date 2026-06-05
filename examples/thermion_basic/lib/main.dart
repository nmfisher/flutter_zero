// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:isolate';

import 'package:thermion_dart/thermion_dart.dart';
// ignore: implementation_imports
import 'package:thermion_dart/src/filament/src/implementation/ffi_filament_app.dart';

/// Vanilla Thermion bootstrap. Renders a magenta background to a BMP file —
/// no UI layer, no animation, no scene content. Confirms Thermion+Filament
/// initializes inside the Flutter Zero Dart runtime and a single frame
/// reaches the swapchain.
///
/// Modeled after Thermion's own examples/dart/cli_headless/bin/example.dart.
///
/// Run:
///   ../../bin/dart --enable-experiment=native-assets run lib/main.dart
///
/// Output:
///   output/render.bmp
Future<void> main() async {
  print('Bootstrapping FFIFilamentApp...');
  await FFIFilamentApp.create();
  print('FilamentApp ready.');

  const width = 500;
  const height = 500;

  final swapChain = await FilamentApp.instance!.createHeadlessSwapChain(
    width,
    height,
  );

  final viewer = ThermionViewerFFI();
  await viewer.initialized;
  print('Viewer ready.');

  await FilamentApp.instance!.register(swapChain, viewer.view);

  await viewer.view.setFrustumCullingEnabled(false);
  await viewer.setBackgroundColor(1, 0, 1, 1);
  await viewer.setViewport(width, height);

  print('Capturing one frame...');
  final result = await FilamentApp.instance!.capture(
    swapChain,
    view: viewer.view,
  );

  final bitmap = await pixelBufferToBmp(
    result.first.$2,
    width,
    height,
    hasAlpha: true,
    isFloat: true,
  );

  final outfile = File('output/render.bmp');
  outfile.parent.createSync(recursive: true);
  outfile.writeAsBytesSync(bitmap);
  print('Wrote ${outfile.path} (${bitmap.length} bytes).');

  await FilamentApp.instance!.destroy();
  Isolate.current.kill();
}
