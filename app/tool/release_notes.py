#!/usr/bin/env python3
"""Prints the text of a GitHub Release: which file is for which device, how
to install it, and the section of CHANGELOG.md for the version.

    python3 app/tool/release_notes.py 1.6.2 > notes.md
"""
import pathlib
import re
import sys

GUIDE = """## Which file do I need?

| File | For |
|---|---|
| `TetraTerminal-{v}-android-arm64.apk` | Android phones (anything from the last years) |
| `TetraTerminal-{v}-android-universal.apk` | Android, if you are not sure: runs on every device, larger file |
| `TetraTerminal-{v}-android-arm32.apk` | older 32-bit Android devices |
| `TetraTerminal-{v}-android-poc.apk` | PoC radios with a hardware PTT key |
| `TetraTerminal-{v}-ios-unsigned.ipa` | iPhone |

### Android
Download the APK on the device and open it; Android asks once to allow
installing from this source. An update installs over the previous release.
If Android refuses the update, an older test build signed with another key is
installed: uninstall it once, then install this one.

### PoC radios
The `-poc` file is the only one with the background key service, which the
hardware PTT key needs while the screen is off. Right now it is fully set up
for the **Hytera P60** only; on other PoC radios the keys can be taught under
Settings > Keys and accessories, without a guarantee that everything works.
Do not use it on a normal phone: Google Play Protect blocks it there.

### iPhone
The IPA is **not signed** and is not in the App Store. It has to be
sideloaded: install it from a computer with
[Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io), which
sign it with your own Apple ID. With a free Apple ID the app runs for 7 days
and then has to be signed again the same way; with a paid developer account
it runs for a year.

`SHA256SUMS.txt` lists the checksums of all files.
"""


def section(changelog: str, version: str) -> str:
    """The body of the `## <version>` section, without its heading."""
    m = re.search(rf"^## {re.escape(version)}\b[^\n]*\n(.*?)(?=^## |\Z)", changelog, re.S | re.M)
    return m.group(1).strip() if m else ""


def main() -> None:
    version = sys.argv[1].lstrip("v")
    root = pathlib.Path(__file__).resolve().parents[2]
    changes = section((root / "CHANGELOG.md").read_text(encoding="utf-8"), version)
    out = GUIDE.format(v=version)
    if changes:
        out += f"\n## What is new in {version}\n\n{changes}\n"
    out += "\nAll versions: [CHANGELOG.md](https://github.com/{repo}/blob/main/CHANGELOG.md)\n".replace(
        "{repo}", __import__("os").environ.get("GITHUB_REPOSITORY", "sebastianmadl/TetraTerminal"))
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
