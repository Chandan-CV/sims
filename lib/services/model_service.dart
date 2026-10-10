import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../utils/constants.dart';

class ModelService {
  static final ModelService _instance = ModelService._internal();
  factory ModelService() => _instance;
  ModelService._internal();

  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _imageEncoder;
  OrtSession? _textEncoder;

  bool get isLoaded => _imageEncoder != null && _textEncoder != null;

  Future<void> loadModels(
      String imageEncoderPath, String textEncoderPath) async {
    _imageEncoder = await _runtime.createSession(imageEncoderPath);
    _textEncoder = await _runtime.createSession(textEncoderPath);
  }

  /// Encodes a batch of already-preprocessed images in a single ONNX run.
  /// The exported image encoder has a dynamic batch dimension
  /// (`['batch_size', 3, 224, 224]` -> `['batch_size', 512]`), so stacking
  /// N images into one `[N, 3, 224, 224]` tensor and running once amortises
  /// the fixed per-call (platform channel + session) overhead over all N,
  /// instead of paying it once per image.
  Future<List<List<double>>> encodeImages(List<Float32List> imageBatch) async {
    final batchSize = imageBatch.length;
    final perImageLength = 3 * kImageSize * kImageSize;
    final stacked = Float32List(batchSize * perImageLength);
    for (int i = 0; i < batchSize; i++) {
      stacked.setAll(i * perImageLength, imageBatch[i]);
    }

    final inputTensor = await OrtValue.fromList(
        stacked, [batchSize, 3, kImageSize, kImageSize]);
    try {
      final outputs = await _imageEncoder!.run({'image_input': inputTensor});
      try {
        final flat = await _firstOutput(outputs, _imageEncoder!);
        return [
          for (int i = 0; i < batchSize; i++)
            flat.sublist(i * kEmbeddingDim, (i + 1) * kEmbeddingDim),
        ];
      } finally {
        for (final tensor in outputs.values) {
          await tensor.dispose();
        }
      }
    } finally {
      await inputTensor.dispose();
    }
  }

  Future<List<double>> encodeText(
      List<int> inputIds, List<int> attentionMask) async {
    final idsTensor = await OrtValue.fromList(
        Int64List.fromList(inputIds), [1, kMaxTokenLength]);

    late final Map<String, OrtValue> outputs;
    try {
      outputs = await _textEncoder!.run({
        'text_input': idsTensor,
      });
    } finally {
      await idsTensor.dispose();
    }

    final List<double> flat;
    try {
      flat = await _firstOutput(outputs, _textEncoder!);
    } finally {
      for (final tensor in outputs.values) {
        await tensor.dispose();
      }
    }

    // The exported CLIP text encoder pools at the EOS token in-graph and
    // returns [1, 512]. Defensive fallback in case a model returns the
    // per-token [1, 77, 512] states instead: extract the EOS embedding.
    if (flat.length == kMaxTokenLength * kEmbeddingDim) {
      final eosIndex = inputIds.indexOf(49407);
      final start = (eosIndex < 0 ? 0 : eosIndex) * kEmbeddingDim;
      return flat.sublist(start, start + kEmbeddingDim);
    }

    return flat;
  }

  Future<List<double>> _firstOutput(
      Map<String, OrtValue> outputs, OrtSession session) async {
    final key = session.outputNames.first;
    final tensor = outputs[key];
    if (tensor == null) throw Exception('No output tensor for key "$key"');
    final raw = await tensor.asFlattenedList();
    return raw.cast<double>();
  }

  Future<void> dispose() async {
    await _imageEncoder?.close();
    await _textEncoder?.close();
    _imageEncoder = null;
    _textEncoder = null;
  }
}
