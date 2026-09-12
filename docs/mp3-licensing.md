# LAME integration and release obligations

This repository uses the official LAME 4.0 encoder as a separate **dynamic** iOS
framework. Upstream source is unmodified; configuration/module-map/build support
is supplied separately. We elect LGPL 2.1 under the encoder's LGPL-2.0-or-later
grant. AAC and ALAC are encoded by Apple frameworks and add no codec library.

The app bundles the full corresponding LAME source, original notices, elected
license, and standalone build instructions in `LAME-4.0-source.zip`. Settings →
MP3 编码与开源许可 displays the license and lets recipients export that archive
offline. A build check rejects stale source archives. After changing the library
or its build support, regenerate it with `python3 Scripts/package-lame-source.py`.

The 19 encoder C files are explicitly built without mpglib, MPG123, the command
line frontend, or assembly/vector objects. The dynamic binary must be verified
with `otool -L` and `nm`; merely naming a static library “framework” is insufficient.
Wrapping this framework with Swift does not change its LGPL obligations.

## Before any external distribution

1. Retain the exact Xcode archive for each app version, and run the functional
   export tests and dynamic-library inspection on that build.
2. Prepare a **matching unencrypted application replacement kit** using the
   app in the archive, before Apple applies App Store encryption:

   ```sh
   python3 Scripts/package-lame-replacement-kit.py --app /path/App.xcarchive/Products/Applications/VocalSeparator.app --output /path/replacement-kit
   ```

   The script checks the bundled source against the checkout, checks dynamic
   linkage, rejects encrypted executables, includes the matching app, and removes
   embedded provisioning profiles. The kit is intended for the app's recipients.
   It does not include private signing keys, user data, or application source.
3. Publish that kit to recipients with the release, keep a stable per-version
   download link in the app's distribution/support materials, and retain older
   kits. The in-app library source package alone is **not** the full replacement
   mechanism when the distributed app is encrypted. This repository does not
   publish a kit or claim any URL is live. A generated local kit is not evidence
   of completed App Store or public distribution compliance.
4. Preserve this exception in every applicable EULA/localization: recipients may
   modify/replace LAME for their own use and reverse engineer the work to debug
   such modifications, as permitted by LGPL 2.1. Do not apply general modification
   or reverse-engineering prohibitions to those rights.
5. Have the concrete App Store terms, code-signing/replacement process and elected
   LGPL compliance path reviewed before commercial release. Dynamic linkage and
   a notice by themselves do not establish compliance or guarantee acceptance.
   Follow LGPL 2.1 sections 4 and 6 for corresponding source, notices and the
   recipient's ability to use a modified compatible library.

## Using a replacement kit

Unzip `LAME-4.0-source.zip` into a directory called `LAME-source`. Modify the library
and build a compatible framework (the script requires only Python 3 and Xcode):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 LAME-source/Integration/build-framework.py --sdk iphonesimulator --arch arm64 --output /tmp/modified/LAME.framework
python3 replace-and-sign.py --app VocalSeparator.app --framework /tmp/modified/LAME.framework --output /tmp/modified/VocalSeparator.app
xcrun simctl install booted /tmp/modified/VocalSeparator.app
```

The example needs a **simulator** app kit. To run on an iPhone, use an iPhone app
kit, compile with `--sdk iphoneos`, then run `replace-and-sign.py` with your own
`--identity 'Apple Development: ...' --profile /path/development.mobileprovision`.
For a wildcard profile, also supply `--bundle-id your.own.identifier`. Install
the signed app using Xcode's Devices and Simulators window. Your device must be
eligible under your own development profile. No distributor signing key is
required; Apple account/provisioning requirements still apply. The script only
writes a new output app and does not overwrite the kit's original app.

## Scope and evidence

This implements an engineering compliance path for the newly added LAME library,
not a legal opinion, warranty, or permission to redistribute unrelated music or
model assets. Existing model licensing restrictions remain documented in the
app's About page and MODEL_PROVENANCE.md. No external release occurs in this task.

Sources:
- LAME commercial use: https://lame.sourceforge.io/license.txt
- LGPL 2.1: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
- GNU linking FAQ: https://www.gnu.org/licenses/gpl-faq.html#LGPLStaticVsDynamic
- Fraunhofer's bounded patent statement: https://www.audioblog.iis.fraunhofer.com/mp3-software-patents-licenses
