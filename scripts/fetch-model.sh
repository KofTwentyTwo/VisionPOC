#!/usr/bin/env bash
# Fetches the bundled object-detection model from Apple's Core ML model catalog.
# The model is too large to commit to git (~248 MB), so we pull it on demand.
#
# Run once after cloning, before the first `xcodegen generate && xcodebuild`:
#   ./scripts/fetch-model.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="$ROOT/Sources/Resources/Models"
MODEL_NAME="YOLOv3"
MODEL_URL="https://docs-assets.developer.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3.mlmodel"
DEST="$MODELS_DIR/$MODEL_NAME.mlmodel"

mkdir -p "$MODELS_DIR"

if [[ -f "$DEST" ]]; then
  size=$(stat -f%z "$DEST")
  if [[ "$size" -gt 100000000 ]]; then
    echo "$MODEL_NAME.mlmodel already present (${size} bytes). Skipping download."
    exit 0
  fi
  echo "Existing $MODEL_NAME.mlmodel looks truncated (${size} bytes); re-downloading."
fi

echo "Downloading $MODEL_NAME from Apple's Core ML catalog…"
curl -fL --progress-bar -o "$DEST" "$MODEL_URL"

actual=$(stat -f%z "$DEST")
echo "Saved $DEST (${actual} bytes)."

if [[ "$actual" -lt 100000000 ]]; then
  echo "Download appears incomplete. Expected ~248 MB; got ${actual} bytes." >&2
  exit 1
fi
