import SwiftUI
import UnabletonCore

struct ChatView: View {
    @ObservedObject var session: ProjectSession
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if session.currentConversation?.messages.isEmpty != false { introduction }
                    ForEach(session.currentConversation?.messages ?? []) { message in
                        messageView(message).id(message.id)
                    }
                    if session.isGenerating {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text(session.generationStatus).font(.caption).foregroundStyle(.secondary)
                        }.id("progress")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(16)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollEdgeEffectStyle(.hard, for: .vertical)
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaBar(edge: .bottom, spacing: 0) { composer }
            .onChange(of: session.currentConversation?.messages.count) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.selectedConversationID) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("AI chat")
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Menu {
                ForEach(session.file.conversations) { conversation in
                    Button { session.selectedConversationID = conversation.id } label: {
                        if conversation.id == session.selectedConversationID { Label(conversation.title, systemImage: "checkmark") }
                        else { Text(conversation.title) }
                    }
                }
            } label: { Text(session.currentConversation?.title ?? "Chat").lineLimit(1).font(.headline) }
                .menuStyle(.borderlessButton)
            Spacer(minLength: 0)
            Button { session.newConversation() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("New chat on this song").accessibilityLabel("New chat")
        }.padding(.horizontal, 14).frame(height: 42)
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe your music").font(.title3).fontWeight(.medium)
            Text("Start with a simple idea or give detailed instructions. Refine the notes, arrangement, instruments, and mix as you go.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                session.composer = "A high energy dubstep remix of Twinkle Twinkle, with a recognizable melody, heavy wobble bass, drums, a build, and a drop."
            } label: {
                Text("A high energy dubstep remix of Twinkle Twinkle")
                    .font(.callout).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered)
            Text("Each prompt edits this song. You can undo the entire change with ⌘Z.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Set Up OpenAI…") { openSettings() }.buttonStyle(.link)
        }.padding(.vertical, 12)
    }
    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == "user" ? "You" : "Unableton").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(displayText(message)).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let id = message.runID, let record = session.file.generations.first(where: { $0.id == id }) {
                HStack(spacing: 7) {
                    Label(record.appliedRevision == nil ? "Answered" : record.isUndone ? "Undone" : "Applied", systemImage: record.appliedRevision == nil ? "text.bubble" : record.isUndone ? "arrow.uturn.backward" : "checkmark.circle")
                    Spacer()
                    Text("\(record.inputTokens + record.outputTokens) tokens")
                }.font(.caption2).foregroundStyle(.secondary)
                if let observation = record.observation {
                    GenerationObservationView(observation: observation, requests: record.generationRequests, retries: record.transientRetries)
                }
            }
        }
        .padding(message.role == "user" ? 12 : 0)
        .background(message.role == "user" ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
    }
    private func displayText(_ message: ChatMessage) -> AttributedString {
        guard message.role == "assistant" else { return AttributedString(message.text) }
        return (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: session.selectedTrack == nil ? "music.note.list" : "scope")
                Text(contextLabel).lineLimit(1)
                Spacer()
                if session.selection.trackID != nil { Button { session.selection = ProjectSelection() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear selection context").accessibilityLabel("Clear selection context") }
            }.font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $session.composer)
                .font(.body).scrollContentBackground(.hidden).frame(minHeight: 70, maxHeight: 130)
                .padding(6).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Music prompt")
            HStack {
                if session.previewURL != nil { Button { session.playPreview() } label: { Image(systemName: "play.circle") }.help("Play latest preview").accessibilityLabel("Play latest preview") }
                if session.isGenerating {
                    Button("Cancel") { session.cancelGeneration() }
                    if session.queuedCount > 0 { Text("\(session.queuedCount) queued").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("⌘Return to send").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { session.submitPrompt() } label: { Label(session.isGenerating ? "Queue" : "Send", systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(session.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(12)
    }
    private var contextLabel: String {
        if let clip = session.selectedClip, let track = session.selectedTrack { return "\(track.name) · \(clip.name)" }
        if let track = session.selectedTrack { return track.name }
        return "Whole song"
    }
}
