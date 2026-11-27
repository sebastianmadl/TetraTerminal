import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../services/version.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A contact the user saved: ISSI and name. A favourite is listed on top of
/// the Contacts tab and may carry a speed dial code for the keypad.
class Contact {
  Contact(this.issi, this.name, {this.note = '', this.favorite = false, this.speedDial = ''});
  final int issi;
  String name;
  String note;
  bool favorite;

  /// `*` or `#` and up to four digits, e.g. `*1`; empty for none.
  String speedDial;

  Map<String, dynamic> toJson() => {
        'issi': issi,
        'name': name,
        if (note.isNotEmpty) 'note': note,
        if (favorite) 'fav': true,
        if (speedDial.isNotEmpty) 'sd': speedDial,
      };
  static Contact fromJson(Map<String, dynamic> j) => Contact(j['issi'] as int, j['name'] as String? ?? '',
      note: j['note'] as String? ?? '', favorite: j['fav'] as bool? ?? false, speedDial: j['sd'] as String? ?? '');
}

/// A speed dial code as it is stored: `*` or `#` followed by one to four
/// digits. Digits alone get a `*`. Empty text gives '', anything else null.
String? normalizeSpeedDial(String text) {
  final t = text.replaceAll(' ', '');
  if (t.isEmpty) return '';
  final m = RegExp(r'^([*#]?)([0-9]{1,4})$').firstMatch(t);
  if (m == null) return null;
  return '${m[1]!.isEmpty ? '*' : m[1]}${m[2]}';
}

/// True for text typed on the keypad that is a speed dial, not an ISSI.
bool isSpeedDial(String text) => text.startsWith('*') || text.startsWith('#');

/// One entry of the RadioID.net database: callsign and first name.
typedef RadioIdEntry = ({String callsign, String firstName});

/// Own contacts plus the RadioID.net database (DMR IDs, which ham TETRA
/// networks use as ISSIs). Own contacts win over the database.
class ContactBook extends ChangeNotifier {
  static const _key = 'contacts.v1';
  static const _dbFile = 'radioid.tsv';
  static const radioIdUrl = 'https://radioid.net/static/user.csv';
  static const maxAge = Duration(days: 7);

  final List<Contact> contacts = [];
  Map<int, RadioIdEntry> _radioId = const {};
  DateTime? radioIdUpdated;
  bool radioIdAuto = true;
  bool updating = false;
  String? radioIdError;

  int get radioIdCount => _radioId.length;

  /// Own contact, else the RadioID callsign. Null when unknown.
  String? nameOf(int issi) => contactOf(issi)?.name ?? _radioId[issi]?.callsign;
  Contact? contactOf(int issi) => contacts.where((c) => c.issi == issi).firstOrNull;
  RadioIdEntry? radioIdOf(int issi) => _radioId[issi];

