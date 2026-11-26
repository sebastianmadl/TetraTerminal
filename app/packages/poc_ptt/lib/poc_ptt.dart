import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Raw events from the native side.
sealed class PocPttEvent {}

class PocPttPress extends PocPttEvent {
  PocPttPress(this.pressed, this.source);
  final bool pressed;
  /// key | broadcast | stop
  final String source;
}

/// One detent of the rotary knob: +1 next talkgroup, -1 previous.
class PocPttKnob extends PocPttEvent {
  PocPttKnob(this.step);
  final int step;
}

/// The key pressed while [PocPtt.learn] was on.
class PocPttLearned extends PocPttEvent {
  PocPttLearned(this.keyCode);
  final int keyCode;
}

/// The radio's broadcast for PTT released, derived from the one for pressed:
/// the last "down" (any case) becomes "up" in the same case, e.g.
/// `com.example.ptt.down` -> `com.example.ptt.up`,
/// `android.intent.action.PTT_DOWN` -> `android.intent.action.PTT_UP`.
/// Returns null when the action contains no "down".
String? deriveUpAction(String down) {
  final d = down.trim();
  final i = d.toLowerCase().lastIndexOf('down');
  if (i < 0) return null;
  final word = d.substring(i, i + 4);
  final up = word == 'DOWN' ? 'UP' : (word[0] == 'D' ? 'Up' : 'up');
  return d.substring(0, i) + up + d.substring(i + 4);
}

/// Hardware PTT on Android PoC radios: a key code and/or a broadcast pair,
/// plus an optional rotary knob for the talkgroup.
/// Android only; elsewhere [supported] is false and calls are no-ops.
class PocPtt {
  static const _m = MethodChannel('org.tetra/poc_ptt');
  static const _e = EventChannel('org.tetra/poc_ptt/events');

  /// The app's own actions, for automation apps (Tasker, MacroDroid, ...).
  static const ownDownAction = 'org.tetra.terminal.ptt.DOWN';
  static const ownUpAction = 'org.tetra.terminal.ptt.UP';

  static bool get supported => Platform.isAndroid;

  static final Stream<PocPttEvent> events = supported
      ? _e.receiveBroadcastStream().map<PocPttEvent>((raw) {
          final m = Map<String, dynamic>.from(raw as Map);
          return switch (m['type']) {
            'learned' => PocPttLearned(m['keyCode'] as int),
            'knob' => PocPttKnob(m['step'] as int),
            _ => PocPttPress(m['pressed'] as bool, m['source'] as String? ?? 'key'),
          };
        }).asBroadcastStream()
      : const Stream.empty();

  /// [keyCode] 0 = no key. [downAction] empty = no radio broadcast; the
  /// release action is derived with [deriveUpAction]. [wake] brings the app to
  /// the front (and over the lock screen) on every press. [knobNextKey] /
  /// [knobPrevKey]: key codes of a rotary knob (0 = none), reported as [PocPttKnob].
  static Future<void> configure({int keyCode = 0, String downAction = '', bool wake = false, int knobNextKey = 0, int knobPrevKey = 0}) async {
    if (!supported) return;
    await _m.invokeMethod('configure', {
      'keyCode': keyCode,
      'downAction': downAction.trim(),
      'upAction': deriveUpAction(downAction),
      'wake': wake,
      'knobNextKey': knobNextKey,
      'knobPrevKey': knobPrevKey,
    });
  }

  static Future<void> stop() async {
    if (!supported) return;
    await _m.invokeMethod('stop');
  }

  /// While on, the next key press is reported as [PocPttLearned] (and not used).
  static Future<void> learn(bool on) async {
    if (!supported) return;
    await _m.invokeMethod('learn', {'on': on});
  }

  /// Whether the background key service is switched on in Accessibility settings.
  static Future<bool> keyServiceEnabled() async {
    if (!supported) return false;
    return await _m.invokeMethod<bool>('keyServiceEnabled') ?? false;
  }

  /// Status LED of the radio: 'tx', 'rx' or 'off'. Returns false where the
  /// device has no LED this app can drive (anything but Hytera PoC firmware).
  static Future<bool> led(String state) async {
    if (!supported) return false;
    try {
      return await _m.invokeMethod<bool>('led', {'state': state}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> openKeyServiceSettings() async {
    if (!supported) return;
    await _m.invokeMethod('openKeyServiceSettings');
  }
}
