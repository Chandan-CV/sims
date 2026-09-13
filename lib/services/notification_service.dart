import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/constants.dart';

/// Thin wrapper around `flutter_local_notifications`, used to show a
/// progress notification while an "index now" job runs as an Android
/// foreground service (see `BackgroundSyncService.runIndexNowInBackground`).
/// iOS has no native progress-bar widget in notifications, so there the
/// notification body just shows "x of y" as text.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
      ),
    );
    _initialized = true;
  }

  /// Requests the Android 13+ POST_NOTIFICATIONS runtime permission. Must be
  /// called from the foreground app (needs an Activity to show the system
  /// permission dialog from) — calling it from inside the headless
  /// background task is a no-op there's nothing to attach the dialog to, so
  /// it would silently fail to grant. Call this before handing an indexing
  /// run off to the background, not from within the background task itself.
  Future<void> requestPermission() async {
    await _ensureInitialized();
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<void> showIndexingProgress(int indexed, int total) async {
    await _ensureInitialized();
    final androidDetails = AndroidNotificationDetails(
      kIndexingNotificationChannelId,
      kIndexingNotificationChannelName,
      channelDescription: 'Progress while SIMS indexes photos in the background.',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      showProgress: true,
      maxProgress: total > 0 ? total : 1,
      progress: indexed,
      indeterminate: total <= 0,
    );
    await _plugin.show(
      id: kIndexingNotificationId,
      title: 'Indexing photos…',
      body: total > 0 ? '$indexed of $total' : 'Starting…',
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(presentBanner: false),
      ),
    );
  }

  /// Dismisses the indexing notification — used when the user cancels a
  /// background run, since the killed isolate can't clear it itself.
  Future<void> cancelIndexingNotification() async {
    await _ensureInitialized();
    await _plugin.cancel(id: kIndexingNotificationId);
  }

  Future<void> showIndexingComplete(int indexed) async {
    await _ensureInitialized();
    const androidDetails = AndroidNotificationDetails(
      kIndexingNotificationChannelId,
      kIndexingNotificationChannelName,
      channelDescription: 'Progress while SIMS indexes photos in the background.',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
    );
    await _plugin.show(
      id: kIndexingNotificationId,
      title: 'Indexing complete',
      body: indexed == 0
          ? 'Nothing new to index.'
          : '$indexed photo${indexed == 1 ? '' : 's'} indexed.',
      notificationDetails: const NotificationDetails(android: androidDetails),
    );
  }
}
