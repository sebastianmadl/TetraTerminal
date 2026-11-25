import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/services/audio_io.dart';

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
