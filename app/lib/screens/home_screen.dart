import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:poc_ptt/poc_ptt.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/glass.dart';
import '../ui/theme.dart';
import 'calls_screen.dart';
import 'contacts_screen.dart';
import 'messages_screen.dart';
import 'settings_screen.dart';
import 'talkgroups_screen.dart';

/// App shell: five tabs. iOS uses the Cupertino tab bar (translucent, SF-style
/// glyphs), Android the Material navigation bar.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tab = widget.initialTab;
  final _calls = GlobalKey<CallsScreenState>();
  final _contacts = GlobalKey<ContactsScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askKeyService());
  }

  /// PoC radio, first start: the PTT key and the knob only work with the
  /// screen locked once the key service is on in the Accessibility settings.
  /// Android does not let an app switch it on, so ask and open that page.
  Future<void> _askKeyService() async {
    if (!PocPtt.supported || !mounted) return;
    final s = context.read<TerminalModel>().settings;
    var enabled = false;
    try {
      enabled = await PocPtt.keyServiceEnabled();
    } catch (_) {}
    if (!mounted || !s.shouldAskKeyService(enabled: enabled)) return;
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keys in the background'),
        content: const Text('So that the PTT key and the knob also work with the screen locked or the app in the background, '
            'switch on "TETRA Terminal PTT key" in the Accessibility settings. Android only lets you do this yourself.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open settings')),
        ],
      ),
    );
    s.keyServiceAsked = true;
    await s.save();
    if (open == true) await PocPtt.openKeyServiceSettings();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final toast = m.toast;
    if (toast != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
        m.clearToast();
      });
    }
    // An incoming private call always surfaces the Calls tab.
    final ringing = m.privateCall?.incoming == true && m.privateCall?.state == 'ringing';
    final tab = ringing ? 1 : _tab;
    final unread = m.messages.where((x) => !x.outgoing && x.status == MsgStatus.received).isNotEmpty;

    final items = [
      (pick(context, Icons.cell_tower, CupertinoIcons.antenna_radiowaves_left_right), 'Radio'),
      (pick(context, Icons.call_outlined, CupertinoIcons.phone), 'Calls'),
      (pick(context, Icons.person_outline, CupertinoIcons.person_crop_circle), 'Contacts'),
      (pick(context, Icons.chat_bubble_outline, CupertinoIcons.chat_bubble_2), 'Messages'),
      (pick(context, Icons.settings_outlined, CupertinoIcons.gear), 'Settings'),
    ];
    const filled = [CupertinoIcons.antenna_radiowaves_left_right, CupertinoIcons.phone_fill, CupertinoIcons.person_crop_circle_fill, CupertinoIcons.chat_bubble_2_fill, CupertinoIcons.gear_solid];
    void select(int i) {
      Haptics.select();
      setState(() => _tab = i);
    }

    return Scaffold(
      // iOS: content runs beneath the floating glass tab bar.
      extendBody: isApple(context),
      body: IndexedStack(index: tab, children: [
        TalkgroupsScreen(onManageGroups: () {
          setState(() => _tab = 2);
          _contacts.currentState?.showGroups();
        }),
        CallsScreen(key: _calls),
        ContactsScreen(key: _contacts, onCall: (issi) {
          setState(() => _tab = 1);
          _calls.currentState?.openKeypad(issi);
        }),
        const MessagesScreen(),
        const SettingsScreen(),
      ]),
      bottomNavigationBar: isApple(context)
          ? GlassTabBar(
              index: tab,
              onTap: select,
              badges: {if (unread) 3},
              items: [for (final (i, it) in items.indexed) (it.$1, filled[i], it.$2)],
            )
          : NavigationBar(
              // Lower than the Material default (80), lower still on small screens.
              height: MediaQuery.sizeOf(context).height < TabPage.compactHeight ? 54 : 64,
              selectedIndex: tab,
              onDestinationSelected: select,
              destinations: [
                for (final (i, it) in items.indexed)
                  NavigationDestination(icon: Badge(isLabelVisible: i == 3 && unread, smallSize: 8, child: Icon(it.$1)), label: it.$2),
              ],
            ),
    );
  }
}

