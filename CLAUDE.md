# VisionPOC

## What this is

VisionPOC is a real-time camera-vision proof of concept for macOS. It is a sibling project to **MetalPOC** (Metal rendering experiments) and **VoicePOC** (speech I/O), part of the broader **Jarvis** program — a personal-assistant stack that fuses local-first perception (cameras, mics) with downstream LLM reasoning. VisionPOC focuses on the perception layer: capture frames from a camera, run them through Vision/CoreML pipelines (object detection, face recognition, text/gesture/activity recognition, spatial reasoning), and render annotated overlays via Metal at 60 Hz.

## Build & run

```sh
brew install xcodegen
xcodegen generate          # writes VisionPOC.xcodeproj
git lfs pull               # one-time: pulls the YOLOv8x-OIV7 weights (~131 MB)
xcodebuild -scheme VisionPOC -destination 'platform=macOS' build
open build/Debug/VisionPOC.app
```

Or open `VisionPOC.xcodeproj` in Xcode 26+ and run.

## Project layout

```
Sources/
  App/          NSApp lifecycle, all secondary windows, menus, user state
    AppDelegate.swift             entry point, menu wiring (5 menus)
    MainWindowController.swift    main camera-view window
    LogStream.swift               ring buffer (1000 entries) + stdout mirror
    LogStreamView.swift           SwiftUI viewer
    LogStreamWindowController.swift
    SettingsView.swift            live tuning UI + diagnostics + output paths
    SettingsWindowController.swift
    StatusView.swift              "what we know right now" panel
    StatusWindowController.swift
    HistoryEntry.swift            DetectionEvent → human-readable row
    HistoryStore.swift            500-entry semantic event ring
    HistoryView.swift             SwiftUI viewer (same controls as LogStream)
    HistoryWindowController.swift
    AboutView.swift               credits + tech stack + license
    AboutWindowController.swift
    CurrentStateStore.swift       Latest expression / activity / per-hand finger counts / recent gestures — singleton subscribed to DetectionEventBus
    OutputLocations.swift         Persistent snapshot/recording directories via security-scoped bookmarks
  Capture/
    CameraCapture.swift           AVCaptureSession + CVMetalTextureCache + device switching + disconnect handling
  Process/      pure-Swift detection/recognition layer
    ObjectDetector.swift          YOLO + Vision + tracker orchestrator (the brain)
    DetectionEvents.swift         enum DetectionEvent.Kind (vocabulary)
    DetectionEventBus.swift       Sendable pub/sub singleton with Token-based unsubscribe
    FaceRegistry.swift            on-disk per-name FeaturePrint store + matchThreshold
    TrackStore.swift              label → UUID persistence across launches
    Greeter.swift                 TTS subscriber on .faceRecognized (mutable + privacy-aware)
    GestureRecognizer.swift       hand-pose → discrete gestures
    ActivityRecognizer.swift      body-pose → discrete activities
    FingerCounter.swift           Extended-finger count per hand chirality
    FacialExpressionAnalyzer.swift outerLips landmarks → smile / frown / neutral
    SpatialReasoner.swift         "near", "above", "inside", "holding"
    AsciiPass.swift               Glyph atlas + uniforms for ASCII pane
    EdgePass.swift                MPS Sobel + threshold compute kernel
    JarvisStylePass.swift         Per-frame uniforms for jarvis_fragment
    ProcessedFrame.swift          TextDetection / PoseDetection / DetectMode types
  Render/       Metal pipeline
    Renderer.swift                main draw loop, pane layout, all overlay helpers
    Pipelines.swift               Metal pipeline state objects (live/jarvis/edges/ascii/boxes/text/lines)
    FrameContext.swift            per-frame transient state
    ColorHash.swift               stable trackId → hue
    Recorder.swift                @MainActor AVAssetWriter pipeline for ⇧⌘R
  Shaders/
    Common.metal, Live.metal, Jarvis.metal, Edges.metal, Boxes.metal (incl. line/dot shader), Ascii.metal
  Text/         TextRasterizer — CoreText → MTLTexture for HUD labels
  Resources/
    Fonts/      Orbitron, ShareTechMono (SIL OFL)
    Models/     yolov8x-oiv7.mlpackage (Git LFS — ~131 MB)
  Theme.swift   single source of truth: palette, layout, fonts, performance knobs
```

## Windows & shortcuts

