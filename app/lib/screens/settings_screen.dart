import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:poc_ptt/poc_ptt.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/settings.dart';
import '../model/terminal_model.dart';
import '../services/call_alert.dart';
import '../services/version.dart';
import '../ui/adaptive.dart';
import '../ui/l10n.dart';
import '../ui/level_meter.dart';
import '../ui/theme.dart';
import 'home_screen.dart';
import 'profile_sheet.dart';

/// Auto-stop of tap-to-talk (seconds; 0 = off).
const pttAutoStopChoices = {0: 'Off', 30: '30 s', 60: '1 min', 120: '2 min', 300: '5 min'};
bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Settings: the connections on top, everything else sorted into a few pages.
/// Changes take effect when a page is left; there is no Save button.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final s = m.settings;
    final scheme = Theme.of(context).colorScheme;
    String onOff(bool v) => tr(v ? 'on' : 'off');

    return TabPage(
      title: 'Settings',
      slivers: [
        SliverToBoxAdapter(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Section(
              header: 'Connections',
              footer: m.lastError,
              children: [
                for (final p in s.profiles) ProfileRow(key: ValueKey(p.id), m: m, p: p),
                Tile(
                  title: 'Add connection',
                  leading: Icon(CupertinoIcons.add_circled_solid, color: scheme.primary),
                  onTap: () => editProfile(context, m, null),
                ),
                const Tile(title: 'Status', trailing: LinkPill()),
              ],
            ),
            Section(children: [
              MenuTile(
                icon: CupertinoIcons.antenna_radiowaves_left_right,
                color: const Color(0xFF1F8A70),
                title: 'Radio',
                summary: '${tr(s.pttToggle ? 'Toggle' : 'Hold to talk')} · P${s.defaultPriority} · ${tr('scan hold {0}', [s.scanHoldSeconds == 0 ? tr('off') : '${s.scanHoldSeconds} s'])}',
                page: const RadioSettings(),
              ),
              MenuTile(
                icon: CupertinoIcons.phone_fill,
                color: const Color(0xFF34A853),
                title: 'Calls and background',
                summary: '${tr('Ringing {0}', [onOff(s.ringIncoming)])} · ${tr(isApple(context) ? 'Live Activity {0}' : 'live notification {0}', [onOff(s.liveActivity)])}',
                page: const CallSettings(),
              ),
              MenuTile(
                icon: CupertinoIcons.waveform,
                color: const Color(0xFFE5484D),
                title: 'Audio',
                summary: '${tr(s.micAuto ? 'Microphone automatic' : 'Microphone manual')} · ${tr('noise suppression {0}', [onOff(s.noiseSuppression)])}',
                page: const AudioSettings(),
              ),
              MenuTile(
                icon: CupertinoIcons.rectangle_on_rectangle_angled,
                color: const Color(0xFF5E5CE6),
                title: 'Display',
                summary: '${L.current == 'de' ? 'Deutsch' : 'English'} · ${tr(const {'system': 'Automatic', 'light': 'Light', 'dark': 'Dark'}[s.appearance] ?? 'Automatic')} · ${tr('buttons')}',
                page: const DisplaySettings(),
              ),
              if (_android)
                MenuTile(
                  icon: CupertinoIcons.dial_fill,
                  color: const Color(0xFFF2994A),
                  title: 'Keys and accessories',
                  summary: [
                    s.pocPttEnabled ? tr(PocProfile.nameOf(s.pocProfile)) : tr('Hardware PTT off'),
                    if (s.headsetEnabled) tr('Bluetooth headset'),
                  ].join(' · '),
                  page: const HardwareSettings(),
                ),
              MenuTile(
                icon: CupertinoIcons.location_fill,
                color: const Color(0xFF0A84FF),
                title: 'Location',
                summary: s.lipEnabled ? (s.lipDestination > 0 ? tr('Every {0} s to {1}', [s.lipIntervalSeconds, s.lipDestination]) : tr('Every {0} s', [s.lipIntervalSeconds])) : 'Off',
                page: const LocationSettings(),
              ),
              MenuTile(
                icon: CupertinoIcons.person_2_fill,
                color: const Color(0xFF8E8E93),
                title: 'Callsign database',
                summary: radioIdStatus(m),
                page: const DatabaseSettings(),
              ),
            ]),
            if (m.multiNetwork)
              Section(
                header: 'Linked networks',
                footer: 'This server links networks (Multi Network). Groups of other networks are set per talkgroup.',
                children: [
                  for (final n in m.networks)
                    Tile(
                      title: n.name,
                      subtitle: n.mni,
                      trailing: n.own ? null : Text(tr(n.up ? 'linked' : 'offline'), style: TextStyle(color: n.up ? Tokens.online : scheme.outline)),
                    ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Tokens.gutter, 16, Tokens.gutter, 8),
              child: DefaultTextStyle.merge(
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.outline, fontSize: 12, height: 1.5),
                child: Column(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.asset('assets/icon/app_icon_small.png', width: 48, height: 48, semanticLabel: 'TETRA Terminal'),
                  ),
                  const SizedBox(height: 8),
                  Text('TETRA Terminal v$appVersion · © 2026', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  const Credit(role: 'Creator', name: 'ysamouhos', github: 'ysamouhos'),
                  const SizedBox(height: 10),
                  const Credit(role: 'Redesign & advanced features', name: 'sebastianmadl (OE4SXM)', github: 'sebastianmadl'),
                  const SizedBox(height: 6),
                  if (m.extensions.isNotEmpty) Text(tr('Server offers: {0}', [m.extensions.join(', ')]), style: const TextStyle(fontSize: 11)),
                  if (s.basestation && m.link != LinkState.offline)
                    Text(tr('Control channel: {0}', [m.controlOnline ? tr('connected') : m.controlError ?? tr('connecting')]), style: const TextStyle(fontSize: 11)),
                ]),
              ),
            ),
          ]),
        ),
      ],
    );
  }
}

