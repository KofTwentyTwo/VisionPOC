# VisionPOC

A real-time computer-vision **proof-of-concept** for macOS Apple Silicon. Captures live video and processes every frame through the GPU and Apple Neural Engine to produce four synchronized views — **LIVE**, **JARVIS** (cinematic stylization), **EDGES** (Sobel map), and **ASCII art** — overlaid with object detection, face recognition, body / hand pose skeletons, OCR, gesture / expression / activity recognition, and per-track motion smoothing.

Sibling to [MetalPOC](https://github.com/KofTwentyTwo/MetalPOC) (Jarvis HUD spine) and [VoicePOC](https://github.com/KofTwentyTwo/VoicePOC) (voice stack) under the **Kingsrook Jarvis program**. This POC proves the camera + ANE + Metal pipeline so future Jarvis "sight" features can build on a known-good foundation.

---

## Capabilities

### Detection — what VisionPOC sees

| What | How | Source |
|---|---|---|
| **Object detection** (601 classes) | YOLOv8x trained on Open Images V7 — coffee cup, mug, wine glass, laptop, mobile phone, computer monitor, sunglasses, book, vase, plus human face / hand / eye, plus broad household / vehicle / animal vocabulary | Ultralytics YOLOv8x-OIV7 → Core ML mlpackage via `coremltools` |
| **Face recognition** | Per-face image FeaturePrint on padded crops, matched against an on-disk registry. Enrolled people get their name as the box label | `VNGenerateImageFeaturePrintRequest` |
| **Body pose** | 14-segment skeleton (nose-neck-shoulders-arms, neck-root-hips-legs) | `VNDetectHumanBodyPoseRequest` |
| **Hand pose** | Up to 2 hands, full finger chains + palm | `VNDetectHumanHandPoseRequest` |
| **Finger counting** | Per-hand chirality (left / right) + extended-finger count via joint geometry | Custom (`FingerCounter`) |
| **Facial expression** | smile / frown / neutral from outer-lip landmark geometry | `VNDetectFaceLandmarksRequest` + custom (`FacialExpressionAnalyzer`) |
| **Gesture** | thumbs_up · open_hand · fist · pointing · peace | Custom (`GestureRecognizer`) |
| **Activity** | standing · sitting · crouching · hand_raised | Custom (`ActivityRecognizer`) |
| **OCR** | Real-time text in scene | `VNRecognizeTextRequest` |
| **Spatial relations** | "X is near Y" · "above" · "inside" · "holding" between detected objects | Custom (`SpatialReasoner`) |
| **Object tracking** | Smooth box motion at 60 Hz between 5 Hz YOLO refreshes; track UUIDs persist across launches | `VNTrackObjectRequest` + `TrackStore` |

### Visual rendering

- **Four-pane 2×2 grid** — letterboxed to source aspect ratio
- **JARVIS pane** — cyan luma tint, scanlines, hex grid, scanning beam, vignette, light chromatic ghost
- **EDGES pane** — `MPSImageSobel` + threshold compute kernel
- **ASCII pane** — live luma quantized into a monospaced character grid
- **Detection overlays** in JARVIS — labeled bounding boxes with per-track stable hues (confidence in 10% buckets), magenta OCR boxes, mint body skeleton, amber hand skeleton — all rendered through a custom rotated-line Metal shader (no axis-aligned blocks)
- **HUD chrome** — cyan corner brackets, pane labels, footer with `FPS · DET 28.4ms (yolo) · QUALITY`

### Audio & interaction

- **TTS greeter** — "Hello, James" when an enrolled face appears (throttled, mutable via Privacy Mode or Settings)
- **Live menu actions** — enroll, forget, snapshot, record, switch camera, toggle privacy

### Persistent state

- **Face registry** — `~/Library/Application Support/VisionPOC/faces.json` (NSKeyedArchiver-encoded VNFeaturePrintObservations per name)
- **Track UUIDs** — `~/Library/Application Support/VisionPOC/tracks.json` (label → UUID, MRU-pruned to 50 entries, debounced 500ms writes)
- **Window frames** — all five panel windows (Main, Settings, Log, History, Status, About) remember their position via `UserDefaults`
- **Output directories** — snapshot + recording destinations are user-configurable in Settings, stored as security-scoped bookmarks

---

## Windows & shortcuts

| Window | Shortcut | What it shows |
|---|---|---|
| Main 4-pane grid | (default) | LIVE / JARVIS / EDGES / ASCII with all overlays |
| **Settings** | ⌘, | Live tuning sliders for YOLO frequency, detection confidence, tracker knobs, face match threshold, edge threshold, ASCII columns, plus mute-greeter and output-directory pickers and a per-stage timing diagnostics readout |
| **Status Panel** | ⌘I | "What VisionPOC knows right now" — FPS, DET ms (yolo/track mode), objects with confidence + colors, faces by name, hands (left/right with finger count), expression, activity, last 8 events |
| **Detection History** | ⇧⌘H | Scrolling timeline of every event the bus has seen, filtered by category, oldest-first with auto-scroll-to-bottom |
| **Log Stream** | ⌘L | Subsystem log feed from APP / CAM / DETECT / TRACK / FACE / RENDER sources, filtered by level + source, mirrored to stdout for `log stream --process VisionPOC` |
| **About** | (menu) | Credits, license, attributions |

| Action | Shortcut |
|---|---|
| **Enroll Face…** | ⌘E |
| Forget Face… | ⇧⌘E |
| **Save Snapshot** (PNG) | ⌘S |
| **Start / Stop Recording** (.mov) | ⇧⌘R |
| **Privacy Mode** toggle | ⇧⌘P |

---

## Build & Run

**Prerequisites**

- macOS 26 Tahoe on Apple Silicon
- Xcode 16+ with the Metal 4 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [Git LFS](https://git-lfs.com) (`brew install git-lfs && git lfs install`) — the YOLOv8x-OIV7 model (~131 MB) is tracked via LFS

```bash
git clone https://github.com/KofTwentyTwo/VisionPOC.git
cd VisionPOC
git lfs pull                                              # materialize the bundled detector model
xcodegen generate
xcodebuild -project VisionPOC.xcodeproj -scheme VisionPOC -configuration Debug build
open build/Debug/VisionPOC.app
```

If LFS isn't installed, `scripts/fetch-model.sh` regenerates the model from Ultralytics' weights via `coremltools` (requires Python 3.12 or 3.13 and a few minutes — installs into a `/tmp` venv).

On first launch, macOS prompts for camera access. Grant it and all four panes activate.

### Tests

```bash
xcodebuild -project VisionPOC.xcodeproj -scheme VisionPOC -configuration Debug -destination 'platform=macOS' test
```

24 unit tests across IoU, aspect-fit, LogStream ring buffer, and DetectionEventBus pub/sub.

### Continuous integration

GitHub Actions builds + tests on every push to `main` — see `.github/workflows/build.yml`. LFS is skipped on CI (the build tolerates a missing model since `ObjectDetector` falls back to the Vision built-ins).

---

## Architecture

```
AVCaptureSession (1080p30 BGRA)
        │
        ▼  CVMetalTextureCache (zero-copy)
   source MTLTexture
        │
        ├──────────────────────────────┬──────────────────┐
        ▼                              ▼                  ▼
   ObjectDetector             EdgePass             AsciiPass
   (~5 Hz YOLO + 60 Hz tracker,
    YOLO + face + body + hand +
    OCR + animal + recognition)
        │
        ▼  publishes via DetectionEventBus
   ┌────┼────────────────────────────┐
   │    │                            │
   ▼    ▼                            ▼
  Greeter  GestureRecognizer    HistoryStore
  (TTS)    ActivityRecognizer   CurrentStateStore
           FingerCounter        LogStream
           FacialExpression     (per-window observers)
           SpatialReasoner

        │
        ▼  Renderer (single MTKView, 4 viewports + HUD chrome)
   ┌─────────────────────────┐
   │  LIVE   ·   JARVIS+overlays │
   │  EDGES  ·   ASCII           │
   └─────────────────────────┘
```

See `CLAUDE.md` for full source-tree map, theme tunables, and "how to add a new detector / overlay" recipes.

The full original design spec lives at `docs/superpowers/specs/2026-05-15-visionpoc-design.md` (kept as archeology — the codebase has grown well beyond it).

---

## Codebase Anatomy & Domain Encapsulation

| Subsystem / Path | Architectural Role & Responsibilities |
| :--- | :--- |
| **`Sources/App/`** | AppKit & SwiftUI window management, menu bar lifecycle, status panel, event log stream, and output destination security bookmarks. |
| **`Sources/Capture/`** | `AVCaptureSession` pipeline, hardware camera selection, and zero-copy `CVMetalTextureCache` frame buffering. |
| **`Sources/Process/`** | `ObjectDetector` orchestrator (YOLOv8x + Vision framework), `DetectionEventBus` pub/sub engine, face registry, gesture/activity/expression analyzers, and spatial reasoning. |
| **`Sources/Render/`** | `MTKViewDelegate` multi-viewport render loop, Metal pipeline states, custom line-drawing box shaders, and `AVAssetWriter` video recording. |
| **`Sources/Shaders/`** | Metal Shading Language kernels (`.metal`) for luma quantization, edge detection, box rendering, and ASCII character rasterization. |
| **`Sources/Text/`** | `TextRasterizer` CoreText to `MTLTexture` engine for chamfer-aware HUD typography. |
| **`Sources/Theme.swift`** | Centralized design system constants, detector thresholds, tracker parameters, and render styling. |

---

## License

[MIT](LICENSE) © 2026 James Maes

## Acknowledgments

- **Detection model**: [Ultralytics YOLOv8](https://github.com/ultralytics/ultralytics) trained on [Open Images V7](https://storage.googleapis.com/openimages/web/index.html), exported to Core ML via [`coremltools`](https://github.com/apple/coremltools)
- **Vision framework**: Apple's [Vision](https://developer.apple.com/documentation/vision) for face landmarks, body / hand pose, text recognition, animal recognition, image feature prints, and per-object tracking
- **Fonts** (both under the [SIL Open Font License](Sources/Resources/Fonts/OFL.txt)):
  - [Share Tech Mono](https://fonts.google.com/specimen/Share+Tech+Mono) by Carrois Apostrophe
  - [Orbitron](https://fonts.google.com/specimen/Orbitron) by Matt McInerney
- **Aesthetic**: Jarvis / Iron Man cinematic HUD
- **Sibling repos**: [MetalPOC](https://github.com/KofTwentyTwo/MetalPOC), [VoicePOC](https://github.com/KofTwentyTwo/VoicePOC)

## Tech stack

Swift 6 · AppKit · SwiftUI · Metal 4 · MetalKit · MetalPerformanceShaders · AVFoundation · CoreVideo · Vision · CoreML · CoreText · AVSpeechSynthesizer · `xcodegen` · `git-lfs` · `coremltools` · `ultralytics`
