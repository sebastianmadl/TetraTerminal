import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../model/settings.dart';
import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/theme.dart';
import 'home_screen.dart';
import 'profile_sheet.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  late Settings s;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      s = context.read<TerminalModel>().settings;
      _loaded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;

    return Form(
      key: _form,
      child: TabPage(
        title: 'Settings',
        actions: [
          TextButton(
            onPressed: () async {
              if (!_form.currentState!.validate()) return;
              _form.currentState!.save();
              await m.applySettings(s);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
            },
            child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
        slivers: [
          SliverToBoxAdapter(
            // A Column keeps every field alive (a lazy list disposes off-screen ones).
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Section(
                header: 'Connections',
                footer: m.lastError ?? 'Tap a connection to switch to it. Server, ISSI and home network are set per connection.',
                children: [
                  for (final p in s.profiles) ProfileRow(key: ValueKey(p.id), m: m, p: p),
                  Tile(
                    title: 'Add connection',
                    leading: Icon(CupertinoIcons.add_circled_solid, color: scheme.primary),
                    onTap: () => editProfile(context, m, null),
                  ),
                ],
              ),
              const Section(children: [Tile(title: 'Status', trailing: LinkPill())]),
              Section(header: 'Radio', children: [
                SliderRow(
                  title: 'Default priority',
                  valueLabel: 'P${s.defaultPriority}',
                  value: s.defaultPriority.toDouble(),
                  min: 0,
                  max: 11,
                  divisions: 11,
                  onChanged: (v) => setState(() => s.defaultPriority = v.round()),
                ),
                SwitchRow(title: 'Allow pre-emption', subtitle: 'Calls of priority 12–15 may interrupt lower calls', value: s.allowPreemption, onChanged: (v) => setState(() => s.allowPreemption = v)),
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
                        trailing: n.own ? null : Text(n.up ? 'linked' : 'offline', style: TextStyle(color: n.up ? Tokens.online : scheme.outline)),
                      ),
                  ],
                ),
              Section(
                header: 'Contacts database',
                footer: m.contacts.radioIdError ??
                    'Callsigns for ISSIs from RadioID.net (DMR IDs, as used on ham TETRA networks). Your own contacts always come first.',
                children: [
                  Tile(
                    title: 'RadioID.net',
                    subtitle: _radioIdStatus(m),
                    trailing: m.contacts.updating
                        ? const Padding(padding: EdgeInsets.only(right: 8), child: CupertinoActivityIndicator())
                        : TextButton(onPressed: m.contacts.updateRadioId, child: const Text('Update now')),
                  ),
                  SwitchRow(title: 'Update weekly', subtitle: 'In the background, when the app starts', value: m.contacts.radioIdAuto, onChanged: m.contacts.setRadioIdAuto),
                ],
              ),
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
                if (isApple(context))
                  SwitchRow(
                    title: 'Live Activity',
                    subtitle: 'Group, talker and time on the Lock Screen and in the Dynamic Island',
                    value: s.liveActivity,
                    onChanged: m.setLiveActivity,
                  ),
              ]),
              Section(header: 'Audio', footer: 'In the background the app keeps a silent audio stream open so calls still come in with the screen locked. Uses some battery.', children: [
                SwitchRow(title: 'Run in the background', value: s.backgroundAudio, onChanged: (v) => setState(() => s.backgroundAudio = v)),
                SliderRow(
                  title: 'Mic gain',
                  valueLabel: '${s.micGainDb >= 0 ? '+' : ''}${s.micGainDb.round()} dB',
                  value: s.micGainDb,
                  min: -12,
                  max: 12,
                  divisions: 24,
                  onChanged: (v) {
                    setState(() => s.micGainDb = v);
                    m.audio.micGainDb = v; // live: takes effect on the next transmission
                  },
                ),
              ]),
              if (Platform.isAndroid)
                Section(header: 'Bluetooth PTT headset', children: [
                  SwitchRow(
                    title: 'Use Savox BTH-101 PTT',
                    subtitle: m.pttDeviceStatus ?? 'Pair the headset in Android Bluetooth settings first (PIN 0000)',
                    value: s.headsetEnabled,
                    onChanged: (v) async {
                      if (v) await Permission.bluetoothConnect.request();
                      setState(() => s.headsetEnabled = v);
                    },
                  ),
                  if (s.headsetEnabled)
                    FieldRow(label: 'Address', initial: s.headsetAddress, hint: 'Empty = first paired Savox', onChanged: (v) => s.headsetAddress = v.trim()),
                ]),
              Section(header: 'Location (LIP)', children: [
                SwitchRow(title: 'Send location reports', value: s.lipEnabled, onChanged: (v) => setState(() => s.lipEnabled = v)),
                if (s.lipEnabled) ...[
                  FieldRow(label: 'Send to ISSI', initial: s.lipDestination == 0 ? '' : '${s.lipDestination}', number: true, onChanged: (v) => s.lipDestination = int.tryParse(v) ?? 0),
                  FieldRow(label: 'Every (s)', initial: '${s.lipIntervalSeconds}', number: true, onChanged: (v) => s.lipIntervalSeconds = (int.tryParse(v) ?? 60).clamp(10, 3600)),
                  SwitchRow(title: 'Also send on PTT', value: s.lipOnPtt, onChanged: (v) => setState(() => s.lipOnPtt = v)),
                  Tile(title: 'Send position now', leading: Icon(CupertinoIcons.location_fill, color: scheme.primary), onTap: m.sendLocationNow),
                ],
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(Tokens.gutter, 8, Tokens.gutter, 0),
                child: Text('TETRA Terminal · Brew v1 terminal${m.extensions.isEmpty ? '' : ' · server offers: ${m.extensions.join(', ')}'}',
                    textAlign: TextAlign.center, style: TextStyle(color: scheme.outline, fontSize: 12)),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  String _radioIdStatus(TerminalModel m) {
    final c = m.contacts;
    if (c.updating) return 'Downloading…';
    if (c.radioIdCount == 0) return 'Not loaded';
    final n = c.radioIdCount.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final t = c.radioIdUpdated;
    if (t == null) return '$n IDs';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '$n IDs · updated ${t.day} ${months[t.month - 1]}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
