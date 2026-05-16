import Foundation

/// One row in the Detection History viewer. Materialized from a
/// `DetectionEvent` at the moment it crosses the bus, so the viewer never
/// has to reach back into the detector to render.
struct HistoryEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let summary: String
    let category: String
}
