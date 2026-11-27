import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Hands an incoming private call to the system so it rings like a phone
/// call, also on the lock screen. iOS: the system call screen (CallKit),
/// packages/tetra_call/ios. Android: a ringing call notification with Answer
/// and Decline that opens full screen over the lock screen,
/// packages/tetra_call/android. Other platforms: no-op.
///
/// Works while the app runs (in front or in the background); a terminated app
/// is not woken up.
class CallAlert {
  static const _channel = MethodChannel('tetra/call');
  bool _unavailable = kIsWeb || !(defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);
  String? _shown;
  bool _system = false;

  /// The user answered / declined or hung up on the system's call screen.
  void Function()? onAnswer;
  void Function()? onEnd;

  /// iOS: the system's mute button and keypad of the call screen.
  void Function(bool muted)? onMute;
  void Function(String digits)? onDtmf;

  /// iOS: the system handed the audio session to the app (true) or took it
  /// back after the call (false).
  void Function(bool active)? onAudio;

  /// Id of the call the system is showing, if any.
  String? get shown => _shown;

  /// iOS: the call lives on the system call screen, so answering and hanging
  /// up inside the app have to go through the system as well.
  bool get viaSystem => _system && _shown != null;

  void listen() {
    if (_unavailable) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'answer':
          onAnswer?.call();
        case 'end':
          _shown = null;
          onEnd?.call();
        case 'mute':
          onMute?.call(call.arguments == true);
        case 'dtmf':
          onDtmf?.call('${call.arguments ?? ''}');
        case 'audio':
          onAudio?.call(call.arguments == true);
      }
    });
  }

  /// Rings for the call [id]. [name] is the caller as the app shows it, [sub]
  /// the line below (ISSI or phone number).
  Future<void> incoming({required String id, required String name, String? sub, required bool emergency, required bool duplex, String? ringtone}) async {
    if (_unavailable) return;
    _shown = id;
    final taken = await _call<bool>('incoming', {'id': id, 'name': name, 'sub': sub, 'emergency': emergency, 'duplex': duplex, 'ringtone': ringtone});
    if (taken != true) {
      // Do Not Disturb or no permission: the app shows the call on its own.
      if (_shown == id) _shown = null;
      return;
    }
    _system = defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// Android: opens the system's ring tone picker. Null when cancelled; throws
  /// a [PlatformException] on a device without a picker.
  Future<({String uri, String title})?> pickRingtone(String? current) async {
    final r = await _channel.invokeMapMethod<String, Object?>('pickRingtone', {'current': current});
    final uri = r?['uri'];
    if (uri is! String) return null;
    return (uri: uri, title: '${r?['title'] ?? 'Ring tone'}');
  }

  /// iOS: ring tones that ship with the app (file name -> label). The iPhone's
  /// own ring tones cannot be chosen for calls of an app.
  static const bundledRingtones = {
    'ring_classic.wav': 'Classic bell',
    'ring_twotone.wav': 'Two-tone',
    'ring_chime.wav': 'Chime',
    'ring_beacon.wav': 'Beacon',
  };

  /// iOS: the bundled ring tones this build really contains.
  Future<List<String>> ringtones() async {
    final found = await _call<List<Object?>>('ringtones', null);
    if (found == null) return bundledRingtones.keys.toList();
    return [for (final f in found) if (bundledRingtones.containsKey(f)) f as String];
  }

  /// iOS: plays a bundled ring tone once (null stops it).
  Future<void> preview(String? name) => _call<void>('preview', {'name': name});

  /// The call was answered: stop ringing.
  Future<void> connected(String id) async {
    if (_shown != id) return;
    await _call<void>('connected', {'id': id});
  }

  /// The call is over (hung up, declined, missed, link lost).
  Future<void> ended(String id) async {
    if (_shown != id) return;
    _shown = null;
    await _call<void>('ended', {'id': id});
  }

  /// iOS: answer through the system; false when the app has to do it itself.
  Future<bool> answer() async => await _call<bool>('answer', {'id': _shown}) == true;

  /// iOS: hang up through the system; false when the app has to do it itself.
  Future<bool> end() async => await _call<bool>('end', {'id': _shown}) == true;

  Future<T?> _call<T>(String method, Object? args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      _unavailable = true;
      _shown = null;
    } catch (e) {
      debugPrint('call alert: $e');
    }
    return null;
  }
}
