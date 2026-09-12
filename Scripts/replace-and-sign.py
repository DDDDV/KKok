#!/usr/bin/env python3
"""Replace LAME in an unencrypted app and sign a private-use copy with your own identity."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--framework", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--identity", default="-", help="Use '-' for Simulator; your own Apple development identity for a device")
parser.add_argument("--profile", type=Path, help="Your own development .mobileprovision for device signing")
parser.add_argument("--bundle-id", help="Your app identifier; needed for a wildcard provisioning profile")
args = parser.parse_args()
info = plistlib.loads((args.app / "Info.plist").read_bytes())
device = "iPhoneOS" in info.get("CFBundleSupportedPlatforms", [])
if args.output.exists() or args.output.suffix != ".app":
    parser.error("Output must be a new .app directory")
if not (args.framework / "LAME").is_file():
    parser.error("Replacement must contain a compiled LAME framework")
entitlements = None
if device:
    if args.identity == "-" or not args.profile:
        parser.error("A device requires your own Apple development identity and provisioning profile")
    profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(args.profile)]))
    entitlements = profile["Entitlements"]
    application_id = entitlements["application-identifier"]
    team, bundle_id = application_id.split(".", 1)
    if "*" in bundle_id:
        if not args.bundle_id:
            parser.error("Wildcard profile requires --bundle-id")
        prefix = bundle_id.split("*", 1)[0]
        if not args.bundle_id.startswith(prefix):
            parser.error("Bundle identifier does not match the provisioning profile")
        bundle_id = args.bundle_id
    elif args.bundle_id and args.bundle_id != bundle_id:
        parser.error("Bundle identifier does not match the provisioning profile")
    entitlements["application-identifier"] = team + "." + bundle_id
    entitlements["keychain-access-groups"] = [team + "." + bundle_id]
    info["CFBundleIdentifier"] = bundle_id
elif args.bundle_id:
    info["CFBundleIdentifier"] = args.bundle_id
shutil.copytree(args.app, args.output, symlinks=True)
try:
    target = args.output / "Frameworks/LAME.framework"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(args.framework, target, symlinks=True)
    (args.output / "Info.plist").write_bytes(plistlib.dumps(info))
    for signature in args.output.rglob("_CodeSignature"):
        shutil.rmtree(signature)
    profile_path = args.output / "embedded.mobileprovision"
    profile_path.unlink(missing_ok=True)
    if device:
        shutil.copy2(args.profile, profile_path)
    frameworks = list((args.output / "Frameworks").glob("*.framework"))
    dylibs = list(args.output.rglob("*.dylib"))
    for binary in sorted(frameworks + dylibs, key=lambda path: len(path.parts), reverse=True):
        subprocess.run(["codesign", "--force", "--sign", args.identity, str(binary)], check=True)
    command = ["codesign", "--force", "--sign", args.identity]
    if entitlements:
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".plist") as file:
            file.write(plistlib.dumps(entitlements))
            file.flush()
            subprocess.run(command + ["--entitlements", file.name, str(args.output)], check=True)
    else:
        subprocess.run(command + [str(args.output)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.output)], check=True)
except BaseException:
    shutil.rmtree(args.output)
    raise
print(args.output)
