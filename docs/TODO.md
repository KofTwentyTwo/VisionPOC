# TODO

## High value, ready to implement

- [ ] **IPC story** for Jarvis-program integration (XPC vs gRPC vs MQTT vs Unix socket vs shared memory). Same decision applies to VoicePOC. Architectural call needs to be made before headless mode or multi-app coordination can be built.
- [ ] **Headless mode** (`--headless` flag) — runs capture + detect + publish-events with no MTKView. Depends on IPC decision.
- [ ] **Multi-camera N×4 grid** — N cameras × 4 display types. M2 Ultra can comfortably run 4 cameras at full feature parity, 6 with selective feature reduction. Moderate refactor: per-camera CameraCapture, multi-source ObjectDetector, dynamic pane-layout generator.

## Medium value

- [ ] **Video-out** — Syphon (1-2 hr, recommended) or NDI (half-day) or CMIOExtension (multi-day, needs Developer ID + notarization). User declined for now in this session.
- [ ] **Open-vocab detection** — OWL-ViT or YOLO-World. Type "find the red mug" → detector locates it. ~250 MB extra LFS + Python conversion.
- [ ] **LVIS-tuned YOLO** (1,203 classes) — alternative to current 601-class OIV7 if more class diversity is needed.
- [ ] **Real-world test of finger counting + expression heuristics** — current thresholds are first guesses, may need tuning under different lighting / camera angles.

## Polish / cosmetic

- [ ] **Real Orbitron-Bold.ttf** — bundled file is HTML 404 from a misfired download. Pane titles fall back to Helvetica Neue.
- [ ] **App icon** — currently uses default macOS app icon.
- [ ] **README screenshots** — README has no images. Easy to grab now via ⌘S.

## Hygiene / distribution

- [ ] **Code signing + notarization** — needs Apple Developer ID ($99/yr). Required before sharing binary.
- [ ] **More test coverage** — currently 24 tests of pure-logic primitives (IoU, aspect-fit, LogStream, EventBus, FaceRegistry). Could expand to gesture / activity / spatial reasoners with mock observations.

## Completed (this session)

- [x] Camera capture → 4-pane Metal renderer (live / jarvis / edges / ascii)
- [x] YOLOv3 → YOLOv8x-OIV7 (601 classes) via Ultralytics + coremltools, bundled via Git LFS
- [x] Face recognition with persistent enrollment (⌘E / ⇧⌘E)
- [x] Object tracking (`VNTrackObjectRequest`) between YOLO refreshes
- [x] Aspect-ratio letterboxing
- [x] Live Settings panel (⌘,) with diagnostics + output dir pickers
- [x] Log Stream (⌘L), Detection History (⇧⌘H), Status Panel (⌘I) — all uniform controls
- [x] DetectionEventBus + 6 consumers (Greeter, Gesture, Activity, FingerCounter, FacialExpression, Spatial)
- [x] Per-track stable colors via ColorHash + UUID persistence (TrackStore)
- [x] Rotated-line shader for proper hand/body skeleton rendering
- [x] Confidence in box labels (10% buckets)
- [x] Snapshot (⌘S) + Recording (⇧⌘R via AVAssetWriter)
- [x] Privacy Mode (⇧⌘P)
- [x] Camera picker with disconnect handling
- [x] Window-frame persistence (Main / Settings / Log / History / Status / About)
- [x] Configurable output directories (security-scoped UserDefaults bookmarks)
- [x] Unit tests + GitHub Actions CI
- [x] About dialog with full credits
- [x] Comprehensive README + CLAUDE.md
- [x] Fix: greyed-out Quit menu item (target was AppDelegate not NSApp)
- [x] Fix: duplicate "unknown" finger row + auto-aging of stale entries
- [x] Menu reorganization: VisionPOC / File / View / Camera / Faces