/// A row of the settings menu: icon, title, what is set right now.
class MenuTile extends StatelessWidget {
  const MenuTile({super.key, required this.icon, required this.color, required this.title, required this.summary, required this.page});
  final IconData icon;
  final Color color;
  final String title;
  final String summary;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return Tile(
      title: title,
      subtitle: summary,
      leading: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
      trailing: isApple(context) ? null : Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
      onTap: () => Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => page)),
    );
  }
}

/// Frame of a settings page. When the page is left the settings are stored
/// and put to work; what the server has to know (see [_serverKey]) reconnects.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.title, required this.builder, this.inputs = false});
  final String title;
  final List<Widget> Function(BuildContext context, TerminalModel m, Settings s, void Function(VoidCallback) set) builder;

  /// The page sets hardware keys: they are set up again when it is left.
  final bool inputs;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _before;

  static String _serverKey(Settings s) => '${s.defaultPriority}/${s.allowPreemption}/${s.txBufferMs}/${s.lipEnabled}/${s.lipDestination}/${s.lipIntervalSeconds}';

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final s = m.settings;
    _before ??= _serverKey(s);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) m.settingsEdited(reconnect: _serverKey(s) != _before, inputs: widget.inputs);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(tr(widget.title))),
        body: ListView(children: widget.builder(context, m, s, setState)),
      ),
    );
  }
}

class RadioSettings extends StatelessWidget {
  const RadioSettings({super.key});
  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Radio',
        builder: (context, m, s, set) => [
          Section(header: 'Push to talk', children: [
            LabeledSegments<bool>(
              label: 'PTT button',
              items: const {false: 'Hold to talk', true: 'Toggle'},
              value: s.pttToggle,
              onChanged: m.setPttToggle,
            ),
            if (s.pttToggle)
              LabeledSegments<int>(
                label: 'Toggle mode stops after',
                items: pttAutoStopChoices,
                value: pttAutoStopChoices.containsKey(s.pttAutoStopSeconds) ? s.pttAutoStopSeconds : 60,
                onChanged: m.setPttAutoStop,
              ),
          ]),
          Section(header: 'Priority', footer: 'Changing the priority reconnects when you leave this page.', children: [
            SliderRow(
              title: 'Default priority',
              valueLabel: 'P${s.defaultPriority}',
              value: s.defaultPriority.toDouble(),
              min: 0,
              max: 11,
              divisions: 11,
              onChanged: (v) => set(() => s.defaultPriority = v.round()),
            ),
            SwitchRow(
                title: 'Allow pre-emption',
                subtitle: 'Calls of priority 12–15 may interrupt lower calls',
                value: s.allowPreemption,
                onChanged: (v) => set(() => s.allowPreemption = v)),
          ]),
          Section(
              header: 'Scan',
              footer: 'After a call on a scanned group the radio stays there this long, and PTT answers on that group. Which groups are scanned is set under Contacts › Groups.',
              children: [
                SliderRow(
                  title: 'Scan hold time',
                  valueLabel: s.scanHoldSeconds == 0 ? 'Off' : '${s.scanHoldSeconds} s',
                  value: s.scanHoldSeconds.toDouble(),
                  min: 0,
                  max: 60,
                  divisions: 12,
                  onChanged: (v) => set(() => s.scanHoldSeconds = v.round()),
                ),
              ]),
        ],
      );
}

