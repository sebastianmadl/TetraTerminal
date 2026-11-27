# Changelog

Newest version on top. Versions up to 1.3.0 are the original app by
[ysamouhos](https://github.com/ysamouhos). From 1.4.0 on the app was rebuilt
and extended in this fork by [sebastianmadl](https://github.com/sebastianmadl)
(OE4SXM): new interface on both platforms, iOS as a full platform, the audio
chain, PoC radio support, phone-style calls and the messages rework.

Entries marked *(not yet verified on a device)* compile and pass the automated
tests but still wait for a test on real hardware.

## 1.6.3 (unreleased)

- iOS bundle id is now `org.tmoaustria.tetraterminal` (was
  `org.tetra.terminal.tetraTerminal`). iOS installs it as a new app beside
  the old one: connections, contacts and messages have to be set up again,
  then the old app can be deleted. Android keeps its id and updates as before.
- The iOS test builds from every push (ios.yml) use the bundle id
  `org.tmoaustria.tetraterminal.dev` and the name "TETRA Dev", so they
  install beside the TestFlight app instead of clashing with it.
- TestFlight: `testflight.yml` signs the app and uploads it to App Store
  Connect, started by hand or by a version tag.

- README: section "Voice codec and audio chain" lists what was changed in
  the ACELP codec and in the audio path around it compared with the
  original. The feature table renders as one table again.
- Calls and messages are marked as checked on a device.
- Earpiece in calls: the call screen has its own loudspeaker / earpiece
  button, next to the keypad, in every call once it no longer rings here
  (before, the switch was only on the Radio tab, and hidden there on PoC
  radios). *(not yet verified on a device)*
- Android: the earpiece really plays. Android only routes voice-call audio
  to the earpiece, and the app played everything as media audio, so the
  switch had no effect. In earpiece mode the player now runs as voice-call
  audio (with the earpiece chosen as communication device on Android 12+);
  loudspeaker and headset stay at media volume as before. The player is a
  vendored copy of `flutter_pcm_sound` 3.3.3 with this one addition.
  *(not yet verified on a device)*
- Echo and feedback in full-duplex calls: the other party heard
  themselves, loud, through the loudspeaker. The echo canceller never saw
  the received audio. On iOS the voice processing only cancels what plays
  through its own audio unit, and the received audio played through a
  separate one: during a full-duplex call it now plays through the
  microphone's engine. On Android the platform echo canceller only takes
  voice-call audio as its reference: a full-duplex call now runs entirely as
  a voice call (call mode, voice-call playback, voice-call microphone
  source), on the loudspeaker as well, at call volume like a phone's
  speakerphone. Group calls and PTT are unchanged. *(not yet verified on a
  device)*
- iOS: switching to the loudspeaker or the receiver on the system call
  screen is kept and the app's button follows, instead of the app switching
  back at the next audio change. *(not yet verified on a device)*

## 1.6.2 (2026-11-27)

### Contacts
- Search field on top of the Contacts tab, like in a new message: type a
  number, a name or a callsign. It searches the own contacts and the
  RadioID.net list; a callsign with several IDs lists each ID in its own row.
  A number that is not saved can be called or written to directly.
- Every row has a message and a call button. Tapping a row that is not a
  contact yet offers to add it.
- Favourites: a contact can be marked as a favourite and is then listed on
  top of the Contacts tab.
- Speed dial: a favourite can carry a code of `*` or `#` and up to four
  digits (for example `*1`), set in the contact form. Dialling the code on
  the keypad shows the favourite and calls its ISSI. A code belongs to one
  contact at a time.

### iOS
- Dynamic Island: RX / TX is centred under the timer, and the standby pill in
  the expanded view no longer runs into the rounded corner.

### Other
- The app logs in as `TetraTerminal/<version>` (was `TetraBrewTerminal`).
- README brought up to date, this changelog added.

*(not yet verified on a device: all of the above)*

## 1.6.1 (2026-11-27)

### Android builds
- Two Android variants. The normal APKs no longer declare the Accessibility
  key service, because Google Play Protect blocked the app on ordinary phones
  with it. `TetraTerminal-<version>-poc.apk` (arm32 + arm64) keeps the service
  for PoC radios such as the Hytera P60. `app/tool/android_variant.py`
  switches between `phone` and `poc`.
- Test builds are signed with a fixed key when the keystore secrets are set in
  the repository, so a new build installs over the previous one. The build log
  prints the certificate it signed with.

### Calls
- While the app is on screen an incoming private call rings inside the app
  only; the notification is used in the background and on the lock screen.
- The app switches to the Calls tab for an incoming call and stays there
  after answering.
- In-call keypad three keys wide like a phone, sized to the space that is
  left, so the hang-up button stays visible on small screens (Hytera P60).
- Call and message buttons on every contact row.

### Messages
- New message screen: search field on top; type a number or search by name or
  callsign across Contacts, Groups and the RadioID.net list. A callsign with
  several IDs lists each ID in its own row.
- Tone for an incoming SDS, and a notification when the app is in the
  background. Switch under Settings > Calls and background.
- Unread counters per conversation and on the Messages tab.
- Messages are kept across restarts, per connection profile (newest 500).
  Long press deletes a conversation.

### App
- Android: the Back key sends the app to the background instead of closing
  it. "Quit app" is in the connection menu at the top, next to
  Connect / Disconnect.
- Connection form: no placeholder in the username field, plain "Password"
  hint, the talker name field is called "Call" in both languages and is
  written in capitals, "Phone prefix" for the telephone prefix.
- About: both authors listed under Developers.

*(Calls and messages were checked on a device on 2026-11-27. Not yet
verified: Play Protect accepting the phone APK, Back / Quit app.)*

## 1.6.0 (2026-11-27)

### Calls
- Incoming private calls ring like a phone call. iOS uses the system call
  screen (CallKit) with accept, decline, mute and keypad; Android shows a
  ringing call notification with Answer and Decline that opens full screen
  over the lock screen. New plugin `app/packages/tetra_call`. Switch
  "Ring on incoming calls", on by default.
- Ring tone can be chosen: the system ring tone picker on Android, four
  bundled tones on iOS (`app/tool/make_ringtones.py`).
- Keypad: compact layout on small screens so the call button stays visible.

### Settings
- A short menu with pages (Radio, Calls and background, Audio, Display, Keys
  and accessories, Location, Callsign database) instead of one long list.
  No Save button; a page applies when it is left.
- German and English, switchable while the app runs, with a language chooser
  on first start. English texts in the code are the keys of
  `app/lib/ui/l10n_de.dart`.

### Audio
- Android: automatic transmit level like on iOS, with up to 24 dB of gain for
  quiet microphones (PoC radios).
- Microphone level automatic or manual.

### PoC radios
- First start on a PoC radio: hardware PTT on, on-screen buttons hidden,
  audio preset, and a prompt to switch on the background key service.

### Other
- The Basestation login mode is hidden; the app always logs in as a Terminal.
- Android: the ongoing notification no longer has a Talk / Stop button.
- A group picked by hand or with the knob is shown at once.
- CI: build files download as they are (no zip), named
  `TetraTerminal-<version>…`.

*(Incoming call ringing was checked on a device on 2026-11-27. Not yet
verified: ring tone picker on the P60, bundled iOS tones, language chooser.)*

## 1.5.0 (2026-11-26)

### Radio screen
- New radio screen: one header row with callsign, link state and connection
  profile; status card with the group in use and the group drop-down; one
  level meter (RX while listening, TX while transmitting); last talkers fill
  the room the screen has. Compact layout on small displays.
- Scan: the card shows the group that is heard, holds it after the call
  (0–60 s, default 15) and PTT answers there.
- The SOS and loudspeaker buttons can be hidden.
- Talkgroups are managed under Contacts > Groups and can be reordered.

### PoC radios (Android)
- New plugin `app/packages/poc_ptt`: hardware PTT key (key code, broadcast,
  background key service), channel knob for talkgroups, status LED.
- Device profiles: the Hytera P60 works without teaching keys; Custom for
  other radios, with the last key seen shown for diagnosis.
- The knob announces the chosen group by speech.
- No silent audio stream in the background while the status service runs
  (it was audible as hiss on PoC radios).

### Audio
- **Codec change:** fixed the transmit chirp. The ETSI ACELP reference code
  (`tetra_core/third_party/tetra-codec`) relies on signed overflow in
  `L_add` / `L_sub`, which clang at -O2 optimised away. The encoder then
  produced a bitstream that radios played as short bursts around 2.7 kHz.
  The two functions do their arithmetic unsigned now (same result as the
  reference), the codec builds with `-fwrapv`, and a test pins the encoder
  output to the reference bitstream. Nothing else in the codec was changed;
  the decoder is untouched.
- Transmit noise suppression through speexdsp in the Rust core.
- Receive audio: boost, level control target, maximum level, test tone.

## 1.4.0 (2026-11-25/26)

First version of the rebuilt app.

### Interface
- New adaptive interface: Cupertino on iOS (floating glass tab bar, large
  titles, grouped lists), Material 3 on Android. Radio screen with PTT in the
  thumb zone, phone-style keypad and in-call screen, message bubbles.
- Appearance: automatic, light or dark.
- PTT button mode hold or toggle, with a configurable auto-stop.
- Loudspeaker / earpiece switch on the radio screen.
- Settings footer with logo, version and credits.

### Connections
- Connection profiles: several servers and ISSIs, switched with one tap.
  Talkgroups and the home network are per profile. Passwords moved from the
  preferences to the keychain.
- Reconnect on resume; optional keep-alive so calls come in with the screen
  locked.
- One User-Agent with the app version everywhere
  (`TetraBrewTerminal/<version>`); a test keeps pubspec, Cargo.toml and the
  Dart constant equal.
- `REREGISTER` is followed by `AFFILIATE`.

### Server extensions (only used when the server offers them)
- The core reads the server's `X-Brew-Extensions` offer. Without an offer
  nothing changes, so TetraPack and other servers see a plain terminal.
- `mni` (Multi Network): the terminal names its home network, tags groups of
  linked networks and shows the network list.
- `group-access`: refused groups are greyed out, listen-only groups have PTT
  off (SOS still works).

### Contacts and calls
- Contacts tab with own contacts (ISSI, name, note) and search.
- RadioID.net callsign database, downloaded in the background. Names follow:
  own contact, the name the radio sent, RadioID callsign, ISSI.
- Calls tab with Recents next to the keypad.
- Talker names sent as 8-bit text are decoded correctly.

### iOS
- Live Activity on the Lock Screen and in the Dynamic Island with group,
  talker and timer, and a home screen / Lock Screen widget
  (`app/ios_widgets`, `app/packages/tetra_live`).
- Background audio playback fixed.
- Own microphone capture (`app/packages/tetra_mic`): the converter is rebuilt
  when the audio hardware changes mid-recording.
- Group calls and PTT play at media volume; the voice-call mode is used only
  in full-duplex calls.
- Playback is converted from 8 kHz to 48 kHz in the app.
- Automatic transmit level; optional recording of own transmissions as WAV.

### Android
- Foreground service with an ongoing status notification that keeps the app
  running in the background.

### Audio (both platforms)
- 300 Hz high-pass before the encoder.
- Switchable transmit noise suppression and receive level control.
- Transmit buffer: voice frames are held before pacing (240 ms by default,
  180 ms to about 1 s selectable), which removed the beeps caused by frames
  arriving late at the base station.

### Location
- LIP location updates keep running in the background.

### CI
- Android workflow builds on a GitHub-hosted runner in forks (upstream keeps
  its own runner). iOS workflow runs on `macos-26` with Xcode 26.

## 1.3.0 (2026-11-24, ysamouhos)
- Savox BTH-101 Bluetooth PTT headset on Android (SPP PTT, SCO audio).
- Headset PTT answers a ringing incoming call.

## 1.2.1 and earlier (2026-11-04/05, ysamouhos)
- Original app: Rust core with the Brew protocol, call engine, SDS, LIP and
  the ACELP codec; Flutter interface for Android and iOS; release workflow.
- Microphone capture at 16 kHz with decimation, gain setting, look-ahead
  limiter, end-of-speech fade-out and PTT hang-over.
