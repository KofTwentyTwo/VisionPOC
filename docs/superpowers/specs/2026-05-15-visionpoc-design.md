# VisionPOC — Design

**Status:** Approved 2026-05-15
**Author:** James Maes
**Skill:** `superpowers:brainstorming` → `superpowers:writing-plans`

## Summary

Standalone macOS app demonstrating real-time camera capture processed through Apple Silicon GPU + Neural Engine, displayed as a 2×2 grid of synchronized views:

1. **LIVE** — raw passthrough of the camera feed
2. **JARVIS** — cinematic HUD stylization (cyan tint, scanlines, hex grid overlay, scanning beam) rendered in Metal
3. **EDGES** — edge-detection map (MPS Sobel)
4. **DETECT** — same live feed with bounding boxes drawn around detected objects

This is a sibling POC to `MetalPOC` (Jarvis HUD rendering) and `VoicePOC` (voice stack) under the Kof22 / Jarvis program. It proves the real-time camera + Neural Engine + Metal pipeline so future Jarvis features (sight, presence detection, object awareness) can build on a known-good foundation.

## Goals

- Camera frames captured at 30 fps and rendered at 60 fps with no perceptible lag
- All four panes update synchronously from a single source frame
- Object detection runs on the Apple Neural Engine, never blocks the render thread
- Visual style consistent with MetalPOC (Theme.swift palette, Share Tech Mono / Orbitron, scanlines, chamfered frames)
- Builds cleanly with XcodeGen + xcodebuild like MetalPOC
- One-command run: `xcodegen generate && xcodebuild ... && open build/Debug/VisionPOC.app`

## Non-goals (v1)

- Recording, snapshots, or export
- Model training, fine-tuning, or bundling custom CoreML models
- Multi-camera / device picker (uses default camera)
- Transparent floating HUD (departure from MetalPOC — VisionPOC is a regular app window)
- Cross-platform support (iOS, iPadOS, etc.)
- Unit tests (smoke-test procedure documented in README instead — POC is visual)
- Telemetry, analytics, settings UI

## Target hardware

