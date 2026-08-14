// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';

/// Reads the handful of Xcode build settings that `flutter build/run` needs,
/// directly from `project.pbxproj`, instead of spawning
/// `xcodebuild -showBuildSettings` (which re-resolves the SwiftPM dependency
/// graph on every invocation — see the macOS build-time notes).
///
/// This is intentionally narrow: it only understands the parts of the pbxproj
/// NeXTSTEP-plist grammar needed to extract `XCBuildConfiguration.buildSettings`
/// for a named configuration, plus the scheme name from the shared `.xcscheme`
/// files. Anything it can't confidently resolve returns null so callers can fall
/// back to the `xcodebuild` path.
class PbxprojSettings {
  const PbxprojSettings._();

  /// The scheme name to build, taken from the first shared `.xcscheme` under
  /// `<project>.xcodeproj/xcshareddata/xcschemes/`, or null if none exist.
  ///
  /// For a stock Flutter template this is always `Runner`.
  static String? schemeForProject(Directory xcodeProject) {
    final Directory schemes = xcodeProject
        .childDirectory('xcshareddata')
        .childDirectory('xcschemes');
    if (!schemes.existsSync()) {
      return null;
    }
    for (final FileSystemEntity entity in schemes.listSync(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.xcscheme')) {
        return entity.basename.substring(0, entity.basename.length - '.xcscheme'.length);
      }
    }
    return null;
  }

  /// The merged `buildSettings` for every `XCBuildConfiguration` whose `name`
  /// matches [configuration], or null if the project has no such configuration.
  ///
  /// Settings from all matching blocks (project- and target-level) are merged
  /// together; this is sufficient for the keys the macOS build consumes
  /// (`MACOSX_DEPLOYMENT_TARGET`, `EXCLUDED_ARCHS`), which are unambiguously
  /// defined on the app target. Callers must validate that the keys they need
  /// are present before trusting the result, and fall back to `xcodebuild`
  /// otherwise.
  static Map<String, String>? buildSettingsForConfiguration(
    File pbxproj,
    String configuration,
  ) {
    if (!pbxproj.existsSync()) {
      return null;
    }
    final List<String> lines = pbxproj.readAsLinesSync();
    final merged = <String, String>{};
    var foundConfiguration = false;

    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains('isa = XCBuildConfiguration;')) {
        continue;
      }

      // Collect this XCBuildConfiguration block by tracking brace depth.
      // The `isa =` line sits *inside* the configuration block (just after its
      // opening `{`), so we start here at depth 0 and stop when the depth goes
      // negative — i.e. the configuration's own closing `};`. Stopping at depth
      // 0 would instead bail on the nested `buildSettings = { … }` close, before
      // the `name =` line is reached.
      final block = <String>[];
      var depth = 0;
      for (var j = i; j < lines.length; j++) {
        final String line = lines[j];
        for (final int ch in line.codeUnits) {
          if (ch == 0x7B /* { */) {
            depth++;
          } else if (ch == 0x7D /* } */) {
            depth--;
          }
        }
        block.add(line);
        if (depth < 0) {
          break;
        }
      }

      final String? name = _match(block, RegExp(r'^\s*name = (.+?);\s*$'));
      if (name != configuration) {
        continue;
      }
      foundConfiguration = true;

      // Extract the buildSettings = { ... } sub-block.
      final int settingsStart = block.indexWhere(
        (String l) => l.contains('buildSettings = {'),
      );
      if (settingsStart == -1) {
        continue;
      }
      for (int k = settingsStart + 1; k < block.length; k++) {
        final String settingsLine = block[k].trim();
        if (settingsLine == '};' || settingsLine.startsWith('}')) {
          break;
        }
        final Match? m = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?);\s*$')
            .firstMatch(settingsLine);
        if (m != null) {
          merged[m.group(1)!] = _unescape(m.group(2)!);
        }
      }
    }

    return foundConfiguration ? merged : null;
  }

  static String? _match(List<String> block, RegExp pattern) {
    for (final line in block) {
      final Match? m = pattern.firstMatch(line);
      if (m != null) {
        return m.group(1);
      }
    }
    return null;
  }

  /// Strip surrounding double quotes from a pbxproj scalar value.
  static String _unescape(String value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}