  /// Favourites, those with a speed dial first, in the order of their codes.
  List<Contact> get favorites => contacts.where((c) => c.favorite).toList()
    ..sort((a, b) {
      if (a.speedDial.isEmpty != b.speedDial.isEmpty) return a.speedDial.isEmpty ? 1 : -1;
      final c = a.speedDial.length.compareTo(b.speedDial.length);
      if (c != 0) return c;
      final d = a.speedDial.compareTo(b.speedDial);
      return d != 0 ? d : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  /// The favourite behind a speed dial code typed on the keypad.
  Contact? bySpeedDial(String code) => code.isEmpty ? null : contacts.where((c) => c.favorite && c.speedDial == code).firstOrNull;

  /// RadioID entries for a search text: callsigns that start with it (every
  /// ID of a callsign is its own row), or IDs that start with it when it is a
  /// number. Exact callsigns first, at most [limit] rows.
  List<({int issi, RadioIdEntry entry})> searchRadioId(String query, {int limit = 40}) {
    final q = query.trim().toUpperCase();
    if (q.length < 2) return const [];
    final digits = RegExp(r'^[0-9]+$').hasMatch(q);
    final exact = <({int issi, RadioIdEntry entry})>[], rest = <({int issi, RadioIdEntry entry})>[];
    for (final e in _radioId.entries) {
      final call = e.value.callsign.toUpperCase();
      if (digits ? '${e.key}'.startsWith(q) : call.startsWith(q)) {
        ((digits ? '${e.key}' == q : call == q) ? exact : rest).add((issi: e.key, entry: e.value));
        if (rest.length >= limit * 4) break;
      }
    }
    int order(({int issi, RadioIdEntry entry}) a, ({int issi, RadioIdEntry entry}) b) {
      final c = a.entry.callsign.compareTo(b.entry.callsign);
      return c != 0 ? c : a.issi.compareTo(b.issi);
    }

    exact.sort(order);
    rest.sort(order);
    return [...exact, ...rest].take(limit).toList();
  }

  /// The name to show for a talker: own contact, then the name the radio
  /// sent (talking party identity), then RadioID, then the ISSI.
  String display(int issi, {String? sentName}) {
    final own = contactOf(issi)?.name;
    if (own != null && own.isNotEmpty) return own;
    // A name with control characters is a mis-decoded one: fall back to RadioID.
    if (sentName != null && sentName.trim().isNotEmpty && !sentName.contains(RegExp(r'[\x00-\x1f\x7f]'))) return sentName;
    return _radioId[issi]?.callsign ?? 'ISSI $issi';
  }

  // ───────── own contacts ─────────

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        contacts
          ..clear()
          ..addAll((j['contacts'] as List? ?? []).map((e) => Contact.fromJson(e as Map<String, dynamic>)));
        radioIdAuto = j['radioIdAuto'] as bool? ?? true;
        final t = j['radioIdUpdated'] as int?;
        radioIdUpdated = t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode({
      'contacts': contacts.map((c) => c.toJson()).toList(),
      'radioIdAuto': radioIdAuto,
      'radioIdUpdated': radioIdUpdated?.millisecondsSinceEpoch,
    }));
  }

  /// Adds or replaces a contact. A speed dial code belongs to one contact:
  /// it is taken from whoever had it, and makes its contact a favourite.
  Future<void> put(Contact c) async {
    if (c.speedDial.isNotEmpty) {
      c.favorite = true;
      for (final x in contacts) {
        if (x.issi != c.issi && x.speedDial == c.speedDial) x.speedDial = '';
      }
    }
    contacts
      ..removeWhere((x) => x.issi == c.issi)
      ..add(c)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
    await save();
  }

  /// Marks or unmarks a favourite. Unmarking drops its speed dial.
  Future<void> setFavorite(Contact c, bool on) async {
    c.favorite = on;
    if (!on) c.speedDial = '';
    notifyListeners();
    await save();
  }

  Future<void> remove(Contact c) async {
    contacts.removeWhere((x) => x.issi == c.issi);
    notifyListeners();
    await save();
  }

  Future<void> setRadioIdAuto(bool on) async {
    radioIdAuto = on;
    notifyListeners();
    await save();
  }

  // ───────── RadioID.net ─────────

  Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/$_dbFile');

  /// Loads the stored database, then refreshes it in the background when it
  /// is missing or older than [maxAge] (and auto update is on).
  Future<void> startRadioId() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        _radioId = await Isolate.run(() => parseRadioIdTsv(f.readAsStringSync()));
        notifyListeners();
      }
    } catch (e) {
      debugPrint('radioid load: $e');
    }
    final stale = radioIdUpdated == null || DateTime.now().difference(radioIdUpdated!) > maxAge || _radioId.isEmpty;
    if (radioIdAuto && stale) unawaited(updateRadioId());
  }

  /// Downloads the whole database now.
  Future<void> updateRadioId() async {
    if (updating) return;
    updating = true;
    radioIdError = null;
    notifyListeners();
    try {
      final f = await _file();
      final path = f.path;
      final db = await Isolate.run(() => _download(radioIdUrl, path));
      if (db.isEmpty) throw const FormatException('no entries');
      _radioId = db;
      radioIdUpdated = DateTime.now();
      await save();
    } catch (e) {
      radioIdError = 'Update failed: $e';
    } finally {
      updating = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  set radioIdForTest(Map<int, RadioIdEntry> db) => _radioId = db;
}

/// Downloads the RadioID CSV, keeps ID, callsign and first name, writes them
/// to [path] as TSV and returns them. Runs in an isolate.
Future<Map<int, RadioIdEntry>> _download(String url, String path) async {
  final client = HttpClient()..userAgent = userAgent;
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final csv = await res.transform(utf8.decoder).join();
    final db = parseRadioIdCsv(csv);
    final out = StringBuffer();
    db.forEach((id, e) => out.writeln('$id\t${e.callsign}\t${e.firstName}'));
    await File(path).writeAsString(out.toString(), flush: true);
    return db;
  } finally {
    client.close(force: true);
  }
}

