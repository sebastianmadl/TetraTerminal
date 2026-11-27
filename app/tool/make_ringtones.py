#!/usr/bin/env python3
"""Writes the ring tones bundled with the iOS app (ios_ringtones/*.wav).

The tones are synthesised here, so there is nothing to license. The system
call screen loops the file, so each one ends with its own pause.
Run from app/:  python3 tool/make_ringtones.py
"""
import math
import struct
import wave

RATE = 22050
PEAK = 0.5  # about -6 dBFS


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def tone(freqs, seconds, attack=0.008, release=0.02, decay=0.0, tremolo=0.0):
    """Sum of sines with a short fade in and out; `decay` > 0 lets it ring out."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        v = sum(a * math.sin(2 * math.pi * f * t) for f, a in freqs) / sum(a for _, a in freqs)
        env = min(1.0, t / attack, (seconds - t) / release)
        if decay:
            env *= math.exp(-t / decay)
        if tremolo:
            env *= 0.55 + 0.45 * math.sin(2 * math.pi * tremolo * t)
        out.append(v * env)
    return out


def write(name, samples):
    with wave.open(f"ios_ringtones/{name}.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * PEAK * 32767)) for s in samples))
    print(f"{name}.wav  {len(samples) / RATE:.1f} s")


# Bell of a desk phone: two bursts, then a pause.
bell = [(1400, 1.0), (1800, 0.8), (2800, 0.25)]
write("ring_classic", tone(bell, 0.45, tremolo=25) + silence(0.2) + tone(bell, 0.45, tremolo=25) + silence(2.4))

# Two-tone trill, like a selective call on a radio.
trill = []
for i in range(10):
    trill += tone([(1000 if i % 2 else 800, 1.0)], 0.12)
write("ring_twotone", trill + silence(1.8))

# Rising chime that rings out.
chime = silence(0.0)
notes = [659.26, 830.61, 987.77, 1318.51]
total = int(RATE * 3.6)
chime = [0.0] * total
for k, f in enumerate(notes):
    start = int(RATE * 0.22 * k)
    for i, s in enumerate(tone([(f, 1.0), (2 * f, 0.3), (3 * f, 0.1)], 1.6, decay=0.45)):
        if start + i < total:
            chime[start + i] += 0.7 * s
write("ring_chime", chime)

# Three short beeps.
beeps = []
for _ in range(3):
    beeps += tone([(1200, 1.0)], 0.12) + silence(0.12)
write("ring_beacon", beeps + silence(1.8))
