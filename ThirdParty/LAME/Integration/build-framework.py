#!/usr/bin/env python3
"""Rebuild the replaceable LAME framework using only Xcode and Python 3.
This integration script is distributed under LGPL-2.1.
"""
import argparse
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

SOURCES = "VbrTag bitstream encoder fft gain_analysis id3tag lame newmdct presets psymodel quantize quantize_pvt reservoir set_get tables takehiro util vbrquantize version".split()


def build(sdk, arch, output):
    root = pathlib.Path(__file__).resolve().parents[1]
    source = root / "lame-4.0"
    if output.exists():
        raise SystemExit("Output already exists; choose a new framework path.")
    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    triple = f"{arch}-apple-ios17.0" + ("-simulator" if sdk == "iphonesimulator" else "")
    with tempfile.TemporaryDirectory(prefix="lame-build-") as temporary:
        objects = []
        for name in SOURCES:
            obj = str(pathlib.Path(temporary) / (name + ".o"))
            subprocess.run(["xcrun", "--sdk", sdk, "clang", "-target", triple,
                            "-isysroot", sdk_path, "-O2", "-DNDEBUG", "-DHAVE_CONFIG_H=1",
                            "-I" + str(root / "Integration"), "-I" + str(source / "include"),
                            "-I" + str(source), "-fPIC", "-c", str(source / "libmp3lame" / (name + ".c")),
                            "-o", obj], check=True)
            objects.append(obj)
        output.mkdir(parents=True)
        try:
            subprocess.run(["xcrun", "--sdk", sdk, "clang", "-target", triple, "-isysroot", sdk_path,
                            "-dynamiclib", "-install_name", "@rpath/LAME.framework/LAME",
                            "-current_version", "4.0", "-compatibility_version", "4.0", *objects,
                            "-o", str(output / "LAME")], check=True)
            (output / "Headers").mkdir()
            shutil.copy2(source / "include/lame.h", output / "Headers/lame.h")
            (output / "Modules").mkdir()
            shutil.copy2(root / "Integration/module.modulemap", output / "Modules/module.modulemap")
            with (output / "Info.plist").open("wb") as file:
                plistlib.dump(dict(CFBundleExecutable="LAME", CFBundleIdentifier="com.example.VocalSeparator.LAME",
                                   CFBundleName="LAME", CFBundlePackageType="FMWK", CFBundleVersion="4.0",
                                   CFBundleShortVersionString="4.0", MinimumOSVersion="17.0",
                                   CFBundleSupportedPlatforms=["iPhoneSimulator" if sdk == "iphonesimulator" else "iPhoneOS"]), file)
        except BaseException:
            shutil.rmtree(output)
            raise
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", choices=["iphoneos", "iphonesimulator"], required=True)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], default="arm64")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.sdk == "iphoneos" and args.arch != "arm64":
        parser.error("iOS devices require arm64")
    build(args.sdk, args.arch, args.output.resolve())
