import AppKit
import CoreGraphics
import simd

/// All tunable parameters for VisionPOC.
/// Edit a value here, rebuild, see the effect everywhere it's used.
enum Theme {

    // MARK: - Palette

    enum Palette {
        /// Primary cyan tint used everywhere (corner brackets, box strokes, scanline highlights).
        static let cyan = SIMD4<Float>(0.20, 0.95, 1.00, 1.0)
        /// Dimmer cyan for secondary chrome.
        static let cyanDim = SIMD4<Float>(0.10, 0.55, 0.62, 1.0)
        /// Background fill behind panes.
        static let background = SIMD4<Float>(0.02, 0.03, 0.04, 1.0)
        /// Pane label text.
        static let label = SIMD4<Float>(0.85, 0.98, 1.00, 1.0)
        /// Footer micro-readouts.
        static let micro = SIMD4<Float>(0.55, 0.85, 0.92, 1.0)
        /// Edge map foreground (white-on-black look).
        static let edgeForeground = SIMD4<Float>(0.85, 1.00, 1.00, 1.0)
        /// Bounding-box stroke.
        static let boxStroke = SIMD4<Float>(0.20, 0.95, 1.00, 1.0)
        /// Bounding-box label background.
        static let boxLabelBg = SIMD4<Float>(0.0, 0.15, 0.18, 0.85)
    }

    // MARK: - Layout

    enum Layout {
        /// 2x2 grid pane normalized rects (origin bottom-left, 0..1).
        /// [topLeft, topRight, bottomLeft, bottomRight]
        static let panes: [CGRect] = [
            CGRect(x: 0.02, y: 0.52, width: 0.47, height: 0.46), // top-left LIVE
            CGRect(x: 0.51, y: 0.52, width: 0.47, height: 0.46), // top-right JARVIS
            CGRect(x: 0.02, y: 0.04, width: 0.47, height: 0.46), // bottom-left EDGES
            CGRect(x: 0.51, y: 0.04, width: 0.47, height: 0.46)  // bottom-right DETECT
        ]
        static let paneLabels: [String] = ["LIVE", "JARVIS", "EDGES", "ASCII"]
        /// Window default size on first launch.
        static let defaultWindowSize = CGSize(width: 1440, height: 900)
        /// Window minimum size.
        static let minWindowSize = CGSize(width: 800, height: 500)
    }

    // MARK: - Font

    enum Font {
        static let bodyName = "ShareTechMono-Regular"
        static let titleName = "Orbitron-Bold"
        static let bodyFallback = "Menlo"
        static let titleFallback = "Helvetica Neue"

        static let paneLabelSize: CGFloat = 18
        static let footerSize: CGFloat = 12
        static let boxLabelSize: CGFloat = 11

        static func body(_ size: CGFloat) -> NSFont {
            NSFont(name: bodyName, size: size) ?? NSFont(name: bodyFallback, size: size) ?? NSFont.systemFont(ofSize: size)
        }

        static func title(_ size: CGFloat) -> NSFont {
            NSFont(name: titleName, size: size) ?? NSFont(name: titleFallback, size: size) ?? NSFont.boldSystemFont(ofSize: size)
        }
    }

    // MARK: - Capture & Detection

    enum Performance {
        enum Profile {
            case balanced  // 720p, 15 Hz detector
            case quality   // 1080p, 20 Hz detector
        }
        static let profile: Profile = .quality

        static var capturePreset: AVCapturePresetName {
            switch profile {
            case .balanced: return .preset1280x720
            case .quality:  return .preset1920x1080
            }
        }

        static var detectorTargetHz: Double {
            switch profile {
            case .balanced: return 15
            case .quality:  return 20
            }
        }

        /// Maximum number of boxes to keep from detector output (saliency can return many regions).
        static let maxDetectionsPerFrame = 20

        /// Minimum normalized area for a box to be drawn (filters out tiny noise regions).
        static let minBoxArea: CGFloat = 0.001

        /// Bundled object detector model. The .mlmodel file must live under
        /// `Sources/Resources/Models/<name>.mlmodel` so Xcode compiles it into
        /// the app bundle as `<name>.mlmodelc`.
        static let detectorModelName: String = "YOLOv3"

        // MARK: - Live tunables
        //
        // These values are mutated at runtime by the Settings panel. Detector
        // and renderer code paths read them many times per second from various
        // queues; primitives (Float/Double/Int) are word-sized on Apple
        // Silicon so the explicit `nonisolated(unsafe)` is honest about the
        // intent: cooperative single-writer (MainActor UI) and many readers.

        /// Sobel magnitude threshold for the edges pane. Higher values produce
        /// fewer, more confident edge pixels. Values are unit-normalized [0..1].
        nonisolated(unsafe) static var edgeThreshold: Float = 0.18

        /// ASCII art pane: number of character cells across the pane horizontally.
        /// The vertical cell count is derived to match the source aspect ratio.
        nonisolated(unsafe) static var asciiColumns: Int = 120

        /// Minimum top-label confidence (0..1) for a YOLO detection to be drawn.
        /// Lower values surface more objects but include weaker guesses.
        nonisolated(unsafe) static var detectionMinConfidence: Float = 0.30

        /// How often YOLO re-detects (Hz). Between detections, `VNTrackObjectRequest`
        /// updates positions on every submitted frame, so boxes follow objects
        /// smoothly. Lower the rate to spend less ANE budget on detection.
        nonisolated(unsafe) static var yoloDetectionHz: Double = 5.0

        /// Tracks expire if YOLO doesn't re-confirm them within this many seconds.
        /// Cover brief occlusions but drop ghosts of objects that left the scene.
        nonisolated(unsafe) static var trackMaxAgeSeconds: Double = 0.6

        /// Minimum tracker confidence to keep a track alive between YOLO refreshes.
        /// Vision's tracker reports 0..1; anything below this is treated as lost.
        nonisolated(unsafe) static var trackerMinConfidence: Float = 0.3

        /// IoU threshold for matching a new YOLO detection to an existing track.
        /// Above this, the existing track is refreshed; below, a new track is
        /// bootstrapped.
        nonisolated(unsafe) static var trackMatchIoU: Float = 0.4

        /// Face match threshold for FaceRegistry. Tuned for image-FeaturePrint
        /// distances on padded face crops (those run ~10–25; same-person
        /// matches usually <18, different people >25).
        nonisolated(unsafe) static var faceMatchThreshold: Float = 18.0
    }

    // MARK: - Tick

    enum Tick {
        /// Target render FPS (display vsync usually caps this).
        static let renderFPS: Double = 60
        /// Scanning beam vertical sweep period in seconds.
        static let scanningBeamPeriod: Double = 3.0
        /// Scanline density (lines per normalized vertical unit, JARVIS pane).
        static let scanlineDensity: Float = 220.0
        /// Hex grid scale (JARVIS pane).
        static let hexGridScale: Float = 28.0
    }

    // MARK: - HUD chrome

    enum HUD {
        static let cornerBracketLength: CGFloat = 16
        static let cornerBracketThickness: CGFloat = 2
        static let paneFrameInset: CGFloat = 6
        static let footerHeight: CGFloat = 22
    }
}

/// Type-safe wrapper around AVCaptureSession.Preset string values to keep Theme.swift framework-light.
struct AVCapturePresetName: RawRepresentable, Equatable {
    let rawValue: String
    static let preset1280x720 = AVCapturePresetName(rawValue: "AVCaptureSessionPreset1280x720")
    static let preset1920x1080 = AVCapturePresetName(rawValue: "AVCaptureSessionPreset1920x1080")
}
