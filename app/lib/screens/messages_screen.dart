import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/l10n.dart';
import '../ui/theme.dart';
import 'home_screen.dart';

String _time(BuildContext context, DateTime t) {
  final now = DateTime.now();
  if (now.difference(t).inHours < 24 && now.day == t.day) return TimeOfDay.fromDateTime(t).format(context);
  return '${t.day}.${t.month}.';
}

/// SDS conversations: one row per peer (radio or group).
class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final peers = <int>[];
    for (final msg in m.messages.reversed) {
      if (!peers.contains(msg.peer)) peers.add(msg.peer);
    }
    String label(int peer) {
      final tg = m.settings.talkgroups.where((t) => t.gssi == peer).firstOrNull;
      return tg != null ? tg.name : m.nameOf(peer);
    }

    bool isGroup(int peer) => m.settings.talkgroups.any((t) => t.gssi == peer);

    return TabPage(
      title: 'Messages',
      actions: [
        IconButton(
          tooltip: tr('New message'),
          icon: Icon(pick(context, Icons.edit_outlined, CupertinoIcons.square_pencil)),
          onPressed: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => const NewMessageScreen())),
        ),
      ],
      slivers: [
        if (peers.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(CupertinoIcons.chat_bubble_2, size: 48, color: scheme.outline),
                const SizedBox(height: 12),
                Tx('No messages', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Tx('Short data messages (SDS) to radios and groups show up here.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ),
          )
        else
          SliverToBoxAdapter(
            child: Section(children: [
              for (final p in peers)
                Builder(builder: (context) {
                  final last = m.messages.lastWhere((x) => x.peer == p);
                  return Tile(
                    leading: CircleAvatar(
                      radius: 20,
                      backgroundColor: isGroup(p) ? scheme.primary : scheme.surfaceContainerHigh,
                      child: Icon(isGroup(p) ? CupertinoIcons.person_3_fill : CupertinoIcons.person_fill, size: 20, color: isGroup(p) ? Colors.white : scheme.onSurfaceVariant),
                    ),
                    title: label(p),
                    subtitle: '${last.outgoing ? '${tr('You')}: ' : ''}${last.text}',
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (m.locations[p] != null) Icon(CupertinoIcons.location_solid, size: 14, color: scheme.outline),
                      const SizedBox(width: 4),
                      Text(_time(context, last.time), style: TextStyle(color: scheme.outline, fontSize: 13)),
                      if (m.unreadMessages(p) > 0) Padding(padding: const EdgeInsets.only(left: 6), child: Badge(label: Text('${m.unreadMessages(p)}'))),
                      if (isApple(context)) const CupertinoListTileChevron(),
                    ]),
                    onTap: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => ConversationScreen(peer: p, title: label(p)))),
                  );
                }),
            ]),
          ),
      ],
    );
  }
}