Primary dev: Mac Studio M2 Ultra, macOS 26 Tahoe. Designed to also run on M5 MacBook Pro and any Apple Silicon Mac running macOS 26. Intel Macs not supported (no path to ANE).

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  AVCaptureSession  (dedicated queue, 1080p @ 30fps, BGRA)    │
│        │                                                      │
│        ▼  CMSampleBuffer → CVPixelBuffer                      │
│  CVMetalTextureCache  ── zero-copy ──►  source MTLTexture    │
│        │                                       │              │
│        ├──────────┬──────────┬──────────┐     │              │
│        ▼          ▼          ▼          ▼                    │
│   ┌───────┐  ┌────────┐ ┌────────┐ ┌──────────┐              │
│   │ Live  │  │ Jarvis │ │ Edges  │ │  Boxes   │              │
│   │ (pass │  │ shader │ │  MPS   │ │ Vision   │              │
│   │ thru) │  │ (.metal│ │ Sobel  │ │ (saliency│              │
│   │       │  │ )      │ │        │ │ +faces   │              │
│   └───────┘  └────────┘ └────────┘ │ +humans  │              │
│                                    │ +animals │ ANE          │
│                                    └──────────┘              │
│        │                                                      │
│        ▼   single render pass, 4 viewports, HUD chrome on top│
│   ┌─────────────────────────┐                                │
│   │  ┌──────┐  ┌──────┐    │  MTKView in resizable NSWindow │
│   │  │ LIVE │  │JARVIS│    │  Jarvis chrome (cyan + fonts + │
│   │  └──────┘  └──────┘    │  scanlines + corner brackets)  │
│   │  ┌──────┐  ┌──────┐    │  FPS / detector ms in footer    │
│   │  │ EDGE │  │BOXES │    │                                 │
│   │  └──────┘  └──────┘    │                                 │
│   └─────────────────────────┘                                │
└──────────────────────────────────────────────────────────────┘
```

## Components

| File | Responsibility | Frameworks |
|---|---|---|
| `Sources/App/AppDelegate.swift` | `NSApplication` lifecycle, single window, menu bar | AppKit |
| `Sources/App/MainWindowController.swift` | `NSWindow` + `MTKView` content view | AppKit, MetalKit |
| `Sources/Capture/CameraCapture.swift` | Owns `AVCaptureSession`; vends latest source `MTLTexture` via `CVMetalTextureCache`; permission flow | AVFoundation, Metal, CoreVideo |
| `Sources/Process/ObjectDetector.swift` | Runs Vision requests on a serial background queue, throttled to ~20 Hz, publishes latest `[Detection]` snapshot | Vision, CoreImage |
| `Sources/Process/EdgePass.swift` | `MPSImageSobel` + threshold compute kernel → edge `MTLTexture` | MetalPerformanceShaders, Metal |
| `Sources/Process/JarvisStylePass.swift` | Owns the Jarvis fragment pipeline; per-frame uniforms (time, scanline phase, beam position) | Metal |
| `Sources/Render/Renderer.swift` | `MTKViewDelegate`; per-frame: pulls source texture, dispatches detector, runs edge pass, encodes 4-viewport render pass + HUD chrome | MetalKit |
| `Sources/Render/Pipelines.swift` | Builds and caches all `MTLRenderPipelineState`s (live, jarvis, edges, boxes, hud) | Metal |
| `Sources/Render/FrameContext.swift` | Per-frame uniform struct, command buffer, drawable, timing | — |
| `Sources/Text/TextRasterizer.swift` | CoreText → MTLTexture for HUD labels (**copied verbatim from MetalPOC**) | CoreText, Metal |
| `Sources/Shaders/Common.metal` | Shared uniform structs, sampling helpers | MSL |
| `Sources/Shaders/Live.metal` | Vertex + passthrough fragment | MSL |
| `Sources/Shaders/Jarvis.metal` | Vertex + Jarvis stylization fragment (tint, scanlines, hex grid, scanning beam, vignette) | MSL |
| `Sources/Shaders/Edges.metal` | Sobel post-threshold display fragment + compute kernel | MSL |
| `Sources/Shaders/Boxes.metal` | Bounding-box quad vertex/fragment with cyan stroke | MSL |
| `Sources/Theme.swift` | All tunables (palette, layout, fonts, capture preset, detector cadence, performance profile) | — |
| `Sources/Resources/Fonts/` | Share Tech Mono + Orbitron (**copied from MetalPOC**) | — |

## Data flow per frame (steady state)

1. AVFoundation delivers a `CMSampleBuffer` on the capture queue.
2. `CameraCapture` wraps the `CVPixelBuffer` as a Metal texture via the texture cache and atomically stores it as `latestSource`.
3. MTKView display link → `Renderer.draw(in:)`.
4. Renderer reads `latestSource` (drops if nil — never blocks).
5. If the detector queue is idle, enqueue a detection on a copy of the source pixel buffer.
6. Run MPS Sobel → `edgesTexture`.
7. Single render pass with 4 viewports:
   - Viewport 0 (top-left): live passthrough
   - Viewport 1 (top-right): Jarvis shader
   - Viewport 2 (bottom-left): edge texture
   - Viewport 3 (bottom-right): live + box overlay (read-only snapshot of detector output)
8. HUD chrome (corner brackets, pane labels, footer with FPS + detector ms + model name).

## Performance targets

| Stage | Budget | Notes |
|---|---|---|
| Render thread total | ≤ 8 ms typical | Plenty of headroom inside 16.6 ms vsync. |
| MPS Sobel | < 1 ms | GPU-native, 1080p. |
| Jarvis fragment | < 1 ms | Math-only fragment shader. |
| Object detection | 5–15 ms | Off the render thread on a serial background queue. |
| Detector cadence | ~20 Hz | Decoupled from render; renderer reuses last result between detections. |

`MLModelConfiguration.computeUnits = .all` so Vision picks the ANE when available.

## Technology choices

| Decision | Selected | Rationale |
|---|---|---|
| OS / toolchain | macOS 26 Tahoe, Swift 6 | Matches VoicePOC; modern Vision/Metal APIs. |
| Project gen | XcodeGen (`project.yml`) | Matches MetalPOC; SPM doesn't fit (need AppKit app + Info.plist + resources). |
| Window | Regular resizable `NSWindow` | POC is meant to be inspected, not floated over the desktop. |
| Camera format | `kCVPixelFormatType_32BGRA` @ 1080p30 | Metal-friendly; no YUV→RGB shader needed. Step-down to 720p available via `Theme.Performance`. |
| Detector | Vision built-ins (saliency + face + human + animal) | No model file to source/convert/bundle; runs on ANE; ships today. YOLOv8s left as future enhancement behind a `Theme.Performance.detectorModel` knob. |
| Edge algorithm | `MPSImageSobel` + threshold | Built-in, GPU-fast. Canny would add 3 passes for marginal POC value. |
| Zero-copy | `CVMetalTextureCache` | Eliminates 2–4 ms/frame of CPU-to-GPU transfer per pane. |
| HUD chrome | Reuse MetalPOC `TextRasterizer` + Theme palette/fonts | Don't reinvent. |
| Tests | None for v1 | YAGNI — visual POC. Smoke-test documented in README. |

## Project layout

```
VisionPOC/
├── project.yml
├── README.md
├── CONTRIBUTING.md
├── LICENSE
├── .gitignore
├── docs/
│   └── superpowers/specs/
│       └── 2026-05-15-visionpoc-design.md
└── Sources/
    ├── App/
    │   ├── AppDelegate.swift
    │   ├── MainWindowController.swift
    │   └── Info.plist                  ← includes NSCameraUsageDescription
    ├── Capture/
    │   └── CameraCapture.swift
    ├── Process/
    │   ├── ObjectDetector.swift
    │   ├── EdgePass.swift
    │   └── JarvisStylePass.swift
    ├── Render/
    │   ├── Renderer.swift
    │   ├── Pipelines.swift
    │   └── FrameContext.swift
    ├── Shaders/
    │   ├── Common.metal
    │   ├── Live.metal
    │   ├── Jarvis.metal
    │   ├── Edges.metal
    │   └── Boxes.metal
    ├── Text/
    │   └── TextRasterizer.swift        ← copied from MetalPOC
    ├── Resources/
    │   └── Fonts/                      ← copied from MetalPOC
    └── Theme.swift
```

## Permissions

`Info.plist`:

- `NSCameraUsageDescription` — "VisionPOC processes a live camera feed to demonstrate Metal and Neural Engine vision pipelines."

First launch triggers the macOS camera permission prompt. On denial, the app displays a clear failure label and continues running so the user can retry after granting permission in System Settings.

## Theme.swift surface

Mirrors MetalPOC's `Theme.swift` structure:

- `Theme.Palette` — cyan tint, scanline color, edge color, box stroke, label colors
- `Theme.Layout` — pane positions and sizes (2×2 grid, screen-normalized)
- `Theme.Font` — Share Tech Mono (body), Orbitron (titles)
- `Theme.Tick` — render cadence, detector target Hz, glitch interval (off by default)
- `Theme.Performance.profile` — `.balanced` (720p, ~15 Hz detector) | `.quality` (1080p, ~20 Hz detector). Default `.quality`.
- `Theme.Performance.capturePreset` — 1080p30 default
- `Theme.Performance.detectorTargetHz` — 20 default
- `Theme.Performance.detectorModel` — `.visionBuiltIn` default; placeholder for future `.yolov8s`

## Build & run (target)

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project VisionPOC.xcodeproj -scheme VisionPOC -configuration Debug build
open build/Debug/VisionPOC.app
```

Smoke-test checklist:

1. macOS shows camera permission prompt → grant access.
2. Window opens with a 2×2 grid.
3. LIVE pane shows raw feed.
4. JARVIS pane shows tinted/scanlined feed.
5. EDGES pane shows white-on-black edge map that responds to motion.
6. DETECT pane shows live feed with cyan bounding boxes around faces/humans/objects.
7. FPS counter in footer stays ≥ 55.

## Future work (out of scope for v1)

- Swap detector to bundled YOLOv8s `.mlpackage` for richer class labels
- Add a `Theme.Glitch` post-process (RGB-split flash) like MetalPOC's
- Frame recording / export
- Multi-camera picker
- Configurable layout (1 large + 3 thumbs, 4-wide row)
- Optional transparent floating-HUD mode

## References

- Sibling: `../MetalPOC/` — Jarvis HUD rendering spine, source of TextRasterizer + fonts + Theme pattern
- Sibling: `../VoicePOC/docs/superpowers/specs/2026-05-14-voicepoc-design.md` — spec convention precedent
- GitHub org: `github.com/KofTwentyTwo`
