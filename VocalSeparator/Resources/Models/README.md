# Model location

Place `HTDemucs_CoreML_FP16.mlpackage` in this directory, then regenerate the
Xcode project with `xcodegen generate`. The repository-level bootstrap script
does both steps automatically.

The publishable branch tracks only
`WhisperKitResources.bundle/MODEL_MANIFEST.json` for the optional transcription
model. The adjacent model and tokenizer directories are ignored task-local
mirror material; reconstruct them from the pinned upstream repositories and URL
rules in the repository-level `MODEL_PROVENANCE.md`, then verify every manifest
byte length and SHA-256. The app target excludes the wrapper and copies only its
manifest; the weights must never be added back to Copy Bundle Resources. A
configured mirror root must expose the exact relative paths listed in the
manifest.
