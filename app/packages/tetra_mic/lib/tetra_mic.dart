import 'dart:async';

import 'package:flutter/services.dart';

/// Microphone capture on iOS (native side: ios/Classes/TetraMicPlugin.swift).
///
/// Streams mono PCM16 at the requested rate. Unlike a capture that fixes its
/// format once at start, the native side rebuilds its tap and converter when
/// the audio hardware is reconfigured mid-recording (route or output override,
/// sample rate change, interruption), so wrongly converted samples never
/// reach the voice encoder.
class TetraMic {
  static const _methods = MethodChannel('tetra/mic');
  static const _events = EventChannel('tetra/mic/pcm');

  /// Asks for the microphone permission if it was not decided yet.
  static Future<bool> hasPermission() async => await _methods.invokeMethod<bool>('hasPermission') ?? false;

  /// Starts capture. The stream is subscribed before the native side starts,
  /// so no early buffer is lost.
  static Future<StreamSubscription<Uint8List>> start({
    required int sampleRate,
    required bool voiceProcessing,
    required void Function(Uint8List pcm) onData,
  }) async {
    final sub = _events.receiveBroadcastStream().cast<Uint8List>().listen(
      onData,
      // A failed restart is reported here; capture simply stays silent.
      onError: (Object _) {},
    );
    try {
      await _methods.invokeMethod<void>('start', {'sampleRate': sampleRate, 'voiceProcessing': voiceProcessing});
    } catch (_) {
      await sub.cancel();
      rethrow;
    }
    return sub;
  }

  static Future<void> stop() => _methods.invokeMethod<void>('stop');
}
