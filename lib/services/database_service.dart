import 'package:libsql_dart/libsql_dart.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/constants.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  static const _kSchemaVersion = 3;

  LibsqlClient? _client;
  LibsqlClient get client => _client!;

  Future<void> init() async {
    if (_client != null) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$kDbFilename';
    _client = LibsqlClient.local(path);
    await _client!.connect();
    await _migrateSchema();
    // Not gated by _kSchemaVersion: this is a standalone key/value store,
    // not part of the `images` schema, so it doesn't need a destructive
    // migration whenever that version bumps.
    await _client!.execute(
        'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)');
  }

  Future<void> _migrateSchema() async {
    final rows = await _client!.query('PRAGMA user_version');
    final current = (rows.first['user_version'] as int?) ?? 0;
    if (current >= _kSchemaVersion) return;

    await _client!.execute('DROP TABLE IF EXISTS images');
    await _client!.execute('''
      CREATE TABLE images (
        asset_id  TEXT PRIMARY KEY,
        embedding F32_BLOB($kEmbeddingDim)
      )
    ''');
    // Deliberately no libsql_vector_idx here: at personal-photo-library
    // scale (thousands, not millions, of rows) an exact linear scan via
    // vector_distance_cos (see searchSimilar/searchSimilarToAsset below)
    // is fast enough and avoids both the DiskANN graph's disk overhead
    // (measured: ~800MB of graph for ~8k photos, dwarfing the ~32MB of
    // actual embeddings) and its approximate-search recall trade-off.
    await _client!.execute('PRAGMA user_version = $_kSchemaVersion');
  }

  /// Bulk-registers freshly discovered asset ids as stub rows (embedding = NULL).
  /// Rows that already exist (already discovered or already indexed) are left alone.
  Future<void> discoverAssetIds(List<String> assetIds) async {
    if (assetIds.isEmpty) return;
    final txn = await _client!.transaction();
    try {
      // Multi-row inserts: one round-trip per chunk instead of per id, which
      // matters when a first-run discovery registers thousands of photos.
      const chunkSize = 500;
      for (var i = 0; i < assetIds.length; i += chunkSize) {
        final chunk = assetIds.sublist(
            i, (i + chunkSize).clamp(0, assetIds.length));
        final placeholders = List.filled(chunk.length, '(?, NULL)').join(',');
        await txn.execute(
          'INSERT OR IGNORE INTO images (asset_id, embedding) '
          'VALUES $placeholders',
          positional: chunk,
        );
      }
      await txn.commit();
    } catch (e) {
      await txn.rollback();
      rethrow;
    }
  }

  /// Fills in the embedding for an already-discovered asset_id row.
  Future<void> setEmbedding(String assetId, List<double> embedding) async {
    final vec = '[${embedding.join(',')}]';
    await _client!.execute(
      'UPDATE images SET embedding = vector32(?) WHERE asset_id = ?',
      positional: [vec, assetId],
    );
  }

  /// Same as [setEmbedding], but writes a whole batch in one transaction
  /// instead of a separate implicit commit per row.
  Future<void> setEmbeddings(Map<String, List<double>> embeddings) async {
    if (embeddings.isEmpty) return;
    final txn = await _client!.transaction();
    try {
      for (final entry in embeddings.entries) {
        final vec = '[${entry.value.join(',')}]';
        await txn.execute(
          'UPDATE images SET embedding = vector32(?) WHERE asset_id = ?',
          positional: [vec, entry.key],
        );
      }
      await txn.commit();
    } catch (e) {
      await txn.rollback();
      rethrow;
    }
  }

  /// True once the one-time device scan has populated at least one row.
  Future<bool> hasDiscoveredAssets() async {
    final rows = await _client!.query('SELECT COUNT(*) AS cnt FROM images');
    final cnt = rows.first['cnt'];
    return (cnt is int ? cnt : (cnt as BigInt).toInt()) > 0;
  }

  /// (total discovered, already-indexed) in one query — COUNT(col) skips NULLs.
  Future<(int, int)> getIndexStats() async {
    final rows = await _client!.query(
      'SELECT COUNT(*) AS total, COUNT(embedding) AS indexed FROM images',
    );
    final row = rows.first;
    int asInt(dynamic v) => v is int ? v : (v as BigInt).toInt();
    return (asInt(row['total']), asInt(row['indexed']));
  }

  /// Ids that are discovered but not yet embedded.
  Future<List<String>> getUnindexedAssetIds() async {
    final rows = await _client!.query(
      'SELECT asset_id FROM images WHERE embedding IS NULL',
    );
    return [for (final row in rows) row['asset_id'] as String];
  }

  /// Removes specific rows, e.g. assets found to be gone from the device
  /// when a search hit couldn't be loaded.
  Future<void> deleteAssetIds(Iterable<String> assetIds) async {
    if (assetIds.isEmpty) return;
    final txn = await _client!.transaction();
    try {
      for (final id in assetIds) {
        await txn.execute(
          'DELETE FROM images WHERE asset_id = ?',
          positional: [id],
        );
      }
      await txn.commit();
    } catch (e) {
      await txn.rollback();
      rethrow;
    }
  }

  Future<List<String>> searchSimilar(
      List<double> queryEmbedding, int topK) async {
    final vec = '[${queryEmbedding.join(',')}]';
    final rows = await _client!.query(
      '''
      SELECT asset_id
      FROM images
      WHERE embedding IS NOT NULL
      ORDER BY vector_distance_cos(embedding, vector32(?))
      LIMIT ?
      ''',
      positional: [vec, topK],
    );
    return rows.map((r) => r['asset_id'] as String).toList();
  }

  Future<List<String>> searchSimilarToAsset(String assetId, int topK) async {
    final rows = await _client!.query(
      '''
      SELECT asset_id
      FROM images
      WHERE embedding IS NOT NULL AND asset_id != ?
      ORDER BY vector_distance_cos(
        embedding, (SELECT embedding FROM images WHERE asset_id = ?))
      LIMIT ?
      ''',
      positional: [assetId, assetId, topK],
    );
    return rows.map((r) => r['asset_id'] as String).toList();
  }

  /// Generic key/value read/write on the `meta` table — used for anything
  /// that's small, single-valued, and shared across isolates (e.g. a sync
  /// checkpoint, a background task's heartbeat). Both the UI isolate and a
  /// WorkManager background isolate open the same SQLite file, so this
  /// serves the same purpose SharedPreferences would, without adding that
  /// dependency back.
  Future<String?> getMeta(String key) async {
    final rows = await _client!.query(
      'SELECT value FROM meta WHERE key = ?',
      positional: [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    await _client!.execute(
      'INSERT INTO meta (key, value) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      positional: [key, value],
    );
  }

  Future<void> deleteMeta(String key) async {
    await _client!.execute('DELETE FROM meta WHERE key = ?', positional: [key]);
  }

  /// The last time [PhotoDiffService] registered new assets, as millis
  /// since epoch — null if it's never run.
  Future<int?> getLastSyncMillis() async {
    final v = await getMeta('last_sync_millis');
    return v == null ? null : int.tryParse(v);
  }

  Future<void> setLastSyncMillis(int millis) =>
      setMeta('last_sync_millis', millis.toString());

  Future<void> dispose() async {
    await _client?.dispose();
    _client = null;
  }
}