/// Connection pill: state colour + label, tap to connect / disconnect.
class LinkPill extends StatelessWidget {
  const LinkPill({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final (label, color) = switch (m.link) {
      LinkState.online => ('Online', Tokens.online),
      LinkState.connecting => ('Connecting', Tokens.connecting),
      LinkState.offline => ('Offline', Theme.of(context).colorScheme.outline),
    };
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$label. ${m.link == LinkState.offline ? 'Tap to connect' : 'Tap to disconnect'}',
      child: GestureDetector(
        onTap: () async {
          if (m.link != LinkState.offline) {
            final go = await showActions<bool>(context,
                title: 'Disconnect from the server?', message: 'You will not hear calls until you connect again.', actions: const [
              SheetAction('Disconnect', true, destructive: true),
            ]);
            if (go == true) await m.goOffline();
          } else if (!m.settings.isConfigured) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fill in server, username and ISSI in Settings first')));
          } else {
            await m.connect();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
          ]),
        ),
      ),
    );
  }
}

/// Seconds since [since] as m:ss, ticking once a second.
class Elapsed extends StatefulWidget {
  const Elapsed(this.since, {super.key, this.style});
  final DateTime since;
  final TextStyle? style;
  @override
  State<Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<Elapsed> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.since);
    final s = d.inSeconds.clamp(0, 359999);
    return Text('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
        style: (widget.style ?? const TextStyle()).copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

/// The selected group and who is on air: the one thing a radio user looks at.
class NowCard extends StatelessWidget {
  const NowCard({super.key, this.picker = false});

  /// Shows the scan state and a chevron: the card opens the group menu.
  final bool picker;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // The group the radio is on: with scan this can be another one than the
    // selected group, while its call runs and for the hold time after it.
    final active = m.activeGssi;
    final tg = m.settings.talkgroups.where((t) => t.gssi == active).firstOrNull;
    final selected = m.settings.talkgroups.where((t) => t.gssi == m.selectedGssi).firstOrNull;
    final scanned = active != null && active != m.selectedGssi;
    final heard = m.heard;
    final emergency = heard?.emergency == true;

    final (Color bg, Color fg, String status, DateTime? since, IconData icon) = switch (()) {
      _ when m.transmitting => (Tokens.talk, Colors.white, 'You are talking', m.myTxSince, CupertinoIcons.mic_fill),
      _ when heard != null => (
          emergency ? Tokens.emergency : scheme.primary,
          Colors.white,
          '${emergency ? 'EMERGENCY · ' : ''}${m.nameOf(heard.talker, sentName: heard.talkerName)}${m.nameOf(heard.talker, sentName: heard.talkerName) != 'ISSI ${heard.talker}' ? ' · ${heard.talker}' : ''}',
          heard.since,
          CupertinoIcons.waveform,
        ),
      _ => (scheme.surfaceContainerLow, scheme.onSurface, m.link == LinkState.online ? 'Channel free' : 'Not connected', null, CupertinoIcons.circle),
    };
    final compact = MediaQuery.sizeOf(context).height < TabPage.compactHeight;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
      padding: compact ? const EdgeInsets.fromLTRB(16, 10, 16, 10) : const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Tokens.radiusLarge)),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: fg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                tg?.name ?? (active != null ? 'TG $active' : 'No talkgroup selected'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.headlineSmall?.copyWith(color: fg, fontWeight: FontWeight.w700, letterSpacing: -.3),
              ),
            ),
            if (tg != null)
              Text('TG ${tg.gssi}', style: text.labelLarge?.copyWith(color: fg.withValues(alpha: .75), fontFeatures: const [FontFeature.tabularFigures()])),
            if (picker) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: fg.withValues(alpha: m.settings.scanMode ? .16 : .08), borderRadius: BorderRadius.circular(11)),
                child: Text(m.settings.scanMode ? 'Scan · ${m.settings.talkgroups.where((t) => t.scan).length}' : 'Scan off',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg.withValues(alpha: m.settings.scanMode ? 1 : .7))),
              ),
              const SizedBox(width: 6),
              Icon(CupertinoIcons.chevron_down, size: 16, color: fg.withValues(alpha: .75)),
            ],
          ]),
          if (scanned)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Scan · selected: ${selected?.name ?? 'TG ${m.selectedGssi}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: fg.withValues(alpha: .75))),
            ),
          if (tg != null && tg.otherNetwork)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(m.networkName(tg.mcc, tg.mnc), style: text.bodySmall?.copyWith(color: fg.withValues(alpha: .75))),
            ),
          SizedBox(height: compact ? 6 : 12),
          Row(children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                heard != null && heard.gssi != active ? '$status on ${m.settings.talkgroups.where((t) => t.gssi == heard.gssi).firstOrNull?.name ?? 'TG ${heard.gssi}'}' : status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
            if (since != null) Elapsed(since, style: text.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
    );
  }
}

