import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:poc_ptt/poc_ptt.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/audio_io.dart';
import '../services/call_alert.dart';
import '../services/live_status.dart';
import '../ui/l10n.dart';
import '../services/location_service.dart';
import '../services/ptt_input.dart';
import '../services/tx_capture_store.dart';
import '../src/rust/api.dart';
import 'contacts.dart';
import 'settings.dart';

enum LinkState { offline, connecting, online }

class GroupCallState {
  GroupCallState(this.gssi, this.talker, this.talkerName, this.priority, this.callId, {DateTime? since}) : since = since ?? DateTime.now();
  final int gssi;
  /// When the talker started (for the "talking for 0:12" timer).
  final DateTime since;
  final int talker;
  final String? talkerName;
  final int priority;
  final String callId;
  bool get emergency => priority >= 15;
}

/// What the server lets this terminal do on a group (`group-access`).
enum GroupAccess { open, listen, refused }

enum MsgStatus { sending, sent, networkAccepted, delivered, failed, received }

class ChatMessage {
  ChatMessage({required this.peer, required this.outgoing, required this.text, required this.status, this.localId, this.immediate = false, DateTime? time})
      : time = time ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'p': peer,
        'o': outgoing,
        'x': text,
        's': status.name,
        't': time.millisecondsSinceEpoch,
        if (immediate) 'i': true,
        if (unread) 'u': true,
      };

  /// A stored message. One that was still being sent when the app closed
  /// never got its answer: it shows as failed.
  static ChatMessage fromJson(Map<String, dynamic> j) {
    final status = MsgStatus.values.firstWhere((v) => v.name == j['s'], orElse: () => MsgStatus.received);
    return ChatMessage(
      peer: j['p'] as int,
      outgoing: j['o'] as bool? ?? false,
      text: j['x'] as String? ?? '',
      status: status == MsgStatus.sending ? MsgStatus.failed : status,
      immediate: j['i'] as bool? ?? false,
      time: DateTime.fromMillisecondsSinceEpoch(j['t'] as int? ?? 0),
    )..unread = j['u'] as bool? ?? false;
  }

  final int peer; // ISSI or GSSI of the conversation
  final bool outgoing;
  final String text;
  final bool immediate;
  final int? localId;
  MsgStatus status;
  final DateTime time;

  /// A received message the user has not seen in its conversation yet.
  bool unread = false;
}

/// A network the server links to (Multi Network, `SERVICE_NETWORKS`).
class LinkedNetwork {
  const LinkedNetwork(this.mcc, this.mnc, this.name, {this.up = true, this.own = false});
  final int mcc;
  final int mnc;
  final String name;
  final bool up;
  /// The server's own network.
  final bool own;
  String get mni => '$mcc-$mnc';
}

class RemoteLocation {
  RemoteLocation(this.issi, this.location, this.reason) : time = DateTime.now();
  final int issi;
  final LocationInfo location;
  final int? reason;
  final DateTime time;
}

/// App-wide state over the Rust `TetraClient`.
class TerminalModel extends ChangeNotifier with WidgetsBindingObserver {
  TerminalModel(this.settings);

  Settings settings;
  final audio = AudioIO();
  final live = LiveStatus();
  final callAlert = CallAlert();
  /// Muted on the system call screen (iOS) during a full-duplex call.
  bool _callMuted = false;
  final contacts = ContactBook();
  final callLog = CallLog();
  /// Open call log entries by call id, to set the duration when they end.
  final Map<String, CallLogEntry> _openLog = {};
  DateTime? _privateConnectedAt;

  /// Name to show for an ISSI (own contact, name sent by the radio, RadioID).
  String nameOf(int issi, {String? sentName}) => contacts.display(issi, sentName: sentName);
  late final location = LocationService((loc, reason) => _client?.sendLocation(to: settings.lipDestination, location: loc, reason: reason));

  TetraClient? _client;

  /// Basestation control channel (Basestation login mode only): DGNA.
  TetraControl? _control;
  bool controlOnline = false;
  String? controlError;
  LinkState link = LinkState.offline;
  String? lastError;

  /// The user wants to be online (connected and not disconnected by hand).
  bool _wantOnline = false;

  /// Brew extensions the server offered on the current connection.
  List<String> extensions = const [];
  bool get multiNetwork => extensions.contains('mni');

  /// Group access from the server (`group-access`): groups that are not open
  /// to us, and with managed talkgroups the listed ones (null = not managed).
  Map<int, GroupAccess> groupAccess = const {};
  Set<int>? managedGroups;

  GroupAccess accessOf(Talkgroup t) {
    final a = groupAccess[t.gssi];
    if (a != null) return a;
    // Managed talkgroups: groups of another network are not checked against the list.
    if (managedGroups != null && !t.otherNetwork && !managedGroups!.contains(t.gssi)) return GroupAccess.refused;
    return GroupAccess.open;
  }

  /// May we talk on the selected group (PTT)? Emergency calls always pass.
  bool get mayTalkOnSelected {
    final g = _scanTalkGssi ?? settings.selectedGssi;
    final t = settings.talkgroups.where((t) => t.gssi == g).firstOrNull;
    return t == null || accessOf(t) == GroupAccess.open;
  }

  /// Multi Network: the server's own network first, then the linked ones.
  List<LinkedNetwork> networks = const [];

  String networkName(int mcc, int mnc) {
    if (mcc == 0 && mnc == 0) return tr('Home network');
    return networks.where((n) => n.mcc == mcc && n.mnc == mnc).firstOrNull?.name ?? '$mcc-$mnc';
  }

