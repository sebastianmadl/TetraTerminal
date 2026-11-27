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
import 'package:tetra_terminal/ui/glass.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/contacts.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/screens/home_screen.dart';
import 'package:tetra_terminal/screens/messages_screen.dart';
import 'package:tetra_terminal/screens/settings_screen.dart';
import 'package:tetra_terminal/ui/l10n.dart';
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
    ..groupAccess = {777: GroupAccess.listen}
    ..networks = parseNetworks('{"this":{"mcc":232,"mnc":5},"networks":[{"mcc":901,"mnc":1638,"name":"TetraPack","up":true},{"mcc":901,"mnc":1234,"name":"Brew North","up":false}]}');
  m.contacts.radioIdForTest = {2320972: (callsign: 'OE1ABC', firstName: 'Anna'), 2629001: (callsign: 'DL2XY', firstName: 'Max'), 2320415: (callsign: 'OE3KLM', firstName: 'Karl')};
  m.contacts.contacts.addAll([Contact(2320901, 'BS1 Kahlenberg', note: 'Lab radio'), Contact(2320972, 'Anna (OE1ABC)'), Contact(2320500, 'Dispatch Vienna')]);
  final now = DateTime.now();
  DateTime ago(int min) => now.subtract(Duration(minutes: min));
  m.callLog.entries.addAll([
    CallLogEntry(time: ago(2), issi: 2320972, kind: CallKind.groupHeard, gssi: 91, groupName: 'Austria', duration: const Duration(seconds: 14)),
    CallLogEntry(time: ago(3), issi: 2320997, kind: CallKind.groupTalked, gssi: 91, groupName: 'Austria', duration: const Duration(seconds: 6)),
    CallLogEntry(time: ago(9), issi: 2629001, kind: CallKind.groupHeard, gssi: 2324, groupName: 'TetraPack DACH', duration: const Duration(seconds: 41)),
    CallLogEntry(time: ago(25), issi: 2320415, kind: CallKind.privateMissed),
    CallLogEntry(time: ago(48), issi: 2320500, kind: CallKind.privateIn, duration: const Duration(minutes: 2, seconds: 3)),
    CallLogEntry(time: ago(70), issi: 2320972, kind: CallKind.groupHeard, gssi: 9, groupName: 'Vienna local', duration: const Duration(seconds: 8), emergency: true),
    CallLogEntry(time: now.subtract(const Duration(days: 1, hours: 2)), issi: 2629001, kind: CallKind.groupHeard, gssi: 2324, groupName: 'TetraPack DACH', duration: const Duration(seconds: 22)),
    for (var i = 0; i < 6; i++)
      CallLogEntry(time: now.subtract(Duration(days: 1, hours: 3 + i)), issi: i.isEven ? 2320972 : 2629001, kind: CallKind.groupHeard, gssi: i.isEven ? 91 : 2324, groupName: i.isEven ? 'Austria' : 'TetraPack DACH', duration: Duration(seconds: 9 + 7 * i)),
  ]);
  return m;
}