/// Hold to talk. Feedback on touch-down (scale + colour), haptic on grant.
/// The SOS button needs a long press so it is never sent by accident.
class PttButton extends StatefulWidget {
  const PttButton({super.key, this.compact = false});
  final bool compact;
  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final online = m.link == LinkState.online;
    // Listen-only or refused group (server group access): no PTT, SOS still works.
    final listenOnly = online && m.privateCall == null && !m.mayTalkOnSelected;
    final enabled = online && !listenOnly;
    final tx = m.transmitting;
    final small = widget.compact || MediaQuery.sizeOf(context).height < TabPage.compactHeight;
    final size = small ? 96.0 : 132.0;
    // Hardware PTT only: a slim row, the screen belongs to the content.
    final slim = !m.showSoftPtt;
    final color = !enabled ? scheme.surfaceContainerHigh : (tx ? Tokens.talk : scheme.primary);

    final toggle = m.settings.pttToggle;
    final apple = isApple(context);

    void up() {
      if (!_down) return;
      setState(() => _down = false);
      if (toggle) return;
      Haptics.release();
      m.pttUp();
    }

    return Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: slim ? 44 : 64, child: m.settings.showSpeakerButton ? SpeakerButton(slim: slim || !apple, size: slim ? 40 : 56) : null),
      const Spacer(),
      // Hardware PTT only (Android setting): no button, the status card shows who talks.
      if (m.showSoftPtt)
      Semantics(
        button: true,
        label: toggle
            ? (tx || m.pttLatched ? 'Talking. Tap to stop' : 'Push to talk. Tap to start talking')
            : (tx ? 'Talking. Release to stop' : 'Push to talk. Hold to talk'),
        enabled: enabled,
        child: Listener(
          onPointerDown: enabled
              ? (_) {
                  setState(() => _down = true);
                  if (toggle) {
                    final stopping = tx || m.pttLatched;
                    stopping ? Haptics.release() : Haptics.press();
                    m.togglePtt();
                  } else {
                    Haptics.press();
                    m.pttDown();
                  }
                }
              : null,
          onPointerUp: enabled ? (_) => up() : null,
          onPointerCancel: enabled ? (_) => up() : null,
          child: AnimatedScale(
            scale: _down ? .95 : 1,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(color: (tx ? Tokens.talk : Colors.black).withValues(alpha: tx ? .40 : (apple ? .10 : .08)), blurRadius: tx ? 28 : 16, spreadRadius: tx ? 4 : 0, offset: const Offset(0, 6)),
                ],
              ),
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(tx ? CupertinoIcons.mic_fill : (listenOnly ? CupertinoIcons.speaker_2 : CupertinoIcons.mic), size: small ? 30 : 38, color: enabled ? Colors.white : scheme.outline),
                const SizedBox(height: 4),
                Text(tx ? 'TALK' : (listenOnly ? 'LISTEN' : 'PTT'),
                    style: TextStyle(fontSize: small ? 15 : 17, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: enabled ? Colors.white : scheme.outline)),
              ]),
            ),
          ),
        ),
      ),
      const Spacer(),
      SizedBox(width: slim ? 44 : 64, child: m.settings.showSosButton ? _SosButton(enabled: online, size: slim ? 40 : 56) : null),
    ]);
  }
}

/// The round buttons float above the content: a soft shadow sets them apart.
const _floatShadow = [BoxShadow(color: Color(0x24000000), blurRadius: 10, offset: Offset(0, 3))];

/// Loudspeaker / earpiece (phone mode). A headset or Bluetooth device always
/// wins; the choice is saved.
class SpeakerButton extends StatelessWidget {
  const SpeakerButton({super.key, this.slim = false, this.size = 56});