  /// Active transmissions per talkgroup.
  final Map<int, GroupCallState> groupActivity = {};
  String? myTxCallId;
  DateTime? myTxSince;
  PrivateCallInfo? privateCall;
  String? focusCallId;
  final List<ChatMessage> messages = [];
  final Map<int, RemoteLocation> locations = {};
  int _nextLocalId = 1;
  String? toast;

  PttInput? _pttInput;
  StreamSubscription<PttInputEvent>? _pttSub;
  /// Hardware PTT device status for the UI (null = none configured).
  String? pttDeviceStatus;
  bool pttDeviceConnected = false;
  int? _headsetVolume;
  bool _swallowRelease = false;

  StreamSubscription<PocPttEvent>? _pocSub;
  bool _pocLearning = false;

  bool get transmitting => myTxCallId != null;

  @override
  void notifyListeners() {
    super.notifyListeners();
    // The widget always gets the status; the Live Activity runs while `live`.
    live.update(liveStatus());
    _updateLed();
  }

  String _led = 'off';

  /// Status LED of a PoC radio: red while we transmit, green while we hear
  /// someone (the radio's own colours; Hytera firmware only, see poc_ptt).
  void _updateLed() {
    if (!PocPtt.supported) return;
    final want = !settings.pocPttEnabled ? 'off' : (transmitting ? 'tx' : (heard != null || privateCall?.state == 'connected' ? 'rx' : 'off'));
    if (want == _led) return;
    _led = want;
    unawaited(PocPtt.led(want));
  }

  String? _lastTalker;
  DateTime? _lastTalkerAt;

  /// What the Live Activity and the home screen widget show. Times are
  /// milliseconds since the epoch; `live` says whether the Live Activity runs.
  Map<String, Object?> liveStatus() {
    final selected = settings.talkgroups.where((t) => t.gssi == settings.selectedGssi).firstOrNull;
    final call = transmitting
        ? null
        : heard ?? groupActivity[settings.selectedGssi] ?? groupActivity.values.firstOrNull;
    final talker = transmitting ? tr('You') : (call == null ? null : nameOf(call.talker, sentName: call.talkerName));
    final since = transmitting ? myTxSince : call?.since;
    if (talker != null && !transmitting) {
      _lastTalker = talker;
      _lastTalkerAt = since;
    }
    return {
      'live': _wantOnline && settings.liveActivity,
      'online': link == LinkState.online,
      'profile': settings.active.displayName,
      'server': settings.active.displayName,
      'group': call != null ? _groupName(call.gssi) : (selected?.name ?? (settings.selectedGssi != null ? 'TG ${settings.selectedGssi}' : tr('No talkgroup'))),
      'talker': talker,
      'talkerSince': talker == null ? null : since?.millisecondsSinceEpoch,
      'transmitting': transmitting,
      'emergency': call?.emergency ?? false,
      'lastTalker': _lastTalker,
      'lastTalkerAt': _lastTalkerAt?.millisecondsSinceEpoch,
      'ownName': settings.name.trim().isEmpty ? null : settings.name.trim(),
      'ownIssi': settings.issi > 0 ? settings.issi : null,
      'canTalk': link == LinkState.online && (privateCall != null || (settings.selectedGssi != null && mayTalkOnSelected)),
      'txEndsAt': latchedTxEndsAt?.millisecondsSinceEpoch,
    };
  }
  int? get selectedGssi => settings.selectedGssi;

  /// The talker currently heard, for the status banner.
  GroupCallState? get heard => groupActivity.values.where((g) => g.callId == focusCallId).firstOrNull;

  // Scan: the group heard last stays the active one for a while after its
  // call ended, so an answer goes to where the call was.
  int? _scanGssi;
  Timer? _scanHold;

  /// The call that ran when the user picked a group by hand: the radio stays
  /// on the picked group instead of following that call.
  String? _scanIgnoredCall;
  GroupCallState? get _scanHeard {
    final h = heard;
    return h != null && h.callId == _scanIgnoredCall ? null : h;
  }

  /// The group the radio is on right now: the one heard, the scanned group
  /// still held after its call ([Settings.scanHoldSeconds]), else the selected one.
  int? get activeGssi => _scanHeard?.gssi ?? _scanGssi ?? settings.selectedGssi;

  /// A scanned group other than the selected one that PTT would answer on.
  int? get _scanTalkGssi {
    final g = _scanHeard?.gssi ?? _scanGssi;
    return g != null && g != settings.selectedGssi && settings.talkgroups.any((t) => t.gssi == g) ? g : null;
  }

  void _trackScan() {
    final h = _scanHeard;
    if (h != null) {
      _scanHold?.cancel();
      _scanHold = null;
      _scanGssi = h.gssi;
    } else if (_scanGssi != null && _scanHold == null) {
      final secs = settings.scanHoldSeconds;
      if (secs <= 0 || _scanGssi == settings.selectedGssi) {
        _scanGssi = null;
      } else {
        _scanHold = Timer(Duration(seconds: secs), () {
          _scanHold = null;
          _scanGssi = null;
          notifyListeners();
        });
      }
    }
  }

