import SwiftUI

/// "What VisionPOC knows right now" panel. Reads three live sources at 4 Hz:
/// the ObjectDetector for current detections / FPS / inference timing, the
/// CurrentStateStore for hands / expression / activity / recent gestures,
/// and the HistoryStore for a small "recent events" tail.
///
/// Surfaced via ⌘I in the App menu.
struct StatusView: View {
    /// Provided by the AppDelegate at window construction. Returns the
    /// current state of the world or nil if the detector isn't reachable.
    let detectorAccess: @MainActor () -> DetectorSnapshot?

    @State private var snapshot: DetectorSnapshot = .empty
    @State private var state: CurrentStateStore.Snapshot = CurrentStateStore.shared.snapshot()
    @State private var recent: [HistoryEntry] = []
    @State private var historyVersion: UInt64 = 0
    @State private var stateVersion: UInt64 = 0

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            scroll
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 480, idealHeight: 640)
        .background(Color(white: 0.07))
        .onReceive(pollTimer) { _ in tick() }
        .onAppear { tick() }
    }

    private func tick() {
        if let s = detectorAccess() { snapshot = s }
        let sv = CurrentStateStore.shared.version
        if sv != stateVersion {
            state = CurrentStateStore.shared.snapshot()
            stateVersion = sv
        }
        let hv = HistoryStore.shared.version
        if hv != historyVersion {
            let entries = HistoryStore.shared.snapshot()
            recent = Array(entries.reversed().prefix(8))
            historyVersion = hv
        }
    }

    @ViewBuilder
    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider().background(Color(white: 0.18))
                objectsSection
                facesSection
                handsSection
                expressionActivitySection
                recentSection
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VISIONPOC STATUS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color(red: 0.20, green: 0.90, blue: 0.95))
            HStack(spacing: 16) {
                kv("FPS", String(format: "%.1f", snapshot.fps))
                kv("DET", String(format: "%.1f ms (%@)", snapshot.lastInferenceMs, snapshot.detectMode))
            }
        }
    }

    @ViewBuilder
    private var objectsSection: some View {
        section(title: "OBJECTS (\(snapshot.objects.count))",
                color: Color(red: 0.20, green: 0.90, blue: 0.95)) {
            if snapshot.objects.isEmpty {
                empty("nothing tracked")
            } else {
                ForEach(Array(snapshot.objects.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 8, height: 8)
                        Text(item.label.lowercased())
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(Int(item.confidence * 100))%")
                            .foregroundStyle(.secondary)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private var facesSection: some View {
        section(title: "FACES (\(snapshot.faces.count))",
                color: Color(red: 0.30, green: 1.00, blue: 0.75)) {
            if snapshot.faces.isEmpty {
                empty("no face in frame")
            } else {
                ForEach(Array(snapshot.faces.enumerated()), id: \.offset) { _, face in
                    HStack {
                        Text(face.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if let d = face.distance {
                            Text(String(format: "dist %.1f", d))
                                .foregroundStyle(.secondary)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private var handsSection: some View {
        section(title: "HANDS",
                color: Color(red: 1.00, green: 0.75, blue: 0.20)) {
            if state.fingerCounts.isEmpty {
                empty("no hands in frame")
            } else {
                let keys = state.fingerCounts.keys.sorted()
                ForEach(keys, id: \.self) { key in
                    HStack {
                        Text(key.capitalized)
                            .foregroundStyle(.primary)
                            .frame(width: 80, alignment: .leading)
                        Text("\(state.fingerCounts[key] ?? 0) fingers")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private var expressionActivitySection: some View {
        section(title: "STATE",
                color: Color(red: 0.80, green: 0.55, blue: 1.00)) {
            HStack {
                Text("Expression")
                    .frame(width: 100, alignment: .leading)
                    .foregroundStyle(.primary)
                Text(state.expression ?? "—")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(.caption, design: .monospaced))
            HStack {
                Text("Activity")
                    .frame(width: 100, alignment: .leading)
                    .foregroundStyle(.primary)
                Text(state.activity ?? "—")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        section(title: "RECENT",
                color: Color(white: 0.6)) {
            if recent.isEmpty {
                empty("waiting for events")
            } else {
                ForEach(recent) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.timeFormatter.string(from: entry.timestamp))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(entry.summary)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    // MARK: - View builders

    @ViewBuilder
    private func section<Content: View>(title: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(color)
            content()
        }
    }

    @ViewBuilder
    private func kv(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
            Text(value)
                .foregroundStyle(.primary)
                .font(.system(.caption, design: .monospaced))
        }
    }

    @ViewBuilder
    private func empty(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.system(.caption, design: .monospaced))
            .italic()
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
}

/// What StatusView needs from the detector each tick. Built on MainActor
/// from the live ObjectDetector + Renderer.
struct DetectorSnapshot: Sendable {
    struct ObjectEntry: Sendable {
        let label: String
        let confidence: Float
        let color: Color
    }
    struct FaceEntry: Sendable {
        let name: String
        let distance: Float?
    }
    var fps: Double = 0
    var lastInferenceMs: Double = 0
    var detectMode: String = "—"
    var objects: [ObjectEntry] = []
    var faces: [FaceEntry] = []

    static let empty = DetectorSnapshot()
}
