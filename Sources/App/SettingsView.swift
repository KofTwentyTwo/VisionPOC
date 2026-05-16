import SwiftUI
import Observation

/// Snapshot of per-stage detector timings, surfaced to the Diagnostics
/// section in Settings. The App layer doesn't know about `DetectorStageTiming`
/// in the Process module; instead, the AppDelegate hands SettingsView a
/// closure that maps the live struct (if it exists yet) into this shape.
struct DiagnosticsTimingSnapshot: Sendable, Equatable {
    var visionBundleMs: Double
    var featurePrintMs: Double
    var trackerMs: Double
    var totalMs: Double

    static let zero = DiagnosticsTimingSnapshot(
        visionBundleMs: 0, featurePrintMs: 0, trackerMs: 0, totalMs: 0
    )
}

/// Mirrors `Theme.Performance`'s live-tunable values into an @Observable so
/// SwiftUI can bind sliders to them. Every property's `didSet` writes back
/// through to the static var so the detector/renderer (which read from
/// `Theme.Performance` directly on background queues) immediately see the
/// updated value.
@Observable
@MainActor
final class TunableSettings {
    static let shared = TunableSettings()

    var yoloHz: Double {
        didSet { Theme.Performance.yoloDetectionHz = yoloHz }
    }
    var detectionMinConfidence: Float {
        didSet { Theme.Performance.detectionMinConfidence = detectionMinConfidence }
    }
    var trackMaxAgeSeconds: Double {
        didSet { Theme.Performance.trackMaxAgeSeconds = trackMaxAgeSeconds }
    }
    var trackerMinConfidence: Float {
        didSet { Theme.Performance.trackerMinConfidence = trackerMinConfidence }
    }
    var trackMatchIoU: Float {
        didSet { Theme.Performance.trackMatchIoU = trackMatchIoU }
    }
    var edgeThreshold: Float {
        didSet { Theme.Performance.edgeThreshold = edgeThreshold }
    }
    var asciiColumns: Int {
        didSet { Theme.Performance.asciiColumns = asciiColumns }
    }
    var faceMatchThreshold: Float {
        didSet { Theme.Performance.faceMatchThreshold = faceMatchThreshold }
    }
    var greeterMuted: Bool {
        didSet { Theme.Performance.greeterMuted = greeterMuted }
    }

    /// Display paths for the snapshot/recording output directories. Stored
    /// here as @Observable strings so the labels in the Settings panel
    /// re-render as soon as the user picks a new folder. The authoritative
    /// values live in UserDefaults via `OutputLocations`.
    var snapshotPath: String = OutputLocations.snapshotDisplayPath()
    var recordingPath: String = OutputLocations.recordingDisplayPath()

    func refreshOutputPaths() {
        snapshotPath = OutputLocations.snapshotDisplayPath()
        recordingPath = OutputLocations.recordingDisplayPath()
    }

    private init() {
        self.yoloHz = Theme.Performance.yoloDetectionHz
        self.detectionMinConfidence = Theme.Performance.detectionMinConfidence
        self.trackMaxAgeSeconds = Theme.Performance.trackMaxAgeSeconds
        self.trackerMinConfidence = Theme.Performance.trackerMinConfidence
        self.trackMatchIoU = Theme.Performance.trackMatchIoU
        self.edgeThreshold = Theme.Performance.edgeThreshold
        self.asciiColumns = Theme.Performance.asciiColumns
        self.faceMatchThreshold = Theme.Performance.faceMatchThreshold
        self.greeterMuted = Theme.Performance.greeterMuted
    }

    func resetDefaults() {
        yoloHz = 5.0
        detectionMinConfidence = 0.30
        trackMaxAgeSeconds = 0.6
        trackerMinConfidence = 0.3
        trackMatchIoU = 0.4
        edgeThreshold = 0.18
        asciiColumns = 120
        faceMatchThreshold = 18.0
        // greeterMuted intentionally not reset — it's a user-visible state
        // tied to Privacy Mode; resetting tunables shouldn't unsilence TTS.
    }
}

struct SettingsView: View {
    @Bindable var settings = TunableSettings.shared

