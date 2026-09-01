# Model location

Place `HTDemucs_CoreML_FP16.mlpackage` in this directory, then regenerate the
Xcode project with `xcodegen generate`. The repository-level bootstrap script
does both steps automatically.

`WhisperKitResources.bundle` is source material for the optional transcription
model mirror. The app target excludes that wrapper and copies only its
`MODEL_MANIFEST.json`; the weights must never be added back to Copy Bundle
Resources. A configured mirror root must expose the exact relative paths listed
in the manifest.
