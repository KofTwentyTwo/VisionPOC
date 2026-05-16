# VisionPOC

A proof-of-concept **real-time camera vision pipeline** for macOS Apple Silicon. Captures live video and renders four synchronized views in a 2×2 grid: raw passthrough, a **Jarvis HUD stylization** (cyan tint, scanlines, hex grid, scanning beam), an **edge map** (MPS Sobel), and an **object-detection overlay** (Vision saliency + face / human / animal recognizers running on the Apple Neural Engine).

Sibling to [MetalPOC](https://github.com/KofTwentyTwo/MetalPOC) (Jarvis HUD rendering spine) and [VoicePOC](https://github.com/KofTwentyTwo/VoicePOC) (voice stack). This POC proves the camera + ANE + Metal pipeline so future Jarvis "sight" features can build on a known-good foundation.

## Highlights

- **Zero-copy capture** — `AVCaptureSession` → `CVPixelBuffer` → `MTLTexture` via `CVMetalTextureCache` (no CPU roundtrip)
- **601-class object detection** — YOLOv8x trained on Open Images V7, exported to a Vision-friendly Core ML pipeline. Recognizes everyday vocabulary like coffee cup, mug, wine glass, mobile phone, laptop, computer monitor, sunglasses, plus body parts (human face / hand / eye) and a broad household / vehicle / animal vocabulary
- **Object tracking** — `VNTrackObjectRequest` updates each track's box on every frame between YOLO refreshes, so detections drift smoothly with motion instead of teleporting
- **Face recognition** — enroll a face via the menu bar (⌘E), it shows up labeled by name in the JARVIS pane on subsequent frames. Powered by Vision's image FeaturePrint on padded face crops; templates persist to `~/Library/Application Support/VisionPOC/`
- **Apple Neural Engine** — Vision requests configured with `MLComputeUnits.all`; runs on the ANE wherever possible
- **Single render pass, four viewports** — one `MTKView`, one render pass, four fragment pipelines, one HUD overlay
- **MPS Sobel** for edge detection — GPU-native, sub-millisecond at 1080p
- **Jarvis stylization shader** — fragment-only Metal shader matching MetalPOC's HUD palette and fonts
- **Detector decoupled from render** — runs at ~20 Hz on a serial background queue; never blocks the 60 fps render thread
- **Centralized tunables** in `Sources/Theme.swift` — palette, layout, fonts, capture preset, detector cadence, performance profile

## Requirements

- macOS 26 Tahoe (Apple Silicon)
- Xcode 16+ with Metal toolchain
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A built-in or attached camera

## Build & Run

Prerequisite: [Git LFS](https://git-lfs.com) is required because the bundled YOLOv8x model (~131 MB, Open Images V7, 601 classes) is tracked via LFS. Install once on your machine: `brew install git-lfs && git lfs install`.

```bash
git clone https://github.com/KofTwentyTwo/VisionPOC.git
cd VisionPOC
git lfs pull                                  # materialize the bundled model
xcodegen generate
xcodebuild -project VisionPOC.xcodeproj -scheme VisionPOC -configuration Debug build
open build/Debug/VisionPOC.app
```

If LFS isn't installed, `scripts/fetch-model.sh` regenerates the model from Ultralytics' weights via `coremltools` (requires python 3.12 or 3.13 and a few minutes — installs into a `/tmp` venv).

On first launch, macOS will prompt for camera access. Grant it and the four-pane grid will activate.

## Architecture

See [`docs/superpowers/specs/2026-05-15-visionpoc-design.md`](docs/superpowers/specs/2026-05-15-visionpoc-design.md) for the full design.

```
AVCaptureSession (1080p30 BGRA)
        │
        ▼  CVMetalTextureCache (zero-copy)
   source MTLTexture
        │
        ├── live  ───► passthrough fragment
        ├── jarvis ──► stylization fragment (cyan, scanlines, hex, beam)
        ├── edges ───► MPS Sobel + threshold
        └── detect ─► Vision (saliency + faces + humans + animals) on ANE
                        │
                        ▼
                  bounding-box overlay on live texture
        │
        ▼  single render pass, 4 viewports + HUD chrome
   MTKView in resizable NSWindow
```

## Project Structure

```
Sources/
├── App/                  NSApplication, window, menu bar
├── Capture/              CameraCapture (AVFoundation + CVMetalTextureCache)
├── Process/              ObjectDetector (Vision), EdgePass (MPS), JarvisStylePass (Metal)
├── Render/               Renderer, Pipelines, FrameContext
├── Shaders/              .metal files — Common, Live, Jarvis, Edges, Boxes
├── Text/                 TextRasterizer (CoreText → MTLTexture)
├── Resources/Fonts/      Bundled Share Tech Mono + Orbitron
└── Theme.swift           All tunable parameters
project.yml               xcodegen project definition
```

The Xcode project is regenerated from `project.yml`, so `VisionPOC.xcodeproj/` is gitignored.

## Smoke Test

1. macOS shows camera permission prompt → grant.
2. Window opens with a 2×2 grid.
3. **LIVE** pane shows raw feed.
4. **JARVIS** pane shows the same feed with cyan tint, scanlines, hex-grid overlay, and a scanning beam.
5. **EDGES** pane shows white-on-black edges that respond to motion.
6. **DETECT** pane shows the live feed with cyan bounding boxes around objects, faces, humans, and animals in view.
7. Footer FPS counter stays ≥ 55.

## Tech Stack

Swift 6 · AppKit · Metal · MetalKit · MetalPerformanceShaders · AVFoundation · CoreVideo · Vision · CoreML · CoreText · `xcodegen`

## License

[MIT](LICENSE) © James Maes

## Acknowledgments

- Fonts bundled under the [SIL Open Font License](Sources/Resources/Fonts/OFL.txt):
  - [Share Tech Mono](https://fonts.google.com/specimen/Share+Tech+Mono) by Carrois Apostrophe
  - [Orbitron](https://fonts.google.com/specimen/Orbitron) by Matt McInerney
- Stylization inspired by the Jarvis / Iron Man cinematic HUD aesthetic.
- Shares the rendering pattern established in [MetalPOC](https://github.com/KofTwentyTwo/MetalPOC).
