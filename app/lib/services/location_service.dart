import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../src/rust/api.dart';

/// LIP reasons for sending (ETSI TS 100 392-18-1), as accepted by
/// `TetraClient.sendLocation`.
class LipReason {
  static const powerOn = 0;
  static const emergency = 2;
  static const ptt = 3;
  static const user = 20;
  static const periodic = 129;
}

/// Location updates that keep coming with the app in the background or the
/// screen locked, so periodic LIP reports go on.
///
/// iOS: background updates must be allowed per request (geolocator leaves
/// them off unless asked; the `location` background mode alone is not
/// enough), with the blue status bar indicator, and never paused by the
/// system. Android: the updates run in geolocator's own foreground service of
/// type location with an ongoing notification; without one Android stops
/// location access for apps in the background.
LocationSettings lipLocationSettings(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        activityType: ActivityType.other,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    case TargetPlatform.android:
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'TETRA Terminal',
          notificationText: 'Sending your position (LIP)',
          notificationChannelName: 'Location (LIP)',
          setOngoing: true,
          enableWakeLock: true,
        ),
      );
    default:
      return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0);
  }
}

/// Tracks the GPS fix and hands LIP reports to [send] on a timer and on
/// demand (PTT, emergency).
class LocationService {
  LocationService(this.send, {Stream<Position> Function(LocationSettings settings)? positions})
      : _positions = positions ?? ((s) => Geolocator.getPositionStream(locationSettings: s));

  final void Function(LocationInfo loc, int reason) send;
  final Stream<Position> Function(LocationSettings settings) _positions;

  StreamSubscription<Position>? _sub;
  Timer? _timer;
  Position? last;

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  /// Starts updates and the periodic report. Already running: only the timer
  /// is restarted, so a reconnect in the background keeps the updates (iOS
  /// and Android do not let a backgrounded app start them again).
  Future<void> start(Duration interval, {bool checkPermission = true}) async {
    _timer?.cancel();
    if (_sub == null) {
      if (checkPermission && !await ensurePermission()) return;
      _sub = _positions(lipLocationSettings(defaultTargetPlatform)).listen((p) {
        final first = last == null;
        last = p;
        if (first) sendNow(LipReason.powerOn);
      }, onError: (_) {});
    }
    _timer = Timer.periodic(interval, (_) => sendNow(LipReason.periodic));
  }

  bool get running => _sub != null;

  void sendNow(int reason) {
    final p = last;
    if (p == null) return;
    send(
      LocationInfo(
        latitude: p.latitude,
        longitude: p.longitude,
        accuracyM: p.accuracy > 0 ? p.accuracy : null,
        speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
        headingDeg: p.heading >= 0 ? p.heading : null,
      ),
      reason,
    );
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
  }
}