Future<void> _shot(WidgetTester t, String name, TerminalModel m, Widget home, {Brightness b = Brightness.light, TargetPlatform p = TargetPlatform.iOS, Future<void> Function(WidgetTester)? act, Size? size}) async {
  debugDefaultTargetPlatformOverride = p;
  t.view.physicalSize = (size ?? const Size(390, 844)) * 2;
  t.view.devicePixelRatio = 2;
  t.view.padding = size != null ? const FakeViewPadding(top: 24 * 2) : const FakeViewPadding(top: 47 * 2, bottom: 34 * 2);
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

  testWidgets('31 radio, scanned group heard', (t) async {
    final m = _model();
    m.groupActivity[2324] = GroupCallState(2324, 2629001, 'DL2XY', 1, 'c2', since: DateTime.now().subtract(const Duration(seconds: 5)));
    m.focusCallId = 'c2';
    await _shot(t, '31-radio-scan-heard', m, const HomeScreen());
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
    await _shot(t, '04-calls-keypad', _model(), const HomeScreen(initialTab: 1), act: (t) async {
      await t.tap(find.text('Keypad'));
    });
  });

  testWidgets('11 recents', (t) async {
    await _shot(t, '11-recents', _model(), const HomeScreen(initialTab: 1));
  });

  testWidgets('12 contacts', (t) async {
    await _shot(t, '12-contacts', _model(), const HomeScreen(initialTab: 2));
  });

  testWidgets('23 radio, group menu open', (t) async {
    await _shot(t, '23-radio-group-menu', _model(), const HomeScreen(), act: (t) async {
      await t.tap(find.textContaining('Scan ·'));
    });
  });

  testWidgets('24 contacts, groups', (t) async {
    await _shot(t, '24-contacts-groups', _model(), const HomeScreen(initialTab: 2), act: (t) async {
      await t.tap(find.text('Groups'));
    });
  });

  testWidgets('25 receive audio', (t) async {
    await _shot(t, '25-receive-audio', _model(), const RxAudioScreen());
  });

  testWidgets('26 android radio, group menu open', (t) async {
    await _shot(t, '26-android-radio-group-menu', _model(), const HomeScreen(), p: TargetPlatform.android, act: (t) async {
      await t.tap(find.textContaining('Scan ·'));
    });
  });

  testWidgets('27 android radio on a small PoC screen, hardware PTT', (t) async {
    final m = _model();
    m.settings.showPttButton = false;
    m.settings.pocPttEnabled = true;
    await _shot(t, '27-android-radio-small', m, const HomeScreen(), p: TargetPlatform.android, size: const Size(320, 500));
  });

  testWidgets('29 android radio on a small PoC screen, no floating buttons', (t) async {
    final m = _model();
    m.settings
      ..showPttButton = false
      ..pocPttEnabled = true
      ..showSosButton = false
      ..showSpeakerButton = false;
    await _shot(t, '29-android-radio-small-bare', m, const HomeScreen(), p: TargetPlatform.android, size: const Size(320, 500));
  });

  testWidgets('30 radio without SOS and loudspeaker buttons', (t) async {
    final m = _model();
    m.settings
      ..showSosButton = false
      ..showSpeakerButton = false;
    await _shot(t, '30-radio-ptt-only', m, const HomeScreen());
  });

  testWidgets('28 android radio on a small PoC screen, on-screen PTT', (t) async {
    await _shot(t, '28-android-radio-small-ptt', _model(), const HomeScreen(), p: TargetPlatform.android, size: const Size(320, 500));
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
    await _shot(t, '07-settings', _model(), const HomeScreen(initialTab: 4));
  });

  testWidgets('09 edit connection', (t) async {
    await _shot(t, '09-edit-connection', _model(), const HomeScreen(initialTab: 4), act: (t) async {
      await t.tap(find.byTooltip('Edit TMO Austria'));
    });
  });

  testWidgets('22 edit connection, Basestation mode', (t) async {
    final m = _model();
    Settings.basestationModeAvailable = true;
    addTearDown(() => Settings.basestationModeAvailable = false);
    m.settings.active.basestation = true;
    await _shot(t, '22-edit-connection-basestation', m, const HomeScreen(initialTab: 4), act: (t) async {
      await t.tap(find.byTooltip('Edit TMO Austria'));
      await t.pumpAndSettle();
      await t.drag(find.text('Login mode'), const Offset(0, -260));
    });
  });

  testWidgets('10 settings dark, appearance', (t) async {
    final m = _model()..settings.appearance = 'dark';
    await _shot(t, '10-settings-appearance-dark', m, const DisplaySettings(), b: Brightness.dark);
  });

  testWidgets('08 android radio', (t) async {
    final m = _model();
    m.groupActivity[91] = GroupCallState(91, 2320972, 'OE1ABC', 1, 'c1', since: DateTime.now().subtract(const Duration(seconds: 12)));
    m.focusCallId = 'c1';
    await _shot(t, '08-android-radio', m, const HomeScreen(), p: TargetPlatform.android);
  });

  testWidgets('13 settings footer', (t) async {
    await _shot(t, '13-settings-footer', _model(), const HomeScreen(initialTab: 4), act: (t) async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    });
  });

  testWidgets('18 settings footer dark', (t) async {
    final m = _model()..settings.appearance = 'dark';
    await _shot(t, '18-settings-footer-dark', m, const HomeScreen(initialTab: 4), b: Brightness.dark, act: (t) async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    });
  });

  testWidgets('19 android contacts', (t) async {
    await _shot(t, '19-android-contacts', _model(), const HomeScreen(initialTab: 2), p: TargetPlatform.android);
  });

  testWidgets('20 android keypad', (t) async {
    await _shot(t, '20-android-keypad', _model(), const HomeScreen(initialTab: 1), p: TargetPlatform.android, act: (t) async {
      await t.tap(find.text('Keypad'));
    });
  });

  testWidgets('32 android keypad on a small PoC screen', (t) async {
    await _shot(t, '32-android-keypad-small', _model(), const HomeScreen(initialTab: 1), p: TargetPlatform.android, size: const Size(320, 533), act: (t) async {
      await t.tap(find.text('Keypad'));
      await t.pump(const Duration(milliseconds: 300));
      for (final k in '2320972'.split('')) {
        await t.tap(find.text(k).last);
        await t.pump();
      }
    });
  });

  testWidgets('21 android settings footer dark', (t) async {
    final m = _model()..settings.appearance = 'dark';
    await _shot(t, '21-android-settings-footer-dark', m, const HomeScreen(initialTab: 4), b: Brightness.dark, p: TargetPlatform.android, act: (t) async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    });
  });

  testWidgets('14 tab bar lens dragged', (t) async {
    TestGesture? g;
    await _shot(t, '14-tabbar-drag', _model(), const HomeScreen(initialTab: 2), act: (t) async {
      final from = t.getCenter(find.descendant(of: find.byType(GlassTabBar), matching: find.text('Contacts')));
      g = await t.startGesture(from);
      for (var i = 1; i <= 6; i++) {
        await g!.moveTo(from + Offset(i * 9.0, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
    });
    await g?.up();
  });

  testWidgets('15 android radio dark, transmitting', (t) async {
    final m = _model()
      ..myTxCallId = 'me'
      ..myTxSince = DateTime.now().subtract(const Duration(seconds: 4));
    await _shot(t, '15-android-radio-talking-dark', m, const HomeScreen(), b: Brightness.dark, p: TargetPlatform.android);
  });

  testWidgets('16 android settings', (t) async {
    await _shot(t, '16-android-settings', _model(), const HomeScreen(initialTab: 4), p: TargetPlatform.android);
  });

  testWidgets('17 android recents', (t) async {
    await _shot(t, '17-android-recents', _model(), const HomeScreen(initialTab: 1), p: TargetPlatform.android);
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  // Settings pages, iOS and Android.
  for (final (n, name, page) in <(int, String, Widget)>[
    (33, 'radio', const RadioSettings()),
    (34, 'calls', const CallSettings()),
    (35, 'audio', const AudioSettings()),
    (36, 'display', const DisplaySettings()),
    (37, 'location', const LocationSettings()),
  ]) {
    testWidgets('$n settings $name', (t) async {
      await _shot(t, '$n-settings-$name', _model()..settings.lipEnabled = true, page);
    });
    testWidgets('$n android settings $name', (t) async {
      await _shot(t, '$n-android-settings-$name', _model()..settings.lipEnabled = true, page, p: TargetPlatform.android);
    });
  }

  testWidgets('38 android settings keys', (t) async {
    final m = _model()..settings.pocPttEnabled = true;
    await _shot(t, '38-android-settings-keys', m, const HardwareSettings(), p: TargetPlatform.android);
  });

  testWidgets('39 android settings on a small PoC screen', (t) async {
    final m = _model()..settings.pocPttEnabled = true;
    await _shot(t, '39-android-settings-small', m, const HomeScreen(initialTab: 4), p: TargetPlatform.android, size: const Size(320, 533));
  });

  testWidgets('40 android settings menu', (t) async {
    final m = _model()..settings.pocPttEnabled = true;
    await _shot(t, '40-android-settings-menu', m, const HomeScreen(initialTab: 4), p: TargetPlatform.android, act: (t) async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -330));
    });
  });

  // German.
  for (final (n, name, home, p) in <(int, String, Widget, TargetPlatform)>[
    (41, 'radio', const HomeScreen(), TargetPlatform.iOS),
    (42, 'settings', const HomeScreen(initialTab: 4), TargetPlatform.iOS),
    (43, 'audio', const AudioSettings(), TargetPlatform.iOS),
    (44, 'android-settings', const HomeScreen(initialTab: 4), TargetPlatform.android),
    (45, 'android-display', const DisplaySettings(), TargetPlatform.android),
  ]) {
    testWidgets('$n german $name', (t) async {
      L.current = 'de';
      addTearDown(() => L.current = 'en');
      final m = _model();
      m.groupActivity[91] = GroupCallState(91, 2320972, 'OE1ABC', 1, 'c1', since: DateTime.now().subtract(const Duration(seconds: 12)));
      m.focusCallId = 'c1';
      await _shot(t, '$n-de-$name', m, home, p: p);
    });
  }

  testWidgets('46 german on a small PoC screen', (t) async {
    L.current = 'de';
    addTearDown(() => L.current = 'en');
    await _shot(t, '46-de-android-small', _model(), const HomeScreen(), p: TargetPlatform.android, size: const Size(320, 533));
  });

  PrivateCallInfo talking() =>
      const PrivateCallInfo(id: 'p1', peer: 2320972, peerName: 'OE1ABC', incoming: true, state: 'connected', duplex: true, hook: true, priority: 1, floor: 'idle');
  Future<void> openPad(WidgetTester t) async {
    await t.tap(find.bySemanticsLabel('Keypad').last);
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('47 in-call keypad like a phone', (t) async {
    await _shot(t, '47-call-keypad-dark', _model()..privateCall = talking(), const HomeScreen(initialTab: 1), b: Brightness.dark, act: openPad);
  });

  testWidgets('48 in-call keypad on a small PoC screen keeps hang up on screen', (t) async {
    await _shot(t, '48-android-call-keypad-small', _model()..privateCall = talking(), const HomeScreen(initialTab: 1),
        p: TargetPlatform.android, size: const Size(320, 533), act: (t) async {
      await openPad(t);
      final hangUp = t.getRect(find.bySemanticsLabel('Hang up').last);
      final bar = t.getRect(find.byType(NavigationBar));
      expect(hangUp.bottom, lessThanOrEqualTo(bar.top));
      expect(t.getRect(find.text('#')).bottom, lessThan(hangUp.top));
    });
  });

  testWidgets('49 incoming call on a small PoC screen', (t) async {
    final m = _model()
      ..privateCall = const PrivateCallInfo(id: 'p1', peer: 2320972, peerName: 'OE1ABC', incoming: true, state: 'ringing', duplex: true, hook: true, priority: 1, floor: 'idle');
    await _shot(t, '49-android-incoming-small', m, const HomeScreen(), p: TargetPlatform.android, size: const Size(320, 533));
  });

  testWidgets('50 new message: number, contacts, groups and callsigns', (t) async {
    final m = _model();
    m.contacts.radioIdForTest = {2320856: (callsign: 'OE4SXM', firstName: 'Sebastian'), 2320997: (callsign: 'OE4SXM', firstName: 'Sebastian'), 2320415: (callsign: 'OE3KLM', firstName: 'Karl')};
    await _shot(t, '50-new-message', m, const NewMessageScreen(), act: (t) async {
      await t.enterText(find.byType(EditableText), 'oe');
      await t.pump();
    });
    await _shot(t, '51-android-new-message-small', m, const NewMessageScreen(), p: TargetPlatform.android, size: const Size(320, 533), act: (t) async {
      await t.enterText(find.byType(EditableText), '2320');
      await t.pump();
    });
  });

  testWidgets('52 messages and contacts: unread counts, call and message buttons', (t) async {
    final m = _model();
    m.messages.addAll([
      ChatMessage(peer: 2320972, outgoing: false, text: 'Bin am Kahlenberg', status: MsgStatus.received)..unread = true,
      ChatMessage(peer: 2320972, outgoing: false, text: 'Wechsle auf TG 2324', status: MsgStatus.received)..unread = true,
      ChatMessage(peer: 2320415, outgoing: false, text: '73!', status: MsgStatus.received)..unread = true,
    ]);
    await _shot(t, '52-messages-unread', m, const HomeScreen(initialTab: 3));
    await _shot(t, '53-android-messages-unread', m, const HomeScreen(initialTab: 3), p: TargetPlatform.android);
    await _shot(t, '54-android-contacts-small', m, const HomeScreen(initialTab: 2), p: TargetPlatform.android, size: const Size(320, 533));
  });
}
