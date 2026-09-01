# Model provenance

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

The package's embedded `license` metadata repeats the converter author's MIT
claim for the model. That field is converter-supplied metadata, not a separate
grant from the pretrained-weight rights holder, so this prototype does not
treat it as commercial redistribution clearance.

The reproducible download script instead fetches the upstream v1.0.0 FP16
release asset and verifies SHA-256
`d85e957dc1692f89f3f7ec73ba388af96402cd07088dcfcdeda84b0edf13edda`.

Bundled package leaf-file SHA-256 values:

- `Manifest.json`: `7e280bbf23974bb9569d8bcb752655a5aaea0c63af286f28369c5dad9ad63e79`
- `Data/com.apple.CoreML/model.mlmodel`: `dca607dbfb16390b0ae930a9a5fb1c805438758df2b48d9b1b1483dcd947531a`
- `Data/com.apple.CoreML/weights/weight.bin`: `efab790ad07d93faeb5a19b6e1eedad8c37ad351563a891a153fce307811c099`

## Distribution warning

The converter repository describes the model as MIT-licensed. However, a
Demucs upstream maintainer stated that pretrained weights are not covered by
the code's MIT license and were provided for scientific use. No later,
HTDemucs-specific commercial redistribution grant was found during this
prototype work.

Treat this model as research/development-only until the weight rights are
clarified. Do not submit the bundled model to TestFlight or the App Store on
the strength of the converter repository's notice alone.

- Converter: https://github.com/dexxdean/htdemucs-coreml
- Upstream discussion: https://github.com/facebookresearch/demucs/issues/327