class CallSettings extends StatelessWidget {
  const CallSettings({super.key});
  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Calls and background',
        builder: (context, m, s, set) => [
          Section(header: 'Incoming private calls', children: [
            SwitchRow(
              title: 'Ring on incoming calls',
              subtitle: isApple(context)
                  ? 'On the iPhone call screen, also when locked, with Accept and Decline'
                  : 'Rings and opens full screen over the lock screen, with Answer and Decline',
              value: s.ringIncoming,
              onChanged: (v) async {
                if (v && _android) await Permission.notification.request();
                set(() => s.ringIncoming = v);
              },
            ),
            if (isApple(context) && s.ringIncoming)
              Tile(
                title: 'Ring tone',
                subtitle: CallAlert.bundledRingtones[s.ringtoneUri] ?? 'Ring tone of the iPhone',
                onTap: () async {
                  final found = await m.callAlert.ringtones();
                  if (!context.mounted) return;
                  final picked = await showActions<String>(context, title: 'Ring tone', actions: [
                    const SheetAction('Ring tone of the iPhone', ''),
                    for (final f in found) SheetAction(CallAlert.bundledRingtones[f]!, f),
                  ]);
                  if (picked == null) return;
                  set(() {
                    s.ringtoneUri = picked.isEmpty ? null : picked;
                    s.ringtoneName = CallAlert.bundledRingtones[picked];
                  });
                  unawaited(m.callAlert.preview(s.ringtoneUri));
                },
              ),
            if (!isApple(context) && s.ringIncoming)
              Tile(
                title: 'Ring tone',
                subtitle: s.ringtoneName ?? 'Ring tone of the phone',
                onTap: () async {
                  try {
                    final picked = await m.callAlert.pickRingtone(s.ringtoneUri);
                    if (picked == null) return;
                    set(() {
                      s.ringtoneUri = picked.uri;
                      s.ringtoneName = picked.title;
                    });
                  } on PlatformException catch (e) {
                    m.toast = tr(e.message ?? 'No ring tone picker on this device');
                    m.notifyListeners();
                  } on MissingPluginException {
                    // not on this platform
                  }
                },
              ),
          ]),
          Section(
            header: 'Background',
            footer: isApple(context)
                ? 'In the background the app keeps a silent audio stream open so calls still come in with the screen locked. Uses some battery.'
                : 'The live notification keeps the app running in the background, so calls still come in with the screen locked.',
            children: [
              if (isApple(context))
                SwitchRow(
                  title: 'Live Activity',
                  subtitle: 'Group, talker and time on the Lock Screen and in the Dynamic Island',
                  value: s.liveActivity,
                  onChanged: m.setLiveActivity,
                )
              else
                SwitchRow(
                  title: 'Live notification',
                  subtitle: 'Group, talker and time in the status bar and on the lock screen',
                  value: s.liveActivity,
                  onChanged: (v) async {
                    if (v && _android) await Permission.notification.request();
                    await m.setLiveActivity(v);
                  },
                ),
              SwitchRow(title: 'Run in the background', value: s.backgroundAudio, onChanged: (v) => set(() => s.backgroundAudio = v)),
            ],
          ),
        ],
      );
}

