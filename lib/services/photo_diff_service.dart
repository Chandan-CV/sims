import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'database_service.dart';

/// How much the device library has moved since the last checkpoint.
class PhotoDiff {
  const PhotoDiff({required this.added, required this.removed});

  /// Assets added (or modified) on the device since the checkpoint.
  final int added;

  /// Assets no longer on the device that the DB still has rows for,
  /// inferred from the count delta (see [PhotoDiffService] for why this is
  /// an estimate, not an exact diff).
  final int removed;

  bool get hasChanges => added > 0 || removed > 0;
  int get total => added + removed;
}

/// Answers "what changed on the device library since last time" without a
/// full walk-and-diff of every asset id (that's the expensive, disruptive
/// operation this app deliberately dropped from the hot path).
///
/// - Additions are counted with a single date-filtered `getAssetCount` —
///   cheap, an index lookup on the device's media store, not a per-row
///   fetch. It can overcount slightly: an edited (not just newly added)
///   photo also matches "updated since X".
/// - Removals aren't found directly. They're inferred from
///   `(DB total + added) - device count`. This is an estimate: it's exact
///   when adds and deletes don't happen to overlap between checks, but an
///   add and a delete in the same window can mask each other. Exact
///   deletions are instead caught lazily wherever a stale id is actually
///   touched (indexAll skipping an unfetchable asset, a search hit that
///   fails to load) rather than searched for up front.
class PhotoDiffService {
  static final PhotoDiffService _instance = PhotoDiffService._internal();
  factory PhotoDiffService() => _instance;
  PhotoDiffService._internal();

  final _db = DatabaseService();

  /// The result of the last [checkForChanges] call, for any screen to read
  /// or listen to — this app has no central state-management store, so the
  /// singleton service holding its own last-known value (the same pattern
  /// as [IndexingService.isRunning] / [ModelService.isLoaded]) is where
  /// shared state like this lives. Null until the first check completes.
  /// A [ValueNotifier] rather than a plain field so a screen that wants to
  /// react (e.g. wrap a badge in [ValueListenableBuilder]) doesn't have to
  /// re-run the check itself just to rebuild when it changes.
  final lastDiff = ValueNotifier<PhotoDiff?>(null);

  /// Read-only: safe to call whenever a screen wants an up-to-date count
  /// (e.g. on load), since it never touches the DB or the checkpoint.
  /// Also publishes the result to [lastDiff].
  Future<PhotoDiff> checkForChanges() async {
    final checkpoint = await _db.getLastSyncMillis();
    final deviceCount =
        await PhotoManager.getAssetCount(type: RequestType.image);

    if (checkpoint == null) {
      // Never synced: nothing to diff against — everything is "new".
      final diff = PhotoDiff(added: deviceCount, removed: 0);
      lastDiff.value = diff;
      return diff;
    }

    final (dbTotal, _) = await _db.getIndexStats();
    final added = await PhotoManager.getAssetCount(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        updateTimeCond: DateTimeCond(
          min: DateTime.fromMillisecondsSinceEpoch(checkpoint),
          max: DateTime.now(),
        ),
      ),
    );
    final removed = dbTotal + added - deviceCount;

    final diff = PhotoDiff(added: added, removed: removed < 0 ? 0 : removed);
    lastDiff.value = diff;
    return diff;
  }

  /// Advances the checkpoint to now without scanning anything. Used right
  /// after a full [IndexingService.discoverAssets] walk, which already
  /// registered every asset on the device — there's nothing left for
  /// [syncNewPhotos] to find, so it only needs a baseline to diff against
  /// from here on.
  Future<void> markSynced() async {
    await _db.setLastSyncMillis(DateTime.now().millisecondsSinceEpoch);
  }

  /// Registers assets added/modified since the checkpoint as stub rows,
  /// then advances the checkpoint to now. Insert is `OR IGNORE`
  /// ([DatabaseService.discoverAssetIds]), so re-registering an already-known
  /// edited photo is a no-op, not a duplicate.
  ///
  /// Returns the number of ids seen (not the number that were actually new
  /// — see [DatabaseService.discoverAssetIds]).
  Future<int> syncNewPhotos() async {
    final checkpoint = await _db.getLastSyncMillis();
    final since = checkpoint == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.fromMillisecondsSinceEpoch(checkpoint);
    final now = DateTime.now();

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        updateTimeCond: DateTimeCond(min: since, max: now),
      ),
    );

    var seen = 0;
    for (final path in paths) {
      int page = 0;
      const pageSize = 100;
      while (true) {
        final batch = await path.getAssetListPaged(page: page, size: pageSize);
        if (batch.isNotEmpty) {
          await _db.discoverAssetIds([for (final a in batch) a.id]);
          seen += batch.length;
        }
        if (batch.length < pageSize) break;
        page++;
      }
    }

    await _db.setLastSyncMillis(now.millisecondsSinceEpoch);
    return seen;
  }
}
