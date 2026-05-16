# Session State

**Last Updated:** 2026-05-16

## Current Status

VisionPOC is feature-complete as a single-camera proof-of-concept. Branch `main` at `670a3e6`, clean working tree, 24 unit tests passing, GitHub Actions CI green. App runs end-to-end: capture → detect (601-class YOLO + Vision built-ins + tracker) → recognize (faces / gestures / activities / expressions / fingers / OCR / spatial relations) → render (4 panes + overlays + HUD).

## What Was Done This Session

Built the entire project from an empty directory through 16 commits. Major milestones:

- Initial scaffold (project.yml, Theme.swift, 4-pane Metal renderer, AVFoundation capture, MPS Sobel edges, ASCII shader, Jarvis stylization)
- VNTrackObjectRequest-based smooth tracking between 5 Hz YOLO refreshes
- YOLOv3 (80 COCO classes) → upgraded to YOLOv8x-OIV7 (601 Open Images classes) via Ultralytics → coremltools, bundled via Git LFS
- Face recognition with enrollment (VNGenerateImageFeaturePrintRequest on padded crops, persistent FaceRegistry)
- Aspect-ratio letterboxing
- Live Settings panel (⌘,) with TunableSettings @Observable mirror over Theme.Performance vars
- Live Log Stream (⌘L), Detection History (⇧⌘H), Status Panel (⌘I) windows — all with identical Auto-scroll / Pause / filter / Clear controls
- DetectionEventBus + consumers (Greeter TTS, GestureRecognizer, ActivityRecognizer, FingerCounter, FacialExpressionAnalyzer, SpatialReasoner)
- Per-track stable colors, confidence labels, proper rotated-line skeleton shader, snapshot (⌘S), recording (⇧⌘R via AVAssetWriter)
- Privacy Mode (⇧⌘P), camera picker, window-frame persistence, configurable output directories via security-scoped bookmarks
- Unit tests + GitHub Actions CI + CLAUDE.md onboarding doc
- About dialog with proper credits
- Comprehensive README + CLAUDE.md rewrite to match current feature set

## Active Branches

| Branch | Status |
|--------|--------|
| `main` | Up to date with `origin/main` at `670a3e6`, working tree clean |

## Pending Work

### Cosmetic (deferred — no clean source)
- [ ] Real Orbitron-Bold.ttf (inherited HTML 404 page, falls back to Helvetica Neue)
- [ ] App icon

### Feature ideas surfaced this session, not yet started
- [ ] Syphon / NDI / CMIOExtension video-out (user declined for now — option chosen: "skip")
- [ ] Multi-camera N×4 grid layout
- [ ] In-process detection event bus → IPC bridge for Jarvis brain (architectural decision pending)
- [ ] Headless mode (`--headless` flag) — depends on IPC decision
- [ ] Open-vocab detection (OWL-ViT / YOLO-World)
- [ ] Code signing + notarization for distribution

### Known issues
- [ ] Orbitron-Bold.ttf file is HTML — Theme.Font falls back cleanly to Helvetica Neue
- [ ] FingerCounter chirality reports "unknown" sometimes when Vision can't determine left vs right (this is correct behavior, not a bug)
- [ ] No app icon — uses default macOS app icon

## Key Reference

- **Repo:** https://github.com/KofTwentyTwo/VisionPOC
- **Current HEAD:** `670a3e6` (Documentation overhaul)
- **Sibling repos:** `MetalPOC`, `VoicePOC` (under same Kof22 / Kingsrook Jarvis program)
- **LFS model:** `Sources/Resources/Models/yolov8x-oiv7.mlpackage` (~131 MB weight.bin)
- **Persistent state files:**
  - `~/Library/Application Support/VisionPOC/faces.json` — enrolled face FeaturePrints
  - `~/Library/Application Support/VisionPOC/tracks.json` — label → UUID map for color stability
- **UserDefaults keys:** `VPOC.{Main,Settings,Log,History,Status,About}WindowFrame`, `VPOC.{Snapshot,Recording}DirectoryBookmark`, plus the privacy/greeter `Theme.Performance` flags
- **Open architectural question:** IPC story for Jarvis-program integration (XPC vs gRPC vs MQTT vs Unix socket). Same decision needs to apply to VoicePOC.

## How to resume

```bash
cd /Users/james.maes/Git.Local/Kof22/VisionPOC
git pull
xcodegen generate
xcodebuild -project VisionPOC.xcodeproj -scheme VisionPOC build
open build/Debug/VisionPOC.app
```

Read `CLAUDE.md` for the agent-onboarding map. Read `docs/superpowers/specs/2026-05-15-visionpoc-design.md` for the original design (kept as archeology — codebase has grown beyond it).
