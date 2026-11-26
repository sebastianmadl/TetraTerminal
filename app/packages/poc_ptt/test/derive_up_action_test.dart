import 'package:flutter_test/flutter_test.dart';
import 'package:poc_ptt/poc_ptt.dart';

void main() {
  test('release action is derived from the press action, keeping the case', () {
    expect(deriveUpAction('com.example.ptt.down'), 'com.example.ptt.up');
    expect(deriveUpAction('android.intent.action.PTT_DOWN'), 'android.intent.action.PTT_UP');
    expect(deriveUpAction(' com.vendor.PttDown '), 'com.vendor.PttUp');
    // Only the last "down" is the key state.
    expect(deriveUpAction('com.download.ptt.down'), 'com.download.ptt.up');
    expect(deriveUpAction('com.example.ptt.pressed'), isNull);
    expect(deriveUpAction(''), isNull);
  });
}