  void _endScanHold() {
    _scanHold?.cancel();
    _scanHold = null;
    _scanGssi = null;
  }

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    callAlert
      ..onAnswer = (() => _client?.answer())
      ..onEnd = (() => _client?.hangup())
      ..onDtmf = dtmf
      ..onMute = (muted) {
        _callMuted = muted;
        _updateMic();
      }
      ..onAudio = _onCallAudio
      ..listen();
    // iOS asks once whether message notifications may be shown.
    if (settings.messageAlert && Settings.firstStartPrompts && defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(callAlert.messagePermission());
    }
    // Android 13+: the ongoing notification needs the notification permission.
    if (!kIsWeb && Platform.isAndroid && (settings.liveActivity || settings.ringIncoming)) unawaited(Permission.notification.request());
    contacts.addListener(notifyListeners);
    await contacts.load();
    await callLog.load();
    await loadMessages();
    unawaited(contacts.startRadioId());
    audio.speaker = settings.speakerOut;
    audio.captureTx = settings.txCapture;
    audio.noiseSuppression = settings.noiseSuppression;
    audio.rxLevel = settings.rxLevel;
    audio.rxGainDb = settings.rxGainDb;
    audio.rxTargetDb = settings.rxTargetDb;
    audio.rxMaxDb = settings.rxMaxDb;
    audio.onTxCapture = TxCaptureStore.save;
    await audio.init();
    audio.micGainDb = settings.micGainDb;
    audio.txAutoLevel = settings.micAuto;
    await _startPttInput();
    await _startPocPtt();
    if (settings.isConfigured) await connect();
  }

  Future<void> _startPttInput() async {
    await _stopPttInput();
    if (!settings.headsetEnabled) return;
    final input = BluetoothHeadsetPtt(address: settings.headsetAddress);
    _pttInput = input;
    pttDeviceStatus = tr('Headset connecting…');
    _pttSub = input.events.listen(_onPttInput);
    await input.start();
    notifyListeners();
  }

  /// Hardware PTT of Android PoC radios (key code and/or radio broadcast).
  Future<void> _startPocPtt() async {
    if (!PocPtt.supported) return;
    _pocSub ??= PocPtt.events.listen((e) {
      if (_pocLearning) return;
      switch (e) {
        case PocPttPress(:final pressed):
          _onPttInput(pressed ? PttPressed() : PttReleased());
        case PocPttKnob(:final step):
          stepTalkgroup(step);
        case PocPttLearned():
      }
    });
    if (!settings.pocPttEnabled) {
      await PocPtt.stop();
      return;
    }
    // A known radio needs no key codes: the plugin recognises its firmware's
    // key broadcasts by itself. Only a custom profile passes its own.
    final custom = settings.pocCustom;
    await PocPtt.configure(
      keyCode: custom ? settings.pocPttKeyCode : 0,
      downAction: custom ? settings.pocPttDownAction : '',
      wake: settings.pocPttWake,
      knobNextKey: custom ? settings.knobNextKey : 0,
      knobPrevKey: custom ? settings.knobPrevKey : 0,
    );
  }

  /// The on-screen PTT button (Android can hide it for radios with a hardware PTT).
  bool get showSoftPtt => defaultTargetPlatform != TargetPlatform.android || settings.showPttButton;

  /// Rotary knob: the next (+1) or previous (-1) talkgroup in the list, wrapping
  /// around. Not while we transmit.
  Future<void> stepTalkgroup(int step) async {
    final tgs = settings.talkgroups;
    if (tgs.isEmpty || transmitting) return;
    final i = tgs.indexWhere((t) => t.gssi == settings.selectedGssi);
    final next = tgs[((i < 0 ? 0 : i + step) % tgs.length + tgs.length) % tgs.length];
    // A bare number is read digit by digit, as on the air.
    if (settings.announceGroup) unawaited(speak(next.name.isEmpty ? '${next.gssi}'.split('').join(' ') : next.name));
    await selectGroup(next.gssi);
  }

  /// Speaks the talkgroup name (replaced in tests).
  @visibleForTesting
  Future<void> Function(String text) speak = PocPtt.speak;

  /// Moves a talkgroup to another place in the list (the knob follows this order).
  Future<void> moveTalkgroup(int from, int to) async {
    final tgs = settings.talkgroups;
    if (from < 0 || from >= tgs.length) return;
    final t = tgs.removeAt(from);
    tgs.insert(to.clamp(0, tgs.length), t);
    await saveTalkgroups();
  }

  /// Waits for the next hardware key press and returns its key code (null on
  /// timeout or [cancelPocPttLearn]). The key is not used while learning.
  Future<int?> learnPocPttKey({Duration timeout = const Duration(seconds: 15)}) async {
    if (!PocPtt.supported) return null;
    cancelPocPttLearn();
    final done = _learn = Completer<int?>();
    final sub = PocPtt.events.listen((e) {
      if (e is PocPttLearned && !done.isCompleted) done.complete(e.keyCode);
    });
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(null);
    });
    _pocLearning = true;
    try {
      await PocPtt.learn(true);
      return await done.future;
    } finally {
      timer.cancel();
      await sub.cancel();
      if (identical(_learn, done)) {
        _learn = null;
        _pocLearning = false;
        await PocPtt.learn(false);
      }
    }
  }

  Completer<int?>? _learn;

  void cancelPocPttLearn() {
    final l = _learn;
    if (l != null && !l.isCompleted) l.complete(null);
  }

  Future<void> _stopPttInput() async {
    await _pttSub?.cancel();
    _pttSub = null;
    final input = _pttInput;
    _pttInput = null;
    if (input != null) {
      await input.stop();
      if (transmitting || _releaseTimer != null) pttUp();
    }
    pttDeviceStatus = null;
    pttDeviceConnected = false;
  }

  void _onPttInput(PttInputEvent e) {
    switch (e) {
      case PttPressed():
        if (link != LinkState.online) return;
        // Ringing incoming call: the press answers it instead of keying up.
        if (privateCall?.state == 'ringing') {
          _swallowRelease = true;
          answer();
          return;
        }
        pttDown();
        return;
      case PttReleased():
        if (_swallowRelease) {
          _swallowRelease = false;
          return;
        }
        pttUp();
        return;
      case PttVolume(:final level, :final max):
        if (_headsetVolume != null && _headsetVolume != level) toast = tr('Volume {0}/{1}', [level, max]);
        _headsetVolume = level;
      case PttDeviceStatus(:final connected, :final text):
        // Announce changes, not every retry.
        if (connected != pttDeviceConnected) toast = text;
        pttDeviceConnected = connected;
        pttDeviceStatus = text;
    }
    notifyListeners();
  }

  /// Android: the ongoing notification runs a foreground service, which keeps
  /// the app alive by itself. Silence would only hold the loudspeaker amplifier
  /// open, which hisses on some radios while the screen is locked.
  bool get _serviceKeepsAlive => defaultTargetPlatform == TargetPlatform.android && settings.liveActivity;

  /// iOS suspends the app in the background unless audio keeps it alive; the
  /// socket then dies quietly. In the background we keep the audio session
  /// playing (if enabled); back in front we reconnect if the link was lost.
  /// When the app is closed for good: deregister.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        audio.keepAlive(false);
        if (_wantOnline && link == LinkState.offline && settings.isConfigured) connect();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        unawaited(saveMessages());
        // Stay reachable in the background while connected (see AudioIO.keepAlive).
        // Starts already on inactive: by the time the app is paused iOS no
        // longer lets it start playback.
        audio.keepAlive(_wantOnline && settings.backgroundAudio && !_serviceKeepsAlive);
      case AppLifecycleState.detached:
        live.end();
        if (_client != null) _client!.shutdown();
    }
  }

  List<GroupNetwork> get _groupNetworks =>
      [for (final t in settings.groupsOfOtherNetworks) GroupNetwork(gssi: t.gssi, mcc: t.mcc, mnc: t.mnc)];

  Future<void> connect() async {
    await disconnect();
    _wantOnline = true;
    final c = await TetraClient.connect(
      config: TerminalConfig(
        serverUrl: settings.serverUrl,
        username: settings.username,
        password: settings.password,
        issi: settings.issi,
        name: settings.name.isEmpty ? null : settings.name,
        groups: Uint32List.fromList(settings.affiliatedGroups),
        selectedGroup: settings.selectedGssi,
        defaultPriority: settings.defaultPriority,
        allowPreemption: settings.allowPreemption,
        insecureTls: settings.insecureTls,
        basestation: settings.basestation,
        homeMcc: settings.homeMcc,
        homeMnc: settings.homeMnc,
        groupNetworks: _groupNetworks,
        txBufferMs: settings.txBufferMs,
      ),
    );
    _client = c;
    unawaited(_pump(c));
    if (settings.basestation) await _startControl();
    if (settings.lipEnabled && settings.lipDestination > 0) {
      await location.start(Duration(seconds: settings.lipIntervalSeconds));
    } else {
      await location.stop();
    }
    await WakelockPlus.enable();
  }

  /// Android "Quit app": disconnects, ends the background service and closes
  /// the app. The only way out, since Back keeps it running.
  Future<void> quitApp() async {
    await goOffline();
    await saveMessages();
    await live.end();
    await callAlert.quit();
  }

  /// Disconnect by hand: stays offline until connected again.
  Future<void> goOffline() async {
    _wantOnline = false;
    await disconnect();
    await location.stop();
  }

  Future<void> disconnect() async {
    final c = _client;
    _client = null;
    final ctl = _control;
    _control = null;
    controlOnline = false;
    controlError = null;
    if (ctl != null) await ctl.shutdown();
    // Location keeps running through a reconnect (see LocationService.start);
    // reports while offline go nowhere.
    await audio.stopMic();
    if (c != null) await c.shutdown();
    link = LinkState.offline;
    groupActivity.clear();
    _closeLog();
    groupAccess = const {};
    managedGroups = null;
    final shown = callAlert.shown;
    if (shown != null) unawaited(callAlert.ended(shown));
    _callMuted = false;
    privateCall = null;
    myTxCallId = null;
    await WakelockPlus.disable();
    notifyListeners();
  }

  Future<void> _startControl() async {
    final p = settings.active;
    final TetraControl ctl;
    try {
      ctl = await TetraControl.connect(
        config: ControlConfig(
          brewUrl: p.serverUrl,
          controlUrl: p.controlUrl,
          tls: p.controlTls,
          insecureTls: p.insecureTls,
          username: p.controlUsername.isEmpty ? p.username : p.controlUsername,
          password: p.controlUsername.isEmpty && p.controlPassword.isEmpty ? p.password : p.controlPassword,
          issi: p.issi,
          groups: [for (final t in p.talkgroups.where((t) => t.dgna)) DgnaGroupInfo(gssi: t.gssi, mnemonic: t.name, attachmentMode: t.dgnaMode)],
        ),
      );
    } catch (e) {
      controlError = '$e';
      notifyListeners();
      return;
    }
    _control = ctl;
    unawaited(() async {
      while (identical(_control, ctl)) {
        final e = await ctl.nextEvent();
        if (e == null || !identical(_control, ctl)) break;
        switch (e) {
          case ControlAppEvent_Connected():
            controlOnline = true;
            controlError = null;
          case ControlAppEvent_Disconnected(:final error):
            controlOnline = false;
            controlError = error;
          case ControlAppEvent_Dgna(:final group, :final attach):
            await applyDgna(group.gssi, group.mnemonic, group.attachmentMode, attach: attach);
        }
        notifyListeners();
      }
    }());
  }

  /// SS-DGNA from the control channel: an assigned group is added (and
  /// scanned, so it is affiliated); a deassigned one is removed if DGNA gave it.
  /// A group the user had already keeps being theirs.
  Future<void> applyDgna(int gssi, String? mnemonic, int attachmentMode, {required bool attach}) async {
    final i = settings.talkgroups.indexWhere((t) => t.gssi == gssi);
    if (attach) {
      if (i < 0) {
        settings.talkgroups.add(Talkgroup(gssi, mnemonic ?? 'TG $gssi', dgna: true, dgnaMode: attachmentMode));
      } else {
        final t = settings.talkgroups[i];
        t.scan = true;
        if (t.dgna) {
          t.dgnaMode = attachmentMode;
          if (mnemonic != null) t.name = mnemonic;
        }
      }
    } else if (i >= 0 && settings.talkgroups[i].dgna) {
      settings.talkgroups.removeAt(i);
    } else {
      return;
    }
    await saveTalkgroups();
  }

  Future<void> _pump(TetraClient c) async {
    while (identical(_client, c)) {
      final e = await c.nextEvent();
      if (e == null) break;
      _handle(e);
    }
  }

  @visibleForTesting
  void handleEvent(AppEvent e) => _handle(e);

  void _handle(AppEvent e) {
    switch (e) {
      case AppEvent_Audio(:final callId, :final pcm):
        if (callId == focusCallId) audio.play(pcm);
        return; // no rebuild per audio frame
      case AppEvent_Connecting():
        link = LinkState.connecting;
      case AppEvent_Connected():
        link = LinkState.online;
        lastError = null;
      case AppEvent_Disconnected(:final reason):
        link = LinkState.offline;
        lastError = reason;
        groupActivity.clear();
        _endScanHold();
        _closeLog();
      case AppEvent_GroupTxStarted(:final gssi, :final talker, :final talkerName, :final priority, :final callId):
        groupActivity[gssi] = GroupCallState(gssi, talker, talkerName, priority, callId);
        _logStart(callId, CallLogEntry(time: DateTime.now(), issi: talker, kind: CallKind.groupHeard, gssi: gssi, groupName: _groupName(gssi), sentName: talkerName, emergency: priority >= 15));
        _trackScan();
      case AppEvent_GroupTxEnded(:final gssi, :final callId):
        if (groupActivity[gssi]?.callId == callId) groupActivity.remove(gssi);
        _trackScan();
        _logEnd(callId);
      case AppEvent_TxGranted(:final callId):
        myTxCallId = callId;
        myTxSince = DateTime.now();
        final g = settings.selectedGssi;
        if (privateCall == null && g != null) {
          _logStart('tx:$callId', CallLogEntry(time: myTxSince!, issi: settings.issi, kind: CallKind.groupTalked, gssi: g, groupName: _groupName(g)));
        }
        HapticFeedback.heavyImpact();
        _startMic();
      case AppEvent_TxDenied(:final reason):
        _clearLatch();
        HapticFeedback.vibrate();
        toast = tr('PTT denied: {0}', [reason]);
      case AppEvent_TxEnded(:final callId, :final preempted):
        if (myTxCallId == callId) {
          myTxCallId = null;
          _clearLatch();
        }
        _logEnd('tx:$callId');
        if (preempted) toast = tr('Transmission pre-empted by a higher priority call');
        _updateMic();
      case AppEvent_PrivateCall(:final call):
        if (!_openLog.containsKey('pc:${call.id}')) {
          _privateConnectedAt = null;
          _logStart('pc:${call.id}', CallLogEntry(
              time: DateTime.now(), issi: call.peer, kind: call.incoming ? CallKind.privateMissed : CallKind.privateOut,
              sentName: call.number ?? call.peerName, emergency: call.priority >= 15));
        }
        if (call.state == 'connected' && _privateConnectedAt == null) {
          _privateConnectedAt = DateTime.now();
          if (call.incoming) _openLog['pc:${call.id}']?.kind = CallKind.privateIn;
        }
        privateCall = call;
        _alertCall(call);
        _updateMic();
      case AppEvent_PrivateCallEnded(:final callId):
        if (privateCall?.id == callId) privateCall = null;
        _callMuted = false;
        unawaited(callAlert.ended(callId));
        final e = _openLog.remove('pc:$callId');
        if (e != null && _privateConnectedAt != null) e.duration = DateTime.now().difference(_privateConnectedAt!);
        callLog.changed();
        _updateMic();
      case AppEvent_AudioFocus(:final callId):
        focusCallId = callId;
        _trackScan();
      case AppEvent_TextReceived(:final from, :final to, :final text, :final immediate):
        // Group messages are filed under the group, private ones under the sender.
        final peer = to == settings.issi ? from : to;
        messages.add(ChatMessage(peer: peer, outgoing: false, text: text, status: MsgStatus.received, immediate: immediate)..unread = openConversation != peer);
        _messagesChanged();
        if (immediate) toast = tr('Flash message from {0}: {1}', [from, text]);
        if (settings.messageAlert) {
          final group = settings.talkgroups.where((t) => t.gssi == peer).firstOrNull;
          final sender = nameOf(from);
          unawaited(callAlert.message(peer: peer, title: group != null ? '$sender · ${group.name}' : sender, text: text));
        }
      case AppEvent_MessageStatus(:final localId, :final status):
        final m = messages.where((m) => m.localId == localId).firstOrNull;
        if (m != null) {
          final next = switch (status) {
            'sent' => MsgStatus.sent,
            'network_accepted' => MsgStatus.networkAccepted,
            'delivered' => MsgStatus.delivered,
            _ => MsgStatus.failed,
          };
          // Never downgrade (a late network report after delivery).
          if (m.status != MsgStatus.delivered) m.status = next;
          _messagesChanged();
        }
      case AppEvent_LocationReceived(:final from, :final location, :final reason):
        locations[from] = RemoteLocation(from, location, reason);
      case AppEvent_ServerError(:final kind):
        toast = kind == 1
            ? tr('Not allowed by the server (group blocked or receive only)')
            : tr('The server could not read a message from this app');
      case AppEvent_Extensions(:final offered):
        extensions = offered;
        if (!multiNetwork) networks = const [];
      case AppEvent_Networks(:final json):
        networks = parseNetworks(json);
      case AppEvent_GroupAccess(:final json):
        final (groups, listed) = parseGroupAccess(json);
        groupAccess = groups;
        managedGroups = listed;
      case AppEvent_SubscriberProfiles():
        break;
    }
    notifyListeners();
  }

  /// Rebuild after a change made outside the model (e.g. the call log).
  void refresh() => notifyListeners();

  String _groupName(int gssi) => settings.talkgroups.where((t) => t.gssi == gssi).firstOrNull?.name ?? 'TG $gssi';

  void _logStart(String key, CallLogEntry e) {
    _openLog[key] = e;
    callLog.add(e);
  }

  void _closeLog() {
    for (final k in _openLog.keys.toList()) {
      _logEnd(k);
    }
  }

  void _logEnd(String key) {
    final e = _openLog.remove(key);
    if (e == null) return;
    e.duration = DateTime.now().difference(e.time);
    callLog.changed();
  }

  bool get _micWanted => myTxCallId != null || (privateCall?.state == 'connected' && privateCall!.duplex && !_callMuted);

  /// An incoming private call rings like a phone call (see [CallAlert]).
  void _alertCall(PrivateCallInfo call) {
    if (!call.incoming) return;
    if (call.state == 'ringing') {
      if (!settings.ringIncoming || callAlert.shown == call.id) return;
      final name = call.number != null ? (call.peerName ?? tr('Phone')) : nameOf(call.peer, sentName: call.peerName);
      final sub = call.number ?? (name != 'ISSI ${call.peer}' ? 'ISSI ${call.peer}' : null);
      unawaited(callAlert.incoming(id: call.id, name: name, sub: sub, labels: [tr(call.priority >= 15 ? 'Emergency call' : 'Incoming call'), tr('Answer'), tr('Decline')], emergency: call.priority >= 15, duplex: call.duplex, ringtone: settings.ringtoneUri));
    } else if (call.state == 'connected') {
      unawaited(callAlert.connected(call.id));
    }
  }

  /// iOS: the system call screen hands the audio session over when the call is
  /// answered and takes it back afterwards. Either way the app's audio has to
  /// start again on the session as it is now.
  Future<void> _onCallAudio(bool active) async {
    await audio.resume();
    if (audio.micRunning) await audio.stopMic();
    _updateMic();
  }

  void _startMic() {
    if (audio.micRunning) return;
    final duplex = privateCall?.state == 'connected' && privateCall!.duplex;
    audio.startMic((pcm) => _client?.pushMicPcm(pcm: pcm), voiceProcessing: duplex).catchError((Object err) {
      toast = err.toString();
      notifyListeners();
    });
  }

  void _updateMic() {
    if (_micWanted) {
      _startMic();
    } else {
      audio.stopMic();
    }
  }

  void clearToast() => toast = null;

  /// The conversation on screen; its messages count as read when they arrive.
  int? openConversation;

  /// Unread received messages, of one conversation or of all.
  int unreadMessages([int? peer]) => messages.where((x) => x.unread && (peer == null || x.peer == peer)).length;

  /// The conversation with [peer] is on screen (or was left, [open] false).
  void conversationOpen(int peer, bool open) {
    if (open) {
      openConversation = peer;
    } else if (openConversation == peer) {
      openConversation = null;
    }
    var changed = false;
    for (final x in messages) {
      if (x.peer == peer && x.unread) {
        x.unread = false;
        changed = true;
      }
    }
    if (changed) {
      _messagesChanged();
      notifyListeners();
    }
  }

  // ───────── stored messages ─────────

  /// Messages are kept across restarts, per connection profile, newest
  /// [maxStoredMessages].
  static const maxStoredMessages = 500;
  String get _messagesKey => 'messages.v1.${settings.activeId}';
  String? _messagesDirty;
  Timer? _messagesTimer;

  Future<void> loadMessages() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_messagesKey);
      if (raw == null) return;
      messages
        ..clear()
        ..addAll((jsonDecode(raw) as List).map((e) => ChatMessage.fromJson(e as Map<String, dynamic>)));
      notifyListeners();
    } catch (_) {}
  }

  void _messagesChanged() {
    _messagesDirty = _messagesKey;
    _messagesTimer?.cancel();
    _messagesTimer = Timer(const Duration(seconds: 1), saveMessages);
  }

  Future<void> saveMessages() async {
    _messagesTimer?.cancel();
    final key = _messagesDirty;
    if (key == null) return;
    _messagesDirty = null;
    if (messages.length > maxStoredMessages) messages.removeRange(0, messages.length - maxStoredMessages);
    try {
      await (await SharedPreferences.getInstance()).setString(key, jsonEncode([for (final x in messages) x.toJson()]));
    } catch (_) {}
  }

  /// Removes the whole conversation with [peer].
  void deleteConversation(int peer) {
    messages.removeWhere((x) => x.peer == peer);
    _messagesChanged();
    notifyListeners();
  }

  // ───────── actions ─────────

  void pttDown({bool emergency = false}) {
    // Pressed again during the hang-over: just keep transmitting.
    if (_releaseTimer != null) {
      _releaseTimer!.cancel();
      _releaseTimer = null;
      if (myTxCallId != null) return;
    }
    // Scan: answering a call heard on another group moves the radio to that group.
    final answer = privateCall == null && !emergency ? _scanTalkGssi : null;
    if (answer != null) unawaited(selectGroup(answer));
    _client?.ptt(pressed: true, group: privateCall == null ? (answer ?? settings.selectedGssi) : null, emergency: emergency);
    if (settings.lipEnabled && (settings.lipOnPtt || emergency)) {
      location.sendNow(emergency ? LipReason.emergency : LipReason.ptt);
    }
  }

  Timer? _releaseTimer;

  /// Keeps the mic live for a moment after release so the end of the last word
  /// is captured and sent instead of being cut off mid-syllable.
  static const _hangover = Duration(milliseconds: 120);

  void pttUp() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_hangover, () {
      _releaseTimer = null;
      _client?.ptt(pressed: false, group: null, emergency: false);
    });
  }

  Timer? _autoStop;
  bool _latched = false;

  /// When tap-to-talk stops by itself (null = no auto-stop or not latched).
  DateTime? latchedTxEndsAt;

  /// Tap-to-talk (the PTT button in toggle mode and the Android notification, whose
  /// buttons only take taps): the first tap keys up, the next one releases.
  /// Stops by itself after [Settings.pttAutoStopSeconds] unless that is 0.
  void togglePtt() {
    if (transmitting || _latched) {
      _clearLatch();
      pttUp();
    } else {
      if (link != LinkState.online || (privateCall == null && !mayTalkOnSelected)) return;
      _latched = true;
      pttDown();
      final secs = settings.pttAutoStopSeconds;
      if (secs > 0) {
        latchedTxEndsAt = DateTime.now().add(Duration(seconds: secs));
        _autoStop = Timer(Duration(seconds: secs), () {
          _clearLatch();
          pttUp();
          notifyListeners();
        });
      }
    }
    notifyListeners();
  }

  void _clearLatch() {
    _autoStop?.cancel();
    _autoStop = null;
    _latched = false;
    latchedTxEndsAt = null;
  }

  /// Whether tap-to-talk is keyed up (waiting for the grant or transmitting).
  bool get pttLatched => _latched;

  Future<void> setPttToggle(bool on) async {
    settings.pttToggle = on;
    notifyListeners();
    await settings.save();
  }

  Future<void> setPttAutoStop(int seconds) async {
    settings.pttAutoStopSeconds = seconds;
    notifyListeners();
    await settings.save();
  }

  Future<void> selectGroup(int gssi) async {
    settings.selectedGssi = gssi;
    // Picked by hand (list or knob): shown at once, and a call running on a
    // scanned group no longer holds the display.
    _endScanHold();
    _scanIgnoredCall = focusCallId;
    notifyListeners();
    await settings.save();
    await _client?.setGroups(groups: Uint32List.fromList(settings.affiliatedGroups), selected: gssi);
    await _client?.selectGroup(gssi: gssi);
    notifyListeners();
  }

  /// Scan mode on: the groups marked for scanning are heard too. Off: only the selected one.
  Future<void> setScanMode(bool on) async {
    settings.scanMode = on;
    await saveTalkgroups();
  }

  Future<void> saveTalkgroups() async {
    if (settings.selectedGssi != null && !settings.talkgroups.any((t) => t.gssi == settings.selectedGssi)) {
      settings.selectedGssi = settings.talkgroups.firstOrNull?.gssi;
    }
    settings.selectedGssi ??= settings.talkgroups.firstOrNull?.gssi;
    await settings.save();
    await _client?.setGroupNetworks(networks: _groupNetworks);
    await _client?.setGroups(groups: Uint32List.fromList(settings.affiliatedGroups), selected: settings.selectedGssi);
    notifyListeners();
  }

  void dial(int issi, {required bool duplex, required bool hook, int? priority}) =>
      _client?.dial(issi: issi, duplex: duplex, hook: hook, priority: priority);
  /// Phone/PBX call through the server's SIP gateway. The configured outside-line
  /// prefix (shown fixed in front of the number field) is always prepended.
  void dialExternal(String number, {int? priority}) =>
      _client?.dialExternal(number: '${settings.externalPrefix}$number', priority: priority);

  /// Answers the ringing call. On iOS a call on the system call screen is
  /// answered through the system, which then calls back into [CallAlert.onAnswer].
  void answer() {
    if (!callAlert.viaSystem) {
      _client?.answer();
      return;
    }
    callAlert.answer().then((ok) {
      if (!ok) _client?.answer();
    });
  }

  void hangup() {
    if (!callAlert.viaSystem) {
      _client?.hangup();
      return;
    }
    callAlert.end().then((ok) {
      if (!ok) _client?.hangup();
    });
  }
  void dtmf(String d) => _client?.sendDtmf(digit: d);

  void sendText(int to, String text, {bool immediate = false}) {
    final id = _nextLocalId++;
    final isGroup = settings.talkgroups.any((t) => t.gssi == to);
    messages.add(ChatMessage(peer: to, outgoing: true, text: text, status: MsgStatus.sending, localId: id, immediate: immediate));
    _messagesChanged();
    // No SDS-TL report for group-addressed messages: every member would answer.
    _client?.sendText(localId: id, to: to, text: text, immediate: immediate, requestReport: !isGroup);
    notifyListeners();
  }

  /// Loudspeaker or earpiece (phone mode), applied at once and saved.
  Future<void> setSpeakerOut(bool on) async {
    settings.speakerOut = on;
    notifyListeners();
    await audio.setSpeaker(on);
    await settings.save();
  }

  void sendLocationNow() => location.sendNow(LipReason.user);

  /// Switches to another connection profile and connects with it.
  Future<void> switchProfile(String id) async {
    if (id == settings.activeId) return;
    settings.activeId = id;
    networks = const [];
    extensions = const [];
    // Every connection profile keeps its own messages.
    await saveMessages();
    messages.clear();
    locations.clear();
    await settings.save();
    await loadMessages();
    if (settings.isConfigured) {
      await connect();
    } else {
      await goOffline();
    }
    notifyListeners();
  }

  /// Adds or updates a profile (from the edit sheet). Reconnects when the
  /// active profile changed.
  Future<void> saveProfile(ConnectionProfile p) async {
    final i = settings.profiles.indexWhere((x) => x.id == p.id);
    if (i < 0) {
      settings.profiles.add(p);
    } else {
      settings.profiles[i] = p;
    }
    await settings.save();
    if (p.id == settings.activeId && settings.isConfigured) await connect();
    notifyListeners();
  }

  Future<void> deleteProfile(ConnectionProfile p) async {
    final wasActive = p.id == settings.activeId;
    await settings.removeProfile(p);
    await settings.save();
    if (wasActive) {
      networks = const [];
      settings.isConfigured ? await connect() : await goOffline();
    }
    notifyListeners();
  }

  /// Light, dark or follow the system; applies at once.
  /// 'system', 'en' or 'de'; every open screen changes at once.
  Future<void> setLanguage(String v) async {
    settings.language = v;
    L.use(v);
    notifyListeners();
    await settings.save();
  }

  Future<void> setAppearance(String v) async {
    settings.appearance = v;
    notifyListeners();
    await settings.save();
  }

  Future<void> setLiveActivity(bool on) async {
    settings.liveActivity = on;
    notifyListeners();
    await settings.save();
  }

  /// A settings page was left: store the settings and put them to work.
  /// [reconnect] when something changed that the server is told at login,
  /// [inputs] when the hardware keys were set.
  Future<void> settingsEdited({required bool reconnect, bool inputs = false}) async {
    if (reconnect) return applySettings(settings);
    await settings.save();
    if (inputs) {
      await _startPttInput();
      await _startPocPtt();
    }
    notifyListeners();
  }

  Future<void> applySettings(Settings s) async {
    settings = s;
    audio.micGainDb = s.micGainDb;
    audio.txAutoLevel = s.micAuto;
    audio.captureTx = s.txCapture;
    audio.noiseSuppression = s.noiseSuppression;
    audio.rxLevel = s.rxLevel;
    audio.rxGainDb = s.rxGainDb;
    audio.rxTargetDb = s.rxTargetDb;
    audio.rxMaxDb = s.rxMaxDb;
    await s.save();
    await _startPttInput();
    await _startPocPtt();
    await connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPttInput();
    _pocSub?.cancel();
    PocPtt.stop();
    disconnect();
    location.stop();
    audio.dispose();
    super.dispose();
  }
}

