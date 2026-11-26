import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/contacts.dart';
import '../model/settings.dart';
import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
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
    final title = m.settings.name.isNotEmpty ? m.settings.name : (m.settings.issi > 0 ? 'ISSI ${m.settings.issi}' : 'Radio');

    return TabPage(
      title: title,
      actions: const [LinkPill()],
      slivers: [
        SliverToBoxAdapter(child: Padding(padding: EdgeInsets.only(top: 4, bottom: compact ? 8 : 12), child: const NowCard())),
        SliverToBoxAdapter(
          child: _Card(
            padding: EdgeInsets.fromLTRB(16, compact ? 9 : 14, 16, compact ? 9 : 14),
            child: Column(children: [
              LevelBar(label: 'TX', meter: m.audio.txMeter),
              SizedBox(height: compact ? 6 : 10),
              LevelBar(label: 'RX', meter: m.audio.rxMeter),
            ]),
          ),
        ),
        if (tgs.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                Icon(CupertinoIcons.person_3, size: 44, color: scheme.outline),
                const SizedBox(height: 12),
                Text('No talkgroups yet', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Add the groups (GSSI) you want to talk and listen on.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => editTalkgroup(context, m, null), child: const Text('Add talkgroup')),
              ]),
            ),
          )
        else ...[
          SliverToBoxAdapter(child: Padding(padding: EdgeInsets.only(top: compact ? 8 : 12), child: GroupPicker(onManageGroups: onManageGroups))),
          const SliverToBoxAdapter(child: LastTalkers()),
        ],
      ],
      bottom: isApple(context)
          ? const PttButton()
          : Container(
              padding: !m.showSoftPtt
                  ? const EdgeInsets.fromLTRB(Tokens.gutter, 6, Tokens.gutter, 6)
                  : EdgeInsets.fromLTRB(Tokens.gutter, compact ? 8 : 14, Tokens.gutter, compact ? 8 : 18),
              decoration: BoxDecoration(color: scheme.surface, border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5), width: .5))),
              child: const PttButton(),
            ),
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

/// The selected group as a drop-down. Open: scan mode on top, then every
/// group to select, each with its own "scan this group" switch.
class GroupPicker extends StatelessWidget {
  const GroupPicker({super.key, this.onManageGroups});
  final VoidCallback? onManageGroups;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final tg = m.settings.talkgroups.where((t) => t.gssi == m.selectedGssi).firstOrNull;
    final scanned = m.settings.talkgroups.where((t) => t.scan).length;
    final scanOn = m.settings.scanMode;
    return Semantics(
      button: true,
      label: 'Talkgroup ${tg?.name ?? 'none'}. Scan ${scanOn ? 'on' : 'off'}. Tap to change',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Haptics.select();
          _open(context, m);
        },
        child: _Card(
          padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
          child: SizedBox(
            height: 52,
            child: Row(children: [
              Flexible(child: Text(tg?.name ?? 'Select a talkgroup', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
              if (tg != null) ...[
                const SizedBox(width: 8),
                Text('TG ${tg.gssi}', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: scanOn ? scheme.primary.withValues(alpha: .14) : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(11)),
                child: Text(scanOn ? 'Scan on · $scanned' : 'Scan off',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scanOn ? scheme.primary : scheme.onSurfaceVariant)),
              ),
              const SizedBox(width: 6),
              Icon(CupertinoIcons.chevron_down, size: 16, color: scheme.onSurfaceVariant),
            ]),
          ),
        ),
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
                  const Text('Scan mode', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(scanOn ? 'You also hear the groups switched on below' : 'You only hear the selected group', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
            Text('SELECT GROUP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .5, color: scheme.onSurfaceVariant)),
            const Spacer(),
            Text('SCAN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .5, color: scheme.onSurfaceVariant)),
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
              child: Text('Edit groups', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: scheme.primary)),
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
      if (access == GroupAccess.listen) 'listen only',
      if (access == GroupAccess.refused) 'not allowed',
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
              label: 'Scan ${t.name}',
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
  const LastTalkers({super.key});
  static const count = 5;

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
        child: Text('LAST TALKERS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: .6, color: scheme.onSurfaceVariant)),
      ),
      _Card(
        child: rows.isEmpty
            ? Padding(padding: const EdgeInsets.all(16), child: Text('Nobody has talked yet.', style: dim))
            : Column(children: [
                for (final (i, e) in rows.indexed)
                  Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35), width: .5))),
                    child: Row(children: [
                      SizedBox(width: 46, child: Text('${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}', style: dim)),
                      Expanded(
                        flex: 5,
                        child: Text(
                          e.kind == CallKind.groupTalked ? 'You' : m.nameOf(e.issi, sentName: e.sentName),
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
          Text('No talkgroups yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Add the groups (GSSI) you want to talk and listen on.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => editTalkgroup(context, m, null), child: const Text('Add talkgroup')),
        ]),
      );
    }
    return Section(
      footer: 'Tap a group to edit or remove it. The switch scans a group, so you hear it too while scan mode is on.',
      children: [for (final t in tgs) _TalkgroupRow(t)],
    );
  }
}

class _TalkgroupRow extends StatelessWidget {
  const _TalkgroupRow(this.t);
  final Talkgroup t;

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
      if (access == GroupAccess.listen) 'listen only',
      if (access == GroupAccess.refused) 'not allowed',
    ].join(' · ');

    return Opacity(
      opacity: access == GroupAccess.refused ? .45 : 1,
      child: Tile(
        title: t.name,
        subtitle: subtitle,
        trailing: Semantics(
          label: 'Scan ${t.name}',
          child: Switch.adaptive(
            value: t.scan,
            onChanged: (v) {
              Haptics.select();
              t.scan = v;
              m.saveTalkgroups();
            },
          ),
        ),
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
              for (final n in nets.where((n) => !n.own)) SheetAction('${n.name}${n.up ? '' : ' (offline)'}', (n.mcc, n.mnc)),
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
