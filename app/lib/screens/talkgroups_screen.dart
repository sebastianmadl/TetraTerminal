import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/contacts.dart';
import '../model/settings.dart';
import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/l10n.dart';
import '../ui/level_meter.dart';
import '../ui/theme.dart';
import 'home_screen.dart';

/// The radio: who is on air, the levels, the group, who talked last, and PTT
/// in the thumb zone. Groups are added and edited under Contacts > Groups.
class TalkgroupsScreen extends StatelessWidget {
  const TalkgroupsScreen({super.key, this.onManageGroups});

  /// Opens the group list (Contacts > Groups).
  final VoidCallback? onManageGroups;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final tgs = m.settings.talkgroups;
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).height < TabPage.compactHeight;
    final title = m.settings.name.isNotEmpty ? m.settings.name : (m.settings.issi > 0 ? 'ISSI ${m.settings.issi}' : tr('Radio'));

    final floating = m.showSoftPtt || m.settings.showSosButton || m.settings.showSpeakerButton;
    final bottomHeight = !m.showSoftPtt ? 56.0 : (compact ? 112.0 : 150.0);

    return TabPage(
      title: title,
      subtitle: m.settings.active.displayName,
      actions: const [LinkPill()],
      slivers: [
        SliverToBoxAdapter(child: Padding(padding: EdgeInsets.only(top: 4, bottom: compact ? 8 : 12), child: tgs.isEmpty ? const NowCard() : GroupPicker(onManageGroups: onManageGroups))),
        SliverToBoxAdapter(
          child: _Card(
            padding: compact ? const EdgeInsets.fromLTRB(16, 8, 16, 8) : const EdgeInsets.fromLTRB(16, 12, 16, 12),
            // One meter: what you hear, and your microphone while you transmit.
            child: m.transmitting
                ? LevelBar(key: const ValueKey('tx'), label: 'TX', meter: m.audio.txMeter)
                : LevelBar(key: const ValueKey('rx'), label: 'RX', meter: m.audio.rxMeter),
          ),
        ),
        if (tgs.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                Icon(CupertinoIcons.person_3, size: 44, color: scheme.outline),
                const SizedBox(height: 12),
                Tx('No talkgroups yet', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Tx('Add the groups (GSSI) you want to talk and listen on.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => editTalkgroup(context, m, null), child: const Tx('Add talkgroup')),
              ]),
            ),
          )
        else ...[
          // As many rows as fit between the cards above and the PTT controls.
          SliverLayoutBuilder(builder: (context, c) {
            final below = 16 + MediaQuery.of(context).padding.bottom + (floating ? bottomHeight : 0);
            final room = c.viewportMainAxisExtent - c.precedingScrollExtent - LastTalkers.headerHeight - below;
            return SliverToBoxAdapter(child: LastTalkers(count: (room / LastTalkers.rowHeight).floor().clamp(2, 12)));
          }),
        ],
      ],
      // Hardware PTT with the SOS and loudspeaker buttons hidden: nothing floats.
      bottom: floating ? const PttButton() : null,
      bottomFrosted: m.showSoftPtt,
      bottomHeight: bottomHeight,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = EdgeInsets.zero});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
        padding: padding,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(18)),
        child: child,
      );
}

/// The status card as a drop-down for the group. Open: scan mode on top, then
/// every group to select, each with its own "scan this group" switch.
class GroupPicker extends StatelessWidget {
  const GroupPicker({super.key, this.onManageGroups});
  final VoidCallback? onManageGroups;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final tg = m.settings.talkgroups.where((t) => t.gssi == m.selectedGssi).firstOrNull;
    final scanOn = m.settings.scanMode;
    return Semantics(
      button: true,
      label: tr('Talkgroup {0}. Scan {1}. Tap to change', [tg?.name ?? tr('none'), tr(scanOn ? 'on' : 'off')]),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Haptics.select();
          _open(context, m);
        },
        child: const NowCard(picker: true),
      ),
    );
  }

  void _open(BuildContext context, TerminalModel m) {
    final box = context.findRenderObject() as RenderBox;
    final top = box.localToGlobal(Offset(0, box.size.height)).dy + 6;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: .22),
      transitionDuration: const Duration(milliseconds: 140),
      transitionBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      pageBuilder: (ctx, _, __) {
        final media = MediaQuery.of(ctx);
        // Below the button; on a short screen as far up as it needs to be.
        // Stay clear of the tab bar (Android: the navigation bar is not part of the padding).
        final room = media.size.height - media.padding.bottom - (isApple(ctx) ? 24 : 96);
        final y = top.clamp(media.padding.top + 8, (room - 280).clamp(media.padding.top + 8, double.infinity)).toDouble();
        return Stack(children: [
          Positioned(
            left: Tokens.gutter,
            right: Tokens.gutter,
            top: y,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: room - y),
              child: ListenableBuilder(listenable: m, builder: (ctx, _) => _GroupMenu(m, onManageGroups: onManageGroups)),
            ),
          ),
        ]);
      },
    );
  }
}

