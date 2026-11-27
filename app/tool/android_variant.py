#!/usr/bin/env python3
"""Switches the Android build between the two variants.

  phone  no Accessibility service in the APK. Google Play Protect refuses to
         install sideloaded apps that declare one ("App blocked to protect
         your device"), so this is the build for normal phones.
  poc    with the background key service for PoC radios (Hytera P60 ...),
         where the PTT key and the knob must work with the screen locked.

Usage: tool/android_variant.py phone|poc   (after tool/setup.sh, from app/)
"""
import re
import sys

MANIFEST = "android/app/src/main/AndroidManifest.xml"
TOOLS_NS = 'xmlns:tools="http://schemas.android.com/tools"'
REMOVE = '<service android:name="org.tetra.poc_ptt.PocPttKeyService" tools:node="remove"/>'


def switch(text: str, variant: str) -> str:
    text = re.sub(r"\n?[ \t]*" + re.escape(REMOVE), "", text)
    if variant == "poc":
        return text
    if TOOLS_NS not in text:
        text = text.replace("<manifest ", "<manifest " + TOOLS_NS + " ", 1)
    out, n = re.subn(r"([ \t]*)</application>", lambda m: m.group(1) + "    " + REMOVE + "\n" + m.group(0), text, count=1)
    if n != 1:
        sys.exit("android_variant: no </application> in the manifest")
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("phone", "poc"):
        sys.exit(__doc__)
    path = sys.argv[2] if len(sys.argv) > 2 else MANIFEST
    with open(path) as f:
        src = f.read()
    with open(path, "w") as f:
        f.write(switch(src, sys.argv[1]))
    print("android variant:", sys.argv[1])
