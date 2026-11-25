import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'tx_level.dart';

/// Writes diagnostic transmission captures as WAV files where the user can
/// get at them: iOS "Files › On My iPhone › TETRA Terminal" (the app's
/// Documents folder, shared through UIFileSharingEnabled), Android the app's
/// external files folder. Keeps the newest [keep] transmissions.
class TxCaptureStore {
  static const keep = 10;

  static Future<Directory> _dir() async {
    final base = Platform.isAndroid ? (await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory()) : await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/tx-captures');
    await d.create(recursive: true);
    return d;
  }

  /// File name stem for a transmission that ended at [t], sortable.
  static String stem(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'tx-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static Future<void> save(TxCapture c, {int micRate = 16000, int encoderRate = 8000}) async {
    try {
      final d = await _dir();
      final s = stem(DateTime.now());
      await File('${d.path}/$s-mic-16k.wav').writeAsBytes(wavBytes(c.raw, micRate));
      await File('${d.path}/$s-encoder-8k.wav').writeAsBytes(wavBytes(c.encoderInput, encoderRate));
      final files = d.listSync().whereType<File>().toList()..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(keep * 2)) {
        await f.delete();
      }
    } catch (_) {
      // Diagnostics only: never disturb a call.
    }
  }
}
