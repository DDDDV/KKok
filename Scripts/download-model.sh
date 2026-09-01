#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
model_dir="$project_root/VocalSeparator/Resources/Models"
model_path="$model_dir/HTDemucs_CoreML_FP16.mlpackage"
asset_url="https://github.com/dexxdean/htdemucs-coreml/releases/download/v1.0.0/HTDemucs_CoreML_FP16.zip"
expected_sha256="d85e957dc1692f89f3f7ec73ba388af96402cd07088dcfcdeda84b0edf13edda"

model_is_complete() {
    local candidate="$1"
    [[ -f "$candidate/Manifest.json" ]] &&
        [[ -f "$candidate/Data/com.apple.CoreML/model.mlmodel" ]] &&
        [[ -f "$candidate/Data/com.apple.CoreML/weights/weight.bin" ]]
}

if [[ -e "$model_path" ]]; then
    if [[ -d "$model_path" ]] && model_is_complete "$model_path"; then
        echo "Model already present and structurally valid: $model_path"
        exit 0
    fi

    echo "An incomplete model already exists: $model_path" >&2
    echo "Remove only that path, then run this script again." >&2
    exit 1
fi

mkdir -p "$model_dir"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/htdemucs-model.XXXXXX")"
staging_path="$(mktemp -d "$model_dir/.HTDemucs_CoreML_FP16.staging.XXXXXX")"
trap 'rm -rf "$temporary_dir" "$staging_path"' EXIT

archive="$temporary_dir/HTDemucs_CoreML_FP16.zip"
echo "Downloading the v1.0.0 FP16 model (about 144 MB)..."
curl --fail --location --retry 3 --output "$archive" "$asset_url"

actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "Checksum mismatch." >&2
    echo "Expected: $expected_sha256" >&2
    echo "Actual:   $actual_sha256" >&2
    exit 1
fi

mkdir -p "$temporary_dir/unpacked"
ditto -x -k "$archive" "$temporary_dir/unpacked"
unpacked_model="$(find "$temporary_dir/unpacked" -type d -name '*.mlpackage' -print -quit)"
if [[ -z "$unpacked_model" ]]; then
    echo "The archive did not contain an .mlpackage." >&2
    exit 1
fi

ditto "$unpacked_model" "$staging_path"
if ! model_is_complete "$staging_path"; then
    echo "The downloaded model package is incomplete." >&2
    exit 1
fi

mv "$staging_path" "$model_path"
echo "Installed: $model_path"