/// RadioID's `user.csv`: a header row naming the columns (RADIO_ID,
/// CALLSIGN, FIRST_NAME, ...), then one user per line.
Map<int, RadioIdEntry> parseRadioIdCsv(String csv) {
  final lines = const LineSplitter().convert(csv);
  if (lines.isEmpty) return {};
  final head = splitCsvLine(lines.first).map((h) => h.trim().toUpperCase()).toList();
  final iId = head.indexOf('RADIO_ID'), iCall = head.indexOf('CALLSIGN'), iFirst = head.indexOf('FIRST_NAME');
  if (iId < 0 || iCall < 0) return {};
  final db = <int, RadioIdEntry>{};
  for (final line in lines.skip(1)) {
    final f = splitCsvLine(line);
    if (f.length <= iCall || f.length <= iId) continue;
    final id = int.tryParse(f[iId].trim());
    final call = f[iCall].trim();
    if (id == null || id <= 0 || id > 0xFFFFFF || call.isEmpty) continue;
    db[id] = (callsign: call, firstName: iFirst >= 0 && iFirst < f.length ? f[iFirst].trim() : '');
  }
  return db;
}

Map<int, RadioIdEntry> parseRadioIdTsv(String tsv) {
  final db = <int, RadioIdEntry>{};
  for (final line in const LineSplitter().convert(tsv)) {
    final f = line.split('\t');
    final id = int.tryParse(f.first);
    if (id == null || f.length < 2) continue;
    db[id] = (callsign: f[1], firstName: f.length > 2 ? f[2] : '');
  }
  return db;
}

/// One CSV line; fields may be quoted ("a, b" and "" for a quote).
List<String> splitCsvLine(String line) {
  final out = <String>[];
  final cur = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cur.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      out.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  out.add(cur.toString());
  return out;
}

// ───────── call log ─────────

enum CallKind { groupHeard, groupTalked, privateIn, privateOut, privateMissed }

class CallLogEntry {
  CallLogEntry({required this.time, required this.issi, required this.kind, this.gssi, this.groupName, this.sentName, this.duration = Duration.zero, this.emergency = false});
  final DateTime time;
  final int issi;
  CallKind kind;
  final int? gssi;
  final String? groupName;
  /// The name the radio sent with the call, if any.
  final String? sentName;
  Duration duration;
  final bool emergency;

  Map<String, dynamic> toJson() => {
        't': time.millisecondsSinceEpoch,
        'issi': issi,
        'k': kind.name,
        if (gssi != null) 'g': gssi,
        if (groupName != null) 'gn': groupName,
        if (sentName != null) 'n': sentName,
        'd': duration.inMilliseconds,
        if (emergency) 'e': true,
      };

  static CallLogEntry fromJson(Map<String, dynamic> j) => CallLogEntry(
        time: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        issi: j['issi'] as int,
        kind: CallKind.values.firstWhere((k) => k.name == j['k'], orElse: () => CallKind.groupHeard),
        gssi: j['g'] as int?,
        groupName: j['gn'] as String?,
        sentName: j['n'] as String?,
        duration: Duration(milliseconds: j['d'] as int? ?? 0),
        emergency: j['e'] as bool? ?? false,
      );
}

/// Recent calls, newest first, kept across restarts.
class CallLog {
  static const _key = 'calllog.v1';
  static const max = 300;
  final List<CallLogEntry> entries = [];

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      entries
        ..clear()
        ..addAll((jsonDecode(raw) as List).map((e) => CallLogEntry.fromJson(e as Map<String, dynamic>)));
    } catch (_) {}
  }

  Timer? _saveTimer;
  void add(CallLogEntry e) {
    entries.insert(0, e);
    if (entries.length > max) entries.removeRange(max, entries.length);
    _scheduleSave();
  }

  void changed() => _scheduleSave();

  Future<void> clear() async {
    entries.clear();
    await _save();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }
}
