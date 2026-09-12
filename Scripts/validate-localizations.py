#!/usr/bin/env python3
"""Validate English-source catalogs; optionally check Swift compiler extraction.

After a Simulator build, pass the app target's Objects-normal/arm64 directory
with --stringsdata-directory to catch messages missing from the catalog.
"""
import argparse
import json
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def validate(stringsdata_directory=None):
    errors = []
    catalogs = {}
    for path in sorted((ROOT / "VocalSeparator/Resources").glob("*.xcstrings")):
        data = json.loads(path.read_text())
        catalogs[path.stem] = data["strings"]
        if data["sourceLanguage"] != "en":
            errors.append(f"{path.name}: source language must be English")
        for key, entry in data["strings"].items():
            values = []
            for language in ("en", "zh-Hans"):
                unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
                value = unit.get("value", "")
                if not value or unit.get("state") != "translated":
                    errors.append(f"{path.name}: missing {language} translation for {key!r}")
                if language == "en" and re.search(r"[\u3400-\u9fff]", value):
                    errors.append(f"{path.name}: Chinese text in English value for {key!r}")
                values.append(value)
            arguments = lambda text: sorted(re.findall(r"%(?:\d+\$)?(?:lld|ld|d|@|f|%)", text))
            if arguments(values[0]) != arguments(values[1]):
                errors.append(f"{path.name}: mismatched format arguments for {key!r}")
    for path in (ROOT / "VocalSeparator").rglob("*.swift"):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(r"[\u3400-\u9fff]", line) and not line.lstrip().startswith("//"):
                errors.append(f"{path.relative_to(ROOT)}:{number}: untranslated Chinese in source")
    extracted = set()
    if stringsdata_directory:
        files = list(stringsdata_directory.glob("*.stringsdata"))
        if not files:
            errors.append("No compiler .stringsdata files found; coverage was not checked")
        for path in files:
            raw = path.read_bytes()
            try:
                data = plistlib.loads(raw)
            except plistlib.InvalidFileException:
                data = json.loads(raw)
            for table, entries in data.get("tables", {}).items():
                for entry in entries:
                    key = entry["key"]
                    extracted.add((table, key))
                    if key not in catalogs.get(table, {}):
                        errors.append(f"{path.name}: uncatalogued {table} key {key!r}")
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Validated {sum(map(len, catalogs.values()))} bilingual entries in {len(catalogs)} catalogs; "
          f"{len(extracted)} compiler-extracted keys checked.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stringsdata-directory", type=Path)
    validate(parser.parse_args().stringsdata_directory)
