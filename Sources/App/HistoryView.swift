import SwiftUI

/// SwiftUI viewer for the Detection History ring buffer. Polls at 1 Hz
/// because the history is meant to be read, not watched in real-time —
/// keeping render cost down lets the main window stay smooth.
struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var lastVersion: UInt64 = 0
    @State private var categoryFilter: Set<String> = Set(HistoryView.allCategories)

    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    static let allCategories: [String] = [
        "object", "face-known", "face-unknown", "ocr",
        "gesture", "activity", "spatial"
    ]

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 360, idealHeight: 520)
        .background(Color(white: 0.07))
        .onAppear { refresh(force: true) }
        .onReceive(pollTimer) { _ in refresh(force: false) }
    }

    private func refresh(force: Bool) {
        let v = HistoryStore.shared.version
        if !force && v == lastVersion { return }
        entries = HistoryStore.shared.snapshot()
        lastVersion = v
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu("Category") {
                ForEach(HistoryView.allCategories, id: \.self) { cat in
                    Toggle(cat, isOn: Binding(
                        get: { categoryFilter.contains(cat) },
                        set: { isOn in
                            if isOn { categoryFilter.insert(cat) } else { categoryFilter.remove(cat) }
                        }
                    ))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Text("\(filtered.count) / \(entries.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Button("Clear") {
                HistoryStore.shared.clear()
                refresh(force: true)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.10))
    }

    private var filtered: [HistoryEntry] {
        // Newest-first feels right for a history reader — scan recent first.
        entries.reversed().filter { categoryFilter.contains($0.category) }
    }

    @ViewBuilder
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.timeFormatter.string(from: entry.timestamp))
                            .foregroundStyle(.secondary)
                        Text(entry.category)
                            .foregroundStyle(color(for: entry.category))
                            .frame(width: 90, alignment: .leading)
                        Text(entry.summary)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .id(entry.id)
                }
            }
        }
    }

    private func color(for category: String) -> Color {
        switch category {
        case "object":        return Color(red: 0.20, green: 0.90, blue: 0.95) // cyan
        case "face-known":    return Color(red: 0.30, green: 1.00, blue: 0.75) // mint
        case "face-unknown":  return Color(white: 0.55)
        case "ocr":           return Color(red: 1.00, green: 0.45, blue: 0.85) // magenta
        case "gesture":       return Color(red: 1.00, green: 0.75, blue: 0.20) // amber
        case "activity":      return .yellow
        case "spatial":       return Color(red: 0.80, green: 0.55, blue: 1.00) // purple
        default:              return .secondary
        }
    }
}
