import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import '../utils/constants.dart';

class TokenizerService {
  static final TokenizerService _instance = TokenizerService._internal();
  factory TokenizerService() => _instance;
  TokenizerService._internal();

  late Map<String, int> _vocab;
  late Map<(String, String), int> _mergeRanks;
  late Map<int, String> _byteToUnicode;

  static const int _bos = 49406;
  static const int _eos = 49407;
  static const int _pad = 0;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    final raw =
        await rootBundle.loadString('assets/tokenizer/tokenizer.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final model = json['model'] as Map<String, dynamic>;

    _vocab = Map<String, int>.from(model['vocab'] as Map);

    final merges = (model['merges'] as List).cast<String>();
    _mergeRanks = {};
    for (int i = 0; i < merges.length; i++) {
      final parts = merges[i].split(' ');
      _mergeRanks[(parts[0], parts[1])] = i;
    }

    _byteToUnicode = _buildByteEncoder();
    _initialized = true;
  }

  /// Returns (input_ids [1,77], attention_mask [1,77]) as flat lists.
  (List<int>, List<int>) tokenize(String text) {
    assert(_initialized, 'TokenizerService.init() not called');
    text = text.toLowerCase().trim();

    final allIds = <int>[_bos];

    // Simple whitespace pre-tokenisation (sufficient for search queries)
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;

      // Map each UTF-8 byte through the GPT-2 byte encoder
      final byteChars = utf8
          .encode(word)
          .map((b) => _byteToUnicode[b] ?? String.fromCharCode(b))
          .toList();

      // Apply BPE merges
      final bpeTokens = _bpe(byteChars);

      for (final t in bpeTokens) {
        final id = _vocab[t];
        if (id != null) allIds.add(id);
      }
    }

    allIds.add(_eos);

    final inputIds = List<int>.filled(kMaxTokenLength, _pad);
    final attentionMask = List<int>.filled(kMaxTokenLength, 0);
    final length = min(allIds.length, kMaxTokenLength);
    for (int i = 0; i < length; i++) {
      inputIds[i] = allIds[i];
      attentionMask[i] = 1;
    }
    return (inputIds, attentionMask);
  }

  // --- BPE helpers ---

  List<String> _bpe(List<String> tokens) {
    if (tokens.length <= 1) return tokens;
    while (true) {
      (String, String)? best;
      int bestRank = 1 << 30;
      for (int i = 0; i < tokens.length - 1; i++) {
        final pair = (tokens[i], tokens[i + 1]);
        final rank = _mergeRanks[pair];
        if (rank != null && rank < bestRank) {
          bestRank = rank;
          best = pair;
        }
      }
      if (best == null) break;

      final merged = <String>[];
      int i = 0;
      while (i < tokens.length) {
        if (i < tokens.length - 1 &&
            tokens[i] == best.$1 &&
            tokens[i + 1] == best.$2) {
          merged.add(best.$1 + best.$2);
          i += 2;
        } else {
          merged.add(tokens[i]);
          i++;
        }
      }
      tokens = merged;
      if (tokens.length == 1) break;
    }
    return tokens;
  }

  /// GPT-2 / CLIP byte-to-unicode mapping.
  Map<int, String> _buildByteEncoder() {
    final bs = <int>[
      ...List.generate(94, (i) => i + 33), // !"#..~
      ...List.generate(12, (i) => i + 161), // ¡..¬
      ...List.generate(82, (i) => i + 174), // ®..ÿ
    ];
    final cs = List<int>.from(bs);
    int n = 0;
    for (int b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n++);
      }
    }
    return {for (int i = 0; i < bs.length; i++) bs[i]: String.fromCharCode(cs[i])};
  }
}
