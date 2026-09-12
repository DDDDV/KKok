# LAME 4.0 source and replacement kit

Upstream: https://lame.sourceforge.io/
Official release: https://sourceforge.net/projects/lame/files/lame/4.0/lame-4.0.tar.gz/download
Downloaded on 2026-09-12. Original tarball SHA-256:
`3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb`

`lame-4.0/` is the complete, unmodified release source tree. Its original copyright
notices and COPYING are preserved. The encoder sources permit LGPL version 2 or
any later version; this application distributes the encoder under **LGPL 2.1**,
whose full text is in `LGPL-2.1.txt`. No patent indemnity is offered.

Only the 19 C encoder files listed in `Integration/build-framework.py` are built.
The frontend, mpglib/MPG123 decoder, x86 assembly and vector implementations are
not built or linked. The application uses Apple's decoder instead. Files under
`Integration/` were added on 2026-09-12, are not upstream changes, and are made
available under LGPL 2.1. They contain the Apple configuration, umbrella header,
and independent framework build script. No library source files were patched.

## Build a modified replacement

Install Xcode and select its command-line tools. Unzip this package on a Mac,
modify `lame-4.0/` as desired, and retain the public LAME 4.0 ABI. Run:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 Integration/build-framework.py --sdk iphoneos --arch arm64 --output /tmp/rebuilt/LAME.framework
```

For an Apple Silicon simulator, use `--sdk iphonesimulator --arch arm64`.
For an Intel simulator, use `--sdk iphonesimulator --arch x86_64`.
This needs no third-party Python packages, XcodeGen, application source, or LAME
network downloads. The library's install name is `@rpath/LAME.framework/LAME`.

Replace `VocalSeparator.app/Frameworks/LAME.framework` in an unencrypted build
of the application with the resulting framework. The distributor's per-version
replacement kit must include such an app, and its `replace-and-sign.py` script.
That script does not need any private signing keys from the distributor. Use
your own Apple development identity and a compatible development provisioning
profile to sign for an iOS device; simulator builds support ad-hoc signing.

Apple controls device signing and provisioning. A copy downloaded from the App
Store may be encrypted and is not an adequate replacement kit on its own.
The distributor must make a matching unencrypted application build available
alongside each released version; see the repository's `docs/mp3-licensing.md`.

## Your rights

You may modify and replace LAME for your own use, and reverse engineer the work
for debugging modifications to LAME, as permitted by LGPL 2.1. Any general EULA
restriction on modification or reverse engineering does not apply to these
rights. LAME is provided without warranty. See the full license and individual
source file copyright notices. This permission does not grant rights to songs,
models, or other independently licensed material in the application.