/// New message: one field on top for a number, a name or a callsign, and
/// below it what matches, from the own lists (contacts, talkgroups) and from
/// the RadioID.net database. A callsign with several IDs lists each ID.
class NewMessageScreen extends StatefulWidget {
  const NewMessageScreen({super.key});
  @override
  State<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends State<NewMessageScreen> {
  String _query = '';

  void _open(int peer, String title) =>
      Navigator.pushReplacement(context, CupertinoPageRoute(builder: (_) => ConversationScreen(peer: peer, title: title)));

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final number = int.tryParse(q);
    bool hit(String name, int id) => q.isEmpty || name.toLowerCase().contains(q) || '$id'.contains(q);
    final contacts = m.contacts.contacts.where((c) => hit(c.name, c.issi)).toList();
    final groups = m.settings.talkgroups.where((t) => hit(t.name, t.gssi)).toList();
    final own = {...contacts.map((c) => c.issi), ...groups.map((t) => t.gssi)};
    final db = m.contacts.searchRadioId(q).where((r) => !own.contains(r.issi)).toList();
    final direct = number != null && number > 0 && number <= 0xFFFFFF && !own.contains(number);

    Widget icon(IconData i, {bool group = false}) => CircleAvatar(
          radius: 18,
          backgroundColor: group ? scheme.primary : scheme.surfaceContainerHigh,
          child: Icon(i, size: 18, color: group ? Colors.white : scheme.onSurfaceVariant),
        );

    return Scaffold(
      appBar: AppBar(title: const Tx('New message'), centerTitle: isApple(context)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Tokens.gutter, 4, Tokens.gutter, 8),
          child: isApple(context)
              ? CupertinoSearchTextField(autofocus: true, placeholder: tr('Number, name or callsign'), onChanged: (v) => setState(() => _query = v))
              : TextField(
                  autofocus: true,
                  decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Number, name or callsign')),
                  onChanged: (v) => setState(() => _query = v),
                ),
        ),
        Expanded(
          child: ListView(keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
            if (direct)
              Section(children: [
                Tile(
                  leading: icon(CupertinoIcons.number),
                  title: tr('Write to {0}', [number]),
                  subtitle: m.contacts.radioIdOf(number)?.callsign ?? 'ISSI or GSSI',
                  onTap: () => _open(number, m.nameOf(number)),
                ),
              ]),
            if (contacts.isNotEmpty)
              Section(header: 'Contacts', children: [
                for (final c in contacts)
                  Tile(leading: icon(CupertinoIcons.person_fill), title: c.name, subtitle: 'ISSI ${c.issi}', onTap: () => _open(c.issi, c.name)),
              ]),
            if (groups.isNotEmpty)
              Section(header: 'Groups', children: [
                for (final t in groups)
                  Tile(leading: icon(CupertinoIcons.person_3_fill, group: true), title: t.name, subtitle: 'GSSI ${t.gssi}', onTap: () => _open(t.gssi, t.name)),
              ]),
            if (db.isNotEmpty)
              Section(header: 'RadioID.net', children: [
                for (final r in db)
                  Tile(
                    leading: icon(CupertinoIcons.antenna_radiowaves_left_right),
                    title: [r.entry.callsign, if (r.entry.firstName.isNotEmpty) r.entry.firstName].join(' · '),
                    subtitle: 'ISSI ${r.issi}',
                    onTap: () => _open(r.issi, r.entry.callsign),
                  ),
              ]),
            if (!direct && contacts.isEmpty && groups.isEmpty && db.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Tx(
                  q.isEmpty ? 'Type a number, or search your contacts, groups and the callsign database.' : 'Nothing found. Type the number (ISSI or GSSI) to write to it directly.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.peer, required this.title});
  final int peer;
  final String title;
  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _text = TextEditingController();
  bool _flash = false;
  late final TerminalModel _model;

  @override
  void initState() {
    super.initState();
    _model = context.read<TerminalModel>();
    // After the first frame: marking as read notifies the lists behind.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _model.conversationOpen(widget.peer, true);
    });
  }

  @override
  void dispose() {
    final model = _model, peer = widget.peer;
    Future.microtask(() => model.conversationOpen(peer, false));
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final msgs = m.messages.where((x) => x.peer == widget.peer).toList();
    final loc = m.locations[widget.peer];
    final outgoingColor = isApple(context) ? const Color(0xFF0A84FF) : scheme.primary;

    void send() {
      final t = _text.text.trim();
      if (t.isEmpty || m.link != LinkState.online) return;
      Haptics.select();
      m.sendText(widget.peer, t, immediate: _flash);
      _text.clear();
      setState(() => _flash = false);
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.title), centerTitle: isApple(context)),
      body: Column(children: [
        if (loc != null)
          Container(
            margin: const EdgeInsets.fromLTRB(Tokens.gutter, 4, Tokens.gutter, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(Tokens.radius)),
            child: Row(children: [
              Icon(CupertinoIcons.location_solid, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${loc.location.latitude.toStringAsFixed(5)}, ${loc.location.longitude.toStringAsFixed(5)}'
                  '${loc.location.speedKmh != null ? ' · ${loc.location.speedKmh!.round()} km/h' : ''}',
                ),
              ),
              Text(TimeOfDay.fromDateTime(loc.time).format(context), style: TextStyle(color: scheme.outline)),
            ]),
          ),
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: msgs.length,
            itemBuilder: (_, i) {
              final msg = msgs[msgs.length - 1 - i];
              final fg = msg.outgoing ? Colors.white : scheme.onSurface;
              return Align(
                alignment: msg.outgoing ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .75),
                  decoration: BoxDecoration(
                    color: msg.outgoing ? outgoingColor : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                    border: msg.immediate ? Border.all(color: Tokens.emergency, width: 2) : null,
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (msg.immediate) Tx('FLASH', style: TextStyle(color: msg.outgoing ? Colors.white : Tokens.emergency, fontSize: 11, fontWeight: FontWeight.w700)),
                    Text(msg.text, style: TextStyle(color: fg, fontSize: 16)),
                    const SizedBox(height: 2),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(TimeOfDay.fromDateTime(msg.time).format(context), style: TextStyle(color: fg.withValues(alpha: .7), fontSize: 11)),
                      if (msg.outgoing) ...[const SizedBox(width: 4), _StatusIcon(msg.status, color: fg.withValues(alpha: .8))],
                    ]),
                  ]),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                tooltip: tr(_flash ? 'Flash message on' : 'Send as flash (immediate) message'),
                icon: Icon(_flash ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt, color: _flash ? Tokens.emergency : scheme.outline),
                onPressed: () => setState(() => _flash = !_flash),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: TextField(
                    controller: _text,
                    maxLength: 120,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => send(),
                    decoration: InputDecoration(hintText: tr('Message'), counterText: '', border: InputBorder.none, isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 10)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: tr('Send'),
                style: IconButton.styleFrom(backgroundColor: outgoingColor),
                onPressed: m.link != LinkState.online ? null : send,
                icon: const Icon(CupertinoIcons.arrow_up, color: Colors.white),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status, {required this.color});
  final MsgStatus status;
  final Color color;
  @override
  Widget build(BuildContext context) => Icon(
        switch (status) {
          MsgStatus.sending => CupertinoIcons.clock,
          MsgStatus.sent || MsgStatus.networkAccepted => CupertinoIcons.checkmark_alt,
          MsgStatus.delivered => CupertinoIcons.checkmark_seal_fill,
          MsgStatus.failed => CupertinoIcons.exclamationmark_circle,
          MsgStatus.received => CupertinoIcons.checkmark_alt,
        },
        size: 13,
        color: status == MsgStatus.failed ? Tokens.emergency : color,
      );
}
