# `flutter pub get` fails with "0.0.0-unknown"

## Symptom

```
$ flutter pub get
The current Flutter SDK version is 0.0.0-unknown.

Because <package> depends on <dep> <version> which requires Flutter SDK version >=1.24.0-1.0.pre, version solving failed.
Failed to update packages.
```

Every `sdk:` constraint in every transitive dependency fails, because the
version pub sees (`0.0.0-unknown`) is lower than any realistic constraint.

## Root cause

The bundled Dart SDK's `pub` solver reads the **legacy** `{FLUTTER_ROOT}/version`
file to detect the Flutter SDK version. Upstream Flutter has a feature flag,
`omitLegacyVersionFile`, that — when enabled — stops the tool from writing that
file (only the newer `bin/cache/flutter.version.json` is written).

In this fork the flag and the bundled Dart SDK were mismatched: the flag was
`fullyEnabled` (so `version` was never written) while the bundled `pub` still
read it. `flutter --version` reported the correct version (it reads
`flutter.version.json`), but `pub` saw `0.0.0-unknown`.

The `version` file is also gitignored, so the problem recurred on every fresh
checkout.

## Fix (in place)

The `omitLegacyVersionFile` flag is disabled by default in
`packages/flutter_tools/lib/src/features.dart`, so the tool writes the legacy
`{FLUTTER_ROOT}/version` file itself (via `_ensureLegacyVersionFile`). This
survives `--version` / `doctor` / the throttled freshness check, all of which
delete the file and then recreate it.

If you ever re-merge upstream and the flag flips back to `fullyEnabled`, this
problem will return. Keep the local override:

```dart
const omitLegacyVersionFile = Feature(
  name: 'stops writing the legacy version file',
  configSetting: 'omit-legacy-version-file',
  master: FeatureChannelSetting(available: true, enabledByDefault: false),
  beta: FeatureChannelSetting(available: true, enabledByDefault: false),
  stable: FeatureChannelSetting(available: true, enabledByDefault: false),
  ...
);
```

After changing `flutter_tools` source you must rebuild the tool snapshot. The
tool usually detects the change automatically; if not, force it:

```sh
rm -f bin/cache/flutter_tools.snapshot bin/cache/flutter_tools.stamp
flutter --version
```

## Manual one-off workaround (if you can't edit the tool)

```sh
printf '%s' "$(python3 -c "import json;print(json.load(open('bin/cache/flutter.version.json'))['frameworkVersion'])")" > version
```

Run from the repo root. This recreates the `version` file from the
authoritative `flutter.version.json`. It will be deleted again by the next
`flutter --version`/`doctor`, so it is only a stopgap — prefer the fix above.