class AudioSettings extends StatelessWidget {
  const AudioSettings({super.key});
  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Audio',
        builder: (context, m, s, set) => [
          Section(
            header: 'Microphone',
            footer:
                'Automatic brings your speech to the right level by itself, the trim shifts it a little. Manual uses the gain you set and nothing else. Check your level before you go on air, on a parrot group or with a second radio on the same talkgroup, so that you do not overdrive.',
            children: [
              LabeledSegments<bool>(
                label: 'Microphone level',
                items: const {true: 'Automatic', false: 'Manual'},
                value: s.micAuto,
                onChanged: (v) {
                  // The trim range of the automatic is narrower than the manual one.
                  set(() {
                    s.micAuto = v;
                    if (v) s.micGainDb = s.micGainDb.clamp(-12, 12);
                  });
                  m.audio.txAutoLevel = v;
                  m.audio.micGainDb = s.micGainDb;
                },
              ),
              SliderRow(
                title: s.micAuto ? 'Mic trim' : 'Mic gain',
                valueLabel: '${s.micGainDb >= 0 ? '+' : ''}${s.micGainDb.round()} dB',
                value: s.micGainDb.clamp(-12, s.micAuto ? 12 : 24).toDouble(),
                min: -12,
                max: s.micAuto ? 12 : 24,
                divisions: s.micAuto ? 24 : 36,
                onChanged: (v) {
                  set(() => s.micGainDb = v);
                  m.audio.micGainDb = v; // live: takes effect on the next transmission
                },
              ),
              SwitchRow(
                title: 'Noise suppression',
                subtitle: 'Turns down background noise in your transmissions',
                value: s.noiseSuppression,
                onChanged: (v) {
                  set(() => s.noiseSuppression = v);
                  m.audio.noiseSuppression = v; // from the next transmission
                },
              ),
            ],
          ),
          Section(header: 'Loudspeaker', children: [
            Tile(
              title: 'Receive audio',
              subtitle: 'Volume boost, level control, maximum level, test tone',
              trailing: isApple(context) ? null : Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
              onTap: () => Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => const RxAudioScreen())),
            ),
          ]),
          Section(
            header: 'Advanced',
            footer: 'A larger transmit buffer delays your speech but bridges gaps on a shaky connection. Changing it reconnects when you leave this page.',
            children: [
              SliderRow(
                title: 'Transmit buffer',
                valueLabel: '${s.txBufferMs} ms',
                value: s.txBufferMs.toDouble(),
                min: 180,
                max: 1020,
                divisions: 14,
                onChanged: (v) => set(() => s.txBufferMs = v.round()),
              ),
              SwitchRow(
                title: 'Record my transmissions',
                subtitle: isApple(context) ? 'Diagnostics: WAV files in Files › On My iPhone › TETRA Terminal' : 'Diagnostics: WAV files in the app folder',
                value: s.txCapture,
                onChanged: (v) {
                  set(() => s.txCapture = v);
                  m.audio.captureTx = v;
                },
              ),
            ],
          ),
        ],
      );
}

class DisplaySettings extends StatelessWidget {
  const DisplaySettings({super.key});
  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Display',
        builder: (context, m, s, set) => [
          Section(header: 'Language', children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 10),
              child: SizedBox(
                width: double.infinity,
                child: Segments<String>(items: L.choices, value: s.language ?? 'system', onChanged: m.setLanguage),
              ),
            ),
          ]),
          Section(header: 'Appearance', children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 10),
              child: SizedBox(
                width: double.infinity,
                child: Segments<String>(
                  items: const {'system': 'Automatic', 'light': 'Light', 'dark': 'Dark'},
                  value: s.appearance,
                  onChanged: m.setAppearance,
                ),
              ),
            ),
          ]),
          Section(header: 'Buttons on the radio screen', footer: 'Hide what you do not need, for example on a radio with its own PTT key.', children: [
            SwitchRow(title: 'PTT button', value: s.showPttButton, onChanged: (v) => set(() => s.showPttButton = v)),
            SwitchRow(title: 'SOS button', value: s.showSosButton, onChanged: (v) => set(() => s.showSosButton = v)),
            SwitchRow(
                title: 'Loudspeaker button',
                subtitle: 'Switches between loudspeaker and earpiece',
                value: s.showSpeakerButton,
                onChanged: (v) => set(() => s.showSpeakerButton = v)),
          ]),
        ],
      );
}

