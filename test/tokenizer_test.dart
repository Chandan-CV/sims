import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sims/services/tokenizer_service.dart';

// Golden ids come from Hugging Face's CLIPTokenizerFast for
// openai/clip-vit-base-patch32 (see tools/export_clip/validate.py).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('tokenizer matches the reference CLIP tokenizer', () async {
    await TokenizerService().init();
    final golden = jsonDecode(
            File('test/fixtures/clip_tokenizer_golden.json').readAsStringSync())
        as Map<String, dynamic>;
    final ids = golden['token_ids'] as Map<String, dynamic>;

    for (final entry in ids.entries) {
      final (inputIds, _) = TokenizerService().tokenize(entry.key);
      final expected = (entry.value as List).cast<int>();
      // HF pads with the EOS id, the app pads with 0 (the text encoder pools
      // at the first EOS either way), so compare through the first EOS only.
      final end = expected.indexOf(49407) + 1;
      expect(inputIds.sublist(0, end), expected.sublist(0, end),
          reason: 'caption: "${entry.key}"');
      expect(inputIds.sublist(end).every((id) => id == 0), isTrue);
    }
  });

  test('long queries keep the EOS token as the last token', () async {
    await TokenizerService().init();
    final (inputIds, mask) = TokenizerService().tokenize('word ' * 200);
    expect(inputIds.length, 77);
    expect(inputIds[76], 49407);
    expect(mask.every((m) => m == 1), isTrue);
  });
}
