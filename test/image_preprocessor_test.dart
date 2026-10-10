import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sims/utils/image_preprocessor.dart';

// Reference tensor from Hugging Face's CLIPImageProcessor
// (openai/clip-vit-base-patch32) for test/fixtures/preprocess_sample.png.
void main() {
  test('preprocessing matches the reference CLIP image processor', () {
    final bytes = File('test/fixtures/preprocess_sample.png').readAsBytesSync();
    final golden = jsonDecode(
            File('test/fixtures/preprocess_sample.json').readAsStringSync())
        as Map<String, dynamic>;
    final expected = (golden['data'] as List).cast<num>();

    final actual = ImagePreprocessor.preprocess(bytes);
    expect(actual.length, expected.length);

    double sumAbs = 0, maxAbs = 0;
    for (int i = 0; i < actual.length; i++) {
      final d = (actual[i] - expected[i]).abs();
      sumAbs += d;
      if (d > maxAbs) maxAbs = d;
    }
    // Interpolation differs slightly between PIL and package:image, so
    // allow a small tolerance (values are in normalised units, range ~±2).
    expect(sumAbs / actual.length, lessThan(0.05));
  });
}