class LocationSettings extends StatelessWidget {
  const LocationSettings({super.key});
  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Location',
        builder: (context, m, s, set) => [
          Section(header: 'Location reports (LIP)', footer: 'Sends your position to the ISSI below, for example a dispatcher.', children: [
            SwitchRow(title: 'Send location reports', value: s.lipEnabled, onChanged: (v) => set(() => s.lipEnabled = v)),
            if (s.lipEnabled) ...[
              FieldRow(label: 'Send to ISSI', initial: s.lipDestination == 0 ? '' : '${s.lipDestination}', number: true, onChanged: (v) => s.lipDestination = int.tryParse(v) ?? 0),
              FieldRow(label: 'Every (s)', initial: '${s.lipIntervalSeconds}', number: true, onChanged: (v) => s.lipIntervalSeconds = (int.tryParse(v) ?? 60).clamp(10, 3600)),
              SwitchRow(title: 'Also send on PTT', value: s.lipOnPtt, onChanged: (v) => set(() => s.lipOnPtt = v)),
            ],
          ]),
          if (s.lipEnabled)
            Section(children: [
              Tile(title: 'Send position now', leading: Icon(CupertinoIcons.location_fill, color: Theme.of(context).colorScheme.primary), onTap: m.sendLocationNow),
            ]),
        ],
      );
}

class DatabaseSettings extends StatelessWidget {
  const DatabaseSettings({super.key});
  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Callsign database',
        builder: (context, m, s, set) => [
          Section(
            footer: m.contacts.radioIdError ?? 'Callsigns for ISSIs from RadioID.net (DMR IDs, as used on ham TETRA networks). Your own contacts always come first.',
            children: [
              Tile(
                title: 'RadioID.net',
                subtitle: radioIdStatus(m),
                trailing: m.contacts.updating
                    ? const Padding(padding: EdgeInsets.only(right: 8), child: CupertinoActivityIndicator())
                    : TextButton(onPressed: m.contacts.updateRadioId, child: const Tx('Update now')),
              ),
              SwitchRow(title: 'Update weekly', subtitle: 'In the background, when the app starts', value: m.contacts.radioIdAuto, onChanged: m.contacts.setRadioIdAuto),
            ],
          ),
        ],
      );
}

