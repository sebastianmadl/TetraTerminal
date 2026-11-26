import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tetra_terminal/services/location_service.dart';

void main() {
  test('iOS keeps location updates running in the background', () {
    final s = lipLocationSettings(TargetPlatform.iOS) as AppleSettings;
    expect(s.allowBackgroundLocationUpdates, isTrue);
    expect(s.pauseLocationUpdatesAutomatically, isFalse);
    expect(s.showBackgroundLocationIndicator, isTrue);
    expect(s.accuracy, LocationAccuracy.high);
  });

  test('Android runs location updates in a foreground service', () {
    final s = lipLocationSettings(TargetPlatform.android) as AndroidSettings;
    expect(s.foregroundNotificationConfig, isNotNull);
    expect(s.foregroundNotificationConfig!.setOngoing, isTrue);
  });

  test('a reconnect keeps the running updates and only restarts the timer', () async {
    final opened = <LocationSettings>[];
    final ctrl = StreamController<Position>.broadcast();
    final loc = LocationService((_, __) {}, positions: (s) {
      opened.add(s);
      return ctrl.stream;
    });
    await loc.start(const Duration(seconds: 60), checkPermission: false);
    await loc.start(const Duration(seconds: 30), checkPermission: false);
    expect(opened.length, 1);
    expect(loc.running, isTrue);
    await loc.stop();
    expect(loc.running, isFalse);
    await loc.start(const Duration(seconds: 60), checkPermission: false);
    expect(opened.length, 2);
    await loc.stop();
    await ctrl.close();
  });
}
