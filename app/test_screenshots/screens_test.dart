// Renders the main screens to PNG for review (not part of `flutter test`).
//   flutter test test_screenshots --update-goldens
// Output: test_screenshots/out/*.png. Fonts: Inter stands in for SF Pro.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/screens/home_screen.dart';
import 'package:tetra_terminal/screens/messages_screen.dart';
import 'package:tetra_terminal/src/rust/api.dart';
import 'package:tetra_terminal/ui/theme.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(File(f).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  }
  await loader.load();
}

Settings _settings() => Settings()
  ..serverUrl = 'https://brew.tmo.example/brew/'
  ..username = '2320997'
  ..issi = 2320997
  ..name = 'OE1XYZ Mobile'
  ..talkgroups = [
    Talkgroup(91, 'Austria'),
    Talkgroup(9, 'Vienna local'),
    Talkgroup(2324, 'TetraPack DACH', mcc: 901, mnc: 1638),
    Talkgroup(777, 'Parrot', scan: false),
  ]
  ..selectedGssi = 91
  ..profiles.first.label = 'TMO Austria'
  ..profiles.addAll([
    ConnectionProfile(id: 'p2', label: 'Lab BS1', serverUrl: 'https://10.0.0.5:9000/brew/', username: 'lab', issi: 2320901, talkgroups: [Talkgroup(1, 'Test')]),
    ConnectionProfile(id: 'p3', serverUrl: 'https://core.tetrapack.example/brew/', username: '2629977', issi: 2629977),
  ]);

TerminalModel _model() {
  final m = TerminalModel(_settings())
    ..link = LinkState.online
    ..extensions = ['dmo-position', 'mni']
    ..networks = parseNetworks('{"this":{"mcc":232,"mnc":5},"networks":[{"mcc":901,"mnc":1638,"name":"TetraPack","up":true},{"mcc":901,"mnc":1234,"name":"Brew North","up":false}]}');
  return m;
}

Future<void> _shot(WidgetTester t, String name, TerminalModel m, Widget home, {Brightness b = Brightness.light, TargetPlatform p = TargetPlatform.iOS, Future<void> Function(WidgetTester)? act}) async {
  debugDefaultTargetPlatformOverride = p;
  t.view.physicalSize = const Size(390 * 2, 844 * 2);
  t.view.devicePixelRatio = 2;
  t.view.padding = const FakeViewPadding(top: 47 * 2, bottom: 34 * 2);
  final key = GlobalKey();
  await t.pumpWidget(RepaintBoundary(
    key: key,
    child: ChangeNotifierProvider.value(
      value: m,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    ),
  ));
  await t.pump(const Duration(milliseconds: 400));
  if (act != null) {
    await act(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
  }
  await expectLater(find.byKey(key), matchesGoldenFile('out/$name.png'));
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // Plugins have no test implementation: answer every channel with null.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['com.llfbandit.record/messages', 'flutter_pcm_sound/methods', 'dev.fluttercommunity.plus/wakelock_plus', 'flutter.baseflow.com/geolocator']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
    const inter = '/usr/share/fonts/opentype/inter';
    await _font('CupertinoSystemText', ['$inter/Inter-Regular.otf', '$inter/Inter-Medium.otf', '$inter/Inter-SemiBold.otf', '$inter/Inter-Bold.otf']);
    await _font('CupertinoSystemDisplay', ['$inter/InterDisplay-Regular.otf', '$inter/InterDisplay-Medium.otf', '$inter/InterDisplay-SemiBold.otf', '$inter/InterDisplay-Bold.otf']);
    final mf = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}/bin/cache/artifacts/material_fonts';
    await _font('Roboto', ['$mf/Roboto-Regular.ttf', '$mf/Roboto-Medium.ttf', '$mf/Roboto-Bold.ttf']);
    await _font('MaterialIcons', ['$mf/MaterialIcons-Regular.otf']);
    final home = Platform.environment['HOME'];
    final cup = Directory('$home/.pub-cache/hosted/pub.dev').listSync().whereType<Directory>().firstWhere((d) => d.path.contains('cupertino_icons-'));
    await _font('packages/cupertino_icons/CupertinoIcons', ['${cup.path}/assets/CupertinoIcons.ttf']);
  });

  testWidgets('01 radio, someone talking', (t) async {
    final m = _model();
    m.groupActivity[91] = GroupCallState(91, 2320972, 'OE1ABC', 1, 'c1', since: DateTime.now().subtract(const Duration(seconds: 12)));
    m.focusCallId = 'c1';
    m.groupActivity[2324] = GroupCallState(2324, 2629001, 'DL2XY', 1, 'c2');
    await _shot(t, '01-radio-heard', m, const HomeScreen());
  });

  testWidgets('02 radio dark, transmitting', (t) async {
    final m = _model()
      ..myTxCallId = 'me'
      ..myTxSince = DateTime.now().subtract(const Duration(seconds: 4));
    await _shot(t, '02-radio-talking-dark', m, const HomeScreen(), b: Brightness.dark);
  });

  testWidgets('03 radio emergency', (t) async {
    final m = _model();
    m.groupActivity[91] = GroupCallState(91, 2320972, 'OE1ABC', 15, 'c1', since: DateTime.now().subtract(const Duration(seconds: 3)));
    m.focusCallId = 'c1';
    await _shot(t, '03-radio-emergency', m, const HomeScreen());
  });

  testWidgets('04 keypad', (t) async {
    await _shot(t, '04-calls-keypad', _model(), const HomeScreen(initialTab: 1));
  });

  testWidgets('05 incoming call', (t) async {
    final m = _model()
      ..privateCall = const PrivateCallInfo(id: 'p1', peer: 2320972, peerName: 'OE1ABC', incoming: true, state: 'ringing', duplex: true, hook: true, priority: 1, floor: 'idle');
    await _shot(t, '05-incoming-call-dark', m, const HomeScreen(), b: Brightness.dark);
  });

  testWidgets('06 conversation', (t) async {
    final m = _model();
    m.messages.addAll([
      ChatMessage(peer: 2320972, outgoing: false, text: 'Bin am Kahlenberg, hörst du mich über BS2?', status: MsgStatus.received),
      ChatMessage(peer: 2320972, outgoing: true, text: 'Laut und klar, Signal 4/5', status: MsgStatus.delivered),
      ChatMessage(peer: 2320972, outgoing: false, text: 'Wechsle jetzt auf TG 2324', status: MsgStatus.received, immediate: true),
    ]);
    await _shot(t, '06-conversation', m, const ConversationScreen(peer: 2320972, title: 'OE1ABC'));
  });

  testWidgets('07 settings', (t) async {
    await _shot(t, '07-settings', _model(), const HomeScreen(initialTab: 3));
  });

  testWidgets('09 edit connection', (t) async {
    await _shot(t, '09-edit-connection', _model(), const HomeScreen(initialTab: 3), act: (t) async {
      await t.tap(find.byTooltip('Edit TMO Austria'));
    });
  });

  testWidgets('10 settings dark, appearance', (t) async {
    final m = _model()..settings.appearance = 'dark';
    await _shot(t, '10-settings-appearance-dark', m, const HomeScreen(initialTab: 3), b: Brightness.dark, act: (t) async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -420));
    });
  });

  testWidgets('08 android radio', (t) async {
    final m = _model();
    m.groupActivity[91] = GroupCallState(91, 2320972, 'OE1ABC', 1, 'c1', since: DateTime.now().subtract(const Duration(seconds: 12)));
    m.focusCallId = 'c1';
    await _shot(t, '08-android-radio', m, const HomeScreen(), p: TargetPlatform.android);
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);
}