Five secondary windows live alongside the main camera grid. Each has its own controller in `Sources/App/`, persists its window frame via `UserDefaults`, and is opened lazily.

| Window | Key | Backing store(s) |
|---|---|---|
| Main 4-pane grid | (default) | live `ObjectDetector` + `Renderer` |
| Settings | ⌘, | `TunableSettings` (mirrors `Theme.Performance.*` vars) |
| Status Panel | ⌘I | `CurrentStateStore.shared` + live `ObjectDetector` + `HistoryStore` tail |
| Detection History | ⇧⌘H | `HistoryStore.shared` (500-entry ring of `HistoryEntry`s) |
| Log Stream | ⌘L | `LogStream.shared` (1000-entry ring of subsystem log lines) |
| About | (menu) | static |

| Action | Key |
|---|---|
| Enroll Face… | ⌘E |
| Forget Face… | ⇧⌘E |
| Save Snapshot | ⌘S |
| Start / Stop Recording | ⇧⌘R |
| Privacy Mode | ⇧⌘P |

Note: ⌘H is intentionally NOT bound here — it's reserved for the standard macOS "Hide Application" shortcut. The History window uses ⇧⌘H.

## Theme tunables

`Sources/Theme.swift` is the single source of truth for visual styling and performance knobs. Two distinct categories:

- `static let` constants for compile-time-fixed values (font names, glyph atlas size, anything baked into shaders at startup).
- `nonisolated(unsafe) static var` for **live-tunable** values — these can be poked at runtime by the Settings panel (`⌘,`) and the next frame picks them up. Use this for thresholds (face-match distance, IoU dedupe), animation timings, colors, and pane layouts.

When adding a new tunable, default the `var` to the same value the old `let` had, and add a SwiftUI control in `SettingsView.swift`.

## Pipelines

**Capture → Process → Render** runs every frame:

1. **Capture** — `CameraCapture` delivers `CVPixelBuffer`s on a serial queue.
2. **Process** — `ObjectDetector.detectAndBootstrap(_:)` fans out Vision/CoreML requests (objects, faces, text, hands, ...) and merges results into a `ProcessedFrame`. Tracked identities live in `TrackStore`. Cross-cutting observations (an appearance, a recognized face) are emitted on `DetectionEventBus`.
3. **Render** — `Renderer` consumes the `ProcessedFrame` on the main thread, picks a pane layout, draws the camera image plus per-pane overlays (boxes, labels, ASCII, edges, Jarvis HUD).

## Detection events

`Sources/Process/DetectionEvents.swift` defines the event vocabulary (object appeared/disappeared/refreshed, face recognized, text/gesture/activity detected, spatial relation). `Sources/Process/DetectionEventBus.swift` is the singleton pub/sub. Producers call `DetectionEventBus.shared.emit(.kind)`; consumers hold a `Token` returned by `subscribe(_:)`. Handlers run on the emitter's thread — hop to MainActor yourself if you need it.

## Observability

`LogStream` lives at `Sources/App/LogStream.swift`. It is a 1000-entry ring buffer + stdout mirror. Sources are tagged: **APP / CAM / DETECT / TRACK / FACE / RENDER / VPOC**. Use `LogStream.shared.log("...", level: .info, source: .detect)`.

- **⌘L** in the running app opens the live viewer window.
- Same entries are also written to stdout, so `log stream --process VisionPOC` works from a terminal.
- The buffer is bounded; expect oldest entries to evict silently.

## Settings

**⌘,** opens the live tuning panel. Bound to `TunableSettings` / `Theme.Performance` and related static vars. Sliders push directly into the `nonisolated(unsafe)` vars in `Theme.swift`. No restart required.

Settings also exposes:
- **Output Locations** — picker buttons that open `NSOpenPanel`, store the chosen folder as a security-scoped bookmark via `OutputLocations`. ⌘S / ⇧⌘R write to these paths instead of `~/Desktop`.
- **Diagnostics** — per-stage detector timing (Vision bundle / FeaturePrint / Tracker / Total) polled at 2 Hz from `ObjectDetector.lastStageTiming`.
- **Mute greeter** — surfaces the same flag as Privacy Mode (and is set by it).

## History

**⇧⌘H** opens the event history window. Same controls as the Log Stream (Category filter, Auto-scroll, Pause, count, Clear), oldest-on-top with auto-scroll-to-bottom. Backed by `HistoryStore.shared` which subscribes to `DetectionEventBus` once at first access.

## Status panel

