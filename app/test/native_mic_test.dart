import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/services/audio_io.dart';
import 'package:tetra_terminal/services/tx_level.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('tetra/mic');
  const events = EventChannel('tetra/mic/pcm');

  late List<String> calls;
  late Map<Object?, Object?> startArgs;
  MockStreamHandlerEventSink? sink;

  setUp(() {
    calls = [];
    startArgs = {};
    sink = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      if (call.method == 'hasPermission') return true;
      if (call.method == 'start') startArgs = call.arguments as Map<Object?, Object?>;
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, s) {
          calls.add('listen');
          sink = s;
        },
        onCancel: (_) => calls.add('cancel'),
      ),
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('iOS captures through the own microphone module, not the record plugin', () async {
    final audio = AudioIO();
    final got = <int>[];
    await audio.startMic((pcm) => got.addAll(pcm));
    expect(calls, ['hasPermission', 'listen', 'start'], reason: 'listening before start loses no buffer');
    expect(startArgs, {'sampleRate': 16000, 'voiceProcessing': false});
    expect(audio.micRunning, isTrue);

    // 100 ms at 16 kHz in, about 50 ms at 8 kHz out (minus the filter delay).
    final chunk = Int16List.fromList(List.generate(1600, (i) => (i % 32) * 100));
    sink!.success(chunk.buffer.asUint8List());
    await pumpEventQueue();
    expect(got.length, 800);

    await audio.stopMic();
    expect(calls, containsAllInOrder(['cancel', 'stop']));
    expect(audio.micRunning, isFalse);
  });

  test('a full-duplex call asks the module for voice processing', () async {
    final audio = AudioIO();
    await audio.startMic((_) {}, voiceProcessing: true);
    expect(startArgs['voiceProcessing'], isTrue);
    await audio.stopMic();
  });

  test('iOS full-duplex call: received audio plays through the mic module, so its echo canceller removes it', () async {
    final pcmCalls = <String>[];
    const pcm = MethodChannel('flutter_pcm_sound/methods');
    messenger.setMockMethodCallHandler(pcm, (c) async => pcmCalls.add(c.method));
    addTearDown(() => messenger.setMockMethodCallHandler(pcm, null));
    // The platform audio session cannot run in a test; the player is ready.
    final audio = AudioIO()..debugPlayerReady();
    final frame = Int16List.fromList(List.generate(480, (i) => (i % 40) * 200));

    await audio.startMic((_) {}, voiceProcessing: true);
    pcmCalls.clear();
    audio.play(frame);
    await pumpEventQueue();
    expect(calls, contains('play'));
    expect(pcmCalls, isNot(contains('feed')));

    await audio.stopMic();
    calls.clear();
    audio.play(frame);
    await pumpEventQueue();
    expect(calls, isNot(contains('play')), reason: 'group calls and PTT play through the normal player');
    expect(pcmCalls, contains('feed'));

    // Half duplex (no voice processing): the normal player as well.
    await audio.startMic((_) {});
    calls.clear();
    audio.play(frame);
    await pumpEventQueue();
    expect(calls, isNot(contains('play')));
    await audio.stopMic();
  });

  test('a hot iOS microphone reaches the encoder at the nominal level, and is captured on request', () async {
    final audio = AudioIO()..captureTx = true;
    TxCapture? captured;
    audio.onTxCapture = (c) => captured = c;
    final got = <int>[];
    await audio.startMic((pcm) => got.addAll(pcm));
    // 2 s of loud speech-like audio at 16 kHz, rms about 12000 (peaks near full scale).
    for (var c = 0; c < 20; c++) {
      final chunk = Int16List.fromList(List.generate(1600, (i) {
        final t = (c * 1600 + i) / 16000;
        final env = 0.5 - 0.5 * math.cos(2 * math.pi * 4 * t);
        return (env * (math.sin(2 * math.pi * 200 * t) + 0.6 * math.sin(2 * math.pi * 900 * t)) * 20000).round().clamp(-32768, 32767);
      }));
      sink!.success(chunk.buffer.asUint8List());
    }
    await pumpEventQueue();
    double rms(Iterable<int> v) => math.sqrt(v.fold<double>(0, (s, x) => s + x * x) / v.length);
    final second = got.skip(8000).toList();
    expect(rms(second), inInclusiveRange(1000, 2900), reason: 'about -24 dBov instead of the microphone level');
    expect(second.map((v) => v.abs()).reduce(math.max), lessThanOrEqualTo(12000));

    await audio.stopMic();
    expect(captured, isNotNull);
    expect(captured!.raw.length, 32000);
    expect(captured!.encoderInput.length, got.length);
  });

  test('rumble from the iOS microphone does not reach the encoder', () async {
    final audio = AudioIO();
    final got = <int>[];
    await audio.startMic((pcm) => got.addAll(pcm));
    // 2 s of 50 Hz hum at 16 kHz, rms about 2800 (-21 dBFS).
    for (var c = 0; c < 20; c++) {
      sink!.success(Int16List.fromList(List.generate(1600, (i) => (math.sin(2 * math.pi * 50 * (c * 1600 + i) / 16000) * 4000).round())).buffer.asUint8List());
    }
    await pumpEventQueue();
    final tail = got.skip(8000);
    expect(math.sqrt(tail.fold<double>(0, (s, x) => s + x * x) / tail.length), lessThan(30));
    await audio.stopMic();
  });

  test('noise suppression turns down room noise, and can be switched off', () async {
    Future<double> noiseOut(bool on) async {
      final audio = AudioIO()..noiseSuppression = on;
      final got = <int>[];
      await audio.startMic((pcm) => got.addAll(pcm));
      final rnd = math.Random(5);
      // 3 s of broadband room noise at 16 kHz, rms about 1000.
      for (var c = 0; c < 30; c++) {
        sink!.success(Int16List.fromList(List.generate(1600, (_) => ((rnd.nextDouble() * 2 - 1) * 1730).round())).buffer.asUint8List());
      }
      await pumpEventQueue();
      await audio.stopMic();
      final tail = got.skip(8000);
      return math.sqrt(tail.fold<double>(0, (s, x) => s + x * x) / tail.length);
    }

    final off = await noiseOut(false), on = await noiseOut(true);
    expect(20 * math.log(off / on) / math.ln10, greaterThan(8), reason: 'off $off, on $on');
  });

  test('a refused microphone does not start capture', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      return call.method == 'hasPermission' ? false : null;
    });
    final audio = AudioIO();
    await expectLater(audio.startMic((_) {}), throwsStateError);
    expect(calls, ['hasPermission']);
    expect(audio.micRunning, isFalse);
  });
}
