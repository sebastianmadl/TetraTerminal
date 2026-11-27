# flutter_pcm_sound (vendored)

Copy of [flutter_pcm_sound](https://github.com/chipweinberger/flutter_pcm_sound) 3.3.3 (public domain, see `LICENSE`).

One change for TETRA Terminal: `setup(androidVoiceCall: true)` plays through an Android `AudioTrack` with `USAGE_VOICE_COMMUNICATION` / `CONTENT_TYPE_SPEECH` instead of `USAGE_MEDIA`. Android only routes voice-call audio to the earpiece; media audio always plays on the loudspeaker or a headset, whatever `setSpeakerphoneOn` or `setCommunicationDevice` say. iOS and macOS are unchanged.
