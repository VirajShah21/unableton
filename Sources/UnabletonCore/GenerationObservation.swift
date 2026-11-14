import Foundation

public enum DraftObservationStatus: String, Codable, Sendable {
    case disabled, pending, completed, unavailable, canceled
}

/// Evidence belongs to a specific generation snapshot, including after Undo.
/// Jev's versioned response is data only; it never authorizes musical commands.
public struct GenerationObservation: Codable, Sendable, Equatable {
    public var analysis: MusicalAnalysisReport
    public var status: DraftObservationStatus
    public var review: JSONValue?
    public var message: String?

    public init(analysis: MusicalAnalysisReport, status: DraftObservationStatus = .disabled, review: JSONValue? = nil, message: String? = nil) {
        self.analysis = analysis; self.status = status; self.review = review; self.message = message
    }
}
