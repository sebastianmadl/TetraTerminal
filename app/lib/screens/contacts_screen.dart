import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/contacts.dart';
import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/l10n.dart';
import '../ui/theme.dart';
import 'home_screen.dart';
import 'messages_screen.dart';
import 'talkgroups_screen.dart';

/// Own contacts (ISSI and name) and, behind the switch on top, the talkgroups.
/// The RadioID.net database is not listed here; it only fills in names
/// elsewhere (Settings shows how many are loaded).
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.onCall});
  /// Opens the keypad with this ISSI.
  final void Function(int issi)? onCall;
  @override
  State<ContactsScreen> createState() => ContactsScreenState();
}

class ContactsScreenState extends State<ContactsScreen> {
  String _query = '';
  bool _groups = false;

  /// Shows the talkgroup list (from the radio screen's "Edit groups").
  void showGroups() => setState(() => _groups = true);

  void _message(int issi, String title) =>
      Navigator.push(context, CupertinoPageRoute(builder: (_) => ConversationScreen(peer: issi, title: title)));

  /// Message and call buttons at the end of every row.
  Widget _buttons(int issi, String title) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tr('Message'),
        icon: Icon(pick(context, Icons.chat_bubble_outline, CupertinoIcons.chat_bubble), color: scheme.primary),
        onPressed: () => _message(issi, title),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tr('Call'),
        icon: Icon(pick(context, Icons.call_outlined, CupertinoIcons.phone), color: Tokens.online),
        onPressed: () => widget.onCall?.call(issi),
      ),
    ]);
  }

  Widget _contactTile(TerminalModel m, Contact c, {bool favorite = false}) => Tile(
        key: ValueKey('${favorite ? 'f' : 'c'}${c.issi}'),
        leading: favorite && c.speedDial.isNotEmpty ? _SpeedDialBadge(c.speedDial) : Avatar(c.name, size: 36),
        title: c.name,
        subtitle: [
          'ISSI ${c.issi}',
          if (m.contacts.radioIdOf(c.issi) case final r? when r.callsign != c.name) r.callsign,
          if (c.note.isNotEmpty) c.note,
        ].join(' · '),
        trailing: _buttons(c.issi, c.name),
        onTap: () => _actions(context, m, c),
      );

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final number = int.tryParse(q);
    final all = m.contacts.contacts;
    final list = all.where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || '${c.issi}'.contains(q) || c.speedDial == q).toList();
    final favorites = q.isEmpty ? m.contacts.favorites : const <Contact>[];
    final own = {for (final c in all) c.issi};
    // While searching, the callsign database is searched too; every ID of a
    // callsign is its own row.
    final db = q.isEmpty ? const <({int issi, RadioIdEntry entry})>[] : m.contacts.searchRadioId(q).where((r) => !own.contains(r.issi)).toList();
    final direct = number != null && number > 0 && number <= 0xFFFFFF && !own.contains(number);

    Widget icon(IconData i) => CircleAvatar(radius: 18, backgroundColor: scheme.surfaceContainerHigh, child: Icon(i, size: 18, color: scheme.onSurfaceVariant));

    return TabPage(
      title: 'Contacts',
      actions: [
        IconButton(
          tooltip: tr(_groups ? 'Add talkgroup' : 'Add contact'),
          icon: Icon(pick(context, _groups ? Icons.group_add_outlined : Icons.person_add_alt, CupertinoIcons.add)),
          onPressed: () => _groups ? editTalkgroup(context, m, null) : editContact(context, m, null),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Tokens.gutter, 4, Tokens.gutter, 8),
            child: SizedBox(width: double.infinity, child: Segments<bool>(items: const {false: 'Contacts', true: 'Groups'}, value: _groups, onChanged: (v) => setState(() => _groups = v))),
          ),
        ),
        if (_groups)
          const SliverToBoxAdapter(child: TalkgroupList())
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Tokens.gutter, 4, Tokens.gutter, 4),
              child: isApple(context)
                  ? CupertinoSearchTextField(placeholder: tr('Number, name or callsign'), onChanged: (v) => setState(() => _query = v))
                  : TextField(decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Number, name or callsign')), onChanged: (v) => setState(() => _query = v)),
            ),
          ),
          if (direct)
            SliverToBoxAdapter(
              child: Section(children: [
                Tile(
                  key: const ValueKey('direct'),
                  leading: icon(CupertinoIcons.number),
                  title: 'ISSI $number',
                  subtitle: m.contacts.radioIdOf(number)?.callsign ?? tr('Not in your contacts'),
                  trailing: _buttons(number, m.nameOf(number)),
                  onTap: () => _unknownActions(context, m, number, m.nameOf(number)),
                ),
              ]),
            ),
          if (favorites.isNotEmpty)
            SliverToBoxAdapter(child: Section(header: 'Favourites', children: [for (final c in favorites) _contactTile(m, c, favorite: true)])),
          if (all.isEmpty && q.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(children: [
                  Icon(CupertinoIcons.person_crop_circle, size: 48, color: scheme.outline),
                  const SizedBox(height: 12),
                  Tx('No contacts yet', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Tx('Save ISSIs with a name. Your names are shown instead of the ones from RadioID.net.',
                      textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () => editContact(context, m, null), child: const Tx('Add contact')),
                ]),
              ),
            )
          else if (list.isNotEmpty)
            SliverToBoxAdapter(child: Section(header: favorites.isNotEmpty || q.isNotEmpty ? 'Contacts' : null, children: [for (final c in list) _contactTile(m, c)])),
          if (db.isNotEmpty)
            SliverToBoxAdapter(
              child: Section(header: 'RadioID.net', children: [
                for (final r in db)
                  Tile(
                    key: ValueKey('r${r.issi}'),
                    leading: icon(CupertinoIcons.antenna_radiowaves_left_right),
                    title: [r.entry.callsign, if (r.entry.firstName.isNotEmpty) r.entry.firstName].join(' · '),
                    subtitle: 'ISSI ${r.issi}',
                    trailing: _buttons(r.issi, r.entry.callsign),
                    onTap: () => _unknownActions(context, m, r.issi, r.entry.callsign),
                  ),
              ]),
            ),
          if (q.isNotEmpty && !direct && list.isEmpty && db.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Tx('Nothing found. Type the number (ISSI) to call it or write to it directly.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            ),
        ],
      ],
    );
  }

  Future<void> _actions(BuildContext context, TerminalModel m, Contact c) async {
    final a = await showActions<String>(context, title: c.name, message: ['ISSI ${c.issi}', if (c.speedDial.isNotEmpty) c.speedDial].join(' · '), actions: [
      const SheetAction('Call', 'call'),
      const SheetAction('Message', 'message'),
      SheetAction(c.favorite ? 'Remove from favourites' : 'Add to favourites', 'favorite'),
      const SheetAction('Edit', 'edit'),
      const SheetAction('Delete', 'delete', destructive: true),
    ]);
    if (!context.mounted) return;
    switch (a) {
      case 'call':
        widget.onCall?.call(c.issi);
      case 'message':
        _message(c.issi, c.name);
      case 'favorite':
        await m.contacts.setFavorite(c, !c.favorite);
      case 'edit':
        await editContact(context, m, c);
      case 'delete':
        await m.contacts.remove(c);
    }
  }

  /// A number or a RadioID entry that is not a contact yet.
  Future<void> _unknownActions(BuildContext context, TerminalModel m, int issi, String name) async {
    final a = await showActions<String>(context, title: name, message: 'ISSI $issi', actions: const [
      SheetAction('Call', 'call'),
      SheetAction('Message', 'message'),
      SheetAction('Add contact', 'add'),
    ]);
    if (!context.mounted) return;
    switch (a) {
      case 'call':
        widget.onCall?.call(issi);
      case 'message':
        _message(issi, name);
      case 'add':
        await editContact(context, m, null, issi: issi);
    }
  }
}

