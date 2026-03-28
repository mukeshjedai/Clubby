import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local (system) notifications when a GPS trip ends. Web is a no-op.
class TripNotifications {
  TripNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'clubby_trips',
    'Trips',
    description: 'Alerts when a trip ends',
    importance: Importance.defaultImportance,
  );

  static Future<void> ensureReady() async {
    if (_initialized) return;
    if (kIsWeb) {
      _initialized = true;
      return;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
      ),
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_channel);
    await androidImpl?.requestNotificationsPermission();

    final iosImpl = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);
    final macImpl = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    await macImpl?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
  }

  /// Shown when the user finishes a trip (stationary end detected).
  static Future<void> showTripEnded({required double distanceKm}) async {
    if (kIsWeb) return;
    await ensureReady();
    final kmStr = distanceKm.toStringAsFixed(2);
    final body = 'Trip end: $kmStr Kms';
    const androidDetails = AndroidNotificationDetails(
      'clubby_trips',
      'Trips',
      channelDescription: 'Alerts when a trip ends',
      importance: Importance.defaultImportance,
      priority: Priority.high,
    );
    const darwinDetails = DarwinNotificationDetails();
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      'Trip ended',
      body,
      const NotificationDetails(android: androidDetails, iOS: darwinDetails, macOS: darwinDetails),
    );
  }
}
