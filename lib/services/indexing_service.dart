import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../utils/constants.dart';
import '../utils/image_preprocessor.dart';
import 'database_service.dart';
import 'model_service.dart';

typedef ProgressCallback = void Function(int indexed, int total);

class IndexingService {
  static final IndexingService _instance = IndexingService._internal();
  factory IndexingService() => _instance;
  IndexingService._internal();

  final _db = DatabaseService();
  final _model = ModelService();
  bool _running = false;

  /// True while [indexAll] is in flight — only one run is allowed at a
  /// time, so callers handing off between an in-app run and a background
  /// one need to wait for this to clear first.
  bool get isRunning => _running;

  /// One-time full device walk (per install, until stage-2 sync exists).
  /// Registers every discovered asset id as a NULL-embedding stub row,
  /// reporting progress against photo_manager's already-deduplicated total.
  Future<void> discoverAssets({required ProgressCallback onProgress}) async {
    final total = await PhotoManager.getAssetCount(type: RequestType.image);
    final paths =
        await PhotoManager.getAssetPathList(type: RequestType.image);
    final seen = <String>{};

    for (final path in paths) {
      int page = 0;
      const pageSize = 100;
      while (true) {
        final batch =
            await path.getAssetListPaged(page: page, size: pageSize);

        final newIds = [
          for (final asset in batch)
            if (seen.add(asset.id)) asset.id,
        ];
        if (newIds.isNotEmpty) {
          await _db.discoverAssetIds(newIds);
        }
        onProgress(seen.length, total);

        if (batch.length < pageSize) break;
        page++;
      }
    }
  }

  /// Full reconciliation against the device library: registers any newly
  /// discovered assets as stub rows and removes DB rows for assets that no
  /// longer exist on the device (deleted/moved out of the library). Used by
  /// [BackgroundSyncService] and can be reused anywhere a full diff (not
  /// just an append-only discovery) is needed.
  /// Returns (newly discovered count, deleted count).
  Future<(int, int)> syncWithDevice() async {
    final existingIds = await _db.getAllAssetIds();
    final paths = await PhotoManager.getAssetPathList(type: RequestType.image);
    final seen = <String>{};

    for (final path in paths) {
      int page = 0;
      const pageSize = 100;
      while (true) {
        final batch =
            await path.getAssetListPaged(page: page, size: pageSize);

        final newIds = [
          for (final asset in batch)
            if (seen.add(asset.id)) asset.id,
        ];
        if (newIds.isNotEmpty) {
          await _db.discoverAssetIds(newIds);
        }

        if (batch.length < pageSize) break;
        page++;
      }
    }

    final deleted = await _db.deleteAssetIdsNotIn(seen);
    final discovered = seen.difference(existingIds).length;
    return (discovered, deleted);
  }

  /// Returns (total device images, already indexed count) — pure DB query.
  Future<(int, int)> getIndexStats() => _db.getIndexStats();

  /// Returns the number of device images not yet indexed — pure DB query.
  Future<int> countUnindexed() async {
    final (total, indexed) = await _db.getIndexStats();
    return total - indexed;
  }

  /// Indexes all un-indexed images, kIndexBatchSize at a time.
  ///
  /// Pipelined so the next batch's thumbnail-fetch + preprocess (I/O and
  /// Dart-isolate CPU work) overlaps with the current batch's ONNX
  /// inference call (an async platform-channel call that runs on the
  /// native side, leaving the Dart isolate free in the meantime) — the
  /// next batch's [_fetchAndPreprocessBatch] future is started *before*
  /// awaiting the current batch's [ModelService.encodeImages], so both
  /// run concurrently instead of strictly one-after-another.
  ///
  /// [onProgress] is called after each batch with (indexed, total).
  /// [shouldStop] returning true aborts the loop cleanly.
  Future<void> indexAll({
    required ProgressCallback onProgress,
    bool Function()? shouldStop,
  }) async {
    if (_running) return;
    _running = true;

    try {
      final pendingIds = await _db.getUnindexedAssetIds();
      final total = pendingIds.length;
      int indexed = 0;

      final batches = <List<String>>[
        for (var i = 0; i < pendingIds.length; i += kIndexBatchSize)
          pendingIds.sublist(
              i, (i + kIndexBatchSize).clamp(0, pendingIds.length)),
      ];

      Future<List<_PreparedImage>>? nextBatchFuture =
          batches.isEmpty ? null : _fetchAndPreprocessBatch(batches.first);

      for (var b = 0; b < batches.length; b++) {
        if (shouldStop?.call() == true) break;

        final prepared = await nextBatchFuture!;
        // Kick off the next batch's fetch+preprocess now, without awaiting
        // it, so it runs concurrently with this batch's inference below.
        nextBatchFuture = b + 1 < batches.length
            ? _fetchAndPreprocessBatch(batches[b + 1])
            : null;

        if (prepared.isNotEmpty) {
          try {
            debugPrint(
                '[SIMS] Encoding batch of ${prepared.length} (${indexed + prepared.length}/$total)');
            final embeddings = await _model
                .encodeImages([for (final p in prepared) p.tensor]);
            await _db.setEmbeddings({
              for (var i = 0; i < prepared.length; i++)
                prepared[i].id: embeddings[i],
            });
          } catch (e) {
            debugPrint('Skipping batch ${batches[b]}: $e');
          }
        }

        indexed += batches[b].length;
        onProgress(indexed, total);

        if ((b + 1) % kCacheClearIntervalBatches == 0) {
          await PhotoManager.clearFileCache();
        }
      }
    } finally {
      // Whatever the outcome, don't leave the just-generated thumbnails
      // for this run sitting on disk indefinitely.
      await PhotoManager.clearFileCache();
      _running = false;
    }
  }

  /// Fetches thumbnails and preprocesses them into model input tensors for
  /// one batch. Images that fail to fetch/decode are skipped individually
  /// rather than aborting the whole batch.
  Future<List<_PreparedImage>> _fetchAndPreprocessBatch(
      List<String> ids) async {
    final prepared = <_PreparedImage>[];
    for (final id in ids) {
      try {
        final asset = await AssetEntity.fromId(id);
        final bytes = await asset?.thumbnailDataWithSize(
          const ThumbnailSize(kImageSize, kImageSize),
          quality: 95,
        );
        if (bytes != null) {
          prepared.add(_PreparedImage(id, ImagePreprocessor.preprocess(bytes)));
        }
      } catch (e) {
        debugPrint('Skipping $id: $e');
      }
    }
    return prepared;
  }
}

class _PreparedImage {
  const _PreparedImage(this.id, this.tensor);
  final String id;
  final Float32List tensor;
}
