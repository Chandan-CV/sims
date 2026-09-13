import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../utils/constants.dart';
import 'database_service.dart';
import 'indexing_service.dart';
import 'model_service.dart';
import 'notification_service.dart';
import 'tokenizer_service.dart';

/// Entry point run by the OS in a headless background isolate (Android
/// WorkManager job / iOS BGProcessingTask). Must stay top-level so it can be
/// used as a `vm:entry-point`. Dispatches on task name: the nightly sync job
/// vs. a user-initiated "index now" hand-off from IndexingScreen.
@pragma('vm:entry-point')
void backgroundSyncCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      if (task == kIndexNowTaskName) {
        await BackgroundSyncService()._runIndexNow();
      } else {
        await BackgroundSyncService().runSync();
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

/// Snapshot of the background "index now" task's progress, as published by
/// the background isolate and read back by the UI isolate.
class BackgroundIndexStatus {
  const BackgroundIndexStatus({
    required this.running,
    required this.indexed,
    required this.total,
    required this.updatedAt,
  });

  static const idle = BackgroundIndexStatus(
    running: false,
    indexed: 0,
    total: 0,
    updatedAt: null,
  );

  /// True only if the task claims to be running *and* its last heartbeat is
  /// recent enough to believe (see [kBgIndexStaleAfter]).
  final bool running;
  final int indexed;
  final int total;
  final DateTime? updatedAt;

  double? get progress => total > 0 ? indexed / total : null;
}

/// Drives the "no babysitting" indexing story described in the roadmap:
/// a cheap change-check against the device library, followed (only if
/// something changed) by a full diff and an encode pass over whatever is
/// still pending. Also handles the user-initiated "run in background" hand
/// off from IndexingScreen, which runs as an Android foreground service
/// with a progress notification.
class BackgroundSyncService {
  static final BackgroundSyncService _instance =
      BackgroundSyncService._internal();
  factory BackgroundSyncService() => _instance;
  BackgroundSyncService._internal();

  bool _running = false;

  /// Registers the OS-level scheduler and the nightly periodic job. Call
  /// once from `main()`, before `runApp`.
  Future<void> initializeScheduler() async {
    await Workmanager().initialize(backgroundSyncCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      kBackgroundSyncTaskId,
      kBackgroundSyncTaskName,
      frequency: const Duration(hours: 24),
      initialDelay: const Duration(hours: 6),
      constraints: Constraints(
        requiresBatteryNotLow: true,
        networkType: NetworkType.notRequired,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.linear,
    );
  }

  /// Cheap "has anything changed" check + (conditionally) full diff, then
  /// an encode pass over any pending rows. No-ops quietly if the models
  /// haven't been downloaded yet — that's a prerequisite the interactive
  /// onboarding flow is responsible for, not this job. Deliberately does
  /// *not* call `PhotoManager.requestPermissionExtend()` here: that needs
  /// an Activity to show its system dialog from, which doesn't exist in
  /// this headless background isolate and throws a NullPointerException on
  /// the Android side if called anyway. Reaching this job at all already
  /// implies permission was granted interactively at least once; if it's
  /// since been revoked, per-image fetches below just fail individually
  /// (already handled) rather than crashing the whole task.
  Future<void> runSync() async {
    if (_running) return;
    _running = true;

    try {
      if (!await _ensureServicesReady()) return;

      final prefs = await SharedPreferences.getInstance();
      final currentCount =
          await PhotoManager.getAssetCount(type: RequestType.image);
      final lastCount = prefs.getInt(kPrefLastAssetCount);

      if (lastCount == null || lastCount != currentCount) {
        final (discovered, deleted) = await IndexingService().syncWithDevice();
        debugPrint(
            '[SIMS] Background sync: +$discovered new, -$deleted removed');
        await prefs.setInt(kPrefLastAssetCount, currentCount);
      }

      // Always try to catch up on whatever is still pending — covers rows
      // left over from a previous sync that got cut off mid-encode.
      await _runIndexWithProgress();

      await prefs.setInt(
          kPrefLastSyncMillis, DateTime.now().millisecondsSinceEpoch);
    } finally {
      _running = false;
    }
  }

  /// Hands off an in-progress indexing run to the OS: schedules a one-off
  /// task that runs as an Android foreground service (so it survives the
  /// app being backgrounded/swiped away) with a persistent progress
  /// notification. On iOS this still runs as a best-effort BGProcessingTask
  /// — no true foreground-service equivalent exists there, but whatever
  /// doesn't finish in that window is picked up by the next periodic sync
  /// since indexing is resumable.
  Future<void> runIndexNowInBackground() async {
    // Publish "running" up front, from the foreground: the OS may take a
    // while to actually start the task, and coming straight back to the
    // indexing screen in that window should still show it as pending rather
    // than as nothing happening at all.
    await _publishIndexProgress(running: true, indexed: 0, total: 0);

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

  /// The "index now" task body: encodes whatever's pending, updating a
  /// progress notification (same notification id as the foreground
  /// service's own, so our updates land on that same system notification)
  /// roughly every 5 images to avoid hammering the notification manager.
  Future<void> _runIndexNow() async {
    // Heartbeat before the slow part: loading the ONNX models into a fresh
    // isolate can take tens of seconds, and without this the run would look
    // stale (and be reported as dead) before it encodes its first image.
    await _publishIndexProgress(running: true, indexed: 0, total: 0);

    if (!await _ensureServicesReady()) {
      await _publishIndexProgress(running: false, indexed: 0, total: 0);
      return;
    }

    // No PhotoManager.requestPermissionExtend() here — see runSync() for
    // why that crashes in this headless context. Permission was already
    // granted interactively before this hand-off could ever be triggered
    // (IndexingScreen only offers "Run in background" mid-indexing, which
    // itself required a granted permission to start).
    await _runIndexWithProgress();
  }

  /// Runs [IndexingService.indexAll], publishing a heartbeat (so
  /// [getIndexNowStatus] — and IndexingScreen's polling built on it —
  /// reflects progress) and a throttled progress notification for every
  /// batch. Shared by the explicit "index now" hand-off and by
  /// [runSync]'s catch-up pass: previously only the explicit hand-off did
  /// this, so a big catch-up triggered by an ordinary app resume ran
  /// completely invisibly — no heartbeat, no notification, nothing for
  /// the UI to poll — even though it could be indexing thousands of
  /// photos for minutes.
  Future<void> _runIndexWithProgress() async {
    await _publishIndexProgress(running: true, indexed: 0, total: 0);

    int lastNotified = -1;
    int finalIndexed = 0;
    int finalTotal = 0;
    await IndexingService().indexAll(
      onProgress: (indexed, total) {
        finalIndexed = indexed;
        finalTotal = total;
        if (indexed == total || indexed - lastNotified >= 5) {
          lastNotified = indexed;
          NotificationService().showIndexingProgress(indexed, total);
          _publishIndexProgress(
              running: true, indexed: indexed, total: total);
        }
      },
    );

    await _publishIndexProgress(
        running: false, indexed: finalIndexed, total: finalTotal);
    // Only notify "complete" if there was actually something to do — this
    // runs on every app resume via runSync(), and most resumes have zero
    // pending photos; a completion notification for doing nothing would
    // fire constantly.
    if (finalTotal > 0) {
      await NotificationService().showIndexingComplete(finalIndexed);
    }
  }

  /// Writes the background task's progress where the UI isolate can read it.
  /// Called from the background isolate (which shares no memory with the UI
  /// one), so SharedPreferences is the transport.
  Future<void> _publishIndexProgress({
    required bool running,
    required int indexed,
    required int total,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrefBgIndexRunning, running);
    await prefs.setInt(kPrefBgIndexIndexed, indexed);
    await prefs.setInt(kPrefBgIndexTotal, total);
    await prefs.setInt(
        kPrefBgIndexUpdatedMillis, DateTime.now().millisecondsSinceEpoch);
  }

  /// Reads back the current state of the "index now" background task, for
  /// the UI to poll while it's on screen. A run whose last heartbeat is
  /// older than [kBgIndexStaleAfter] is reported as not running — the OS can
  /// kill the isolate outright, leaving the flag set with nobody to clear it.
  Future<BackgroundIndexStatus> getIndexNowStatus() async {
    final prefs = await SharedPreferences.getInstance();
    // A background isolate wrote these after this isolate's cache was
    // populated, so the in-memory copy is stale without an explicit reload.
    await prefs.reload();

    final millis = prefs.getInt(kPrefBgIndexUpdatedMillis);
    if (millis == null) return BackgroundIndexStatus.idle;

    final updatedAt = DateTime.fromMillisecondsSinceEpoch(millis);
    final fresh =
        DateTime.now().difference(updatedAt) < kBgIndexStaleAfter;

    return BackgroundIndexStatus(
      running: (prefs.getBool(kPrefBgIndexRunning) ?? false) && fresh,
      indexed: prefs.getInt(kPrefBgIndexIndexed) ?? 0,
      total: prefs.getInt(kPrefBgIndexTotal) ?? 0,
      updatedAt: updatedAt,
    );
  }

  /// Cancels a running "index now" task. The isolate is killed outright, so
  /// the running flag is cleared and the progress notification dismissed
  /// from here — nothing in the background will get the chance to.
  Future<void> cancelIndexNow() async {
    await Workmanager().cancelByUniqueName(kIndexNowTaskId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await _publishIndexProgress(
      running: false,
      indexed: prefs.getInt(kPrefBgIndexIndexed) ?? 0,
      total: prefs.getInt(kPrefBgIndexTotal) ?? 0,
    );
    await NotificationService().cancelIndexingNotification();
  }

  /// Loads models/tokenizer/DB if not already loaded (e.g. a fresh
  /// background isolate has none of the app's in-memory state). Returns
  /// false if the models haven't been downloaded yet.
  Future<bool> _ensureServicesReady() async {
    final dir = await getApplicationDocumentsDirectory();
    final imgPath = '${dir.path}/$kImageEncoderFilename';
    final txtPath = '${dir.path}/$kTextEncoderFilename';
    if (!File(imgPath).existsSync() || !File(txtPath).existsSync()) {
      return false;
    }

    if (!ModelService().isLoaded) {
      await ModelService().loadModels(imgPath, txtPath);
    }
    await TokenizerService().init();
    await DatabaseService().init();
    return true;
  }
}
