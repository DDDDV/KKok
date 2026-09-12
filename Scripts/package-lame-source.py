#!/usr/bin/env python3
"""Create/check the exact source archive bundled with the LGPL dynamic library."""
import argparse
import hashlib
import io
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
source = root / "ThirdParty/LAME"
destination = root / "VocalSeparator/Resources/LAME-4.0-source.zip"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
buffer = io.BytesIO()
with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob("*")):
        if not path.is_file() or path.name == ".DS_Store" or "__pycache__" in path.parts:
            continue
        info = zipfile.ZipInfo(str(path.relative_to(source)), date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, path.read_bytes())
payload = buffer.getvalue()
license_path = root / "VocalSeparator/Resources/LAME-LGPL-2.1.txt"
license_data = (source / "LGPL-2.1.txt").read_bytes()
if args.check:
    if not destination.exists() or destination.read_bytes() != payload or license_path.read_bytes() != license_data:
        raise SystemExit("LAME source/license package is stale. Run python3 Scripts/package-lame-source.py before building.")
    print("LAME source/license package matches the checked-in library and integration files.")
else:
    destination.write_bytes(payload)
    license_path.write_bytes(license_data)
    print(f"{destination.name}: {len(payload)} bytes, SHA-256 {hashlib.sha256(payload).hexdigest()}")
