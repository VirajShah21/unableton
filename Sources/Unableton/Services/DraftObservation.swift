import Foundation
import UnabletonCore
import UnabletonAI

enum DraftReviewPreferences {
    static let enabledKey = "ai.jev.observationEnabled"
}

extension ProjectSession {
    func analyzeAppliedDraft(runID: UUID, before: Song, after: Song, selection: ProjectSelection, prompt: String, summary: String) async {
        let analysis = await Task.detached(priority: .utility) {
            MusicalAnalyzer.analyze(before: before, after: after, selection: selection)
        }.value
        guard !closed, let index = file.generations.firstIndex(where: { $0.id == runID }) else { return }
        file.generations[index].observation = GenerationObservation(analysis: analysis)
        if !Task.isCancelled { observeDraft(runID: runID, prompt: prompt, summary: summary, analysis: analysis) }
    }

    /// Called only after the revision-validated musical transaction succeeds.
    /// This task never touches song, selection, composer continuation or Undo.
    func observeDraft(runID: UUID, prompt: String, summary: String, analysis: MusicalAnalysisReport) {
        guard reviewPreferences.bool(forKey: DraftReviewPreferences.enabledKey) else { return }
        // Bound background work even if many short answers arrive together.
        guard draftReviewTasks.count < 2 else {
            updateDraftObservation(runID, status: .unavailable, message: "Review skipped while other observations were running.")
            return
        }
        updateDraftObservation(runID, status: .pending)
        let reviewer = draftReviewer, keyProvider = reviewKeyProvider
        draftReviewTasks[runID] = Task { [weak self] in
            do {
                let key = try await Task.detached(priority: .utility) { try keyProvider() }.value
                try Task.checkCancellation()
                guard let self, !self.closed else { return }
                guard self.reviewPreferences.bool(forKey: DraftReviewPreferences.enabledKey) else {
                    self.updateDraftObservation(runID, status: .canceled, message: "Jev observation was turned off.")
                    self.draftReviewTasks.removeValue(forKey: runID)
                    return
                }
                guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.updateDraftObservation(runID, status: .unavailable, message: "Add a TypeSafe API key in Settings to observe drafts with Jev.")
                    self.draftReviewTasks.removeValue(forKey: runID)
                    return
                }
                let observation = try await reviewer.review(prompt: prompt, summary: summary, analysis: analysis, apiKey: key)
                try Task.checkCancellation()
                self.updateDraftObservation(runID, status: .completed, review: try JSONValue.encode(observation))
            } catch is CancellationError {
                self?.updateDraftObservation(runID, status: .canceled, message: "Observation canceled. The generation was kept.")
            } catch {
                // Provider bodies and credentials never enter document history.
                self?.updateDraftObservation(runID, status: .unavailable, message: "Jev review unavailable. The generation was kept.")
            }
            self?.draftReviewTasks.removeValue(forKey: runID)
        }
    }

    private func updateDraftObservation(_ id: UUID, status: DraftObservationStatus, review: JSONValue? = nil, message: String? = nil) {
        guard !closed, let index = file.generations.firstIndex(where: { $0.id == id }) else { return }
        file.generations[index].observation?.status = status
        file.generations[index].observation?.review = review
        file.generations[index].observation?.message = message
    }
}