/// `SERVICE_NETWORKS` JSON → the server's own network first, then the linked ones.
List<LinkedNetwork> parseNetworks(String json) {
  try {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final own = j['this'] as Map<String, dynamic>?;
    return [
      if (own != null) LinkedNetwork(own['mcc'] as int? ?? 0, own['mnc'] as int? ?? 0, tr('This server'), own: true),
      for (final n in (j['networks'] as List? ?? []).cast<Map<String, dynamic>>())
        LinkedNetwork(n['mcc'] as int? ?? 0, n['mnc'] as int? ?? 0, n['name'] as String? ?? '?', up: n['up'] as bool? ?? false),
    ];
  } catch (_) {
    return const [];
  }
}

/// `SERVICE_GROUP_ACCESS` for a terminal (docs/Brew-Extensions.md 12.3):
/// `{"groups":[{"gssi":N,"access":"refused"|"listen"}],"managed"?:true,"listed"?:[..]}`.
(Map<int, GroupAccess>, Set<int>?) parseGroupAccess(String json) {
  try {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final groups = <int, GroupAccess>{
      for (final g in (j['groups'] as List? ?? []).cast<Map<String, dynamic>>())
        if (g['gssi'] is int)
          g['gssi'] as int: switch (g['access']) {
            'refused' => GroupAccess.refused,
            'listen' => GroupAccess.listen,
            _ => GroupAccess.open,
          },
    }..removeWhere((_, a) => a == GroupAccess.open);
    final listed = j['managed'] == true ? {...(j['listed'] as List? ?? []).whereType<int>()} : null;
    return (groups, listed);
  } catch (_) {
    return (const <int, GroupAccess>{}, null);
  }
}
