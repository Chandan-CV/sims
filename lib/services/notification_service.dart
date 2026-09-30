import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/constants.dart';

/// The progress-bar notification shown while the "index now" background
/// task runs (see BackgroundIndexService), plus its completion notice.
class NotificationService {
  static final NotificationService _instance =
      NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _initialized = true;
  }

  /// Android 13+ notification permission. Must be called from the
  /// foreground, where an Activity exists to show the system dialog from —
  /// calling it from the headless background task itself silently fails.
  Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Same notification id the workmanager foreground service posts (see
  /// [ForegroundServiceConfig.notificationId] in BackgroundIndexService), so
  /// this replaces that notification's content instead of adding a second
  /// one alongside it.
  Future<void> showProgress(int indexed, int total) async {
    await init();
    await _plugin.show(
      id: kIndexingNotificationId,
      title: 'SIMS',
      body: 'Indexing your photos… $indexed of $total',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          kIndexingNotificationChannelId,
          kIndexingNotificationChannelName,
          channelDescription: 'Progress while photos are being indexed',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: total,
          progress: indexed,
          indeterminate: total == 0,
          silent: true,
        ),
      ),
    );
  }

  Future<void> showComplete(int count) async {
    await init();
    await _plugin.show(
      id: kIndexingNotificationId,
      title: 'SIMS',
      body: 'Finished indexing $count photo${count == 1 ? '' : 's'}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          kIndexingNotificationChannelId,
          kIndexingNotificationChannelName,
          channelDescription: 'Progress while photos are being indexed',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: false,
        ),
      ),
    );
  }

  Future<void> cancel() async {
    await init();
    await _plugin.cancel(id: kIndexingNotificationId);
  }
}
