import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/contacts.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/src/rust/api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);

  test('RadioID CSV: columns by header, quoted fields, bad rows skipped', () {
    const csv = 'RADIO_ID,CALLSIGN,FIRST_NAME,LAST_NAME,CITY,STATE,COUNTRY\n'
        '2320972,OE1ABC,Anna,Muster,Wien,,Austria\n'
        '2629001,DL2XY,"Max, Jr.",X,Berlin,,Germany\n'
        'x,BAD,,,,,\n'
        '99999999,TOOBIG,,,,,\n'
        '2320973,,NoCall,,,,\n';
    final db = parseRadioIdCsv(csv);
    expect(db.keys, [2320972, 2629001]);
    expect(db[2629001], (callsign: 'DL2XY', firstName: 'Max, Jr.'));
    expect(parseRadioIdCsv('FOO,BAR\n1,2'), isEmpty, reason: 'unknown header');
    final tsv = db.entries.map((e) => '${e.key}\t${e.value.callsign}\t${e.value.firstName}').join('\n');
    expect(parseRadioIdTsv(tsv), db);
  });

  test('own contacts win over the radio\'s name and RadioID', () {
    final book = ContactBook()..radioIdForTest = {2320972: (callsign: 'OE1ABC', firstName: 'Anna')};
    expect(book.display(2320972), 'OE1ABC');
    expect(book.display(2320972, sentName: 'Mobile 1'), 'Mobile 1');
    book.contacts.add(Contact(2320972, 'Anna Kahlenberg'));
    expect(book.display(2320972, sentName: 'Mobile 1'), 'Anna Kahlenberg');
    expect(book.display(5), 'ISSI 5');
  });

  test('call log: group calls heard with group and duration, missed private calls', () async {
    SharedPreferences.setMockInitialValues({});
    final m = TerminalModel(Settings()..talkgroups = [Talkgroup(91, 'Austria')]);
    m.handleEvent(const AppEvent.groupTxStarted(gssi: 91, talker: 2320972, talkerName: 'OE1ABC', priority: 1, emergency: false, callId: 'c1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    m.handleEvent(const AppEvent.groupTxEnded(gssi: 91, callId: 'c1', cause: 0));
    final e = m.callLog.entries.single;
    expect((e.kind, e.issi, e.groupName, e.sentName), (CallKind.groupHeard, 2320972, 'Austria', 'OE1ABC'));
    expect(e.duration.inMilliseconds, greaterThanOrEqualTo(20));

    const ring = PrivateCallInfo(id: 'p1', peer: 2629001, incoming: true, state: 'ringing', duplex: true, hook: true, priority: 1, floor: 'idle');
    m.handleEvent(const AppEvent.privateCall(call: ring));
    m.handleEvent(const AppEvent.privateCallEnded(callId: 'p1', peer: 2629001, cause: 0));
    expect(m.callLog.entries.first.kind, CallKind.privateMissed);

    final back = CallLogEntry.fromJson(e.toJson());
    expect((back.kind, back.issi, back.gssi, back.duration.inMilliseconds), (e.kind, e.issi, e.gssi, e.duration.inMilliseconds));
  });

  test('a garbled sent name falls back to RadioID', () {
    final b = ContactBook()..radioIdForTest = {2321109: (callsign: 'OE1GKS', firstName: 'G')};
    expect(b.display(2321109, sentName: 'O\nE94i'), 'OE1GKS');
    expect(b.display(2321109, sentName: 'OE1GKS-M'), 'OE1GKS-M');
  });

  test('RadioID search: callsign prefix, every ID of a callsign, exact match first, IDs by number', () {
    final b = ContactBook()
      ..radioIdForTest = {
        2320856: (callsign: 'OE4SXM', firstName: 'Sebastian'),
        2320997: (callsign: 'OE4SXM', firstName: 'Sebastian'),
        2320111: (callsign: 'OE4SX', firstName: 'Max'),
        2629001: (callsign: 'DL2XY', firstName: 'Max'),
      };
    expect(b.searchRadioId('oe4sx').map((r) => r.issi), [2320111, 2320856, 2320997]);
    expect(b.searchRadioId('OE4SXM').map((r) => r.issi), [2320856, 2320997]);
    expect(b.searchRadioId('23208').map((r) => r.issi), [2320856]);
    expect(b.searchRadioId('o'), isEmpty);
    expect(b.searchRadioId('zz'), isEmpty);
  });

  test('speed dial codes: * or # with digits, digits alone get a *, anything else is refused', () {
    expect(normalizeSpeedDial('*1'), '*1');
    expect(normalizeSpeedDial('#12'), '#12');
    expect(normalizeSpeedDial(' 7 '), '*7');
    expect(normalizeSpeedDial(''), '');
    expect(normalizeSpeedDial('*'), isNull);
    expect(normalizeSpeedDial('*12345'), isNull);
    expect(normalizeSpeedDial('a1'), isNull);
    expect(isSpeedDial('*1'), isTrue);
    expect(isSpeedDial('#1'), isTrue);
    expect(isSpeedDial('2320997'), isFalse);
  });

  test('favourites: a speed dial makes a favourite, belongs to one contact, and is found from the keypad', () async {
    SharedPreferences.setMockInitialValues({});
    final b = ContactBook();
    await b.put(Contact(2320997, 'OE4SXM', speedDial: '*1'));
    await b.put(Contact(2320415, 'OE3KLM', favorite: true));
    await b.put(Contact(2320500, 'Dispatch'));
    expect(b.favorites.map((c) => c.issi), [2320997, 2320415]);
    expect(b.bySpeedDial('*1')?.issi, 2320997);
    expect(b.bySpeedDial('#1'), isNull);
    expect(b.bySpeedDial(''), isNull);

    // The code moves to the contact it is given to.
    await b.put(Contact(2320500, 'Dispatch', speedDial: '*1'));
    expect(b.bySpeedDial('*1')?.issi, 2320500);
    expect(b.contactOf(2320997)!.speedDial, '');
    expect(b.contactOf(2320997)!.favorite, isTrue);

    // Kept across a restart; unmarking drops the code.
    final again = ContactBook();
    await again.load();
    expect(again.bySpeedDial('*1')?.issi, 2320500);
    expect(again.favorites.length, 3);
    await again.setFavorite(again.contactOf(2320500)!, false);
    expect(again.bySpeedDial('*1'), isNull);

    // Contacts saved before favourites existed load as plain contacts.
    final old = Contact.fromJson({'issi': 1, 'name': 'x'});
    expect((old.favorite, old.speedDial), (false, ''));
  });
}
