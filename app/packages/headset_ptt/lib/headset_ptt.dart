import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Raw events from the native headset link.
sealed class HeadsetEvent {}

class HeadsetPtt extends HeadsetEvent {
  HeadsetPtt(this.pressed);
  final bool pressed;
}

class HeadsetLinkState extends HeadsetEvent {
  HeadsetLinkState(this.state, this.detail);
  /// connecting | connected | disconnected | stopped
  final String state;
  final String? detail;
}

class HeadsetVolume extends HeadsetEvent {
  HeadsetVolume(this.level, this.max);
  final int level;
  final int max;
}

/// Bluetooth PTT headset (Savox BTH-101 style "+PTT=P"/"+PTT=R" on SPP).
/// Android only; elsewhere [supported] is false and calls are no-ops.
class HeadsetPttChannel {
  static const _m = MethodChannel('org.tetra/headset_ptt');
  static const _e = EventChannel('org.tetra/headset_ptt/events');

  static bool get supported => Platform.isAndroid;

  static final Stream<HeadsetEvent> events = supported
      ? _e.receiveBroadcastStream().map((raw) {
          final m = Map<String, dynamic>.from(raw as Map);
          return switch (m['type']) {
            'ptt' => HeadsetPtt(m['pressed'] as bool),
            'volume' => HeadsetVolume(m['level'] as int, m['max'] as int),
            _ => HeadsetLinkState(m['state'] as String, m['detail'] as String?),
          } as HeadsetEvent;
        })
      : const Stream.empty();

  /// Connects (and keeps reconnecting) to the headset. [address] empty = first
  /// paired device whose name starts with [namePrefix].
  static Future<void> start({String address = '', String namePrefix = 'Savox', int channel = 1}) async {
    if (!supported) return;
    await _m.invokeMethod('start', {'address': address, 'namePrefix': namePrefix, 'channel': channel});
  }

  static Future<void> stop() async {
    if (!supported) return;
    await _m.invokeMethod('stop');
  }

  /// Routes voice audio over the headset's SCO link. Returns false if no SCO device.
  static Future<bool> setScoRouting(bool on) async {
    if (!supported) return false;
    return await _m.invokeMethod<bool>('setScoRouting', {'on': on}) ?? false;
  }
}
