import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/services/audio_io.dart';

class _Secrets implements SecretStore {
  final v = <String, String>{};
  @override
  Future<String?> read(String key) async => v[key];
  @override
  Future<void> write(String key, String value) async => v[key] = value;
  @override
  Future<void> delete(String key) async => v.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('loudspeaker mode moves off the receiver if iOS fell back to it', () {
    expect(iosOverride(speaker: true, outputs: [AVAudioSessionPort.builtInReceiver]), AVAudioSessionPortOverride.speaker);
  });

  test('earpiece mode clears the override when the loudspeaker plays', () {
    expect(iosOverride(speaker: false, outputs: [AVAudioSessionPort.builtInSpeaker]), AVAudioSessionPortOverride.none);
  });

  test('a route that is already right is not touched (no hardware reconfiguration, no chirping)', () {
    expect(iosOverride(speaker: true, outputs: [AVAudioSessionPort.builtInSpeaker]), isNull);
    expect(iosOverride(speaker: false, outputs: [AVAudioSessionPort.builtInReceiver]), isNull);
  });

  test('a headset or Bluetooth device always wins', () {
    for (final port in [AVAudioSessionPort.headphones, AVAudioSessionPort.bluetoothHfp, AVAudioSessionPort.bluetoothA2dp, AVAudioSessionPort.carAudio]) {
      expect(iosOverride(speaker: true, outputs: [port]), isNull, reason: '$port');
      expect(iosOverride(speaker: false, outputs: [port]), isNull, reason: '$port');
    }
    expect(isHeadset(AndroidAudioDeviceType.bluetoothSco), isTrue);
    expect(isHeadset(AndroidAudioDeviceType.wiredHeadset), isTrue);
    expect(isHeadset(AndroidAudioDeviceType.builtInSpeaker), isFalse);
    expect(isHeadset(AndroidAudioDeviceType.builtInEarpiece), isFalse);
  });

  test('only a full-duplex call puts iOS into call mode (call volume)', () {
    for (final speaker in [true, false]) {
      expect(sessionConfig(speaker: speaker, duplex: false).avAudioSessionMode, AVAudioSessionMode.defaultMode, reason: 'speaker=$speaker');
      expect(sessionConfig(speaker: speaker, duplex: true).avAudioSessionMode, AVAudioSessionMode.voiceChat, reason: 'speaker=$speaker');
    }
    final loud = sessionConfig(speaker: true, duplex: true).avAudioSessionCategoryOptions!;
    expect(loud.contains(AVAudioSessionCategoryOptions.defaultToSpeaker), isTrue);
    final ear = sessionConfig(speaker: false, duplex: false).avAudioSessionCategoryOptions!;
    expect(ear.contains(AVAudioSessionCategoryOptions.defaultToSpeaker), isFalse);
  });

  test('Android earpiece: call mode and voice-call playback (media audio never reaches the earpiece)', () {
    final ear = androidRoute(headset: false, speaker: false);
    expect(ear, AndroidRoute.earpiece);
    expect(ear.mode, AndroidAudioHardwareMode.inCommunication);
    expect(ear.voiceCallPlayback, isTrue);
  });

  test('Android loudspeaker and headset stay media audio in normal mode', () {
    for (final r in [androidRoute(headset: false, speaker: true), androidRoute(headset: true, speaker: true), androidRoute(headset: true, speaker: false)]) {
      expect(r.mode, AndroidAudioHardwareMode.normal, reason: '$r');
      expect(r.voiceCallPlayback, isFalse, reason: '$r');
    }
    expect(androidRoute(headset: true, speaker: false), AndroidRoute.headset);
  });

  test('Android full-duplex call runs as a voice call, so the echo canceller has its reference', () {
    final loud = androidRoute(headset: false, speaker: true, duplex: true);
    expect(loud, AndroidRoute.callSpeaker);
    expect(loud.mode, AndroidAudioHardwareMode.inCommunication);
    expect(loud.voiceCallPlayback, isTrue);
    expect(loud.speakerphone, isTrue);
    expect(loud.device!(AndroidAudioDeviceType.builtInSpeaker), isTrue);
    final head = androidRoute(headset: true, speaker: true, duplex: true);
    expect(head, AndroidRoute.callHeadset);
    expect(head.voiceCallPlayback, isTrue);
    expect(head.device!(AndroidAudioDeviceType.bluetoothSco), isTrue);
    expect(androidRoute(headset: false, speaker: false, duplex: true), AndroidRoute.earpiece);
    expect(AndroidRoute.earpiece.device!(AndroidAudioDeviceType.builtInEarpiece), isTrue);
  });

  test('iOS: the output switched on the system call screen is read back as the choice', () {
    expect(iosSpeakerOf([AVAudioSessionPort.builtInSpeaker]), isTrue);
    expect(iosSpeakerOf([AVAudioSessionPort.builtInReceiver]), isFalse);
    expect(iosSpeakerOf([AVAudioSessionPort.bluetoothHfp]), isNull);
    expect(iosSpeakerOf([]), isNull);
  });

  test('the choice is saved, loudspeaker by default', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = _Secrets();
    final s = Settings();
    expect(s.speakerOut, isTrue);
    s.speakerOut = false;
    await s.save();
    expect((await Settings.load()).speakerOut, isFalse);
  });
}