String radioIdStatus(TerminalModel m) {
  final c = m.contacts;
  if (c.updating) return tr('Downloading…');
  if (c.radioIdCount == 0) return tr('Not loaded');
  final n = c.radioIdCount.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final t = c.radioIdUpdated;
  if (t == null) return '$n IDs';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '$n IDs · ${tr('updated')} ${t.day}${L.current == 'de' ? '.' : ''} ${tr(months[t.month - 1])}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Android: hardware PTT key, knob and LED of PoC radios, Bluetooth PTT headset.
class HardwareSettings extends StatefulWidget {
  const HardwareSettings({super.key});
  @override
  State<HardwareSettings> createState() => _HardwareSettingsState();
}

class _HardwareSettingsState extends State<HardwareSettings> {
  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Keys and accessories',
        inputs: true,
        builder: (context, m, s, set) => [
          Section(
            header: 'Radio with keys (PoC devices)',
            footer: tr(
                'For Android radios with a hardware PTT key or a channel knob. Pick your device, or Custom to set the keys '
                'yourself: tap a key row and press the key to teach it. Some radios send a broadcast for PTT instead; '
                'enter its "down" action, the "up" action is derived. Automation apps can send '
                '{0} / {1}. On Hytera radios the status LED shows transmit and receive.',
                [PocPtt.ownDownAction, PocPtt.ownUpAction]),
            children: [
              SwitchRow(
                title: 'Use hardware PTT and knob',
                value: s.pocPttEnabled,
                onChanged: (v) => set(() => s.pocPttEnabled = v),
              ),
              if (s.pocPttEnabled) ...[
                Tile(
                  title: 'Device',
                  subtitle: s.pocCustom ? 'Set the keys below' : 'PTT key, knob and LED are set',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(tr(PocProfile.nameOf(s.pocProfile)), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    Icon(Icons.arrow_drop_down, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ]),
                  onTap: () async {
                    final id = await showActions<String>(context, title: 'Device', actions: [
                      for (final p in PocProfile.all) SheetAction(p.name, p.id),
                      const SheetAction('Custom', PocProfile.customId),
                    ]);
                    if (id != null && mounted) set(() => s.setPocProfile(id));
                  },
                ),
                if (s.pocCustom) ...[
                  Tile(
                    title: 'PTT key',
                    subtitle: _keyLabel(s.pocPttKeyCode),
                    onTap: () => _teachKey(m, 'PTT key', (c) => s.pocPttKeyCode = c),
                  ),
                  FieldRow(
                    label: 'PTT broadcast',
                    initial: s.pocPttDownAction,
                    hint: 'e.g. com.example.ptt.down',
                    keyboard: TextInputType.url,
                    onChanged: (v) => set(() => s.pocPttDownAction = v.trim()),
                  ),
                  if (s.pocPttDownAction.isNotEmpty) Tile(title: 'Release broadcast', subtitle: deriveUpAction(s.pocPttDownAction) ?? 'Needs "down" in the action'),
                  Tile(
                    title: 'Knob: next talkgroup',
                    subtitle: _keyLabel(s.knobNextKey),
                    onTap: () => _teachKey(m, 'Knob: next talkgroup', (c) => s.knobNextKey = c),
                  ),
                  Tile(
                    title: 'Knob: previous talkgroup',
                    subtitle: _keyLabel(s.knobPrevKey),
                    onTap: () => _teachKey(m, 'Knob: previous talkgroup', (c) => s.knobPrevKey = c),
                  ),
                ],
                SwitchRow(
                  title: 'Announce talkgroup',
                  subtitle: 'Speaks the group name when you turn the knob, in the device language',
                  value: s.announceGroup,
                  onChanged: (v) => set(() => s.announceGroup = v),
                ),
                SwitchRow(
                  title: 'Wake screen and open the app on PTT',
                  value: s.pocPttWake,
                  onChanged: (v) => set(() => s.pocPttWake = v),
                ),
                FutureBuilder<List<bool>>(
                  future: Future.wait([PocPtt.keyServiceAvailable(), PocPtt.keyServiceEnabled()]),
                  builder: (context, snap) {
                    final available = snap.data?[0] ?? true, on = snap.data?[1] ?? false;
                    if (!available) {
                      return const Tile(
                        title: 'Keys in the background',
                        subtitle: 'Not in this version. Install the "-poc" version of the app for keys with the screen locked',
                      );
                    }
                    return Tile(
                      title: 'Keys in the background',
                      subtitle: on
                          ? 'On: keys also work with the app closed or the screen locked'
                          : 'Off: keys only work while the app is open. Tap and switch on "TETRA Terminal PTT key" in Accessibility',
                      onTap: () async {
                        await PocPtt.openKeyServiceSettings();
                        if (mounted) setState(() {});
                      },
                    );
                  },
                ),
                FutureBuilder<String?>(
                  future: PocPtt.lastSeen(),
                  builder: (context, snap) => Tile(
                    title: 'Last key seen',
                    subtitle: snap.data ?? 'Nothing yet. Press a key or turn the knob, then tap here',
                    onTap: () => setState(() {}),
                  ),
                ),
              ],
            ],
          ),
          Section(header: 'Bluetooth PTT headset', children: [
            SwitchRow(
              title: 'Use Savox BTH-101 PTT',
              subtitle: m.pttDeviceStatus ?? 'Pair the headset in Android Bluetooth settings first (PIN 0000)',
              value: s.headsetEnabled,
              onChanged: (v) async {
                if (v) await Permission.bluetoothConnect.request();
                set(() => s.headsetEnabled = v);
              },
            ),
            if (s.headsetEnabled) FieldRow(label: 'Address', initial: s.headsetAddress, hint: 'Empty = first paired Savox', onChanged: (v) => s.headsetAddress = v.trim()),
          ]),
        ],
      );

  static String _keyLabel(int code) => code == 0 ? tr('None. Tap, then press a key to set one') : tr('Key code {0}', [code]);

  /// Waits for one hardware key press and stores its code via [set].
  Future<void> _teachKey(TerminalModel m, String title, void Function(int code) set) async {
    var cancelled = false;
    final dialog = showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(title)),
        content: const Tx('Press the key on your radio now…'),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              m.cancelPocPttLearn();
              set(0);
              Navigator.pop(ctx);
            },
            child: const Tx('Remove'),
          ),
          TextButton(
            onPressed: () {
              cancelled = true;
              m.cancelPocPttLearn();
              Navigator.pop(ctx);
            },
            child: const Tx('Cancel'),
          ),
        ],
      ),
    );
    // Dismissing the dialog (back gesture, tap outside) also stops learning.
    unawaited(dialog.then((_) {
      cancelled = true;
      m.cancelPocPttLearn();
    }));
    final code = await m.learnPocPttKey();
    if (!mounted) return;
    if (!cancelled) {
      cancelled = true;
      Navigator.of(context).pop();
      if (code != null) set(code);
    }
    setState(() {});
  }
}

