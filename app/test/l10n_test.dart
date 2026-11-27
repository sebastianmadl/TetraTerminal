import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/screens/settings_screen.dart';
import 'package:tetra_terminal/ui/l10n.dart';
import 'package:tetra_terminal/ui/l10n_de.dart';
import 'package:tetra_terminal/ui/theme.dart';

void main() {
  tearDown(() => L.current = 'en');

  test('English is the source, German comes from the table, unknown texts pass through', () {
    expect(tr('Settings'), 'Settings');
    L.current = 'de';
    expect(tr('Settings'), 'Einstellungen');
    expect(tr('OE1ABC'), 'OE1ABC');
    expect(tr('Every {0} s to {1}', [60, 2320901]), 'Alle 60 s an 2320901');
  });

  test('every German text keeps the placeholders of its English one', () {
    final slot = RegExp(r'\{\d\}');
    for (final e in german.entries) {
      final want = slot.allMatches(e.key).map((m) => m[0]).toSet();
      final got = slot.allMatches(e.value).map((m) => m[0]).toSet();
      expect(got, want, reason: e.key);
      expect(e.value.trim(), isNotEmpty, reason: e.key);
    }
  });

  test('the language setting: fixed choices win, otherwise the device language', () {
    expect(L.resolve('de'), 'de');
    expect(L.resolve('en'), 'en');
    expect(L.resolve('system'), anyOf('en', 'de'));
  });

  testWidgets('switching the language redraws the open page at once, constant texts included', (t) async {
    Settings.isPocDevice = () => false;
    final m = TerminalModel(Settings());
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: m,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const DisplaySettings()),
    ));
    expect(find.text('Loudspeaker button'), findsOneWidget);
    expect(find.text('Display'), findsOneWidget);

    await t.tap(find.text('Deutsch'));
    await t.pump();
    expect(m.settings.language, 'de');
    expect(find.text('Lautsprecher-Knopf'), findsOneWidget);
    expect(find.text('Anzeige'), findsOneWidget);
    expect(find.text('Loudspeaker button'), findsNothing);

    await t.tap(find.text('English'));
    await t.pump();
    expect(find.text('Loudspeaker button'), findsOneWidget);
  });
}
