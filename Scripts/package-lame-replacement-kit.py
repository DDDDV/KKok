#!/usr/bin/env python3
"""Prepare a per-build, unencrypted replacement kit for distribution to app recipients."""
import argparse
from pathlib import Path
import hashlib
import json
import plistlib
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
app = args.app.resolve()
output = args.output.resolve()
if output.exists():
    parser.error("Output must be a new directory")
subprocess.run(["python3", str(root / "Scripts/package-lame-source.py"), "--check"], check=True)
source_zip = "LAME-4.0-source.zip"
if (app / source_zip).read_bytes() != (root / "VocalSeparator/Resources" / source_zip).read_bytes():
    parser.error("The app does not contain this checkout's exact LAME source package")
info = plistlib.loads((app / "Info.plist").read_bytes())
binary = app / info["CFBundleExecutable"]
linked_binaries = [binary] + list(app.glob("*.dylib"))
loads = "\n".join(subprocess.check_output(["otool", "-L", str(p)], text=True) for p in linked_binaries)
if "@rpath/LAME.framework/LAME" not in loads:
    parser.error("The application must dynamically load LAME")
for path in [binary, app / "Frameworks/LAME.framework/LAME"] + list(app.rglob("*.dylib")):
    headers = subprocess.check_output(["otool", "-l", str(path)], text=True)
    if re.search(r"cryptid\s+[1-9]", headers):
        parser.error("Encrypted App Store binaries cannot be used as a replacement kit")
output.mkdir(parents=True)
try:
    copied = output / app.name
    shutil.copytree(app, copied, symlinks=True)
    # Do not publish provisioning profiles containing developer device identifiers.
    for profile in copied.rglob("embedded.mobileprovision"):
        profile.unlink()
    shutil.copy2(root / "Scripts/replace-and-sign.py", output / "replace-and-sign.py")
    shutil.copy2(root / "VocalSeparator/Resources" / source_zip, output / source_zip)
    shutil.copy2(root / "docs/mp3-licensing.md", output / "README.md")
    manifest = {"bundleIdentifier": info["CFBundleIdentifier"], "version": info.get("CFBundleShortVersionString"),
                "build": info.get("CFBundleVersion"), "lame": "4.0", "files": {}}
    for path in sorted(output.rglob("*")):
        if path.is_file():
            manifest["files"][str(path.relative_to(output))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
except BaseException:
    shutil.rmtree(output)
    raise
print(output)