/// Role, name and the GitHub profile link below. The link keeps the text colour
/// (black in light, white in dark mode) and is only underlined.
class Credit extends StatelessWidget {
  const Credit({super.key, required this.role, required this.name, required this.github});
  final String role;
  final String name;
  final String github;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = 'https://github.com/$github';
    return Column(children: [
      Text(tr(role).toUpperCase(), style: TextStyle(color: scheme.outline, fontSize: 10.5, letterSpacing: .6, fontWeight: FontWeight.w600)),
      Text(name, style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
      Semantics(
        link: true,
        label: 'GitHub profile of $github',
        child: GestureDetector(
          onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Text('github.com/$github', style: TextStyle(color: scheme.onSurface, decoration: TextDecoration.underline, decorationColor: scheme.onSurface)),
        ),
      ),
    ]);
  }
}

/// Receive audio: boost, automatic level with its target, the maximum level,
/// and a test tone to set them without waiting for a call.
class RxAudioScreen extends StatefulWidget {
  const RxAudioScreen({super.key});
  @override
  State<RxAudioScreen> createState() => _RxAudioScreenState();
}

class _RxAudioScreenState extends State<RxAudioScreen> {
  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final s = m.settings;
    final scheme = Theme.of(context).colorScheme;
    String db(double v) => '${v > 0 ? '+' : ''}${v.round()} dB';
    return Scaffold(
      appBar: AppBar(title: const Tx('Receive audio')),
      body: ListView(children: [
        Section(header: 'Volume', footer: 'Raises what you hear on top of the device volume.', children: [
          SliderRow(
            title: 'Boost',
            valueLabel: db(s.rxGainDb),
            value: s.rxGainDb,
            min: 0,
            max: 18,
            divisions: 18,
            onChanged: (v) {
              setState(() => s.rxGainDb = v);
              m.audio.rxGainDb = v;
            },
          ),
        ]),
        Section(header: 'Automatic', footer: 'The level control brings quiet and loud talkers to the target level. The maximum level limits peaks, with or without it.', children: [
          SwitchRow(
            title: 'Level control (AGC)',
            subtitle: 'Quiet and loud talkers play at the same level',
            value: s.rxLevel,
            onChanged: (v) {
              setState(() => s.rxLevel = v);
              m.audio.rxLevel = v;
              s.save();
            },
          ),
          if (s.rxLevel)
            SliderRow(
              title: 'Target level',
              valueLabel: db(s.rxTargetDb),
              value: s.rxTargetDb,
              min: -30,
              max: -9,
              divisions: 21,
              onChanged: (v) {
                setState(() => s.rxTargetDb = v);
                m.audio.rxTargetDb = v;
              },
            ),
          SliderRow(
            title: 'Maximum level',
            valueLabel: db(s.rxMaxDb),
            value: s.rxMaxDb,
            min: -12,
            max: 0,
            divisions: 12,
            onChanged: (v) {
              setState(() => s.rxMaxDb = v);
              m.audio.rxMaxDb = v;
            },
          ),
        ]),
        Section(header: 'Test', footer: '1 kHz at -12 dB for two seconds, through the settings above like a received call.', children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Tokens.gutter, 16, Tokens.gutter, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LevelBar(label: 'RX', meter: m.audio.rxMeter),
              const SizedBox(height: 14),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: scheme.primary, minimumSize: const Size.fromHeight(46)),
                onPressed: () {
                  s.save();
                  m.audio.playTestTone();
                },
                child: const Tx('Play test tone'),
              ),
            ]),
          ),
        ]),
      ]),
    );
  }

  @override
  void deactivate() {
    context.read<TerminalModel>().settings.save();
    super.deactivate();
  }
}
