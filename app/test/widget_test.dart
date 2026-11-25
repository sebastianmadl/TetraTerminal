import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';

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

  test('SERVICE_NETWORKS is parsed with the server first', () {
    final n = parseNetworks('{"this":{"mcc":901,"mnc":9999},"networks":[{"mcc":901,"mnc":1638,"name":"TetraPack","up":true}]}');
    expect(n.map((x) => x.name), ['This server', 'TetraPack']);
    expect(n.first.own, isTrue);
    expect(n.last.up, isTrue);
    expect(parseNetworks('garbage'), isEmpty);
  });
}
