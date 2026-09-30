import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../utils/constants.dart';
import 'app_bootstrap.dart';
import 'database_service.dart';
import 'indexing_service.dart';
import 'notification_service.dart';

/// Entry point run by the OS in a headless background isolate (Android
/// WorkManager job). Must stay top-level so it can be used as a
/// `vm:entry-point`.
@pragma('vm:entry-point')
void backgroundIndexCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      if (task == kIndexNowTaskName) {
        await BackgroundIndexService()._runIndexNow();
      }
    } catch (e) {
      debugPrint('[SIMS] Background task "$task" failed: $e');
    }
    // Always report success — a partial run just leaves rows pending for
    // next time (indexing is idempotent/resumable), so there's nothing to
    // "retry" that a normal re-run wouldn't already redo.
    return true;
  });
}

/// Hands an in-progress indexing run off to the OS: runs as an Android
/// foreground service (so it survives the app being backgrounded/swiped
/// away) with a persistent progress notification, same idea as how
/// downloads show progress.
///
/// Deliberately minimal — no app-resume trigger, no periodic job, no device
/// sync inside the task. The only way in is [start], called once from
/// IndexingScreen's "Run in background" button.
class BackgroundIndexService {
  static final BackgroundIndexService _instance =
      BackgroundIndexService._internal();
  factory BackgroundIndexService() => _instance;
  BackgroundIndexService._internal();

  /// Registers the WorkManager plugin. Call once from `main()`, before
  /// `runApp` — cheap and safe to call unconditionally on every launch, it
  /// does not itself schedule or start anything.
  Future<void> initialize() async {
    await Workmanager().initialize(backgroundIndexCallbackDispatcher);
  }

  /// Schedules the one-off task. Publishes "running" up front, from the
  /// foreground: the OS may take a moment to actually start the task, and
  /// coming straight back to the indexing screen in that window should
  /// still show it as pending rather than as nothing happening at all.
  Future<void> start() async {
    await _publishHeartbeat();

    await Workmanager().registerOneOffTask(
      kIndexNowTaskId,
      kIndexNowTaskName,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.notRequired),
      foregroundServiceConfig: ForegroundServiceConfig(
        notificationTitle: 'SIMS',
        notificationText: 'Indexing your photos…',
        notificationChannelId: kIndexingNotificationChannelId,
        notificationChannelName: kIndexingNotificationChannelName,
        notificationId: kIndexingNotificationId,
        foregroundServiceType: ForegroundServiceType.dataSync,
      ),
    );
  }

  /// The task body: encodes whatever's pending, updating a progress
  /// notification (same notification id as the foreground service's own,
  /// so our updates land on that same system notification) and a heartbeat
  /// roughly every 5 images.
  Future<void> _runIndexNow() async {
    // The DB is opened first, specifically because the heartbeat write
    // below needs it — this is a fresh isolate, so DatabaseService's
    // _client is still null until init() runs. Cheap (opening a local
    // SQLite file), unlike loading the ONNX models below, which is what
    // actually justifies writing the heartbeat before the slow part:
    // without it, a run would look stale (and get reported as dead)
    // before it encodes its first image.
    await DatabaseService().init();
    await _publishHeartbeat();

    if (!await ensureServicesLoaded()) {
      await _clearHeartbeat();
      return;
    }

    // No permission request here: requesting it needs an Activity to show
    // its system dialog from, which doesn't exist in this headless
    // isolate. Permission was already granted interactively — IndexingScreen
    // only offers "Run in background" mid-indexing, which itself required a
    // granted permission to start.
    int lastNotified = -1;
    int finalIndexed = 0;
    int finalTotal = 0;
    try {
      await IndexingService().indexAll(
        onProgress: (indexed, total) {
          finalIndexed = indexed;
          finalTotal = total;
          if (indexed == total || indexed - lastNotified >= 5) {
            lastNotified = indexed;
            // Fire-and-forget (onProgress is synchronous), but caught and
            // logged rather than left to vanish as an unhandled Future
            // rejection — a failure here (e.g. notification permission not
            // actually granted) would otherwise be invisible: indexing
            // keeps running fine with no notification and no error either.
            NotificationService().showProgress(indexed, total).catchError(
                (e) => debugPrint('[SIMS] showProgress failed: $e'));
            _publishHeartbeat()
                .catchError((e) => debugPrint('[SIMS] heartbeat failed: $e'));
          }
        },
      );
    } finally {
      await _clearHeartbeat();
    }

    if (finalTotal > 0) {
      await NotificationService().showComplete(finalIndexed);
    }
  }

  Future<void> _publishHeartbeat() => DatabaseService().setMeta(
      kMetaBgIndexHeartbeatMillis,
      DateTime.now().millisecondsSinceEpoch.toString());

  Future<void> _clearHeartbeat() =>
      DatabaseService().deleteMeta(kMetaBgIndexHeartbeatMillis);

  /// True only if the task's last heartbeat is recent enough to believe —
  /// the OS can kill the background isolate outright, leaving no chance for
  /// it to clear its own heartbeat.
  Future<bool> isRunning() async {
    final raw = await DatabaseService().getMeta(kMetaBgIndexHeartbeatMillis);
    if (raw == null) return false;
    final millis = int.tryParse(raw);
    if (millis == null) return false;
    final updatedAt = DateTime.fromMillisecondsSinceEpoch(millis);
    return DateTime.now().difference(updatedAt) < kBgIndexStaleAfter;
  }

  /// Cancels a running task. The isolate is killed outright, so the
  /// heartbeat is cleared and the progress notification dismissed from
  /// here — nothing in the background will get the chance to.
  Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(kIndexNowTaskId);
    await _clearHeartbeat();
    await NotificationService().cancel();
  }
}
