#!/usr/bin/env bash
# Fallback for environments without Git LFS. Re-runs the YOLO conversion
# from Ultralytics' published Open Images V7 weights — produces a Core ML
# mlpackage with 601 object classes in Sources/Resources/Models/.
#
# Run once after cloning, if `git lfs pull` is unavailable or didn't fetch
# the model:
#   ./scripts/fetch-model.sh
#
# Requirements:
#   - python3.12 or python3.13 (3.14 isn't supported by coremltools yet)
#   - ~3 GB free disk for the venv (PyTorch + ultralytics + coremltools)
#   - ~250 MB network for the pretrained weights
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="$ROOT/Sources/Resources/Models"
MODEL_NAME="yolov8x-oiv7"
DEST="$MODELS_DIR/$MODEL_NAME.mlpackage"
VENV="${VPOC_VENV:-/tmp/visionpoc-venv}"

mkdir -p "$MODELS_DIR"

if [[ -d "$DEST" ]] && [[ -f "$DEST/Data/com.apple.CoreML/weights/weight.bin" ]]; then
  size=$(stat -f%z "$DEST/Data/com.apple.CoreML/weights/weight.bin")
  if [[ "$size" -gt 10000000 ]]; then
    echo "$MODEL_NAME.mlpackage already present and looks valid. Skipping rebuild."
    exit 0
  fi
fi

PY_BIN=""
for cand in python3.13 python3.12; do
  if command -v "$cand" >/dev/null 2>&1; then
    PY_BIN="$cand"
    break
  fi
done

if [[ -z "$PY_BIN" ]]; then
  echo "Need python3.12 or python3.13. Install via: brew install python@3.13" >&2
  exit 1
fi

if [[ ! -d "$VENV" ]]; then
  echo "Creating Python venv at $VENV…"
  "$PY_BIN" -m venv "$VENV"
fi

echo "Installing coremltools + ultralytics into $VENV (this takes a couple of minutes)…"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet coremltools ultralytics

echo "Running conversion…"
"$VENV/bin/python" "$ROOT/scripts/convert-yolo-oiv7.py"

echo "Done. Set Theme.Performance.detectorModelName to \"$MODEL_NAME\" (default)."
