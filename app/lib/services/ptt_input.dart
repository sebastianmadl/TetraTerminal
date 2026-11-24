import 'dart:async';

import 'package:headset_ptt/headset_ptt.dart';

/// Something outside the touch screen that can key the radio.
sealed class PttInputEvent {}

class PttPressed extends PttInputEvent {}

class PttReleased extends PttInputEvent {}

/// Device link status, for the UI.
class PttDeviceStatus extends PttInputEvent {
  PttDeviceStatus(this.connected, this.text);
  final bool connected;
  final String text;
}

/// Volume reported by the device (0..max).
class PttVolume extends PttInputEvent {
  PttVolume(this.level, this.max);
  final int level;
  final int max;
}

/// A hardware PTT source (Bluetooth headset, later maybe a BLE button or
/// a media key). [TerminalModel] only sees press/release/status/volume.
abstract class PttInput {
  Stream<PttInputEvent> get events;
  Future<void> start();
  Future<void> stop();
}

/// Savox BTH-101 (and compatible) PTT headset over Bluetooth SPP.
/// Reconnects by itself (native side, backoff 1-15 s) while started.
class BluetoothHeadsetPtt implements PttInput {
  BluetoothHeadsetPtt({this.address = '', this.routeAudio = true});
  final String address;
  final bool routeAudio;

  @override
  Stream<PttInputEvent> get events => HeadsetPttChannel.events.asyncMap<PttInputEvent>((e) async {
        switch (e) {
          case HeadsetPtt(:final pressed):
            return pressed ? PttPressed() : PttReleased();
          case HeadsetVolume(:final level, :final max):
            return PttVolume(level, max);
          case HeadsetLinkState(:final state, :final detail):
            final connected = state == 'connected';
            if (routeAudio && connected) await HeadsetPttChannel.setScoRouting(true);
            return PttDeviceStatus(connected, switch (state) {
              'connected' => 'Headset connected${detail == null ? '' : ': $detail'}',
              'connecting' => 'Headset connecting…',
              'stopped' => 'Headset off',
              _ => 'Headset lost (${detail ?? 'unknown'}), retrying',
            });
        }
      });

  @override
  Future<void> start() => HeadsetPttChannel.start(address: address);

  @override
  Future<void> stop() async {
    await HeadsetPttChannel.stop();
    if (routeAudio) await HeadsetPttChannel.setScoRouting(false);
  }
}
