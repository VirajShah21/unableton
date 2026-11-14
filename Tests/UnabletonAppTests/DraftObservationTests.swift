import Foundation
import Testing
import UnabletonCore
@testable import UnabletonAI
@testable import Unableton

private actor ObservationAgent: MusicGenerating {
    func generate(song: Song, conversation: Conversation, selection: ProjectSelection, configuration: AgentConfiguration,
                  vocals: VocalSession?, preview: @escaping @Sendable (Song, Double, Double) async throws -> PreviewReport,
                  status: @escaping @Sendable (String) -> Void) async throws -> AgentResult {
        if let budget = configuration.runBudget {
            try await budget.beginRequest(limit: 32)
            try await budget.recordUsage(inputTokens: 20, outputTokens: 10)
        }
        var draft = song
        try ProjectEditor.apply([.init(op: .setTempo, value: song.tempo + 5)], to: &draft)
        return AgentResult(song: draft, summary: "Raised tempo.", model: "fixture-composer", inputTokens: 20, outputTokens: 10,
                           responseItems: [.object(["fixture": .bool(true)])], runID: UUID())
    }
}

private actor ObservationReviewer: DraftReviewing {
    enum Behavior: Sendable { case flagged, failure, slow }
    let behavior: Behavior
    private(set) var calls = 0
    private(set) var canceled = false
    init(_ behavior: Behavior = .flagged) { self.behavior = behavior }
    func review(prompt: String, summary: String, analysis: MusicalAnalysisReport, apiKey: String) async throws -> DraftReviewObservation {
        calls += 1
        if behavior == .failure { throw JevError.provider(503) }
        if behavior == .slow {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { canceled = true; throw error }
        }
        return DraftReviewObservation(model: "jev-fixture", durationSeconds: 0.01, inputTokens: 400, outputTokens: 20,
            checks: [DraftReviewCheck(criterion: .editScope, applicabilityProbability: 0.99, issueProbability: 0.99, evidenceProbability: 0.99)])
    }
}

private final class PendingObservationKey: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 2) == .success }
    func load() -> String {
        entered.signal()
        _ = release.wait(timeout: .now() + 2)
        return "fixture"
    }
}

