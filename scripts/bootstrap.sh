#!/usr/bin/env bash
# One-time setup: fetches the third-party reader-mode library and
# generates the Xcode project. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

READABILITY_VERSION="0.6.0"
READABILITY_PATH="AuraSearch/Resources/Readability.js"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

if [ ! -f "$READABILITY_PATH" ]; then
  echo "Downloading Mozilla Readability.js ${READABILITY_VERSION} (Apache-2.0)..."
  curl -fsSL -o "$READABILITY_PATH" \
    "https://raw.githubusercontent.com/mozilla/readability/${READABILITY_VERSION}/Readability.js"
fi

xcodegen generate
echo
echo "Done. Open AuraSearch.xcodeproj in Xcode and press Run."
