#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"

"$script_dir/download-model.sh"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
    exit 1
fi

cd "$project_root"
xcodegen generate --spec project.yml
echo "Generated: $project_root/VocalSeparatorPrototype.xcodeproj"
