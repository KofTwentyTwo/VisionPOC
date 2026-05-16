import SwiftUI

/// SwiftUI viewer for the Detection History ring buffer. Mirrors the Log
/// Stream viewer's behavior and controls so both windows feel identical:
/// oldest-to-newest order with auto-scroll-to-bottom on append, plus
/// Pause and Auto-scroll toggles, a Category filter, and a Clear button.
struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var lastVersion: UInt64 = 0
    @State private var categoryFilter: Set<String> = Set(HistoryView.allCategories)
    @State private var autoScroll: Bool = true
    @State private var paused: Bool = false

    private let pollTimer = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    static let allCategories: [String] = [
        "object", "face-known", "face-unknown", "ocr",
        "gesture", "activity", "spatial"
    ]

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 360, idealHeight: 540)
        .background(Color(white: 0.07))
        .onReceive(pollTimer) { _ in
            guard !paused else { return }
            let v = HistoryStore.shared.version
            guard v != lastVersion else { return }
            entries = HistoryStore.shared.snapshot()
            lastVersion = v
        }
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

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Toggle("Pause", isOn: $paused)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Spacer()

            Text("\(filteredEntries.count) / \(entries.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Button("Clear") {
                HistoryStore.shared.clear()
                entries = []
                lastVersion = HistoryStore.shared.version
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.10))
    }

    /// Oldest-first, matching the Log Stream. Newest entries arrive at the
    /// bottom and the ScrollViewReader pins the viewport there when
    /// auto-scroll is on.
    private var filteredEntries: [HistoryEntry] {
        entries.filter { categoryFilter.contains($0.category) }
    }

    @ViewBuilder
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEntries) { entry in
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
            .onChange(of: filteredEntries.last?.id) { _, newValue in
                guard autoScroll, let last = newValue else { return }
                withAnimation(.linear(duration: 0.06)) {
                    proxy.scrollTo(last, anchor: .bottom)
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