    /// If non-nil, the Diagnostics section polls this closure at 2 Hz and
    /// shows the per-stage detector timing. Hidden when nil (e.g. when the
    /// detector isn't available yet, or hasn't exposed timing).
    var timingProvider: (@MainActor () -> DiagnosticsTimingSnapshot?)?

    @State private var timing: DiagnosticsTimingSnapshot = .zero
    @State private var hasTiming: Bool = false
    private let diagnosticsTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Detection") {
                        slider("YOLO frequency",
                               value: $settings.yoloHz,
                               range: 1...20,
                               format: "%.1f Hz")
                        slider("Min confidence",
                               value: $settings.detectionMinConfidence,
                               range: 0.05...0.95,
                               format: "%.2f")
                    }

                    section("Tracking") {
                        slider("Max age (s) without YOLO refresh",
                               value: $settings.trackMaxAgeSeconds,
                               range: 0.1...3.0,
                               format: "%.2f s")
                        slider("Tracker min confidence",
                               value: $settings.trackerMinConfidence,
                               range: 0.0...0.9,
                               format: "%.2f")
                        slider("Match IoU",
                               value: $settings.trackMatchIoU,
                               range: 0.1...0.9,
                               format: "%.2f")
                    }

                    section("Faces") {
                        slider("Match threshold (lower = stricter)",
                               value: $settings.faceMatchThreshold,
                               range: 5.0...40.0,
                               format: "%.1f")
                        Text("Image FeaturePrint distances on face crops typically range 10–30. Same person usually <18, different people usually >24.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Mute greeter (TTS)", isOn: $settings.greeterMuted)
                            .toggleStyle(.checkbox)
                    }

                    section("Edges") {
                        slider("Sobel threshold",
                               value: $settings.edgeThreshold,
                               range: 0.0...0.8,
                               format: "%.2f")
                    }

                    section("ASCII") {
                        intSlider("Columns",
                                  value: $settings.asciiColumns,
                                  range: 20...300)
                    }

                    section("Output Locations") {
                        outputRow(
                            label: "Snapshots",
                            path: settings.snapshotPath,
                            chooseTitle: "Choose Snapshot Folder",
                            apply: { url in
                                OutputLocations.setSnapshotDirectory(url)
                                settings.refreshOutputPaths()
                            }
                        )
                        outputRow(
                            label: "Recordings",
                            path: settings.recordingPath,
                            chooseTitle: "Choose Recording Folder",
                            apply: { url in
                                OutputLocations.setRecordingDirectory(url)
                                settings.refreshOutputPaths()
                            }
                        )
                    }

                    if hasTiming {
                        section("Diagnostics") {
                            timingRow("Vision bundle", ms: timing.visionBundleMs)
                            timingRow("Feature print", ms: timing.featurePrintMs)
                            timingRow("Tracker",       ms: timing.trackerMs)
                            Divider().padding(.vertical, 2)
                            timingRow("Total",         ms: timing.totalMs)
                        }
                    }
                }
                .padding(20)
            }
            .onReceive(diagnosticsTimer) { _ in
                guard let provider = timingProvider, let snap = provider() else {
                    if hasTiming { hasTiming = false }
                    return
                }
                timing = snap
                if !hasTiming { hasTiming = true }
            }

            Divider()
            HStack {
                Button("Reset to defaults") { settings.resetDefaults() }
                Spacer()
                Text("Changes apply live; no need to restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520, idealHeight: 640)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            content()
        }
    }

    @ViewBuilder
    private func slider<V: BinaryFloatingPoint>(
        _ label: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        format: String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.body)
                Spacer()
                Text(String(format: format, Double(value.wrappedValue)))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    @ViewBuilder
    private func outputRow(
        label: String,
        path: String,
        chooseTitle: String,
        apply: @escaping (URL) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 84, alignment: .leading)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") {
                OutputLocations.chooseDirectory(title: chooseTitle) { url in
                    if let url = url { apply(url) }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func timingRow(_ label: String, ms: Double) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            Text(String(format: "%.1f ms", ms))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func intSlider(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        let doubleBinding = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Int($0.rounded()) }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.body)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: doubleBinding, in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }
}
