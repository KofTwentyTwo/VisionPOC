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
  App/          NSApp lifecycle, windows, ⌘L log viewer, ⌘, settings, ⌘H history
    AppDelegate.swift             entry point, menu wiring
    MainWindowController.swift    main camera-view window
    LogStream.swift               in-memory ring buffer (1000 entries) + stdout mirror
    LogStreamView.swift           SwiftUI viewer for LogStream
    LogStreamWindowController.swift
    SettingsView.swift            live tuning UI bound to TunableSettings
    SettingsWindowController.swift
  Capture/      AVFoundation → CVPixelBuffer
    CameraCapture.swift           camera enumeration + delegate-based frame stream
  Process/      pure-Swift detection/recognition layer
    ObjectDetector.swift          YOLO + Vision rectangle/track requests; the orchestrator
    FaceRegistry.swift            persisted feature-print store, distance match
    TrackStore.swift              identity tracking across frames
    DetectionEvents.swift         enum of cross-subsystem event kinds
    DetectionEventBus.swift       Sendable pub/sub singleton
    Greeter.swift                 TTS announcements for face/object appearances
    GestureRecognizer.swift       Vision hand-pose → gesture labels
    ActivityRecognizer.swift      time-windowed gesture/motion → activity labels
    SpatialReasoner.swift         "X is to the left of Y" derivations from rects
    AsciiPass.swift               renders frame as ASCII art (effect pane)
    EdgePass.swift                Sobel/edge pass
    JarvisStylePass.swift         Jarvis-themed HUD chrome
    ProcessedFrame.swift          per-frame bundle of detections passed to Renderer
  Render/       Metal pipeline
    Renderer.swift                main draw loop, pane layout, overlays
    Pipelines.swift               Metal pipeline state objects (boxes/edges/ascii/etc.)
    FrameContext.swift            per-frame transient state
    ColorHash.swift               stable label → color mapping
    Recorder.swift                Metal → mp4 capture
  Shaders/      .metal sources for each pass
  Text/         TextRasterizer — bitmap label rendering for Metal overlays
  Resources/
    Fonts/      Orbitron, ShareTechMono
    Models/     yolov8x-oiv7.mlpackage (LFS)
  Theme.swift   single source of truth for colors, sizes, rects, perf knobs
```

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

## History

**⌘H** opens the event history window — a scrollback of recent `DetectionEvent`s with timestamps and metadata. Useful for verifying that an emission actually fired and for replaying recent activity.

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

- Inherited HTML-derived Orbitron font name; on missing TTF it falls back to Helvetica. Cosmetic only.
- No app icon yet.
- IPC story for Jarvis-program integration (sharing events with VoicePOC / a central agent) is still TBD.
