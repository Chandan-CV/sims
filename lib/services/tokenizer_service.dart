import 'dart:convert';

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

  // CLIP's pre-tokenisation pattern (applied to lower-cased, whitespace-
  // normalised text): special tokens, English contractions, runs of letters,
  // single digits, and runs of other non-space symbols.
  static final RegExp _pattern = RegExp(
    r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+",
    unicode: true,
  );

  final Map<String, List<int>> _wordCache = {};

  /// Returns (input_ids [1,77], attention_mask [1,77]) as flat lists.
  (List<int>, List<int>) tokenize(String text) {
    assert(_initialized, 'TokenizerService.init() not called');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

    final allIds = <int>[_bos];
    for (final match in _pattern.allMatches(text)) {
      allIds.addAll(_encodeWord(match.group(0)!));
    }

    // Truncate to the context length but keep the EOS token last, as CLIP's
    // own tokenizer does — the text encoder pools at the EOS position.
    if (allIds.length > kMaxTokenLength - 1) {
      allIds.removeRange(kMaxTokenLength - 1, allIds.length);
    }
    allIds.add(_eos);

    final inputIds = List<int>.filled(kMaxTokenLength, _pad);
    final attentionMask = List<int>.filled(kMaxTokenLength, 0);
    for (int i = 0; i < allIds.length; i++) {
      inputIds[i] = allIds[i];
      attentionMask[i] = 1;
    }
    return (inputIds, attentionMask);
  }

  List<int> _encodeWord(String word) {
    final cached = _wordCache[word];
    if (cached != null) return cached;

    final List<int> ids;
    if (word == '<|startoftext|>' || word == '<|endoftext|>') {
      ids = [_vocab[word]!];
    } else {
      // Map each UTF-8 byte through the GPT-2 byte encoder.
      final symbols = utf8
          .encode(word)
          .map((b) => _byteToUnicode[b] ?? String.fromCharCode(b))
          .toList();
      // CLIP marks the end of every word by suffixing its last symbol with
      // "</w>" before applying merges (the vocab holds both forms, and the
      // text encoder was trained on the "</w>" ids).
      symbols[symbols.length - 1] = '${symbols.last}</w>';
      ids = [
        for (final t in _bpe(symbols))
          if (_vocab[t] != null) _vocab[t]!,
      ];
    }
    if (_wordCache.length < 10000) _wordCache[word] = ids;
    return ids;
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
