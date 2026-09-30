import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../utils/constants.dart';
import 'database_service.dart';
import 'model_service.dart';
import 'tokenizer_service.dart';

/// Loads the ONNX models, tokenizer and DB if they aren't already loaded in
/// this isolate. Shared by [HomeScreen._loadEverything] (the UI isolate, on
/// launch) and [BackgroundIndexService]'s task body (a fresh headless
/// isolate has none of this in-memory state), so the two stay in sync
/// rather than each keeping its own copy of this sequence.
///
/// Returns false if the models haven't been downloaded yet — that's a
/// prerequisite the interactive onboarding flow (DownloadScreen) is
/// responsible for, not this helper.
Future<bool> ensureServicesLoaded() async {
  final dir = await getApplicationDocumentsDirectory();
  final imgPath = '${dir.path}/$kImageEncoderFilename';
  final txtPath = '${dir.path}/$kTextEncoderFilename';

  if (!File(imgPath).existsSync() || !File(txtPath).existsSync()) {
    return false;
  }

  if (!ModelService().isLoaded) {
    await ModelService().loadModels(imgPath, txtPath);
  }
  await TokenizerService().init();
  await DatabaseService().init();
  return true;
}