  /// Without the caption (floating over content on Android).
  final bool slim;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final on = m.settings.speakerOut;
    return Semantics(
      button: true,
      toggled: on,
      label: on ? 'Loudspeaker on. Tap for earpiece' : 'Earpiece. Tap for loudspeaker',
      child: Tooltip(
        message: on ? 'Loudspeaker' : 'Earpiece',
        child: GestureDetector(
          onTap: () {
            Haptics.select();
            m.setSpeakerOut(!on);
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: size,
              height: size,
              decoration: BoxDecoration(shape: BoxShape.circle, color: on ? scheme.primaryContainer : scheme.surfaceContainerHigh, boxShadow: _floatShadow),
              alignment: Alignment.center,
              child: Icon(on ? CupertinoIcons.speaker_3_fill : CupertinoIcons.phone_fill, size: size < 56 ? 18 : 24, color: on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            ),
            if (!slim) ...[
              const SizedBox(height: 4),
              Text(on ? 'Speaker' : 'Earpiece', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
    );
  }
}

class _SosButton extends StatelessWidget {
  const _SosButton({required this.enabled, this.size = 56});
  final bool enabled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = context.read<TerminalModel>();
    return Semantics(
      button: true,
      label: 'Emergency. Long press to talk with emergency priority',
      child: GestureDetector(
        onLongPressStart: enabled
            ? (_) {
                Haptics.warn();
                m.pttDown(emergency: true);
              }
            : null,
        onLongPressEnd: enabled ? (_) => m.pttUp() : null,
        onTap: enabled
            ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hold the SOS button to talk with emergency priority')))
            : null,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? Tokens.emergency : Theme.of(context).colorScheme.surfaceContainerHigh, boxShadow: _floatShadow),
          alignment: Alignment.center,
          child: Text('SOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size < 56 ? 12 : 15, letterSpacing: .5)),
        ),
      ),
    );
  }
}

/// Large-title page scaffold used by every tab: title, optional trailing
/// actions, then content.
class TabPage extends StatelessWidget {
  const TabPage({super.key, required this.title, this.subtitle, this.actions = const [], required this.slivers, this.bottom, this.bottomHeight = 150, this.bottomFrosted = false});
  final String title;

  /// A small second line under the title. A page with one gets a single
  /// pinned header row on every screen size instead of the large title.
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Widget? bottom;

  /// Room the floating [bottom] takes, kept free below the last row.
  final double bottomHeight;

  /// A translucent, blurred bar behind [bottom] (Android, on-screen PTT).
  final bool bottomFrosted;

  /// Screens lower than this (logical pixels) get the compact layout.
  static const compactHeight = 700.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final apple = isApple(context);
    // Bottom inset: the floating tab bar (Scaffold.extendBody puts it in the padding).
    final barInset = MediaQuery.of(context).padding.bottom;
    final compact = MediaQuery.sizeOf(context).height < TabPage.compactHeight;
    final scroll = CustomScrollView(slivers: [
      if (subtitle != null)
        SliverAppBar(
          pinned: true,
          toolbarHeight: compact ? 56 : 64,
          titleSpacing: Tokens.gutter,
          backgroundColor: apple ? scheme.surface.withValues(alpha: .9) : null,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: compact ? 20 : 24, fontWeight: apple ? FontWeight.w700 : FontWeight.w500, height: 1.15)),
            if (subtitle!.isNotEmpty)
              Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: scheme.onSurfaceVariant, height: 1.2)),
          ]),
          actions: [...actions, SizedBox(width: apple ? 12 : 8)],
        )
      else if (apple)
        CupertinoSliverNavigationBar(
          largeTitle: Text(title),
          backgroundColor: scheme.surface.withValues(alpha: .9),
          border: null,
          trailing: actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: actions),
        )
      else
        // A small screen (PoC radios) has no room for the large title: one pinned row.
        if (compact)
          SliverAppBar(pinned: true, toolbarHeight: 52, title: Text(title), actions: [...actions, const SizedBox(width: 8)])
        else
          SliverAppBar.large(title: Text(title), actions: [...actions, const SizedBox(width: 8)]),
      ...slivers,
      SliverToBoxAdapter(child: SizedBox(height: 16 + barInset + (bottom != null ? bottomHeight : 0))),
    ]);
    if (bottom == null) return scroll;
    // The PTT controls float above the content, which scrolls beneath them
    // (iOS: above the glass tab bar; Android: above the navigation bar).
    if (bottomFrosted && !apple) {
      return Stack(children: [
        Positioned.fill(child: scroll),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                padding: EdgeInsets.fromLTRB(Tokens.gutter, 10, Tokens.gutter, barInset + 10),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: .62),
                  border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .35), width: .5)),
                ),
                child: bottom!,
              ),
            ),
          ),
        ),
      ]);
    }
    return Stack(children: [
      Positioned.fill(child: scroll),
      Positioned(left: apple ? 20 : Tokens.gutter, right: apple ? 20 : Tokens.gutter, bottom: barInset + (apple ? 14 : 10), child: bottom!),
    ]);
  }
}
