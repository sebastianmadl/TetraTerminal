import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/services/call_alert.dart';
import 'package:tetra_terminal/src/rust/api.dart';

/// Incoming private calls are handed to the system call screen / the ringing
/// call notification over the "tetra/call" channel.
class _Secrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('tetra/call');
  final calls = <MethodCall>[];

  PrivateCallInfo call(String state, {bool incoming = true, int priority = 1, String? number, String? peerName}) => PrivateCallInfo(
      id: 'p1', peer: 2629001, peerName: peerName, number: number, incoming: incoming, state: state, duplex: true, hook: true, priority: priority, floor: 'idle');

  setUp(() {
    calls.clear();
    Settings.isPocDevice = () => false;
    messenger.setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return c.method == 'incoming' || c.method == 'answer' || c.method == 'end' ? true : null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a ringing incoming call rings once, stops when answered and when over', () async {
    final m = TerminalModel(Settings());
    m.handleEvent(AppEvent.privateCall(call: call('ringing', peerName: 'OE1ABC')));
    m.handleEvent(AppEvent.privateCall(call: call('ringing', peerName: 'OE1ABC')));
    await settle();
    expect(calls.map((c) => c.method), ['incoming']);
    expect(calls.single.arguments, {'id': 'p1', 'name': 'OE1ABC', 'sub': 'ISSI 2629001', 'emergency': false, 'duplex': true, 'ringtone': null, 'labels': ['Incoming call', 'Answer', 'Decline']});

    m.handleEvent(AppEvent.privateCall(call: call('connected', peerName: 'OE1ABC')));
    await settle();
    expect(calls.last.method, 'connected');

    m.handleEvent(const AppEvent.privateCallEnded(callId: 'p1', peer: 2629001, cause: 0));
    await settle();
    expect(calls.map((c) => c.method), ['incoming', 'connected', 'ended']);
    expect(m.callAlert.shown, isNull);
  });

  test('an emergency call and a phone call are announced as such', () async {
    final m = TerminalModel(Settings()..ringtoneUri = 'content://media/ring/7');
    m.handleEvent(AppEvent.privateCall(call: call('ringing', priority: 15, number: '+4312345', peerName: 'Office')));
    await settle();
    expect(calls.single.arguments, {'id': 'p1', 'name': 'Office', 'sub': '+4312345', 'emergency': true, 'duplex': true, 'ringtone': 'content://media/ring/7', 'labels': ['Emergency call', 'Answer', 'Decline']});
  });

  test('no ringing for outgoing calls or with the setting off', () async {
    final m = TerminalModel(Settings());
    m.handleEvent(AppEvent.privateCall(call: call('alerting', incoming: false)));
    m.handleEvent(AppEvent.privateCall(call: call('connected', incoming: false)));
    m.handleEvent(const AppEvent.privateCallEnded(callId: 'p1', peer: 2629001, cause: 0));
    final off = TerminalModel(Settings()..ringIncoming = false);
    off.handleEvent(AppEvent.privateCall(call: call('ringing')));
    off.handleEvent(const AppEvent.privateCallEnded(callId: 'p1', peer: 2629001, cause: 0));
    await settle();
    expect(calls, isEmpty);
  });

  test('Android: the app answers and hangs up itself, the system is not asked', () async {
    final m = TerminalModel(Settings());
    m.handleEvent(AppEvent.privateCall(call: call('ringing')));
    await settle();
    expect(m.callAlert.viaSystem, isFalse);
    m.answer();
    m.hangup();
    await settle();
    expect(calls.map((c) => c.method), ['incoming']);
  });

  test('iOS: answering and hanging up in the app go through the system call screen', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final m = TerminalModel(Settings());
    m.handleEvent(AppEvent.privateCall(call: call('ringing')));
    await settle();
    expect(m.callAlert.viaSystem, isTrue);
    m.answer();
    await settle();
    m.hangup();
    await settle();
    expect(calls.map((c) => c.method), ['incoming', 'answer', 'end']);
    expect(calls.last.arguments, {'id': 'p1'});
  });

  test('the system refusing the call (Do Not Disturb) leaves it to the app', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return false;
    });
    final m = TerminalModel(Settings());
    m.handleEvent(AppEvent.privateCall(call: call('ringing')));
    await settle();
    expect(m.callAlert.viaSystem, isFalse);
    expect(m.callAlert.shown, isNull);
  });

  test('a call declined on the system call screen is forgotten', () async {
    final m = TerminalModel(Settings());
    m.callAlert.listen();
    var ended = 0;
    m.callAlert.onEnd = () => ended++;
    m.handleEvent(AppEvent.privateCall(call: call('ringing')));
    await settle();
    await messenger.handlePlatformMessage('tetra/call', const StandardMethodCodec().encodeMethodCall(const MethodCall('end', 'p1')), (_) {});
    expect(ended, 1);
    expect(m.callAlert.shown, isNull);
  });

  test('ring setting and ring tone survive a save', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = _Secrets();
    final s = Settings()
      ..ringIncoming = false
      ..ringtoneUri = 'content://media/ring/7'
      ..ringtoneName = 'Bell';
    await s.save();
    final loaded = await Settings.load();
    expect((loaded.ringIncoming, loaded.ringtoneUri, loaded.ringtoneName), (false, 'content://media/ring/7', 'Bell'));
    SharedPreferences.setMockInitialValues({});
    expect((await Settings.load()).ringIncoming, isTrue);
  });

  test('the ring tone picker hands back the chosen tone', () async {
    messenger.setMockMethodCallHandler(channel, (c) async => c.method == 'pickRingtone' ? {'uri': 'content://x', 'title': 'Bell'} : null);
    final picked = await CallAlert().pickRingtone(null);
    expect((picked?.uri, picked?.title), ('content://x', 'Bell'));
  });

  test('iOS: only the bundled ring tones this build contains are offered', () async {
    messenger.setMockMethodCallHandler(channel, (c) async => c.method == 'ringtones' ? ['ring_chime.wav', 'other.wav'] : null);
    expect(await CallAlert().ringtones(), ['ring_chime.wav']);
  });

  test('a received message alerts with the sender and counts as unread until its chat is opened', () async {
    final m = TerminalModel(Settings()..issi = 2320997);
    m.handleEvent(const AppEvent.textReceived(from: 2629001, to: 2320997, text: 'Hello', immediate: false));
    m.handleEvent(const AppEvent.textReceived(from: 2629001, to: 2320997, text: 'Again', immediate: false));
    m.handleEvent(const AppEvent.textReceived(from: 2320415, to: 2320997, text: 'Hi', immediate: false));
    await settle();
    final alerts = calls.where((c) => c.method == 'message').toList();
    expect(alerts, hasLength(3));
    expect((alerts.first.arguments as Map)['text'], 'Hello');
    expect((alerts.first.arguments as Map)['peer'], 2629001);
    expect((m.unreadMessages(), m.unreadMessages(2629001), m.unreadMessages(2320415)), (3, 2, 1));

    m.conversationOpen(2629001, true);
    expect((m.unreadMessages(), m.unreadMessages(2629001)), (1, 0));
    // A message into the open chat is read right away.
    m.handleEvent(const AppEvent.textReceived(from: 2629001, to: 2320997, text: 'Still there?', immediate: false));
    expect(m.unreadMessages(2629001), 0);
    m.conversationOpen(2629001, false);
    m.handleEvent(const AppEvent.textReceived(from: 2629001, to: 2320997, text: 'Later', immediate: false));
    expect(m.unreadMessages(2629001), 1);
  });

  test('message alerts can be switched off', () async {
    final m = TerminalModel(Settings()
      ..issi = 2320997
      ..messageAlert = false);
    m.handleEvent(const AppEvent.textReceived(from: 2629001, to: 2320997, text: 'Hello', immediate: false));
    await settle();
    expect(calls.where((c) => c.method == 'message'), isEmpty);
    expect(m.unreadMessages(), 1);
  });
}
