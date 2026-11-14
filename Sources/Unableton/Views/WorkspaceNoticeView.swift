import SwiftUI

/// Operation feedback appears briefly without occupying a permanent status bar.
struct WorkspaceNoticeView: View {
    @ObservedObject var session: ProjectSession
    @State private var notice = ""
    @State private var noticeID = UUID()

    var body: some View {
        Group {
            if session.isExporting || !notice.isEmpty {
                HStack(spacing: 10) {
                    if session.isExporting {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Exporting audio")
                    }
                    Text(session.isExporting ? "Exporting audio…" : notice)
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if !session.isExporting {
                        Button {
                            notice = ""
                        } label: {
                            Image(systemName: "xmark").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss notice").accessibilityLabel("Dismiss notice")
                    }
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Notification")
            }
        }
        .onReceive(session.$notice) { message in
            notice = message
            // A repeated message is a new operation and gets its own timeout.
            noticeID = UUID()
        }
        .task(id: noticeID) {
            guard !notice.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(6)) }
            catch { return }
            notice = ""
        }
    }
}
