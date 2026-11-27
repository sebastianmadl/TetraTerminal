import 'package:flutter/widgets.dart';

import 'l10n_de.dart';

/// The app's languages. English is the source: the texts in the code are the
/// English ones and double as the keys of the German table (l10n_de.dart).
class L {
  static const choices = {'system': 'Automatic', 'en': 'English', 'de': 'Deutsch'};

  /// 'en' or 'de': the language in use.
  static String current = 'en';

  /// Language for the setting [choice] ('system', 'en', 'de').
  static String resolve(String choice) {
    if (choice == 'en' || choice == 'de') return choice;
    return WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'de' ? 'de' : 'en';
  }

  /// Switches the language and redraws every screen that is open, constant
  /// widgets included. Navigation, scroll positions and text entered stay.
  static void use(String choice) {
    final next = resolve(choice);
    if (next == current) return;
    current = next;
    final root = WidgetsBinding.instance.rootElement;
    if (root != null) WidgetsBinding.instance.buildOwner?.reassemble(root);
  }
}

/// [text] in the current language. Texts without a translation (names,
/// numbers, callsigns) come back unchanged. `{0}`, `{1}` … are filled from [args].
String tr(String text, [List<Object?> args = const []]) {
  var out = L.current == 'de' ? (german[text] ?? text) : text;
  for (var i = 0; i < args.length; i++) {
    out = out.replaceAll('{$i}', '${args[i]}');
  }
  return out;
}

/// A [Text] that shows its text in the current language; can be `const`.
class Tx extends StatelessWidget {
  const Tx(this.text, {super.key, this.style, this.textAlign, this.maxLines, this.overflow});
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) => Text(tr(text), style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow);
}