class _GroupMenu extends StatelessWidget {
  const _GroupMenu(this.m, {this.onManageGroups});
  final TerminalModel m;
  final VoidCallback? onManageGroups;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tgs = m.settings.talkgroups;
    final scanOn = m.settings.scanMode;
    final hair = BorderSide(color: scheme.outlineVariant.withValues(alpha: .5), width: .5);
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: .4),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () => m.setScanMode(!scanOn),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Tx('Scan mode', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(tr(scanOn ? 'You also hear the groups switched on below' : 'You only hear the selected group'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
              ),
              Switch.adaptive(value: scanOn, onChanged: m.setScanMode),
            ]),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh.withValues(alpha: .45), border: Border(top: hair, bottom: hair)),
          child: Row(children: [
            Tx('SELECT GROUP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .5, color: scheme.onSurfaceVariant)),
            const Spacer(),
            Tx('SCAN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .5, color: scheme.onSurfaceVariant)),
          ]),
        ),
        Flexible(
          child: ListView(padding: EdgeInsets.zero, shrinkWrap: true, children: [
            for (final t in tgs) _GroupMenuRow(m, t),
          ]),
        ),
        if (onManageGroups != null)
          InkWell(
            onTap: () {
              Navigator.pop(context);
              onManageGroups!();
            },
            child: Container(
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border(top: hair)),
              child: Tx('Edit groups', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: scheme.primary)),
            ),
          ),
      ]),
    );
  }
}

class _GroupMenuRow extends StatelessWidget {
  const _GroupMenuRow(this.m, this.t);
  final TerminalModel m;
  final Talkgroup t;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = t.gssi == m.selectedGssi;
    final access = m.accessOf(t);
    final active = m.groupActivity[t.gssi];
    final note = [
      if (t.otherNetwork) m.networkName(t.mcc, t.mnc),
      if (access == GroupAccess.listen) tr('listen only'),
      if (access == GroupAccess.refused) tr('not allowed'),
    ].join(' · ');
    return Opacity(
      opacity: access == GroupAccess.refused ? .45 : 1,
      child: InkWell(
        onTap: () {
          Haptics.select();
          m.selectGroup(t.gssi);
          Navigator.pop(context);
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.fromLTRB(14, 2, 12, 2),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35), width: .5))),
          child: Row(children: [
            Icon(CupertinoIcons.checkmark_alt, size: 18, color: selected ? scheme.primary : Colors.transparent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                if (note.isNotEmpty) Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
            ),
            if (active != null) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(CupertinoIcons.waveform, size: 18, color: active.emergency ? Tokens.emergency : scheme.primary)),
            Text('TG ${t.gssi}', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 6),
            Semantics(
              label: tr('Scan {0}', [t.name]),
              child: Transform.scale(
                scale: .8,
                child: Switch.adaptive(
                  value: t.scan,
                  onChanged: (v) {
                    t.scan = v;
                    m.saveTalkgroups();
                  },
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The last five talkers on the groups: time, callsign and name, group, how long.
class LastTalkers extends StatelessWidget {
  const LastTalkers({super.key, this.count = 5});

  /// Rows shown at most.
  final int count;
  static const rowHeight = 44.0;

  /// The caption above the rows, with its padding.
  static const headerHeight = 44.0;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final rows = m.callLog.entries.where((e) => e.kind == CallKind.groupHeard || e.kind == CallKind.groupTalked).take(count).toList();
    const tabular = [FontFeature.tabularFigures()];
    final dim = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, fontFeatures: tabular);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Tokens.gutter + 4, 18, Tokens.gutter + 4, 8),
        child: Tx('LAST TALKERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: .6, color: scheme.onSurfaceVariant)),
      ),
      _Card(
        child: rows.isEmpty
            ? Padding(padding: const EdgeInsets.all(16), child: Tx('Nobody has talked yet.', style: dim))
            : Column(children: [
                for (final (i, e) in rows.indexed)
                  Container(
                    height: rowHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35), width: .5))),
                    child: Row(children: [
                      SizedBox(width: 46, child: Text('${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}', style: dim)),
                      Expanded(
                        flex: 5,
                        child: Text(
                          e.kind == CallKind.groupTalked ? tr('You') : m.nameOf(e.issi, sentName: e.sentName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: e.emergency ? Tokens.emergency : scheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: Text(
                          m.settings.talkgroups.where((t) => t.gssi == e.gssi).firstOrNull?.name ?? e.groupName ?? 'TG ${e.gssi}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: dim,
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          e.duration.inSeconds <= 0 ? '' : '${e.duration.inSeconds ~/ 60}:${(e.duration.inSeconds % 60).toString().padLeft(2, '0')}',
                          textAlign: TextAlign.right,
                          style: dim.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ]),
                  ),
              ]),
      ),
    ]);
  }
}