/// The speed dial code of a favourite, in place of the initials.
class _SpeedDialBadge extends StatelessWidget {
  const _SpeedDialBadge(this.code);
  final String code;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary.withValues(alpha: .16)),
      child: FittedBox(
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Text(code, style: TextStyle(color: scheme.primary, fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// Add or edit a contact. An empty name takes the RadioID callsign. A speed
/// dial code (`*1`, `#12`) makes the contact a favourite; the keypad calls it
/// when the code is dialled.
Future<void> editContact(BuildContext context, TerminalModel m, Contact? existing, {int? issi}) async {
  var number = existing?.issi.toString() ?? (issi?.toString() ?? '');
  var name = existing?.name ?? '';
  var note = existing?.note ?? '';
  var speed = existing?.speedDial ?? '';
  final hint = issi != null ? m.contacts.radioIdOf(issi) : null;
  final ok = await showFormSheet(context, title: existing == null ? 'New contact' : 'Edit contact', action: existing == null ? 'Add' : 'Save', fields: [
    if (existing == null) FieldRow(label: 'ISSI', initial: number, number: true, hint: 'e.g. 2320972', onChanged: (v) => number = v),
    FieldRow(label: 'Name', initial: name, hint: hint != null ? '${hint.callsign} ${hint.firstName}'.trim() : 'Callsign or name', onChanged: (v) => name = v),
    FieldRow(label: 'Note', initial: note, hint: 'Optional', onChanged: (v) => note = v),
    FieldRow(label: 'Speed dial', initial: speed, hint: '* or # and a number, e.g. *1', keyboard: TextInputType.phone, onChanged: (v) => speed = v),
  ]);
  if (!ok) return;
  final n = int.tryParse(number.trim());
  if (n == null || n <= 0 || n > 0xFFFFFF) return;
  final r = m.contacts.radioIdOf(n);
  final label = name.trim().isNotEmpty ? name.trim() : (r != null ? '${r.callsign} ${r.firstName}'.trim() : 'ISSI $n');
  // A code that is not * or # with digits is left as it was.
  final code = normalizeSpeedDial(speed) ?? existing?.speedDial ?? '';
  await m.contacts.put(Contact(n, label, note: note.trim(), favorite: (existing?.favorite ?? false) || code.isNotEmpty, speedDial: code));
}

/// Round initials, as in Messages and Phone.
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 40});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final words = name.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim().split(' ').where((w) => w.isNotEmpty);
    final initials = words.isEmpty ? '?' : words.take(2).map((w) => w[0].toUpperCase()).join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [scheme.outline.withValues(alpha: .55), scheme.outline.withValues(alpha: .8)]),
      ),
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: size * .38, fontWeight: FontWeight.w600)),
    );
  }
}
