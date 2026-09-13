# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Flutter application (`sims`) targeting Android and iOS. Currently at the initial scaffold stage — `lib/main.dart` contains the default counter demo app.

- Flutter SDK: requires Dart `^3.11.0`
- Dependencies: `cupertino_icons`, `flutter_lints`

## Common Commands

```bash
# Get dependencies
flutter pub get

# Run the app (requires a connected device or emulator)
flutter run

# Run all tests
flutter test

# Run a single test file
flutter test test/widget_test.dart

# Analyze for lint/type errors
flutter analyze

# Build release APK (Android)
flutter build apk

# Build release IPA (iOS)
flutter build ios
```

## Code Structure

- `lib/main.dart` — app entry point; `MyApp` is the root widget, `MyHomePage` + `_MyHomePageState` implement the home screen
- `test/` — widget tests using `flutter_test`
- `analysis_options.yaml` — uses `package:flutter_lints/flutter.yaml` ruleset

## Linting

Lint rules come from `flutter_lints`. Suppress per-line with `// ignore: rule_name` or per-file with `// ignore_for_file: rule_name`.