/// The saved talkgroups as a list to manage (Contacts > Groups): tap to
/// select, the switch scans a group, long press or the info button edits.
class TalkgroupList extends StatelessWidget {
  const TalkgroupList({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final tgs = m.settings.talkgroups;
    if (tgs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(children: [
          Icon(CupertinoIcons.person_3, size: 44, color: scheme.outline),
          const SizedBox(height: 12),
          Tx('No talkgroups yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Tx('Add the groups (GSSI) you want to talk and listen on.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => editTalkgroup(context, m, null), child: const Tx('Add talkgroup')),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Card(
        child: ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: tgs.length,
          onReorder: (from, to) {
            Haptics.select();
            m.moveTalkgroup(from, to > from ? to - 1 : to);
          },
          itemBuilder: (context, i) => Material(
            key: ValueKey(tgs[i].gssi),
            color: scheme.surfaceContainerLow,
            child: _TalkgroupRow(tgs[i], index: i),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Tokens.gutter + 4, 8, Tokens.gutter + 4, 0),
        child: Tx('Tap a group to edit or remove it. Drag the handle to change the order, which the channel knob follows. The switch is the scan switch: with it on you also hear that group while scan mode is on. Off does not disable the group, you can still select it and talk there.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      ),
    ]);
  }
}

class _TalkgroupRow extends StatelessWidget {
  const _TalkgroupRow(this.t, {required this.index});
  final Talkgroup t;
  final int index;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final selected = t.gssi == m.selectedGssi;
    final access = m.accessOf(t);
    final subtitle = [
      'GSSI ${t.gssi}',
      if (selected) 'selected',
      if (t.otherNetwork) m.networkName(t.mcc, t.mnc),
      if (t.dgna) 'DGNA',
      if (access == GroupAccess.listen) tr('listen only'),
      if (access == GroupAccess.refused) tr('not allowed'),
    ].join(' · ');

    return Opacity(
      opacity: access == GroupAccess.refused ? .45 : 1,
      child: Tile(
        title: t.name,
        subtitle: subtitle,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          // Named, so it is not taken for "group on/off".
          Tx('Scan', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .3, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(width: 6),
          Semantics(
            label: tr('Scan {0}', [t.name]),
            child: Switch.adaptive(
              value: t.scan,
              onChanged: (v) {
                Haptics.select();
                t.scan = v;
                m.saveTalkgroups();
              },
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Semantics(
              label: tr('Move {0}', [t.name]),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
                child: Icon(CupertinoIcons.line_horizontal_3, size: 22, color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ),
        ]),
        onTap: () => editTalkgroup(context, m, t),
      ),
    );
  }
}

/// Add or edit a talkgroup in a sheet. With Multi Network the group can be
/// one of a linked network.
Future<void> editTalkgroup(BuildContext context, TerminalModel m, Talkgroup? existing) async {
  var gssi = existing?.gssi.toString() ?? '';
  var name = existing?.name ?? '';
  var net = (existing?.mcc ?? 0, existing?.mnc ?? 0);
  final nets = m.networks;

  if (existing != null) {
    final action = await showActions<String>(context, title: existing.name, message: 'GSSI ${existing.gssi}', actions: const [
      SheetAction('Select', 'select'),
      SheetAction('Edit', 'edit'),
      SheetAction('Remove', 'remove', destructive: true),
    ]);
    if (action == null || !context.mounted) return;
    if (action == 'select') {
      await m.selectGroup(existing.gssi);
      return;
    }
    if (action == 'remove') {
      m.settings.talkgroups.remove(existing);
      await m.saveTalkgroups();
      return;
    }
  }

  final ok = await showFormSheet(context, title: existing == null ? 'New talkgroup' : 'Edit talkgroup', action: existing == null ? 'Add' : 'Save', fields: [
    if (existing == null) FieldRow(label: 'GSSI', initial: gssi, number: true, hint: 'e.g. 91', onChanged: (v) => gssi = v),
    FieldRow(label: 'Name', initial: name, hint: 'Optional', onChanged: (v) => name = v),
    if (nets.length > 1)
      StatefulBuilder(
        builder: (ctx, setState) => Tile(
          title: 'Network',
          subtitle: net == (0, 0) ? 'Home network' : m.networkName(net.$1, net.$2),
          onTap: () async {
            final picked = await showActions<(int, int)>(ctx, title: 'Network of this group', actions: [
              const SheetAction('Home network', (0, 0)),
              for (final n in nets.where((n) => !n.own)) SheetAction('${n.name}${n.up ? '' : ' (${tr('offline')})'}', (n.mcc, n.mnc)),
            ]);
            if (picked != null) setState(() => net = picked);
          },
        ),
      ),
  ]);
  if (!ok) return;
  final g = int.tryParse(gssi.trim());
  if (g == null || g <= 0 || g > 0xFFFFFF) return;
  final label = name.trim().isEmpty ? 'TG $g' : name.trim();
  if (existing != null) {
    existing
      ..name = label
      ..mcc = net.$1
      ..mnc = net.$2;
  } else if (!m.settings.talkgroups.any((t) => t.gssi == g)) {
    m.settings.talkgroups.add(Talkgroup(g, label, mcc: net.$1, mnc: net.$2));
  }
  await m.saveTalkgroups();
}