**⌘I** opens the Status panel — the single most useful window for "is everything seeing what I think it should be seeing." Sections:

- **header** — FPS + DET ms + mode (yolo / track) from the live `Renderer` + `ObjectDetector`
- **OBJECTS (N)** — every active track, colored dot matches the JARVIS-pane box, sorted by confidence
- **FACES (N)** — recognized names from `FaceRegistry`
- **HANDS** — per-chirality finger counts written by `FingerCounter` into `CurrentStateStore`. Entries auto-expire ~1.2s after a hand leaves the frame.
- **STATE** — last `expression` and `activity` from `CurrentStateStore`
- **RECENT** — newest 8 entries from `HistoryStore`

The panel polls four times per second; the underlying state stores use lock-protected snapshots.

## Privacy mode (⇧⌘P)

Toggle that flips both `Theme.Performance.greeterMuted` and `Theme.Performance.faceRecognitionDisabled`. The greeter suppresses TTS. The `HistoryStore` filters face entries out of the timeline. Detector behavior for face *recognition* labels in the bounding boxes is left to the detector's discretion — the flag is informational.

## Adding a new detector

1. Build a `VNRequest` (or CoreML wrapper) and a thread-safe result accessor.
2. Wire it into `ObjectDetector.detectAndBootstrap(_:)` alongside the existing requests so it runs on the same frame.
3. Define a new case in `DetectionEvent.Kind` if downstream consumers care.
4. Emit on `DetectionEventBus.shared` from inside the request completion.
5. If the result needs rendering, add a draw helper in `Renderer` and a pane case for it.

## Adding a new HUD overlay

1. Add the palette color (and any sizes) to `Theme.swift`.
2. Add a `drawXxx(...)` helper to `Renderer.swift` that issues a `pipelines.boxes` (or appropriate) draw with the right uniforms.
3. Call it from the pane switch inside `Renderer.draw(_:)` for the pane case that should show it.

## Build idiosyncrasies

- **XcodeGen owns the project**. Never hand-edit `VisionPOC.xcodeproj`. Edit `project.yml`, run `xcodegen generate`.
- **LFS holds the YOLO model.** Run `git lfs pull` after clone or the model file will be a 132-byte pointer. The app tolerates a missing model (`ObjectDetector` logs "model not found" and falls back to Vision built-ins), so the build does not fail without it.
- **Test target** (`VisionPOCTests`) builds without the model. Tests cover pure-logic units (IoU, aspect-fit, log buffer, event bus) and do not require Vision fixtures.
- **macOS 26 SDK + Swift 6.** Concurrency checking is strict; `nonisolated(unsafe)` annotations are deliberate.

## Known issues

- The bundled `Orbitron-Bold.ttf` is inherited from MetalPOC and is actually an HTML 404 page from a misfired download. `Theme.Font.title(_:)` falls back to Helvetica Neue cleanly; pane labels just lose their custom typography. Drop a real TTF in `Sources/Resources/Fonts/` to fix.
- No app icon yet (uses the default macOS application icon).
- IPC story for Jarvis-program integration (sharing events with VoicePOC / a central agent) is still TBD. The in-process `DetectionEventBus` is the primitive a future IPC layer would publish over.

## Conventions for agents working on this codebase

- **Never hand-edit `VisionPOC.xcodeproj`.** Always edit `project.yml` and re-run `xcodegen generate`.
- **Stay within scope.** When fanning out parallel agents, partition by file ownership (App / Process / Render / Tests) and lock cross-agent contracts BEFORE dispatch — `DetectionEvents.swift`, `ProcessedFrame.swift`, and protocol shapes are the typical contracts.
- **Don't add new files without considering placement.** Subsystems group by directory (`Sources/Process/` for detector logic, `Sources/App/` for UI/windows, `Sources/Render/` for Metal). A new analyzer goes in Process; a new window goes in App.
- **Trust the LogStream over print().** Use `LogStream.shared.log(_:level:source:)` so events show up in the live viewer AND on stdout.
- **Match the live-tunable convention.** New tunables get `nonisolated(unsafe) static var` in `Theme.Performance`, a mirror property in `TunableSettings` with a `didSet` writeback, and a SwiftUI control in `SettingsView`.
- **SourceKit warnings about "Cannot find type X in scope" are usually stale** — `xcodegen generate` re-syncs them after new files land. Trust `xcodebuild` over SourceKit's live diagnostics.
