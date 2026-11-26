import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/src/rust/api.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  // The Basestation mode is hidden in the app; its tests still cover the code.
  setUp(() {
    Settings.basestationModeAvailable = true;
    // The test window is small and the test platform Android: not a PoC radio here.
    Settings.isPocDevice = () => false;
  });

  test('Basestation mode is hidden: a profile saved with it logs in as a Terminal', () {
    Settings.basestationModeAvailable = false;
    final s = Settings()..active.basestation = true;
    expect(s.basestation, isFalse);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  // The audio plugin has no test implementation.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);
  test('settings persist and affiliate selected + scanned groups', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final s = Settings()
      ..issi = 2040001
      ..username = '2040001'
      ..serverUrl = 'https://brew.example.org/brew/'
      ..talkgroups = [Talkgroup(91, 'Ops'), Talkgroup(92, 'Spare', scan: false)]
      ..selectedGssi = 92
      ..appearance = 'dark';
    await s.save();
    final loaded = await Settings.load();
    expect(loaded.isConfigured, isTrue);
    expect(loaded.affiliatedGroups, [91, 92]);
    expect(loaded.talkgroups[1].scan, isFalse);
    expect(loaded.appearance, 'dark');
  });

  test('password lives in the keychain, and an old stored one moves there', () async {
    final secrets = MemorySecrets();
    Settings.secrets = secrets;
    SharedPreferences.setMockInitialValues({'settings.v1': '{"username":"2040001","issi":2040001,"password":"old"}'});
    final loaded = await Settings.load();
    expect(loaded.password, 'old');
    expect(secrets.values['brew.password.p1'], 'old');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.v1'), isNot(contains('old')));
    loaded.password = 'new';
    await loaded.save();
    expect(secrets.values['brew.password.p1'], 'new');
    expect(prefs.getString('settings.v1'), isNot(contains('new')));
  });

  test('several connection profiles, each with its own password and groups', () async {
    final secrets = MemorySecrets();
    Settings.secrets = secrets;
    SharedPreferences.setMockInitialValues({});
    final s = Settings()
      ..serverUrl = 'https://a.example.org/brew/'
      ..password = 'pa'
      ..talkgroups = [Talkgroup(91, 'Ops')];
    final b = ConnectionProfile(id: s.newProfileId(), label: 'Lab', serverUrl: 'https://b.example.org/brew/', password: 'pb', issi: 7);
    expect(b.id, 'p2');
    s.profiles.add(b);
    s.activeId = b.id;
    await s.save();
    expect(secrets.values, {'brew.password.p1': 'pa', 'brew.password.p2': 'pb'});

    final loaded = await Settings.load();
    expect(loaded.profiles.map((p) => p.displayName), ['a.example.org', 'Lab']);
    expect(loaded.activeId, 'p2');
    expect(loaded.serverUrl, 'https://b.example.org/brew/', reason: 'getters follow the active profile');
    expect(loaded.password, 'pb');
    expect(loaded.talkgroups, isEmpty);
    loaded.activeId = 'p1';
    expect(loaded.talkgroups.single.gssi, 91);

    await loaded.removeProfile(loaded.profiles.last);
    expect(loaded.profiles.length, 1);
    expect(secrets.values.keys, ['brew.password.p1'], reason: 'removing a profile deletes its password');
    await loaded.removeProfile(loaded.profiles.single);
    expect(loaded.profiles.length, 1, reason: 'the last profile stays');
  });

  test('login mode is per connection, Terminal unless set', () async {
    Settings.secrets = MemorySecrets();
    SharedPreferences.setMockInitialValues({});
    final s = Settings();
    expect(s.basestation, isFalse, reason: 'Terminal stays the default (TetraPack)');
    final own = s.active.copy(id: 'p2')..basestation = true;
    s.profiles.add(own);
    await s.save();
    final loaded = await Settings.load();
    expect(loaded.profiles.firstWhere((p) => p.id == 'p1').basestation, isFalse);
    expect(loaded.profiles.firstWhere((p) => p.id == 'p2').basestation, isTrue);
    loaded.activeId = 'p2';
    expect(loaded.basestation, isTrue);
    // A profile saved before the option existed logs in as a Terminal.
    expect(ConnectionProfile.fromJson({'id': 'old', 'serverUrl': 'x'}).basestation, isFalse);
  });

  test('groups of other networks and the home network', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final s = Settings()
      ..homeMcc = 901
      ..homeMnc = 1638
      ..talkgroups = [Talkgroup(91, 'Ops'), Talkgroup(2324, 'TP', mcc: 901, mnc: 9999), Talkgroup(9, 'Home', mcc: 901, mnc: 1638)];
    await s.save();
    final loaded = await Settings.load();
    expect((loaded.homeMcc, loaded.homeMnc), (901, 1638));
    expect(loaded.groupsOfOtherNetworks.map((t) => t.gssi), [2324], reason: '91 has no network, 9 is in the home network');
  });

  test('status for the Live Activity and the widget', () {
    final m = TerminalModel(Settings()
      ..talkgroups = [Talkgroup(91, 'Austria'), Talkgroup(9, 'Vienna')]
      ..selectedGssi = 91)
      ..link = LinkState.online;
    var s = m.liveStatus();
    expect(s['group'], 'Austria');
    expect(s['talker'], isNull);
    expect(s['online'], isTrue);
    expect(s['live'], isFalse, reason: 'not connected by the user yet');

    final since = DateTime(2026, 11, 25, 10, 0, 0);
    m.groupActivity[9] = GroupCallState(9, 2320972, 'OE1ABC', 15, 'c1', since: since);
    s = m.liveStatus();
    expect(s['group'], 'Vienna', reason: 'a scanned group that is talking wins');
    expect(s['talker'], 'OE1ABC');
    expect(s['talkerSince'], since.millisecondsSinceEpoch);
    expect(s['emergency'], isTrue);

    m.groupActivity.clear();
    m.myTxCallId = 'me';
    m.myTxSince = since;
    s = m.liveStatus();
    expect((s['talker'], s['transmitting'], s['group']), ('You', true, 'Austria'));
    expect(s['lastTalker'], 'OE1ABC', reason: 'the widget shows who spoke last');
  });

  test('group access: verdicts and managed talkgroups', () {
    var (groups, listed) = parseGroupAccess('{"groups":[{"gssi":2321,"access":"refused"},{"gssi":9,"access":"listen"},{"gssi":7,"access":"odd"}]}');
    expect(groups, {2321: GroupAccess.refused, 9: GroupAccess.listen});
    expect(listed, isNull);
    final m = TerminalModel(Settings()
      ..talkgroups = [Talkgroup(9, 'Vienna'), Talkgroup(91, 'Austria'), Talkgroup(2324, 'TP', mcc: 901, mnc: 1638)]
      ..selectedGssi = 9);
    m.groupAccess = groups;
    expect(m.mayTalkOnSelected, isFalse, reason: '9 is listen only');
    m.settings.selectedGssi = 91;
    expect(m.mayTalkOnSelected, isTrue);
    (groups, listed) = parseGroupAccess('{"groups":[],"managed":true,"listed":[9]}');
    m
      ..groupAccess = groups
      ..managedGroups = listed;
    expect(m.accessOf(m.settings.talkgroups[1]), GroupAccess.refused, reason: 'not listed');
    expect(m.accessOf(m.settings.talkgroups[2]), GroupAccess.open, reason: 'groups of another network are not checked');
    expect(parseGroupAccess('garbage').$1, isEmpty);
  });

  test('SERVICE_NETWORKS is parsed with the server first', () {
    final n = parseNetworks('{"this":{"mcc":901,"mnc":9999},"networks":[{"mcc":901,"mnc":1638,"name":"TetraPack","up":true}]}');
    expect(n.map((x) => x.name), ['This server', 'TetraPack']);
    expect(n.first.own, isTrue);
    expect(n.last.up, isTrue);
    expect(parseNetworks('garbage'), isEmpty);
  });

  test('Live Activity standby line and tap-to-talk', () async {
    final m = TerminalModel(Settings()
      ..issi = 2320001
      ..name = 'OE1XYZ'
      ..talkgroups = [Talkgroup(91, 'Austria')]
      ..selectedGssi = 91
      ..pttAutoStopSeconds = 30);
    var s = m.liveStatus();
    expect((s['ownName'], s['ownIssi']), ('OE1XYZ', 2320001));
    expect(s['canTalk'], isFalse, reason: 'offline');
    m.togglePtt();
    expect(m.latchedTxEndsAt, isNull, reason: 'no key-up while offline');

    m.link = LinkState.online;
    expect(m.liveStatus()['canTalk'], isTrue);
    m.togglePtt();
    expect(m.latchedTxEndsAt, isNotNull);
    expect(m.latchedTxEndsAt!.difference(DateTime.now()).inSeconds, inInclusiveRange(29, 30));
    expect(m.liveStatus()['txEndsAt'], m.latchedTxEndsAt!.millisecondsSinceEpoch);
    m.togglePtt(); // second tap releases
    expect(m.latchedTxEndsAt, isNull);

    m.settings.pttAutoStopSeconds = 0;
    m.togglePtt();
    expect(m.latchedTxEndsAt, isNull, reason: 'auto-stop off');
    m.handleEvent(const AppEvent.txGranted(callId: 'c9'));
    expect(m.transmitting, isTrue);
    m.togglePtt();
    m.handleEvent(const AppEvent.txEnded(callId: 'c9', preempted: false));
    expect(m.transmitting, isFalse);
  });

  test('tap-to-talk auto-stop is saved', () async {
    final s = Settings()
      ..pttAutoStopSeconds = 120
      ..pttToggle = true;
    await s.save();
    final l = await Settings.load();
    expect((l.pttAutoStopSeconds, l.pttToggle), (120, true));
  });

  test('microphone level is automatic by default; manual is saved', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final d = await Settings.load();
    expect((d.micAuto, d.micGainDb), (true, 0.0));
    d
      ..micAuto = false
      ..micGainDb = 18;
    await d.save();
    final l = await Settings.load();
    expect((l.micAuto, l.micGainDb), (false, 18.0));
  });

  test('noise suppression is off and received level on by default, both saved', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final d = await Settings.load();
    expect((d.noiseSuppression, d.rxLevel), (false, true));
    final s = Settings()
      ..noiseSuppression = true
      ..rxLevel = false
      ..txBufferMs = 600;
    await s.save();
    final l = await Settings.load();
    expect((l.noiseSuppression, l.rxLevel, l.txBufferMs), (true, false, 600));
    expect(d.txBufferMs, 240, reason: '240 ms by default');
  });

  test('receive audio: boost, target and maximum level are saved; scan mode off hears only the selected group', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final d = await Settings.load();
    expect((d.rxGainDb, d.rxTargetDb, d.rxMaxDb, d.scanMode), (0, -21, -3, true));
    final s = Settings()
      ..talkgroups = [Talkgroup(91, 'Ops'), Talkgroup(92, 'Spare'), Talkgroup(93, 'Quiet', scan: false)]
      ..selectedGssi = 93
      ..rxGainDb = 6
      ..rxTargetDb = -18
      ..rxMaxDb = -6;
    expect(s.affiliatedGroups, [91, 92, 93]);
    s.scanMode = false;
    expect(s.affiliatedGroups, [93]);
    await s.save();
    final l = await Settings.load();
    expect((l.rxGainDb, l.rxTargetDb, l.rxMaxDb, l.scanMode), (6, -18, -6, false));
    expect(l.affiliatedGroups, [93]);
  });

  test('PoC radio buttons: off by default, on-screen PTT shown, all saved', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final d = await Settings.load();
    expect((d.pocPttEnabled, d.pocPttKeyCode, d.pocPttDownAction, d.pocPttWake, d.knobNextKey, d.knobPrevKey, d.showPttButton),
        (false, 0, '', false, 0, 0, true));
    final s = Settings()
      ..pocPttEnabled = true
      ..pocPttKeyCode = 142
      ..pocPttDownAction = 'com.example.ptt.down'
      ..pocPttWake = true
      ..knobNextKey = 22
      ..knobPrevKey = 21
      ..showPttButton = false;
    await s.save();
    final l = await Settings.load();
    expect((l.pocPttEnabled, l.pocPttKeyCode, l.pocPttDownAction, l.pocPttWake, l.knobNextKey, l.knobPrevKey, l.showPttButton),
        (true, 142, 'com.example.ptt.down', true, 22, 21, false));
  });

  test('PoC device profile: Hytera P60 by default, custom starts with its keys', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final s = await Settings.load();
    expect((s.pocProfile, s.pocCustom), ('hytera-p60', false));
    s.setPocProfile(PocProfile.customId);
    expect((s.pocCustom, s.pocPttKeyCode, s.pocPttDownAction, s.knobNextKey, s.knobPrevKey), (true, 142, '', 292, 293));
    // Keys the user changed survive going to the device profile and back.
    s.knobNextKey = 22;
    s.setPocProfile(PocProfile.hyteraP60.id);
    s.setPocProfile(PocProfile.customId);
    expect((s.pocPttKeyCode, s.knobNextKey), (142, 22));
    await s.save();
    expect((await Settings.load()).pocProfile, PocProfile.customId);
  });

  test('PoC device profile: keys taught before the profiles stay custom', () async {
    Settings.secrets = MemorySecrets();
    Future<Settings> old(Map<String, dynamic> j) async {
      SharedPreferences.setMockInitialValues({'settings.v1': jsonEncode(j)});
      return Settings.load();
    }

    expect((await old({'pocPttKeyCode': 131})).pocCustom, true);
    expect((await old({'pocPttDownAction': 'com.example.ptt.down'})).pocCustom, true);
    expect((await old({'pocPttEnabled': true})).pocProfile, 'hytera-p60');
  });

  test('SOS and loudspeaker buttons: shown by default, the choice is saved', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final d = await Settings.load();
    expect((d.showSosButton, d.showSpeakerButton), (true, true));
    d
      ..showSosButton = false
      ..showSpeakerButton = false;
    await d.save();
    final l = await Settings.load();
    expect((l.showSosButton, l.showSpeakerButton), (false, false));
  });

  test('scan: the group heard is the active one, held after the call, and PTT moves there', () {
    fakeAsync((a) {
      SharedPreferences.setMockInitialValues({});
      Settings.secrets = MemorySecrets();
      final s = Settings()
        ..talkgroups = [Talkgroup(1, 'One'), Talkgroup(2, 'Two')]
        ..selectedGssi = 1
        ..scanHoldSeconds = 15;
      final m = TerminalModel(s);
      expect(m.activeGssi, 1);
      m.handleEvent(const AppEvent.groupTxStarted(gssi: 2, talker: 7, talkerName: null, priority: 1, emergency: false, callId: 'c1'));
      m.handleEvent(const AppEvent.audioFocus(callId: 'c1'));
      expect((m.activeGssi, m.selectedGssi), (2, 1), reason: 'the scanned group is shown while it is heard');
      m.handleEvent(const AppEvent.groupTxEnded(gssi: 2, callId: 'c1', cause: 0));
      m.handleEvent(const AppEvent.audioFocus(callId: null));
      a.elapse(const Duration(seconds: 14));
      expect(m.activeGssi, 2, reason: 'held after the call');
      a.elapse(const Duration(seconds: 2));
      expect(m.activeGssi, 1, reason: 'back on the selected group after the hold time');

      // PTT during the hold answers on the scanned group and selects it.
      m.handleEvent(const AppEvent.groupTxStarted(gssi: 2, talker: 7, talkerName: null, priority: 1, emergency: false, callId: 'c2'));
      m.handleEvent(const AppEvent.audioFocus(callId: 'c2'));
      m.handleEvent(const AppEvent.groupTxEnded(gssi: 2, callId: 'c2', cause: 0));
      a.elapse(const Duration(seconds: 5));
      m.pttDown();
      a.flushMicrotasks();
      expect((m.selectedGssi, m.activeGssi), (2, 2));
      a.elapse(const Duration(seconds: 30));
      expect(m.selectedGssi, 2, reason: 'the radio stays on the group it answered on');

      // Picking a group by hand wins at once over a call on a scanned group.
      s.talkgroups.add(Talkgroup(3, 'Three'));
      m.handleEvent(const AppEvent.groupTxStarted(gssi: 1, talker: 7, talkerName: null, priority: 1, emergency: false, callId: 'c9'));
      m.handleEvent(const AppEvent.audioFocus(callId: 'c9'));
      expect(m.activeGssi, 1);
      var told = 0;
      m.addListener(() => told++);
      m.selectGroup(3);
      expect((m.activeGssi, told > 0), (3, true), reason: 'shown before the server answered');
      m.handleEvent(const AppEvent.groupTxEnded(gssi: 1, callId: 'c9', cause: 0));
      a.elapse(const Duration(seconds: 1));
      expect(m.activeGssi, 3, reason: 'no hold on the call that was left');
      m.selectGroup(2);
      a.flushMicrotasks();

      // Hold time 0: back at once.
      s.scanHoldSeconds = 0;
      m.handleEvent(const AppEvent.groupTxStarted(gssi: 1, talker: 7, talkerName: null, priority: 1, emergency: false, callId: 'c3'));
      m.handleEvent(const AppEvent.audioFocus(callId: 'c3'));
      expect(m.activeGssi, 1);
      m.handleEvent(const AppEvent.groupTxEnded(gssi: 1, callId: 'c3', cause: 0));
      expect(m.activeGssi, 2);
    });
  });

  test('first start on a PoC radio: hardware PTT, no on-screen buttons, audio preset', () async {
    Settings.secrets = MemorySecrets();
    Settings.isPocDevice = () => true;
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    expect((s.pocPttEnabled, s.showPttButton, s.showSosButton, s.showSpeakerButton), (true, false, false, false));
    expect((s.rxLevel, s.rxTargetDb, s.rxMaxDb, s.noiseSuppression, s.micAuto, s.micGainDb), (true, -13.0, -8.0, true, true, 0.0));
    // Only the first start: what the user changed afterwards stays.
    s.showSosButton = true;
    await s.save();
    expect((await Settings.load()).showSosButton, true);
    // Any other device keeps the general defaults.
    Settings.isPocDevice = () => false;
    SharedPreferences.setMockInitialValues({});
    final d = await Settings.load();
    expect((d.pocPttEnabled, d.showPttButton, d.rxTargetDb, d.noiseSuppression), (false, true, -21.0, false));
  });

  test('the knob steps through the talkgroups and wraps around', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final s = Settings()
      ..talkgroups = [Talkgroup(1, 'One'), Talkgroup(2, 'Two'), Talkgroup(3, '')]
      ..selectedGssi = 1;
    final said = <String>[];
    final m = TerminalModel(s)..speak = (t) async => said.add(t);
    await m.stepTalkgroup(1);
    expect((m.selectedGssi, m.toast), (2, null), reason: 'the status card shows the group, no pop-up');
    await m.stepTalkgroup(1);
    expect(m.selectedGssi, 3);
    await m.stepTalkgroup(1);
    expect(m.selectedGssi, 1, reason: 'wraps to the first');
    await m.stepTalkgroup(-1);
    expect(m.selectedGssi, 3, reason: 'wraps to the last');
    expect(said, ['Two', '3', 'One', '3'], reason: 'each step is announced');
    s.announceGroup = false;
    await m.stepTalkgroup(1);
    expect(said.length, 4, reason: 'announcement switched off');
  });

  test('talkgroups can be moved; the knob follows the new order', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final s = Settings()
      ..talkgroups = [Talkgroup(1, 'One'), Talkgroup(2, 'Two'), Talkgroup(3, 'Three')]
      ..selectedGssi = 1;
    final m = TerminalModel(s)..speak = (_) async {};
    await m.moveTalkgroup(2, 0);
    expect(s.talkgroups.map((t) => t.gssi), [3, 1, 2]);
    expect(m.selectedGssi, 1, reason: 'the selection stays');
    await m.stepTalkgroup(-1);
    expect(m.selectedGssi, 3);
    expect((await Settings.load()).talkgroups.map((t) => t.gssi), [3, 1, 2], reason: 'saved');
  });

  test('DGNA adds and removes only its own groups, and survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = MemorySecrets();
    Settings.secrets = secrets;
    final m = TerminalModel(Settings()
      ..issi = 2320997
      ..talkgroups = [Talkgroup(91, 'Austria'), Talkgroup(92, 'Mine', scan: false)]
      ..selectedGssi = 91);
    await m.applyDgna(2329, 'Event', 1, attach: true);
    final event = m.settings.talkgroups.firstWhere((t) => t.gssi == 2329);
    expect((event.name, event.dgna, event.dgnaMode), ('Event', true, 1));
    expect(m.settings.affiliatedGroups, containsAll([91, 2329]), reason: 'a DGNA group is affiliated');

    await m.applyDgna(92, 'Other', 0, attach: true);
    final mine = m.settings.talkgroups.firstWhere((t) => t.gssi == 92);
    expect((mine.name, mine.dgna, mine.scan), ('Mine', false, true), reason: 'the user\'s own group stays theirs, now scanned');
    await m.applyDgna(92, null, 0, attach: false);
    expect(m.settings.talkgroups.any((t) => t.gssi == 92), isTrue, reason: 'not taken by a deassign');

    final p = m.settings.active
      ..basestation = true
      ..controlUrl = 'ctl.example.org:9443'
      ..controlTls = true
      ..controlUsername = 'app1'
      ..controlPassword = 'secret';
    await m.settings.save();
    expect(secrets.values[p.controlSecretKey], 'secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.v1'), isNot(contains('secret')));
    final l = await Settings.load();
    final lp = l.active;
    expect((lp.controlUrl, lp.controlTls, lp.controlUsername, lp.controlPassword), ('ctl.example.org:9443', true, 'app1', 'secret'));
    expect(l.talkgroups.firstWhere((t) => t.gssi == 2329).dgna, isTrue);

    await m.applyDgna(2329, null, 0, attach: false);
    expect(m.settings.talkgroups.any((t) => t.gssi == 2329), isFalse);
    expect(m.settings.affiliatedGroups, isNot(contains(2329)));
  });
}
