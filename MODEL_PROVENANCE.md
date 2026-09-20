# Model provenance

## Optional Whisper transcription model

The app does not embed the Whisper weights. Its signed resources contain only
`MODEL_MANIFEST.json`, which pins:

- Argmax Core ML model revision
  `7235bbd38ae9ab5476bee007313c0bb327387b84`;
- OpenAI tokenizer revision
  `06f233fe06e710322aca913c1bc4249a0d71fce1`;
- every installed relative path, byte length, and SHA-256 digest.

The exact upstream inputs verified on 2026-09-01 are:

| Material | Repository | Fixed revision | Files | Bytes |
| --- | --- | --- | ---: | ---: |
| WhisperKit Core ML model folder `openai_whisper-large-v3-v20240930_626MB` | https://huggingface.co/argmaxinc/whisperkit-coreml | `7235bbd38ae9ab5476bee007313c0bb327387b84` | 17 | 626,718,238 |
| Whisper large-v3 tokenizer and processor metadata | https://huggingface.co/openai/whisper-large-v3 | `06f233fe06e710322aca913c1bc4249a0d71fce1` | 10 | 4,388,788 |

Together these are the 27 manifest entries and total 631,107,026 bytes
(approximately 601.87 MiB). The committed manifest is the authoritative
per-file inventory; it contains the relative path, exact byte length, and
SHA-256 for every file.

For reproducible retrieval, model entries use this direct URL rule, where
`{manifest-relative-path}` includes the model folder name:

```text
https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/7235bbd38ae9ab5476bee007313c0bb327387b84/{manifest-relative-path}
```

Tokenizer entries use this rule, with the leading `tokenizer/` removed from
the manifest path:

```text
https://huggingface.co/openai/whisper-large-v3/resolve/06f233fe06e710322aca913c1bc4249a0d71fce1/{path-after-tokenizer-prefix}
```

The browsable pinned trees are:

- https://huggingface.co/argmaxinc/whisperkit-coreml/tree/7235bbd38ae9ab5476bee007313c0bb327387b84/openai_whisper-large-v3-v20240930_626MB
- https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1

After explicit user consent, the installer tries release-configured HTTPS mirror
roots first and those fixed Hugging Face revisions only as a final fallback. A
download is not exposed to WhisperKit until every manifest entry passes
validation and the staging directory has been atomically installed. WhisperKit's
own model download remains disabled.

The publishable branch history intentionally retains only
`WhisperKitResources.bundle/MODEL_MANIFEST.json`. The model and tokenizer
directories are ignored task-local mirror material and are not pushed to the
remote repository. To reconstruct a mirror, download the entries using the
rules above, preserve their manifest-relative paths, and reject any file whose
length or SHA-256 differs. A release-configured mirror root must expose those
same manifest-relative paths. `project.yml` excludes the wrapper from Copy
Bundle Resources and adds only its manifest. Local recovery refs created while
rewriting earlier history are outside the branch and must never be sent with a
mirror or explicit backup-ref push.

## HTDemucs separation model

The bundled development model is `HTDemucs_CoreML_FP16.mlpackage`, generated
from `dexxdean/htdemucs-coreml` commit `d6fe735` with:

```sh
python convert.py --fp16 --output HTDemucs_CoreML_FP16.mlpackage
```

Conversion environment used for this prototype:

- Python 3.9.6
- torch / torchaudio 2.8.0
- coremltools 9.0
- demucs 4.0.1
- numpy 2.0.2
- einops 0.8.2

The converter's built-in comparison against the PyTorch reference completed
successfully:

- maximum absolute difference: `0.006569`
- mean absolute difference: `0.000478`

The compiled FP16 package metadata declares a Float32 `audio` input and a
Float16 `sources` output. This differs from the repository README, which labels
the output Float32. The app follows the actual model description and supports
both Float16 (FP16 package) and Float32 (FP32 package) output arrays.

The package's embedded `license` metadata identifies the model as MIT-licensed.
The app's HTDemucs notices use the MIT License for the model, pretrained
weights, Demucs source code, and Core ML conversion code, based on the project
owner's confirmation recorded below.

The reproducible download script instead fetches the upstream v1.0.0 FP16
release asset and verifies SHA-256
`d85e957dc1692f89f3f7ec73ba388af96402cd07088dcfcdeda84b0edf13edda`.

Bundled package leaf-file SHA-256 values:

- `Manifest.json`: `7e280bbf23974bb9569d8bcb752655a5aaea0c63af286f28369c5dad9ad63e79`
- `Data/com.apple.CoreML/model.mlmodel`: `dca607dbfb16390b0ae930a9a5fb1c805438758df2b48d9b1b1483dcd947531a`
- `Data/com.apple.CoreML/weights/weight.bin`: `efab790ad07d93faeb5a19b6e1eedad8c37ad351563a891a153fce307811c099`

## HTDemucs license

On 2026-09-20, the project owner confirmed that the HTDemucs model and pretrained
weights are covered by the MIT License and that adapting the model to Core ML
for Apple platforms does not change that license. The app's license notices
have been updated on that basis; this records the owner's confirmation rather
than a new independent license audit.

The HTDemucs model and pretrained weights, Demucs source code, and Core ML
conversion code are provided under the MIT License. Commercial use,
modification, and redistribution are permitted under the MIT License, provided
that the copyright and permission notices are retained. The bundled
`VocalSeparator/Resources/THIRD_PARTY_NOTICES.txt` preserves the original
copyright notices and full MIT License text.

- Converter: https://github.com/dexxdean/htdemucs-coreml
- Demucs MIT License: https://github.com/facebookresearch/demucs/blob/main/LICENSE