@MainActor
private func awaitObservation(_ predicate: @MainActor () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < end else { throw JevError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct DraftObservationTests {
    private func preferences(enabled: Bool) -> UserDefaults {
        let preferences = UserDefaults(suiteName: "Unableton-Draft-Tests-\(UUID())")!
        preferences.set(enabled, forKey: DraftReviewPreferences.enabledKey)
        return preferences
    }
    private func session(_ preferences: UserDefaults, reviewer: ObservationReviewer, key: String? = "fixture-typesafe-secret") -> ProjectSession {
        ProjectSession(agent: ObservationAgent(), keyProvider: { "fixture-openai-secret" }, draftReviewer: reviewer,
                       reviewKeyProvider: { key }, reviewPreferences: preferences)
    }

    @Test func localAnalysisRunsWithoutProviderAndRetainsOldFormatCompatibility() async throws {
        let reviewer = ObservationReviewer(), session = session(preferences(enabled: false), reviewer: reviewer)
        defer { session.close() }
        session.composer = "Raise the tempo"; session.submitPrompt()
        try await awaitObservation { session.generationTask == nil }
        let record = try #require(session.file.generations.first)
        let observation = try #require(record.observation)
        #expect(observation.status == .disabled)
        #expect(observation.analysis.changes.globalFields == ["tempo"])
        #expect(observation.analysis.afterRevision == record.appliedRevision)
        #expect(record.generationRequests == 1 && record.transientRetries == 0)
        #expect(await reviewer.calls == 0)
        var legacy = try JSONValue.encode(record)
        if case .object(var fields) = legacy {
            fields.removeValue(forKey: "observation"); fields.removeValue(forKey: "generationRequests"); fields.removeValue(forKey: "transientRetries")
            legacy = .object(fields)
        }
        let decoded = try legacy.decode(GenerationRecord.self)
        #expect(decoded.observation == nil)
        #expect(decoded.id == record.id)
    }

    @Test func negativeReviewDoesNotRejectRepairOrChangeUndoAndPersists() async throws {
        let reviewer = ObservationReviewer(), session = session(preferences(enabled: true), reviewer: reviewer)
        let undo = UndoManager(); undo.groupsByEvent = false; session.undoManager = undo
        defer { session.close() }
        let before = session.file.song
        undo.beginUndoGrouping()
        session.composer = "Keep everything except tempo"; session.submitPrompt()
        try await awaitObservation { session.generationTask == nil && session.draftReviewTasks.isEmpty }
        undo.endUndoGrouping()
        let observation = try #require(session.file.generations[0].observation)
        let review = try #require(observation.review).decode(DraftReviewObservation.self)
        #expect(review.flaggedCount == 1 && observation.status == .completed)
        #expect(session.file.song.tempo == before.tempo + 5)
        #expect(session.file.song.revision == 1)
        #expect(session.errorMessage == nil)
        #expect(session.file.conversations[0].responseItems == [.object(["fixture": .bool(true)])])
        undo.undo()
        #expect(session.file.song.tempo == before.tempo)
        #expect(session.file.generations[0].isUndone)
        #expect(session.file.generations[0].observation == observation)
        #expect(!undo.canUndo)
        let decoded = try ProjectArchive.decode(ProjectArchive.encode(project: session.file, assets: [:]))
        #expect(decoded.project.generations[0].observation == observation)
        #expect(decoded.project.formatVersion == 1)
        let serialized = String(decoding: try JSONEncoder().encode(decoded.project), as: UTF8.self)
        #expect(!serialized.contains("fixture-typesafe-secret") && !serialized.contains("fixture-openai-secret"))
        undo.redo()
        #expect(session.file.song.tempo == before.tempo + 5)
    }

    @Test func reviewerFailureAndMissingKeyLeaveGenerationSuccessful() async throws {
        for key: String? in ["fixture", nil] {
            let reviewer = ObservationReviewer(.failure), session = session(preferences(enabled: true), reviewer: reviewer, key: key)
            defer { session.close() }
            session.composer = "Raise tempo"; session.submitPrompt()
            try await awaitObservation { session.generationTask == nil && session.draftReviewTasks.isEmpty }
            #expect(session.file.song.tempo == 145)
            #expect(session.file.generations[0].observation?.status == .unavailable)
            #expect(session.errorMessage == nil)
            #expect(await reviewer.calls == (key == nil ? 0 : 1))
        }
    }

    @Test func slowObserverDoesNotBlockQueuedGenerationAndClosesCleanly() async throws {
        let reviewer = ObservationReviewer(.slow), session = session(preferences(enabled: true), reviewer: reviewer)
        session.composer = "First tempo edit"; session.submitPrompt()
        session.composer = "Second tempo edit"; session.submitPrompt()
        try await awaitObservation { session.generationTask == nil && session.file.generations.count == 2 && session.draftReviewTasks.count == 2 }
        #expect(session.file.song.tempo == 150)
        #expect(session.file.generations.allSatisfy { $0.observation?.status == .pending })
        let committed = session.file.song
        session.close()
        try await awaitObservation { await reviewer.canceled }
        #expect(session.draftReviewTasks.isEmpty)
        #expect(session.file.song == committed)
        #expect(session.file.generations.allSatisfy { $0.observation?.status == .canceled })
    }

    @Test func reopeningPendingObservationDoesNotStartProviderWork() async throws {
        let preferences = preferences(enabled: true), reviewer = ObservationReviewer()
        var file = ProjectFile()
        var record = GenerationRecord(conversationID: file.conversations[0].id, model: "fixture", summary: "Done", baseRevision: 0)
        record.observation = GenerationObservation(analysis: MusicalAnalyzer.analyze(before: file.song, after: file.song, selection: .init()), status: .pending)
        file.generations = [record]
        let session = ProjectSession(file: file, draftReviewer: reviewer, reviewKeyProvider: { "fixture" }, reviewPreferences: preferences)
        defer { session.close() }
        #expect(session.file.generations[0].observation?.status == .unavailable)
        #expect(await reviewer.calls == 0)
        #expect(session.file.song == file.song)
    }

    @Test func disablingDuringCredentialLookupPreventsUpload() async throws {
        let preferences = preferences(enabled: true), reviewer = ObservationReviewer(), pending = PendingObservationKey()
        let session = ProjectSession(agent: ObservationAgent(), keyProvider: { "fixture" }, draftReviewer: reviewer,
            reviewKeyProvider: { pending.load() }, reviewPreferences: preferences)
        defer { pending.release.signal(); session.close() }
        session.composer = "Raise tempo"; session.submitPrompt()
        let entered = await Task.detached { pending.waitForEntry() }.value
        #expect(entered)
        preferences.set(false, forKey: DraftReviewPreferences.enabledKey)
        pending.release.signal()
        try await awaitObservation { session.generationTask == nil && session.draftReviewTasks.isEmpty }
        #expect(await reviewer.calls == 0)
        #expect(session.file.generations[0].observation?.status == .canceled)
        #expect(session.file.song.tempo == 145)
    }

    @Test func observationConcurrencyIsBoundedWithoutDroppingMusicalEdits() async throws {
        let reviewer = ObservationReviewer(.slow), session = session(preferences(enabled: true), reviewer: reviewer)
        defer { session.close() }
        for index in 0..<3 { session.composer = "Tempo edit \(index)"; session.submitPrompt() }
        try await awaitObservation { session.generationTask == nil && session.file.generations.count == 3 }
        #expect(session.file.song.tempo == 155)
        #expect(session.draftReviewTasks.count == 2)
        #expect(session.file.generations.last?.observation?.status == .unavailable)
        #expect(session.errorMessage == nil)
    }
}
