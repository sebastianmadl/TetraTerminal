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
