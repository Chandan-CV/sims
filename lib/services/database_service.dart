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
      for (final id in assetIds) {
        await txn.execute(
          'INSERT OR IGNORE INTO images (asset_id, embedding) VALUES (?, NULL)',
          positional: [id],
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

  /// All asset ids currently tracked in the DB (discovered and/or indexed).
  Future<Set<String>> getAllAssetIds() async {
    final rows = await _client!.query('SELECT asset_id FROM images');
    return {for (final row in rows) row['asset_id'] as String};
  }

  /// Deletes rows for asset ids no longer present on the device (photo
  /// deleted/moved out of the library since the last sync). Returns the
  /// number of rows removed.
  Future<int> deleteAssetIdsNotIn(Set<String> currentDeviceIds) async {
    final dbIds = await getAllAssetIds();
    final stale = dbIds.difference(currentDeviceIds);
    if (stale.isEmpty) return 0;

    final txn = await _client!.transaction();
    try {
      for (final id in stale) {
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
    return stale.length;
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

  Future<void> dispose() async {
    await _client?.dispose();
    _client = null;
  }
}
