import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications for backup health. Used today for one thing: if
/// the automatic Google Drive backup fails, the owner hears about it
/// instead of discovering a missing backup months later. Every call is
/// guarded — notifications must never break the app or the backup.
class BackupNotifier {
  BackupNotifier._();
  static final BackupNotifier instance = BackupNotifier._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin
          .initialize(const InitializationSettings(android: android));
      _ready = true;
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();
    } catch (_) {
      // No notifications on this device — in-app status still shows.
    }
  }

  Future<void> showBackupFailed() async {
    try {
      if (!_ready) await init();
      if (!_ready) return;
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'backup_alerts',
          'Backup Alerts',
          channelDescription:
              'Alerts when the automatic Google Drive backup fails',
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      await _plugin.show(
        1001,
        'Google Drive backup failed',
        'Namat Oil Mill: the automatic backup could not finish. '
            'Open the app and check Settings > Google Drive.',
        details,
      );
    } catch (_) {}
  }
}
