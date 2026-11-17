import SwiftUI
import UnabletonCore

struct ChatAttachmentView: View {
    @ObservedObject var session: ProjectSession
    let attachment: SongAttachment
    var pending = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { session.playAttachment(attachment.id) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).help("Play \(attachment.fileName)")
                .accessibilityLabel("Play attached song \(session.attachmentNumber(attachment.id))")
            VStack(alignment: .leading, spacing: 3) {
                Text("Song \(session.attachmentNumber(attachment.id)) · \(attachment.fileName)").font(.caption).lineLimit(2)
                Text(session.attachmentStatus[attachment.id] ?? "\(duration) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if pending {
                Menu {
                    Button("Move Earlier") { session.movePendingAttachment(attachment.id, by: -1) }
                    Button("Move Later") { session.movePendingAttachment(attachment.id, by: 1) }
                    Button("Remove", role: .destructive) { session.removePendingAttachment(attachment.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(attachment.fileName)")
            }
            if !pending {
                Menu {
                    Button("Retry Failed Processing") { session.retryReferenceProcessing(attachment.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Processing actions for \(attachment.fileName)")
            }
        }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
    private var duration: String { "\(Int(attachment.duration) / 60):\(String(format: "%02d", Int(attachment.duration) % 60))" }
}
