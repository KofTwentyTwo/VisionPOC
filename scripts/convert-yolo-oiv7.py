#!/usr/bin/env python3
"""
Convert Ultralytics' yolov8x-oiv7 (Open Images V7, 600 classes) to a
Vision-friendly Core ML package and copy it into Sources/Resources/Models/.

Usage:
    /tmp/visionpoc-venv/bin/python scripts/convert-yolo-oiv7.py
"""
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = ROOT / "Sources" / "Resources" / "Models"
MODELS_DIR.mkdir(parents=True, exist_ok=True)

VARIANT = os.environ.get("VPOC_YOLO_VARIANT", "yolov8x-oiv7")
WEIGHTS = f"{VARIANT}.pt"

from ultralytics import YOLO

print(f"Loading {WEIGHTS}…")
model = YOLO(WEIGHTS)
print(f"Class count: {len(model.names)}")
sample_labels = ", ".join(list(model.names.values())[:25])
print(f"Sample labels: {sample_labels}…")

print("Exporting to Core ML (Vision-friendly, NMS baked in)…")
exported_path = model.export(
    format="coreml",
    nms=True,
    int8=False,
    half=False,
    imgsz=640,
)
print(f"Exported to: {exported_path}")

dest = MODELS_DIR / f"{VARIANT}.mlpackage"
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(exported_path, dest)
print(f"Installed at: {dest}")
print(f"DONE — set Theme.Performance.detectorModelName to \"{VARIANT}\"")
