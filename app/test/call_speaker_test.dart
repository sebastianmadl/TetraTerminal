import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/screens/calls_screen.dart';
import 'package:tetra_terminal/src/rust/api.dart';
import 'package:tetra_terminal/ui/theme.dart';

class _Secrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The loudspeaker / earpiece switch sits on the call screen itself, so it
/// can be used during a full-duplex call (it used to be on the Radio tab only,
/// and hidden there on PoC radios).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  PrivateCallInfo call(String state) => PrivateCallInfo(
      id: 'p1', peer: 2629001, peerName: 'OE1ABC', incoming: true, state: state, duplex: true, hook: true, priority: 1, floor: 'idle');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = _Secrets();
    Settings.isPocDevice = () => false;
    messenger.setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('tetra/call'), (_) async => null);
  });

  Future<TerminalModel> show(WidgetTester t, String state, {bool poc = false}) async {
    final s = Settings();
    if (poc) s.applyPocDefaults();
    final m = TerminalModel(s);
    m.handleEvent(AppEvent.privateCall(call: call(state)));
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: m,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: CallsScreen())),
    ));
    return m;
  }

  // The model's short timers (call handling) run out before the test ends.
  Future<void> done(WidgetTester t) => t.pump(const Duration(seconds: 3));

  testWidgets('a connected full-duplex call switches between loudspeaker and earpiece', (t) async {
    final m = await show(t, 'connected');
    expect(m.settings.speakerOut, isTrue);
    await t.tap(find.bySemanticsLabel('Loudspeaker on. Tap for earpiece'));
    await t.pump();
    expect(m.settings.speakerOut, isFalse);
    expect(find.bySemanticsLabel('Earpiece. Tap for loudspeaker'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Earpiece. Tap for loudspeaker'));
    await t.pump();
    expect(m.settings.speakerOut, isTrue);
    await done(t);
  });

  testWidgets('the switch is there on a PoC radio too, where the Radio tab hides it', (t) async {
    final m = await show(t, 'connected', poc: true);
    expect(m.settings.showSpeakerButton, isFalse);
    expect(find.bySemanticsLabel('Loudspeaker on. Tap for earpiece'), findsOneWidget);
    await done(t);
  });

  testWidgets('an outgoing call can be switched while it rings at the other end', (t) async {
    await show(t, 'alerting');
    expect(find.bySemanticsLabel('Loudspeaker on. Tap for earpiece'), findsOneWidget);
    await done(t);
  });

  testWidgets('a call ringing here shows answer and hang up only', (t) async {
    await show(t, 'ringing');
    expect(find.bySemanticsLabel('Loudspeaker on. Tap for earpiece'), findsNothing);
    await done(t);
  });
}
