import SwiftUI
import AppKit
import UnabletonCore
import UnabletonAI

struct GenerationObservationView: View {
    let observation: GenerationObservation
    var requests: Int?
    var retries: Int?

    private var analysis: MusicalAnalysisReport { observation.analysis }
    private var review: DraftReviewObservation? { try? observation.review?.decode(DraftReviewObservation.self) }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                Text("\(analysis.after.trackCount) tracks · \(analysis.after.noteCount) notes · \(analysis.after.drumNoteCount) drum events")
                Text("Tracks: \(analysis.changes.tracks.addedCount) added, \(analysis.changes.tracks.changedCount) changed, \(analysis.changes.tracks.deletedCount) removed.")
                Text("Note edits in \(analysis.changes.noteChangedClipCount) existing \(analysis.changes.noteChangedClipCount == 1 ? "clip" : "clips").")
                if !analysis.changes.globalFields.isEmpty { Text("Project changes: " + analysis.changes.globalFields.joined(separator: ", ")) }
                if let requests { Text("Composer: \(requests) requests · \(retries ?? 0) transient retries") }
                Text("Symbolic measurements only. Activity and generated-vocal coverage do not measure sound quality or actual singing.")
                    .foregroundStyle(.secondary)
                if let message = observation.message { Text(message).foregroundStyle(.secondary) }
                if let review {
                    Text("Jev observation · \(review.model)").fontWeight(.medium)
                    ForEach(review.checks) { check in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(check.criterion.title): \(statusLabel(check.status))")
                            Text("Reported probabilities — relevant: \(percent(check.applicabilityProbability)), evidence: \(percent(check.evidenceProbability)), issue: \(percent(check.issueProbability))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("\(review.inputTokens) input tokens · \(review.durationSeconds, specifier: "%.2f") seconds. Findings did not change the generation.")
                        .foregroundStyle(.secondary)
                    if review.promptTruncated || review.summaryTruncated || review.analysisTruncated {
                        Text("The review used shortened context. Some requirements may be unassessable.").foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Timeline measurements") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Uniform time windows, not detected sections.").foregroundStyle(.secondary)
                        ForEach(Array(analysis.after.windows.enumerated()), id: \.offset) { _, window in
                            Text("Beat \(window.startBeat + 1, specifier: "%.0f"): \(window.audibleActiveTrackCount) active tracks · \(window.audibleNoteOnsets) note onsets · \(window.audibleDrumOnsets) drum onsets")
                        }
                    }
                }
                if analysis.before.truncated || analysis.after.truncated || analysis.changes.idsTruncated {
                    Text("Analysis detail is bounded; exact entity totals are retained. See the copied report for limits.").foregroundStyle(.secondary)
                }
                Button("Copy Analysis") { copyReport() }.buttonStyle(.link)
            }.font(.caption).textSelection(.enabled).padding(.top, 5)
        } label: {
            Label(label, systemImage: "chart.bar.xaxis").font(.caption)
        }
    }

    private var label: String {
        switch observation.status {
        case .disabled: "Draft analysis · local"
        case .pending: "Draft analysis · Jev reviewing"
        case .completed: "Draft analysis · Jev observed"
        case .unavailable: "Draft analysis · Jev unavailable"
        case .canceled: "Draft analysis · review canceled"
        }
    }

    private func statusLabel(_ status: DraftReviewCheckStatus) -> String {
        switch status {
        case .notApplicable: "Not requested"
        case .insufficientEvidence: "Insufficient evidence"
        case .flagged: "Possible issue"
        case .noConcern: "No concern reported"
        case .uncertain: "Uncertain"
        }
    }
    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    private func copyReport() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(observation), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
